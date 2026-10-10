import Foundation
import Testing
@testable import LonghandKit

/// A stand-in for a loaded model: identity is what matters.
private final class Model: @unchecked Sendable {
    let name: String
    init(_ name: String) { self.name = name }
}

/// Counts loads, so a test can tell a cache hit from a reload.
private final class Loads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next(_ name: String) -> Model {
        lock.withLock { count += 1 }
        return Model(name)
    }
    var total: Int { lock.withLock { count } }
}

@Suite struct WarmInstanceCacheTests {

    @Test func aSecondUseIsFree() async throws {
        let cache = WarmInstanceCache<String, Model>()
        let loads = Loads()
        let first = try await cache.instance(for: "turbo") { loads.next("turbo") }
        let second = try await cache.instance(for: "turbo") { loads.next("turbo") }
        #expect(first === second)
        #expect(loads.total == 1)
        #expect(cache.warmKey == "turbo")
    }

    @Test func aDifferentKeyReplacesTheOldInstance() async throws {
        let cache = WarmInstanceCache<String, Model>()
        let loads = Loads()
        let released = Loads()
        cache.onRelease = { _ in _ = released.next("gone") }
        let turbo = try await cache.instance(for: "turbo") { loads.next("turbo") }
        let large = try await cache.instance(for: "large") { loads.next("large") }
        #expect(turbo !== large)
        #expect(cache.warmKey == "large")
        #expect(released.total == 1, "the old instance is handed to onRelease")
    }

    @Test func prewarmMakesTheNextUseReady() async throws {
        let cache = WarmInstanceCache<String, Model>()
        let loads = Loads()
        cache.prewarm("turbo") {
            try await Task.sleep(for: .milliseconds(50))
            return loads.next("turbo")
        }
        // The use arrives while the prewarm is still loading and joins it
        // rather than starting a second load.
        let model = try await cache.instance(for: "turbo") { loads.next("turbo") }
        #expect(model.name == "turbo")
        #expect(loads.total == 1)
        #expect(cache.isWarm)
    }

    @Test func releaseDropsItAndTheNextUseReloads() async throws {
        let cache = WarmInstanceCache<String, Model>()
        let loads = Loads()
        _ = try await cache.instance(for: "turbo") { loads.next("turbo") }
        await cache.release()
        #expect(!cache.isWarm)
        _ = try await cache.instance(for: "turbo") { loads.next("turbo") }
        #expect(loads.total == 2)
    }

    @Test func theIdleWindowReleasesAnUnusedInstance() async throws {
        let cache = WarmInstanceCache<String, Model>(idleWindow: .milliseconds(60))
        let loads = Loads()
        _ = try await cache.instance(for: "turbo") { loads.next("turbo") }
        #expect(cache.isWarm)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!cache.isWarm)
    }

    @Test func aUseRestartsTheIdleClock() async throws {
        let cache = WarmInstanceCache<String, Model>(idleWindow: .milliseconds(120))
        let loads = Loads()
        _ = try await cache.instance(for: "turbo") { loads.next("turbo") }
        try await Task.sleep(for: .milliseconds(80))
        _ = try await cache.instance(for: "turbo") { loads.next("turbo") }
        try await Task.sleep(for: .milliseconds(80))
        #expect(cache.isWarm, "used 80 ms ago, inside the window")
        #expect(loads.total == 1)
    }

    @Test func notRetainingPassesLoadsThroughAndIgnoresPrewarm() async throws {
        let cache = WarmInstanceCache<String, Model>()
        let loads = Loads()
        await cache.setRetaining(false)
        cache.prewarm("turbo") { loads.next("turbo") }
        try await Task.sleep(for: .milliseconds(30))
        #expect(loads.total == 0, "a prewarm while not retaining is refused")
        _ = try await cache.instance(for: "turbo") { loads.next("turbo") }
        #expect(loads.total == 1)
        #expect(!cache.isWarm, "the job got its model; nothing was kept")
        await cache.setRetaining(true)
        _ = try await cache.instance(for: "turbo") { loads.next("turbo") }
        #expect(cache.isWarm)
    }

    @Test func aFailedLoadLeavesNothingBehind() async throws {
        struct Boom: Error {}
        let cache = WarmInstanceCache<String, Model>()
        await #expect(throws: Boom.self) {
            try await cache.instance(for: "turbo") { throw Boom() }
        }
        #expect(!cache.isWarm)
        #expect(!cache.isLoading)
    }
}
