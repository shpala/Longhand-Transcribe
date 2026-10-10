import Foundation
import Observation

/// One place that knows which model is downloading and how far along, so
/// reopening Settings neither loses sight of it nor offers to start it again.
@Observable
@MainActor
public final class ModelDownloadState {
    public static let shared = ModelDownloadState()

    private var progressByVariant: [String: Double] = [:]
    /// Which download each progress callback belongs to. A callback hops to
    /// the main actor, and one still in flight when the download finished
    /// used to put the entry back after `defer` had cleared it, leaving the
    /// bar up and the buttons disabled until the next launch.
    private var tokenByVariant: [String: UInt64] = [:]
    private var nextToken: UInt64 = 0
    public var isDownloading: Bool { !progressByVariant.isEmpty }

    public func fraction(for variant: WhisperModelVariant) -> Double? {
        progressByVariant[variant.rawValue]
    }

    /// A message on failure, nil on success. A second call for a variant
    /// already downloading is ignored.
    public func download(_ variant: WhisperModelVariant) async -> String? {
        let key = variant.rawValue
        guard progressByVariant[key] == nil else { return nil }
        nextToken &+= 1
        let token = nextToken
        tokenByVariant[key] = token
        progressByVariant[key] = 0
        defer {
            progressByVariant[key] = nil
            tokenByVariant[key] = nil
        }
        do {
            try await WhisperKitEngine.prefetch(variant) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.tokenByVariant[key] == token else { return }
                    self.progressByVariant[key] = value
                }
            }
            return nil
        } catch {
            return JobLibraryModel.describe(error)
        }
    }
}
