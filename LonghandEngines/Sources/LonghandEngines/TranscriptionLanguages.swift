import Foundation
import Speech
import WhisperKit

/// A language the app can be told to transcribe, and what choosing it costs.
/// Apple's `SpeechTranscriber` covers ten languages with no download and no
/// model load; everything else routes to WhisperKit (§4.2) and its 626 MB
/// model, which a flat list of language names would misrepresent as free.
public struct TranscriptionLanguage: Identifiable, Sendable, Hashable {
    /// The code stored in `metadata.declaredLanguage`.
    public let code: String
    /// Endonym-free display name in the user's own language.
    public let name: String

    public var id: String { code }

    init(code: String) {
        self.code = code
        self.name = Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized
            ?? code.uppercased()
    }
}

/// The two groups a language picker should show, and the sentinels that are
/// not languages at all.
@MainActor
@Observable
public final class TranscriptionLanguages {

    public static let shared = TranscriptionLanguages()

    /// "No declaration; route on the device's own language". A string because
    /// it is an `@AppStorage` value in both shells.
    public static let systemSentinel = "system"
    /// §4.2's mixed-language sentinel: WhisperKit with per-window detection.
    public static let mixedSentinel = JobPipeline.autoDetectLanguage

    /// Read from the framework rather than hardcoded, so it cannot go stale
    /// when Apple adds one. Empty until `load()` has run.
    public private(set) var onDevice: [TranscriptionLanguage] = []

    /// Every language WhisperKit declares that Apple's engine does not cover,
    /// derived from `Constants.languages` so the list cannot drift from what
    /// the model does. Quality is not uniform across the set: large-v3's
    /// training data is thin at the low-resource end, so this states what the
    /// model claims rather than promising each one works well.
    ///
    /// Static, not `lazy`: `@Observable` rewrites stored properties and a lazy
    /// one cannot survive that. The set never changes at run time.
    private static let allNeedsModel: [TranscriptionLanguage] = {
        Set(Constants.languages.values)
            .subtracting(Set(knownOnDevice))
            .map(TranscriptionLanguage.init(code:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    public var needsModel: [TranscriptionLanguage] { Self.allNeedsModel }

    /// The handful shown inline, so the common case is not a scroll through
    /// 90. Seeded with the two §4.2 names, reordered by use from then on.
    public var recentModelLanguages: [TranscriptionLanguage] {
        let stored = UserDefaults.standard.string(forKey: Self.recentKey) ?? "he,ru"
        let codes = stored.split(separator: ",").map(String.init)
        let known = Set(needsModel.map(\.code))
        return codes.filter(known.contains).prefix(5).map(TranscriptionLanguage.init(code:))
    }

    static let recentKey = "recentModelLanguages"

    /// Sentinels and on-device languages are not recorded: they are already
    /// reachable without scrolling.
    public func remember(_ code: String) {
        guard needsModel.contains(where: { $0.code == code }) else { return }
        var codes = (UserDefaults.standard.string(forKey: Self.recentKey) ?? "he,ru")
            .split(separator: ",").map(String.init)
        codes.removeAll { $0 == code }
        codes.insert(code, at: 0)
        UserDefaults.standard.set(codes.prefix(5).joined(separator: ","), forKey: Self.recentKey)
    }

    /// What "Automatic" resolves to, so the picker can say it. Naming it is
    /// the only defence against the quiet failure: an English-locale phone
    /// recording Hebrew routes to Apple's engine and transcribes it as English,
    /// and nothing in §17 fires, because from the router's side nothing failed.
    public var deviceLanguage: TranscriptionLanguage {
        TranscriptionLanguage(code: Locale.current.language.languageCode?.identifier ?? "en")
    }

    /// True when "Automatic" would pick an engine that cannot hear the device's
    /// own language, which is worth saying out loud in the picker.
    public var deviceLanguageIsOnDevice: Bool {
        onDevice.contains { $0.code == deviceLanguage.code }
    }

    /// Apple's set as of iOS 26, used only when the framework reports nothing:
    /// `supportedLocales` is empty on simulators and on a device whose speech
    /// assets are not installed. Offering one the device turns out not to have
    /// is safe, since routing re-checks `supports(language:)` and degrades to
    /// WhisperKit with a recorded substitution (§17).
    static let knownOnDevice = ["de", "en", "es", "fr", "it", "ja", "ko", "pt", "yue", "zh"]

    public func load() async {
        guard onDevice.isEmpty else { return }
        let locales = await SpeechTranscriber.supportedLocales
        let reported = Set(locales.compactMap { $0.language.languageCode?.identifier })
        let codes = reported.isEmpty ? Set(Self.knownOnDevice) : reported
        onDevice = codes.map(TranscriptionLanguage.init(code:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Headers name the engine, not the location: everything is transcribed on
    /// this device (§14.2), so a header claiming it of one group implies the
    /// other sends audio somewhere. What differs is which engine runs.
    public static let onDeviceHeader = "Apple speech recognition"

    /// State-dependent, because the size is a gate rather than a property:
    /// naming the download to someone who already has it describes a cost they
    /// have paid.
    public var modelHeader: String {
        // The selected variant, not `.turbo`. Naming turbo's size while
        // Maximum accuracy is chosen would disclose 626 MB and then fetch
        // 947 MB, which is the one thing §4.2.3(ii) is about.
        WhisperKitEngine.isDownloaded(WhisperModelVariant.current)
            ? "Whisper speech model"
            : "Whisper speech model · \(Self.modelSizeDescription) download"
    }

    /// Said once under the picker, because the grouping invites exactly the
    /// wrong inference.
    public static let bothAreLocalNote = "Both run entirely on this device. Nothing is uploaded."

    /// The download the model group implies while it is still pending.
    public static var modelSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: WhisperModelVariant.current.approximateBytes,
                                  countStyle: .file)
    }

    /// Display name for whatever is currently stored, sentinels included.
    public func label(for stored: String) -> String {
        switch stored {
        case Self.systemSentinel: return "Automatic (\(deviceLanguage.name))"
        case Self.mixedSentinel: return "Mixed"
        default: return TranscriptionLanguage(code: stored).name
        }
    }
}
