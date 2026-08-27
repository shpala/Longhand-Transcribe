import Foundation
import AVFoundation
import Testing
import LonghandKit
@testable import LonghandEngines

/// A diarizer whose answer the test dictates, so the rules around the embedding
/// can be checked without Core ML or a real voice.
private struct ScriptedDiarizer: SpeakerDiarizer {
    static let engineID = "test/scripted"
    let modelIdentifier = "test/scripted-v1"
    let intervals: [SpeakerInterval]
    let centroids: [String: [Float]]?

    func diarize(_ input: AudioAsset, expectedSpeakers: Int?,
                 progress: @escaping ProgressSink) async throws -> DiarizationResult {
        DiarizationResult(engine: Self.engineID, modelIdentifier: modelIdentifier,
                          intervals: intervals, centroids: centroids)
    }
}

/// Enrolling from a deliberately recorded clip (§9.2, §9.3). This is the one
/// sample that decides whether the first call says "Me" or says it about the
/// wrong person, so the rules that refuse a bad clip matter more than the happy
/// path does.
///
/// Serialized: two cases check for leaked `enroll-*.wav` files by diffing the
/// shared temporary directory, so a sibling case's clip, still in flight, reads
/// as this one's leak.
@Suite(.serialized) struct VoiceEnrollmentTests {

    private func makeClip(seconds: Double = 12) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enroll-src-\(UUID()).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData)[0]
        for frame in 0..<Int(frames) {
            samples[frame] = 0.3 * sinf(2 * .pi * 220 * Float(frame) / 44_100)
        }
        try file.write(from: buffer)
        return url
    }

    private func speech(_ spans: [(String, Double, Double)]) -> [SpeakerInterval] {
        spans.map { SpeakerInterval(speaker: $0.0, start: $0.1, end: $0.2) }
    }

    @Test func aCleanClipYieldsTheDominantClustersEmbedding() async throws {
        let clip = try makeClip()
        defer { try? FileManager.default.removeItem(at: clip) }

        let diarizer = ScriptedDiarizer(
            intervals: speech([("SPEAKER_00", 0, 10)]),
            centroids: ["SPEAKER_00": [0.1, 0.2, 0.3]])
        let result = try await VoiceEnrollment.embed(clipURL: clip, diarizer: diarizer)

        #expect(result.embedding == [0.1, 0.2, 0.3])
        #expect(result.modelIdentifier == "test/scripted-v1")
        #expect(result.speechSeconds == 10)
    }

    /// A centroid over two seconds of speech is noise wearing a voice's
    /// clothes. Refusing is better than enrolling something that will mislabel.
    @Test func tooLittleSpeechIsRefusedWithTheNumbersInIt() async throws {
        let clip = try makeClip()
        defer { try? FileManager.default.removeItem(at: clip) }

        let diarizer = ScriptedDiarizer(
            intervals: speech([("SPEAKER_00", 0, 2)]),
            centroids: ["SPEAKER_00": [0.1]])
        await #expect(throws: VoiceEnrollment.Failure.notEnoughSpeech(
            found: 2, needed: VoiceEnrollment.minimumSpeechSeconds)) {
            try await VoiceEnrollment.embed(clipURL: clip, diarizer: diarizer)
        }
    }

    /// The clip is supposed to be one person alone. Someone else with real
    /// airtime means it is not, and enrolling the dominant cluster anyway would
    /// bake a stranger's voice into the wrong profile.
    @Test func aSecondVoiceWithRealAirtimeIsRefused() async throws {
        let clip = try makeClip()
        defer { try? FileManager.default.removeItem(at: clip) }

        let diarizer = ScriptedDiarizer(
            intervals: speech([("SPEAKER_00", 0, 10), ("SPEAKER_01", 10, 14)]),
            centroids: ["SPEAKER_00": [0.1], "SPEAKER_01": [0.9]])
        await #expect(throws: VoiceEnrollment.Failure.moreThanOneVoice) {
            try await VoiceEnrollment.embed(clipURL: clip, diarizer: diarizer)
        }
    }

    /// Diarizers emit brief spurious clusters on breaths and room noise. If any
    /// second cluster at all were disqualifying, honest clips would be rejected
    /// and the feature would read as broken.
    @Test func aBriefStrayClusterDoesNotDisqualifyAnHonestClip() async throws {
        let clip = try makeClip()
        defer { try? FileManager.default.removeItem(at: clip) }

        let diarizer = ScriptedDiarizer(
            intervals: speech([("SPEAKER_00", 0, 20), ("SPEAKER_01", 20, 20.5)]),
            centroids: ["SPEAKER_00": [0.4], "SPEAKER_01": [0.9]])
        let result = try await VoiceEnrollment.embed(clipURL: clip, diarizer: diarizer)
        #expect(result.embedding == [0.4], "the main speaker should still win")
    }

    /// A diarizer backend that exposes no centroids cannot enrol anyone, and
    /// saying so beats storing an empty embedding that matches nothing.
    @Test func aClipWithNoVoiceSignatureIsRefused() async throws {
        let clip = try makeClip()
        defer { try? FileManager.default.removeItem(at: clip) }

        let diarizer = ScriptedDiarizer(
            intervals: speech([("SPEAKER_00", 0, 10)]), centroids: nil)
        await #expect(throws: VoiceEnrollment.Failure.noEmbedding) {
            try await VoiceEnrollment.embed(clipURL: clip, diarizer: diarizer)
        }
    }

    /// §14.1: the normalised copy is derived biometric-like audio and must not
    /// outlive the embedding. It is written to the temporary directory, so a
    /// leak here is a file nobody ever deletes.
    @Test func theNormalisedCopyDoesNotOutliveTheEmbedding() async throws {
        let clip = try makeClip()
        defer { try? FileManager.default.removeItem(at: clip) }

        let temp = FileManager.default.temporaryDirectory
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])

        let diarizer = ScriptedDiarizer(
            intervals: speech([("SPEAKER_00", 0, 10)]),
            centroids: ["SPEAKER_00": [0.1]])
        _ = try await VoiceEnrollment.embed(clipURL: clip, diarizer: diarizer)

        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])
        let leaked = after.subtracting(before).filter { $0.hasPrefix("enroll-") && $0.hasSuffix(".wav") }
        #expect(leaked.isEmpty, "left behind: \(leaked)")
    }

    /// The refusal path throws before the embedding exists, which is exactly
    /// where a `defer` is easy to get wrong and leave audio on disk.
    @Test func theNormalisedCopyGoesEvenWhenEnrollmentIsRefused() async throws {
        let clip = try makeClip()
        defer { try? FileManager.default.removeItem(at: clip) }

        let temp = FileManager.default.temporaryDirectory
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])

        let diarizer = ScriptedDiarizer(
            intervals: speech([("SPEAKER_00", 0, 1)]),
            centroids: ["SPEAKER_00": [0.1]])
        _ = try? await VoiceEnrollment.embed(clipURL: clip, diarizer: diarizer)

        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [])
        let leaked = after.subtracting(before).filter { $0.hasPrefix("enroll-") && $0.hasSuffix(".wav") }
        #expect(leaked.isEmpty, "left behind: \(leaked)")
    }
}
