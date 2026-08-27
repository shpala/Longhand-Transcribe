import XCTest
@testable import LonghandKit

final class QuietBoostTests: XCTestCase {

    func testNormalSpeechIsUntouched() {
        XCTAssertNil(QuietBoost.gainDb(forPeakDb: -6))
        XCTAssertNil(QuietBoost.gainDb(forPeakDb: -12))   // trigger is exclusive
        XCTAssertNil(QuietBoost.gainDb(forPeakDb: 0))
    }

    func testQuietRecordingIsBoostedToTargetPeak() {
        // The real-world case that motivated this: peak -20 dBFS take.
        XCTAssertEqual(QuietBoost.gainDb(forPeakDb: -20), 17)
        XCTAssertEqual(QuietBoost.gainDb(forPeakDb: -30), 27)
    }

    func testBoostIsCapped() {
        XCTAssertEqual(QuietBoost.gainDb(forPeakDb: -55), QuietBoost.maxBoostDb)
    }

    func testDigitalSilenceIsNotBoosted() {
        XCTAssertNil(QuietBoost.gainDb(forPeakDb: -60))
        XCTAssertNil(QuietBoost.gainDb(forPeakDb: -120))
        XCTAssertNil(QuietBoost.gainDb(forPeakDb: -.infinity))
    }

    func testLinearGainNeverClipsAtTarget() {
        for peak in stride(from: -59.0, to: QuietBoost.peakTriggerDb, by: 0.5) {
            guard let db = QuietBoost.gainDb(forPeakDb: peak) else { continue }
            let boostedPeak = peak + db
            XCTAssertLessThanOrEqual(boostedPeak, QuietBoost.targetPeakDb + 0.001,
                                     "peak \(peak) boosted past target")
        }
    }
}
