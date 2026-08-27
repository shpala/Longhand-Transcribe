import Foundation

/// A vendored Core ML model tree on disk, and the only two questions worth
/// asking about one: is it there, and will it load.
///
/// Both vendored engines have now shipped the same bug. SpeakerKit reported a
/// tree as present while `weight.bin` was missing, and Core ML answered with
/// "Compile the model with Xcode", which reads like a build mistake. WhisperKit
/// reported a tree as present on two directory names it never opened, one of
/// the three components missing from the list entirely. Each was fixed
/// separately, the second fix largely a copy of the first, and a third vendored
/// model would have repeated it. The rule lives here once instead.
public struct ModelAsset: Sendable {

    /// What the user is told is missing, when it is.
    public let name: String
    /// Where the vendor caches the tree.
    public let root: URL
    /// Paths under `root` that must each resolve to at least one loadable
    /// compiled bundle. A component may be the `.mlmodelc` itself, as
    /// WhisperKit lays them out, or a directory the vendor nests them inside at
    /// a depth that is theirs to change, as SpeakerKit does.
    public let components: [String]

    public init(name: String, root: URL, components: [String]) {
        self.name = name
        self.root = root
        self.components = components
    }

    /// Every required component present and loadable.
    ///
    /// Names alone are not enough. Components arrive one at a time, so an
    /// interrupted download reports itself complete once the first directory
    /// lands, and a bundle whose bytes never finished still has its directory.
    /// A vendor rename makes this answer "absent", which is the safe way to be
    /// wrong: a redundant download costs bandwidth, a skipped one costs the
    /// feature.
    public var isPresent: Bool { Self.isPresent(in: root, components: components) }

    public static func isPresent(in root: URL, components: [String]) -> Bool {
        components.allSatisfy { component in
            let bundles = compiledBundles(under: root.appendingPathComponent(component))
            return !bundles.isEmpty && bundles.allSatisfy(isLoadable)
        }
    }

    public var bytesOnDisk: Int64 { Self.bytesOnDisk(of: root) }

    public static func bytesOnDisk(of folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Removes the tree so the next presence check tells the truth and the
    /// refetch is a real one rather than a no-op over the same broken files.
    public func purge() {
        try? FileManager.default.removeItem(at: root)
    }

    /// The compiled bundles a component resolves to: itself when the component
    /// is already a `.mlmodelc`, otherwise every one nested under it, at
    /// whatever depth the release happens to use.
    public static func compiledBundles(under component: URL) -> [URL] {
        if component.pathExtension == "mlmodelc" {
            return FileManager.default.fileExists(atPath: component.path) ? [component] : []
        }
        guard let walker = FileManager.default.enumerator(
            at: component, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "mlmodelc" {
            found.append(url)
            walker.skipDescendants()
        }
        return found
    }

    /// A compiled bundle Core ML will actually accept.
    ///
    /// The file names come from diffing a working install against a broken
    /// phone: one bundle was missing `model.mil`, another `coremldata.bin` as
    /// well, a third `weights/weight.bin`, while every directory and every
    /// `metadata.json` was present. Sizes are checked too, because a resumed
    /// fetch leaves the file in place at zero length rather than removing it.
    public static func isLoadable(_ bundle: URL) -> Bool {
        let fm = FileManager.default
        for name in ["coremldata.bin", "model.mil"] {
            guard isNonEmptyFile(bundle.appendingPathComponent(name)) else { return false }
        }
        // Absent is fine, since not every compiled model carries weights, but
        // present-and-empty is the signature of an interrupted fetch.
        let weights = bundle.appendingPathComponent("weights")
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: weights.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return true
        }
        let files = (try? fm.contentsOfDirectory(atPath: weights.path)) ?? []
        return files.contains { isNonEmptyFile(weights.appendingPathComponent($0)) }
    }

    static func isNonEmptyFile(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        return (size?.intValue ?? 0) > 0
    }
}
