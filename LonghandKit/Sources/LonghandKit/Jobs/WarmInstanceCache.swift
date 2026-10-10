import Foundation

/// Keeps one expensive instance (a loaded speech model) alive between the
/// jobs that need it, and knows when to let go.
///
/// The pipeline used to build a fresh model for every job and drop it after,
/// which kept memory honest and cost every job a load measured in tens of
/// seconds. This holds the instance for a short idle window after a use, can
/// start loading it before anyone asks (a take in a Whisper language is a
/// transcription a few minutes from now), and releases it when the host says
/// memory is tight or the app has left the foreground. Policy lives in the
/// host; this is the bookkeeping, kept pure so it can be tested.
///
/// One instance at a time, keyed: asking for a different key drops the old
/// one, since two speech models resident at once is the jetsam the pipeline
/// gate exists to prevent.
public final class WarmInstanceCache<Key: Hashable & Sendable, Instance: AnyObject & Sendable>: @unchecked Sendable {

    public typealias Loader = @Sendable () async throws -> Instance

    private let lock = NSLock()
    private var key: Key?
    private var instance: Instance?
    private var loading: (key: Key, task: Task<Instance, Error>)?
    /// Set while the host has asked for nothing to be kept: a use still
    /// completes, but nothing is retained afterwards.
    private var retaining = true
    private var idleTask: Task<Void, Never>?
    /// How long an unused instance stays after its last use or load.
    public var idleWindow: Duration
    /// What to do with an instance on its way out (the model's own unload),
    /// run off the lock.
    public var onRelease: (@Sendable (Instance) async -> Void)?

    public init(idleWindow: Duration = .seconds(300)) {
        self.idleWindow = idleWindow
    }

    // MARK: - Reading state

    public var isWarm: Bool {
        lock.withLock { instance != nil }
    }

    public var warmKey: Key? {
        lock.withLock { instance == nil ? nil : key }
    }

    public var isLoading: Bool {
        lock.withLock { loading != nil }
    }

    // MARK: - Use

    /// The instance for `key`, from the cache, from a load already under way,
    /// or from `loader`. Every use restarts the idle clock.
    public func instance(for key: Key, loader: @escaping Loader) async throws -> Instance {
        let (ready, inFlight) = lock.withLock { () -> (Instance?, Task<Instance, Error>?) in
            if let instance, self.key == key { return (instance, nil) }
            if let loading, loading.key == key { return (nil, loading.task) }
            return (nil, nil)
        }
        if let ready {
            touch()
            return ready
        }
        if let inFlight {
            let loaded = try await inFlight.value
            touch()
            return loaded
        }
        return try await load(key, loader: loader)
    }

    /// Starts loading `key` now so a later `instance(for:)` finds it ready.
    /// Nothing happens when it is already warm or loading, or while the host
    /// has asked for nothing to be kept.
    public func prewarm(_ key: Key, loader: @escaping Loader) {
        let skip = lock.withLock {
            !retaining || (instance != nil && self.key == key) || loading?.key == key
        }
        guard !skip else { return }
        Task { _ = try? await load(key, loader: loader) }
    }

    private func load(_ key: Key, loader: @escaping Loader) async throws -> Instance {
        let task = Task { try await loader() }
        let previous: Instance? = lock.withLock {
            // A different key on the way in: the old instance goes now, not
            // when the new one lands, so the two never overlap in memory.
            let previous = self.key == key ? nil : instance
            if previous != nil { instance = nil; self.key = nil }
            loading = (key, task)
            return previous
        }
        if let previous { await onRelease?(previous) }
        do {
            let loaded = try await task.value
            let keep = lock.withLock {
                if loading?.key == key { loading = nil }
                guard retaining else { return false }
                instance = loaded
                self.key = key
                return true
            }
            if keep {
                touch()
            }
            return loaded
        } catch {
            lock.withLock { if loading?.key == key { loading = nil } }
            throw error
        }
    }

    /// Restarts the idle clock: the instance stays `idleWindow` longer.
    public func touch() {
        let window = idleWindow
        lock.withLock {
            idleTask?.cancel()
            idleTask = Task { [weak self] in
                try? await Task.sleep(for: window)
                guard !Task.isCancelled else { return }
                await self?.release()
            }
        }
    }

    // MARK: - Letting go

    /// Drops the instance now. A load in flight completes but is not kept.
    public func release() async {
        let (gone, idle) = lock.withLock { () -> (Instance?, Task<Void, Never>?) in
            let gone = instance
            instance = nil
            key = nil
            let idle = idleTask
            idleTask = nil
            return (gone, idle)
        }
        idle?.cancel()
        if let gone { await onRelease?(gone) }
    }

    /// Whether anything is kept from now on. Off releases at once and makes
    /// later loads pass through without being retained; on restores the
    /// normal behaviour for the next use.
    public func setRetaining(_ value: Bool) async {
        lock.withLock { retaining = value }
        if !value { await release() }
    }

    public var isRetaining: Bool {
        lock.withLock { retaining }
    }
}
