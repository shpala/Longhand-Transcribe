import Foundation

/// The vendors' download staging area, which nothing else accounts for.
///
/// HuggingFace stages a fetch in `.cache/huggingface/download/` beside the
/// models it is writing, and a resumed or abandoned fetch leaves
/// `weight.bin.<sha>.incomplete` behind rather than removing it. No storage
/// figure counts that directory (`totalDiskUsage` walks job folders,
/// `downloadedBytes` walks a variant's own folder) and no code path sweeps it,
/// so an interrupted 626 MB download can sit there permanently, invisible.
public enum ModelStaging {

    /// Where HuggingFace stages, relative to the folder holding the models.
    static let stagingPath = ".cache/huggingface/download"

    /// The folders the two vendored engines write their models into.
    ///
    /// Spelled out rather than read off the engines, which live inside
    /// `#if canImport` guards and vanish in a build without the packages. A
    /// test pins these against `WhisperKitEngine.modelFolder(for:)` and
    /// `CommunityOneDiarizer.modelFolder()` so the two cannot drift apart.
    public static var vendorRoots: [URL] {
        let hub = hubRoot.appendingPathComponent("models/argmaxinc")
        return [hub.appendingPathComponent("whisperkit-coreml"),
                hub.appendingPathComponent("speakerkit-coreml")]
    }

    /// The folder every vendor download lands under, models and staging alike.
    /// Documents because that is where Argmax's hub client writes by default.
    public static var hubRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface")
    }

    /// Keeps the models out of iCloud and Time Machine backups. They are up to
    /// 1.5 GB that can be fetched again, and Apple's storage guidance says
    /// re-downloadable data must not be backed up. The flag sits on the folder,
    /// so it covers everything written beneath it later, and the folder is
    /// created first so a download in progress is never backed up either.
    ///
    /// Moving the models to Caches was the alternative and is worse: the system
    /// purges Caches under storage pressure, which would turn a 626 MB download
    /// into one that can recur without warning.
    @discardableResult
    public static func excludeFromBackup(_ root: URL = hubRoot) -> Bool {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var url = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    public static func stagingRoot(in vendorRoot: URL) -> URL {
        vendorRoot.appendingPathComponent(stagingPath)
    }

    /// Partial payloads nobody is going to resume.
    ///
    /// Only `.incomplete` files: the `.metadata` files beside them are the
    /// vendor's bookkeeping for etag checks, and deleting those would invite
    /// exactly the re-fetch this project has already been bitten by once.
    public static func abandonedPayloads(in vendorRoot: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: stagingRoot(in: vendorRoot), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "incomplete" {
            found.append(url)
        }
        return found
    }

    public static func leftoverBytes(in vendorRoot: URL) -> Int64 {
        abandonedPayloads(in: vendorRoot).reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            total += Int64(size ?? 0)
        }
    }

    /// Bytes held by partial payloads across both vendors, for the Settings
    /// storage line. Zero on a healthy install, which is the point: a number
    /// that is usually invisible is the one worth being able to see.
    public static func totalLeftoverBytes() -> Int64 {
        vendorRoots.reduce(into: Int64(0)) { $0 += leftoverBytes(in: $1) }
    }

    /// Deletes the partial payloads under a vendor root and reports what it
    /// reclaimed. Callers must only sweep a model that is already present:
    /// removing the staging of a fetch still in flight turns a resumable
    /// download into a restarted one.
    @discardableResult
    public static func sweep(in vendorRoot: URL) -> Int64 {
        var reclaimed: Int64 = 0
        for url in abandonedPayloads(in: vendorRoot) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if (try? FileManager.default.removeItem(at: url)) != nil {
                reclaimed += Int64(size)
            }
        }
        return reclaimed
    }
}
