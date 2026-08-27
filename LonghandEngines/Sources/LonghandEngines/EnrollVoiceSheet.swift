import SwiftUI
import AVFoundation
import LonghandKit

/// Recording a voice sample on purpose, rather than harvesting one from a
/// transcript (§9.2, §9.3 known-self mode).
///
/// This exists for the cold start. Enrolling from a transcript needs a
/// recording that already exists and has already been processed, so the very
/// first call cannot label "Me" however obvious it is. One clip up front fixes
/// that, and nothing else about identification changes.
///
/// The clip is a means to an embedding and never a recording: it is written to
/// the temporary directory, and it and every derived copy are deleted before
/// this sheet closes, per §14.1.
public struct EnrollVoiceSheet: View {

    public init() {}


    /// Prefilled rather than fixed. §9.3's known-self mode is what this is for,
    /// and "Me" is the label that mode reads, but nothing breaks if the owner
    /// would rather see their own name in transcripts.
    @State private var name = "Me"
    @State private var recorder = VoiceSampleRecorder()
    @State private var status: Status = .idle
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private enum Status: Equatable {
        case idle, recording, working, done(Double)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                        .accessibilityIdentifier("enroll-voice-name")
                } header: {
                    Text("Whose voice")
                } footer: {
                    Text("“Me” is what Longhand looks for when it decides which speaker in a recording is you. Any other name works too, and shows up in transcripts as written here.")
                }

                Section {
                    switch status {
                    case .idle:
                        Button {
                            start()
                        } label: {
                            Label("Start Recording", systemImage: "mic.circle.fill")
                        }
                        .disabled(!canSave)
                        .accessibilityIdentifier("enroll-voice-record")
                    case .recording:
                        HStack {
                            Text(String(format: "%.0f seconds", recorder.elapsed))
                                .font(.title2.monospacedDigit())
                            Spacer()
                            Button("Stop") { stop() }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                        }
                    case .working:
                        HStack {
                            ProgressView()
                            Text("Reading the recording").foregroundStyle(.secondary)
                        }
                    case let .done(seconds):
                        Label(String(format: "Enrolled from %.0f seconds of speech", seconds),
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("Voice sample")
                } footer: {
                    Text("Talk for about twenty seconds: read anything aloud, or say what you did today. Somewhere quiet, with nobody else speaking. The recording is used to work out your voice signature and is deleted immediately afterwards; it is never saved as a recording and never leaves this device.")
                }
            }
            .navigationTitle("Record My Voice")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .interactiveDismissDisabled(status == .recording || status == .working)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                        .disabled(status == .working)
                }
            }
            .alert("Couldn't Enroll That Recording",
                   isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func start() {
        status = .recording
        Task {
            if await recorder.start() == false {
                status = .idle
                error = "The microphone did not start. Close anything else using it and try again."
                return
            }
            // Auto-stops so nobody has to guess how long is enough, and so a
            // sheet left open does not sit there recording the room.
            await recorder.waitUntilFull()
            if status == .recording { stop() }
        }
    }

    private func stop() {
        status = .working
        Task {
            guard let clip = await recorder.stop() else {
                status = .idle
                error = "That recording could not be read back."
                return
            }
            // §14.1: the clip goes whatever happens next.
            defer { try? FileManager.default.removeItem(at: clip) }
            do {
                let enrolled = try await VoiceEnrollment.embed(clipURL: clip)
                SpeakerProfileStore.enroll(displayName: name.trimmingCharacters(in: .whitespaces),
                                           embedding: enrolled.embedding,
                                           modelIdentifier: enrolled.modelIdentifier)
                status = .done(enrolled.speechSeconds)
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            } catch {
                status = .idle
                self.error = JobLibraryModel.describe(error)
            }
        }
    }

    private func cancel() {
        Task {
            if let clip = await recorder.stop() {
                try? FileManager.default.removeItem(at: clip)
            }
            dismiss()
        }
    }
}

/// A microphone for one clip, deliberately not `RecorderService`: that one owns
/// takes, writes into the library, and hands off to the pipeline, none of which
/// should happen for audio that is about to be deleted.
@MainActor
@Observable
public final class VoiceSampleRecorder {

    public init() {}


    /// Long enough to clear `VoiceEnrollment.minimumSpeechSeconds` with room
    /// for the pauses in ordinary speech, short enough that nobody has to be
    /// told to stop.
    public static let limit: TimeInterval = 25

    public private(set) var elapsed: TimeInterval = 0
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var ticker: Task<Void, Never>?

    public func start() async -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-sample-\(UUID().uuidString).m4a")
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            #endif
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            guard recorder.record() else { return false }
            self.recorder = recorder
            self.url = url
            elapsed = 0
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    self.elapsed = self.recorder?.currentTime ?? self.elapsed
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Returns once the clip has run its length, so the caller does not have to
    /// poll `elapsed` itself.
    public func waitUntilFull() async {
        while let recorder, recorder.isRecording, recorder.currentTime < Self.limit {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    public func stop() async -> URL? {
        ticker?.cancel()
        ticker = nil
        recorder?.stop()
        recorder = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        defer { url = nil }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
