import AppIntents
import Foundation
import UniformTypeIdentifiers
import LonghandKit
import LonghandEngines

// Siri, Shortcuts and the Action Button, for the iOS and Mac apps alike: the
// Mac target compiles this file too. Start Recording lives beside the Live
// Activity code because the Control Center control names it; everything here
// runs only in an app.

/// The one library model each app has.
@MainActor
private enum IntentHost {
    static var library: JobLibraryModel {
        #if os(macOS)
        MacLibrary.model
        #else
        AppLibrary.model
        #endif
    }
}

/// Phrases Siri understands with no setup, and the actions offered when the
/// Action Button is set to a shortcut.
struct LonghandShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Start recording with \(.applicationName)",
                              "Record with \(.applicationName)",
                              "New \(.applicationName) recording"],
                    shortTitle: "Start Recording",
                    systemImageName: "mic.fill")
        AppShortcut(intent: SaveRecordingIntent(),
                    phrases: ["Stop recording with \(.applicationName)",
                              "Save the \(.applicationName) recording"],
                    shortTitle: "Stop Recording",
                    systemImageName: "stop.circle")
        AppShortcut(intent: OpenRecordingIntent(),
                    phrases: ["Open a recording in \(.applicationName)"],
                    shortTitle: "Open Recording",
                    systemImageName: "waveform")
        AppShortcut(intent: GetTranscriptIntent(),
                    phrases: ["Get a transcript from \(.applicationName)"],
                    shortTitle: "Get Transcript",
                    systemImageName: "text.quote")
    }
}

// MARK: - Recording

/// Stops the take in progress and saves it, as Stop & Save does. Runs without
/// opening the app: the take is already running there.
struct SaveRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the recording in progress and saves it for transcription.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard LiveRecordingControls.handler != nil else {
            throw LonghandIntentError.notRecording
        }
        await LiveRecordingControls.send(.stop)
        return .result(dialog: "Saved. Longhand is transcribing it.")
    }
}

/// Imports an audio or video file and transcribes it with the default language
/// and speaker settings, as a file shared from another app is.
struct TranscribeFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Transcribe Audio File"
    static let description = IntentDescription("Adds an audio or video file to Longhand and transcribes it on this device.")
    // The transcription runs for minutes; the app has to be there for it.
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "File", supportedContentTypes: [.audio, .movie])
    var file: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = file.filename.isEmpty ? "Recording" : file.filename
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try file.data.write(to: url)

        let defaults = UserDefaults.standard
        let language = defaults.string(forKey: "defaultImportLanguage") ?? "system"
        let speakers = defaults.integer(forKey: "defaultSpeakerCount")
        IntentHost.library.importRecording(
            from: url,
            securityScoped: false,
            deleteSourceAfterImport: true,
            declaredLanguage: language == "system" ? nil : language,
            expectedSpeakerCount: speakers == 0 ? nil : speakers)
        return .result(dialog: "Transcribing \(name).")
    }
}

// MARK: - Recordings as entities

/// A recording in the library, for Shortcuts to pick, search and pass along.
/// Carries the title and date only: the transcript leaves the app through Get
/// Transcript, which asks first.
struct RecordingEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Recording"
    static let defaultQuery = RecordingQuery()

    let id: UUID
    let title: String
    let date: Date

    init(_ record: JobRecord) {
        id = record.id
        title = record.title
        date = record.createdAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: "\(date.formatted(date: .abbreviated, time: .shortened))")
    }
}

/// Searches titles and transcript text the way the library's search field
/// does, accents, Hebrew niqqud and all.
struct RecordingQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [RecordingEntity] {
        let wanted = Set(identifiers)
        return JobStore.allJobs().map(\.record).filter { wanted.contains($0.id) }.map(RecordingEntity.init)
    }

    func entities(matching string: String) async throws -> [RecordingEntity] {
        let jobs = JobStore.allJobs().map(\.record)
        guard let results = await LibrarySearch().results(for: string, in: jobs) else {
            return jobs.map(RecordingEntity.init)
        }
        let matched = Set(results.map(\.jobID))
        return jobs.filter { matched.contains($0.id) }.map(RecordingEntity.init)
    }

    func suggestedEntities() async throws -> [RecordingEntity] {
        JobStore.allJobs().map(\.record).prefix(20).map(RecordingEntity.init)
    }
}

struct OpenRecordingIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Recording"
    static let description = IntentDescription("Opens a recording's transcript in Longhand.")

    @Parameter(title: "Recording")
    var target: RecordingEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRequests.shared.openRecording = target.id
        return .result()
    }
}

/// The transcript as plain text, for a shortcut to pass on. Handing it to
/// whatever the shortcut does next is an export like any other (§14.1), so it
/// asks first, every time.
struct GetTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Transcript"
    static let description = IntentDescription("Returns a recording's transcript as text, with speaker names.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Recording")
    var recording: RecordingEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let files = JobStore.files(for: recording.id)
        guard let text = try? String(contentsOf: files.transcriptText, encoding: .utf8) else {
            throw LonghandIntentError.notTranscribed(recording.title)
        }
        try await requestConfirmation(
            actionName: .share,
            dialog: "Share the transcript of “\(recording.title)” with this shortcut? It leaves on-device processing.")
        return .result(value: text)
    }
}

enum LonghandIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRecording
    case notTranscribed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRecording:
            "Longhand isn't recording."
        case .notTranscribed(let title):
            "“\(title)” hasn't been transcribed yet."
        }
    }
}
