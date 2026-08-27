import Foundation
import Testing
@testable import LonghandKit

private let model = "speakerkit/pyannote-community-1"

private func profile(_ name: String, _ embeddings: [[Float]], model modelID: String = model) -> SpeakerProfile {
    SpeakerProfile(displayName: name, modelIdentifier: modelID, embeddings: embeddings,
                   createdAt: .distantPast, updatedAt: .distantPast)
}

/// Unit vectors at controlled angles make similarity values predictable.
private func vec(_ angle: Double) -> [Float] {
    [Float(cos(angle)), Float(sin(angle)), 0, 0]
}

@Suite struct SpeakerMatcherTests {

    @Test func clearMatchIsClaimed() {
        let me = profile("Me", [vec(0)])
        let result = SpeakerMatcher.match(
            centroids: ["SPEAKER_00": vec(0.1),      // cos ≈ 0.995 to "Me"
                        "SPEAKER_01": vec(1.4)],     // cos ≈ 0.17 to "Me"
            profiles: [me], modelIdentifier: model)
        #expect(result.matches.count == 1)
        #expect(result.matches["SPEAKER_00"]?.displayName == "Me")
        #expect(result.matches["SPEAKER_01"] == nil)
    }

    @Test func belowFloorClaimsNothing() {
        let me = profile("Me", [vec(0)])
        let result = SpeakerMatcher.match(
            centroids: ["SPEAKER_00": vec(1.2), "SPEAKER_01": vec(1.5)],
            profiles: [me], modelIdentifier: model)
        #expect(result.matches.isEmpty)
    }

    @Test func ambiguousClustersClaimNothing() {
        // §9.3: both clusters score within a small delta of each other,
        // assign neither.
        let me = profile("Me", [vec(0)])
        let result = SpeakerMatcher.match(
            centroids: ["SPEAKER_00": vec(0.20), "SPEAKER_01": vec(0.24)],
            profiles: [me], modelIdentifier: model)
        #expect(result.matches.isEmpty)
    }

    @Test func crossModelEmbeddingsAreIgnored() {
        let stale = profile("Me", [vec(0)], model: "titanet-large")
        let result = SpeakerMatcher.match(
            centroids: ["SPEAKER_00": vec(0)],
            profiles: [stale], modelIdentifier: model)
        #expect(result.matches.isEmpty)
    }

    @Test func multiSampleEnrollmentUsesBestSample() {
        // The close sample (0.15 rad) rescues a profile whose other sample is far.
        let me = profile("Me", [vec(2.5), vec(0.15)])
        let result = SpeakerMatcher.match(
            centroids: ["SPEAKER_00": vec(0), "SPEAKER_01": vec(1.6)],
            profiles: [me], modelIdentifier: model)
        #expect(result.matches["SPEAKER_00"]?.displayName == "Me")
    }

    @Test func noDoubleAssignment() {
        // Two profiles, one cluster near both: the cluster goes to the closer
        // profile only if the margin holds; the other profile claims nothing.
        let a = profile("A", [vec(0)])
        let b = profile("B", [vec(0.05)])
        let result = SpeakerMatcher.match(
            centroids: ["SPEAKER_00": vec(0.02)],
            profiles: [a, b], modelIdentifier: model)
        // Profiles are ~0.999 vs ~0.9996 similar, inside the margin → no claim.
        #expect(result.matches.isEmpty)
    }

    @Test func distinctProfilesBothMatch() {
        let a = profile("A", [vec(0)])
        let b = profile("B", [vec(1.5)])
        let result = SpeakerMatcher.match(
            centroids: ["SPEAKER_00": vec(0.05), "SPEAKER_01": vec(1.45)],
            profiles: [a, b], modelIdentifier: model)
        #expect(result.matches["SPEAKER_00"]?.displayName == "A")
        #expect(result.matches["SPEAKER_01"]?.displayName == "B")
    }

    @Test func matcherIsDeterministic() {
        let a = profile("A", [vec(0)])
        let b = profile("B", [vec(1.5)])
        let centroids = ["SPEAKER_00": vec(0.05), "SPEAKER_01": vec(1.45), "SPEAKER_02": vec(3.0)]
        let first = SpeakerMatcher.match(centroids: centroids, profiles: [a, b], modelIdentifier: model)
        for _ in 0..<10 {
            #expect(SpeakerMatcher.match(centroids: centroids, profiles: [a, b], modelIdentifier: model) == first)
        }
    }

    @Test func enrollmentCleanlinessRespectsOverlapFraction() {
        func turn(_ id: Int, _ start: Double, _ end: Double, overlapped: Bool) -> Transcript.Turn {
            .init(id: id, cluster: "SPEAKER_00", speaker: "S", start: start, end: end,
                  overlapped: overlapped, text: "")
        }
        // 10% overlapped → clean.
        #expect(SpeakerMatcher.isCleanForEnrollment(clusterTurns: [
            turn(0, 0, 9, overlapped: false), turn(1, 9, 10, overlapped: true),
        ]))
        // 50% overlapped → not clean (§8.2 hard rule).
        #expect(!SpeakerMatcher.isCleanForEnrollment(clusterTurns: [
            turn(0, 0, 5, overlapped: false), turn(1, 5, 10, overlapped: true),
        ]))
        // No speech at all → never enroll.
        #expect(!SpeakerMatcher.isCleanForEnrollment(clusterTurns: []))
    }
}
