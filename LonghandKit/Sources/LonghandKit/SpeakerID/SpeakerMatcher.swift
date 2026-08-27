import Foundation

/// Deterministic cluster-to-person matching over diarizer centroids (§9.3,
/// generalized to any number of enrolled people).
///
/// A margin is required, not just a winner: a cluster is claimed only when its
/// best profile clears the score floor and beats both every other cluster
/// competing for that profile and the runner-up profile for that cluster.
/// Anything less keeps the generic label, since a confidently wrong "Me" is
/// the worst output this stage can produce.
public enum SpeakerMatcher {

    public struct Config: Sendable, Equatable {
        /// Minimum cosine similarity to consider a claim. Measured on device
        /// against Community-1 pre-PLDA centroids (Aug 2026): the same voice
        /// across recordings scores ≈0.57-0.72, different voices ≈0.38-0.53,
        /// and clusters split from one voice within a recording ≈0.80-1.0,
        /// which the margin rule turns into a refusal. Calibrated from a
        /// handful of samples; §18.2's calibration test is the proper source.
        public var scoreFloor: Double
        /// Required similarity gap over the runner-up (both directions).
        public var margin: Double

        public init(scoreFloor: Double = 0.55, margin: Double = 0.05) {
            self.scoreFloor = scoreFloor
            self.margin = margin
        }
    }

    /// - Parameters:
    ///   - centroids: per-cluster embeddings from the diarizer.
    ///   - profiles: enrolled people; entries whose `modelIdentifier` differs
    ///     from `modelIdentifier` are ignored, because cross-model embeddings are
    ///     not comparable (§13.2).
    public static func match(centroids: [String: [Float]],
                             profiles: [SpeakerProfile],
                             modelIdentifier: String,
                             config: Config = Config()) -> IdentityResult {
        let comparable = profiles.filter { $0.modelIdentifier == modelIdentifier && !$0.embeddings.isEmpty }
        var matches: [String: IdentityMatch] = [:]

        guard !comparable.isEmpty, !centroids.isEmpty else {
            return IdentityResult(engine: "centroid-cosine", modelIdentifier: modelIdentifier,
                                  scoreFloor: config.scoreFloor, margin: config.margin, matches: matches)
        }

        // Score every (cluster, profile) pair: max similarity over the
        // profile's enrolled embeddings (§9.2 multi-sample enrollment).
        struct Pair { let cluster: String; let profile: SpeakerProfile; let score: Double }
        var pairs: [Pair] = []
        for (cluster, centroid) in centroids {
            for profile in comparable {
                let score = profile.embeddings
                    .map { cosineSimilarity($0, centroid) }
                    .max() ?? -1
                pairs.append(Pair(cluster: cluster, profile: profile, score: score))
            }
        }
        // Deterministic order: best score first, ties broken by IDs.
        pairs.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.cluster != $1.cluster { return $0.cluster < $1.cluster }
            return $0.profile.id.uuidString < $1.profile.id.uuidString
        }

        var claimedClusters = Set<String>()
        var claimedProfiles = Set<UUID>()
        for pair in pairs {
            guard pair.score >= config.scoreFloor,
                  !claimedClusters.contains(pair.cluster),
                  !claimedProfiles.contains(pair.profile.id) else { continue }

            // Margin vs. the best OTHER cluster for this profile (§9.3: if
            // both clusters score within a small delta, assign neither).
            let bestOtherCluster = pairs
                .filter { $0.profile.id == pair.profile.id && $0.cluster != pair.cluster && !claimedClusters.contains($0.cluster) }
                .map(\.score).max() ?? -1
            // Margin vs. the runner-up profile for this cluster.
            let bestOtherProfile = pairs
                .filter { $0.cluster == pair.cluster && $0.profile.id != pair.profile.id && !claimedProfiles.contains($0.profile.id) }
                .map(\.score).max() ?? -1

            guard pair.score - bestOtherCluster >= config.margin,
                  pair.score - bestOtherProfile >= config.margin else { continue }

            matches[pair.cluster] = IdentityMatch(personID: pair.profile.id.uuidString,
                                                  displayName: pair.profile.displayName,
                                                  score: pair.score,
                                                  margin: pair.score - max(bestOtherCluster, bestOtherProfile))
            claimedClusters.insert(pair.cluster)
            claimedProfiles.insert(pair.profile.id)
        }

        return IdentityResult(engine: "centroid-cosine", modelIdentifier: modelIdentifier,
                              scoreFloor: config.scoreFloor, margin: config.margin, matches: matches)
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in 0..<a.count {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return -1 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// §8.2 hard rule support: a cluster is safe to enroll from only when its
    /// speech is not dominated by overlapped regions.
    public static func isCleanForEnrollment(clusterTurns: [Transcript.Turn],
                                            maxOverlappedFraction: Double = 0.2) -> Bool {
        let total = clusterTurns.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        guard total > 0 else { return false }
        let overlapped = clusterTurns.filter(\.overlapped).reduce(0.0) { $0 + max(0, $1.end - $1.start) }
        return overlapped / total <= maxOverlappedFraction
    }
}
