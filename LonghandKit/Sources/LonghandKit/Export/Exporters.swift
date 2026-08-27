import Foundation

/// Derived-format exporters (§2.1, §15.4, §8.2). JSON is canonical; these are
/// projections. The overlap flag is never silently dropped: formats that can
/// carry a marker do. Subtitle formats (SRT, WebVTT) were dropped by owner
/// decision; see docs/IMPLEMENTATION.md.
public enum TranscriptExporter {

    public static let overlapMarker = "[overlap]"

    // MARK: - Timestamps

    static func hms(_ t: TimeInterval) -> String {
        let total = Int(t.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    // MARK: - Formats

    public static func text(_ transcript: Transcript) -> String {
        transcript.turns.map { turn in
            let overlap = turn.overlapped ? " \(overlapMarker)" : ""
            return "[\(hms(turn.start))] \(turn.speaker):\(overlap) \(BidiText.isolatedForExport(turn.text))"
        }
        .joined(separator: "\n")
        + "\n"
    }

    public static func markdown(_ transcript: Transcript) -> String {
        var lines: [String] = []
        var pendingMarkers = (transcript.markers ?? []).sorted { $0.time < $1.time }
        for turn in transcript.turns {
            // Markdown is the one export with room for markers.
            while let marker = pendingMarkers.first, marker.time <= turn.start {
                lines.append(markerLine(marker))
                lines.append("")
                pendingMarkers.removeFirst()
            }
            let overlap = turn.overlapped ? " *(overlapping)*" : ""
            lines.append("**\(BidiText.isolatedForExport(turn.speaker))** · \(hms(turn.start))\(overlap)")
            lines.append("")
            lines.append(BidiText.isolatedForExport(turn.text))
            lines.append("")
        }
        for marker in pendingMarkers {
            lines.append(markerLine(marker))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func markerLine(_ marker: Transcript.Marker) -> String {
        let label = marker.label.map { " \(BidiText.isolatedForExport($0))" } ?? ""
        return "*\(hms(marker.time)) ·\(label.isEmpty ? " marker" : label)*"
    }

    public static func canonicalJSON(_ transcript: Transcript) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(transcript)
    }

    /// Writes every export format next to the canonical JSON (§10.1). Never
    /// includes speaker embeddings (§14.1).
    ///
    /// Not a pure function of `transcript`: it reads `files.overlay` and
    /// applies the user's names, corrections, reassignments and markers first,
    /// so no export path can drop what someone typed. The pure part is
    /// `UserOverlay.apply(to:)`.
    ///
    /// Returns the edits that could not be reattached, so the caller can say so
    /// (§17). A corrupt overlay throws rather than being skipped: losing user
    /// text quietly is worth failing an export over.
    @discardableResult
    public static func writeAll(_ transcript: Transcript, to files: JobFiles) throws -> UserOverlay.ApplyResult {
        let overlay = try AtomicFile.readJSON(UserOverlay.self, from: files.overlay, stage: "overlay")
        let result = overlay?.applyReportingStale(to: transcript)
            ?? UserOverlay.ApplyResult(transcript: transcript, staleEdits: [])
        let final = result.transcript

        try AtomicFile.write(try canonicalJSON(final), to: files.transcriptJSON)
        try AtomicFile.write(Data(text(final).utf8), to: files.transcriptText)
        try AtomicFile.write(Data(markdown(final).utf8), to: files.transcriptMarkdown)
        return result
    }
}
