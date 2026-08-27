import Foundation

/// Names for recordings made inside the app.
///
/// An imported file keeps the name it arrived with; that name is usually
/// meaningful to whoever made it. A take recorded in the app has no such name,
/// and used to inherit the temp file's, which is how the library ended up
/// listing `mac-take-31B0E9C5-9D89-4591-9DEF-61E6DA6E079C`. A date is not a
/// great title either, but it is one a person can recognise, and it is
/// renameable.
public enum RecordingTitle {

    /// e.g. "19 Aug 2026 at 19:42", or "Watch · 19 Aug 2026 at 19:42".
    public static func forTake(at date: Date = Date(), source: Source = .thisDevice) -> String {
        let stamp = date.formatted(date: .abbreviated, time: .shortened)
        guard let prefix = source.prefix else { return stamp }
        return "\(prefix) · \(stamp)"
    }

    public enum Source: Sendable {
        case thisDevice
        case watch

        var prefix: String? {
            switch self {
            case .thisDevice: nil
            case .watch: String(localized: "Watch")
            }
        }
    }
}
