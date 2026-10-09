import UIKit
import UserNotifications

/// Tells the user when a take stops without them: a call took the
/// microphone, the disk filled, the encoder failed. The Live Activity shows
/// the same on the Lock Screen, but a card that quietly changed from
/// "Recording" to "Interrupted" is easy to miss in a pocket, and a
/// notification makes a sound.
///
/// Nothing is posted while the app is in front: the sheet is already saying
/// it. Permission is asked for once, at the first take, after the microphone,
/// and never under a UI test, where the system alert would block the run.
@MainActor
enum TakeNotifier {

    private static let identifier = "take-stopped"
    private static let askedKey = "takeNotificationsRequested"

    /// Asks once. Declining is remembered by the system; a user who said no
    /// is not asked again, and the take goes on as before.
    static func requestAuthorizationIfNeeded() async {
        guard !UITestSupport.isUITestRun else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: askedKey) else { return }
        defaults.set(true, forKey: askedKey)
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    enum Reason {
        case interrupted
        case halted(String?)

        var title: String {
            switch self {
            case .interrupted: "Recording interrupted"
            case .halted: "Recording stopped"
            }
        }

        var body: String {
            switch self {
            case .interrupted:
                return "Something took the microphone. Open Longhand to resume, or stop and save what you have."
            case let .halted(detail):
                let detail = detail.map { $0 + " " } ?? ""
                return "\(detail)The take so far is safe. Open Longhand to save it."
            }
        }
    }

    /// Posted only when the app is not in front. Replaces any earlier one,
    /// so a take interrupted twice shows one notification.
    static func takeStopped(_ reason: Reason) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = reason.title
        content.body = reason.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The take resumed or ended: the notification no longer describes
    /// anything.
    static func clear() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
