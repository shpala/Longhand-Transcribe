import Foundation

/// Third-party attributions required for distribution (§4.3 audit): MIT
/// (Argmax OSS, Whisper weights), Apache 2.0 (swift-transformers portions),
/// CC BY 4.0 (pyannote Community-1; attribution is a licence condition, not
/// a courtesy). The texts ship as resources of this package, so every shell
/// that links the engines gets the same set without copying files around.
public nonisolated enum Acknowledgments {

    public struct Entry: Identifiable, Sendable {
        public let id: String        // bundled resource name
        public let title: String
        public let subtitle: String
    }

    public static let entries: [Entry] = [
        Entry(id: "ArgmaxOSS-MIT",
              title: "Argmax OSS (WhisperKit & SpeakerKit)",
              subtitle: "MIT License · argmax, inc."),
        Entry(id: "Whisper-MIT",
              title: "OpenAI Whisper model",
              subtitle: "MIT License · OpenAI"),
        Entry(id: "Pyannote-CC-BY-4.0",
              title: "pyannote speaker-diarization-community-1",
              subtitle: "CC BY 4.0 · pyannote / pyannoteAI"),
        Entry(id: "SwiftTransformers-Apache-2.0",
              title: "swift-transformers (portions)",
              subtitle: "Apache License 2.0 · Hugging Face"),
    ]

    /// The licence text, or an honest placeholder, never a silent blank.
    public static func licenseText(for resource: String) -> String {
        let url = Bundle.module.url(forResource: resource, withExtension: "txt", subdirectory: "Licenses")
            ?? Bundle.module.url(forResource: resource, withExtension: "txt")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "License text missing from bundle; see the project repository."
        }
        return text
    }
}
