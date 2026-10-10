import Foundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// Asks the real on-device model for a summary and checks that the title it
/// writes beside it is one a library row can carry. Skips wherever Apple
/// Intelligence is not available, which includes CI, so this is a check to
/// run on a Mac that has it rather than a guard that runs everywhere.
@Suite struct SummaryTitleModelTests {

    @Test func theModelWritesAUsableTitle() async throws {
        guard TranscriptSummarizer.deviceAvailability.isAvailable else { return }
        let lines: [(String, String)] = [
            ("Dana", "We said we would come back to the onboarding screen once the copy was settled, so let us start there."),
            ("Noam", "The copy is settled. What is not settled is whether the permission prompt comes before or after the first recording."),
            ("Dana", "Before. If someone taps record and then gets asked for the microphone, the first take is already half lost."),
            ("Noam", "Asking on a screen that has not explained anything yet is exactly the prompt people deny."),
            ("Dana", "So we explain first and ask second, on the same screen. One sentence about what the app does, then the button."),
            ("Noam", "Agreed. I will draft the sentence today and we review it tomorrow morning."),
        ]
        let transcript = Transcript(
            recordingID: "TITLE-1", sourceHash: "cafe", duration: 60, language: "en",
            pipelineVersion: Transcript.currentPipelineVersion,
            models: .init(asr: "test/fixture"),
            mergeParams: .init(boundaryToleranceMs: 250, turnGapSeconds: 1.0),
            speakers: ["SPEAKER_00": .init(displayName: "Dana"), "SPEAKER_01": .init(displayName: "Noam")],
            turns: lines.enumerated().map { index, line in
                .init(id: index, cluster: line.0 == "Dana" ? "SPEAKER_00" : "SPEAKER_01",
                      speaker: line.0, start: Double(index * 8), end: Double(index * 8 + 6),
                      overlapped: false, text: line.1)
            })
        let summary = try await TranscriptSummarizer.summarize(transcript, title: nil)
        let title = try #require(summary.title)
        #expect(!title.isEmpty && title.count <= TranscriptSummary.maximumTitleLength)
        #expect(!title.contains("\n"))
        #expect(!title.hasSuffix("."))
        // A title names the subject, not the kind of thing it is.
        for generic in ["Recording", "Conversation", "Meeting", "Summary"] {
            #expect(title.localizedCaseInsensitiveCompare(generic) != .orderedSame)
        }
        print("generated title: \(title)")
    }
}
