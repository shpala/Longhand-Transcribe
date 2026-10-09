import Foundation
import OSLog
import WidgetKit
import LonghandKit
import LonghandEngines

/// Keeps the Home Screen widget's snapshot in step with the library. Written
/// on every refresh, but the widget is only asked to redraw when something it
/// shows has changed: a reload per progress tick would be a reload storm.
@MainActor
enum WidgetBridge {

    private static var last: [WidgetSnapshot.Recording]?
    private static let log = Logger(subsystem: "com.shpala.Longhand", category: "widget")

    static func publish(_ jobs: [JobRecord]) {
        let recordings = jobs.prefix(WidgetSnapshot.limit).map { job in
            WidgetSnapshot.Recording(id: job.id, title: job.title, date: job.createdAt,
                                     status: status(of: job), duration: job.duration)
        }
        guard recordings != last else { return }
        last = recordings
        guard WidgetSnapshot.fileURL != nil else {
            log.error("no App Group container; the widget cannot see the library")
            return
        }
        do {
            try WidgetSnapshot(recordings: Array(recordings), updatedAt: Date()).write()
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshot.kind)
            log.info("published \(recordings.count) recordings to the widget")
        } catch {
            // The widget keeps showing the previous library; nothing here is
            // worth an alert.
            log.error("writing the widget snapshot failed: \(error.localizedDescription)")
        }
    }

    private static func status(of job: JobRecord) -> WidgetSnapshot.Status {
        switch job.state {
        case .complete: .complete
        case .failed: .failed
        case .interrupted: job.isPaused ? .paused : .working
        default: .working
        }
    }
}
