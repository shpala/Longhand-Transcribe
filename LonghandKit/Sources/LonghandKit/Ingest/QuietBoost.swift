import Foundation

/// Gain policy for very quiet recordings (§5.4 addition). Whisper-family
/// models return zero segments on ~-36 dBFS speech rather than erroring, so
/// a whole-take that quiet reads as "Complete, no words", so boosting the
/// transient normalized PCM (never the retained original) recovers it.
/// Peak-referenced so the boost can never clip.
public enum QuietBoost {

    /// Boost only when the loudest sample is below this. Normal speech
    /// peaks well above it, so ordinary recordings are untouched.
    public static let peakTriggerDb = -12.0
    /// Post-boost peak target; the safety margin below full scale.
    public static let targetPeakDb = -3.0
    /// Cap so a near-silent noise floor is not amplified into loud hiss.
    public static let maxBoostDb = 30.0
    /// Below this peak there is no signal worth recovering; boosting would
    /// only manufacture noise (and a misleading "boosted" note).
    public static let silenceFloorDb = -60.0

    /// Gain in dB to apply to a recording whose loudest sample is `peakDb`
    /// dBFS, or nil when no boost is warranted.
    public static func gainDb(forPeakDb peakDb: Double) -> Double? {
        guard peakDb.isFinite, peakDb < peakTriggerDb, peakDb > silenceFloorDb else { return nil }
        return min(targetPeakDb - peakDb, maxBoostDb)
    }

    public static func linearGain(forDb db: Double) -> Double {
        pow(10, db / 20)
    }
}
