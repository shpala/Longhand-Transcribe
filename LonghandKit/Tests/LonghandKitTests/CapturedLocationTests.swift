import XCTest
@testable import LonghandKit

final class CapturedLocationTests: XCTestCase {

    func testParsesIOSStyleISO6709WithAltitude() {
        let loc = CapturedLocation.parseISO6709("+32.0853+034.7818+000.000/")
        XCTAssertEqual(loc?.latitude ?? 0, 32.0853, accuracy: 1e-9)
        XCTAssertEqual(loc?.longitude ?? 0, 34.7818, accuracy: 1e-9)
    }

    func testParsesNegativeCoordinatesWithoutAltitude() {
        let loc = CapturedLocation.parseISO6709("-33.8688+151.2093/")
        XCTAssertEqual(loc?.latitude ?? 0, -33.8688, accuracy: 1e-9)
        XCTAssertEqual(loc?.longitude ?? 0, 151.2093, accuracy: 1e-9)
        XCTAssertNotNil(CapturedLocation.parseISO6709("+40.7128-074.0060"))
    }

    func testRejectsGarbageAndOutOfRange() {
        XCTAssertNil(CapturedLocation.parseISO6709(""))
        XCTAssertNil(CapturedLocation.parseISO6709("not a location"))
        XCTAssertNil(CapturedLocation.parseISO6709("+95.0+034.0/"))    // lat > 90
        XCTAssertNil(CapturedLocation.parseISO6709("+32.0+190.0/"))    // lon > 180
        XCTAssertNil(CapturedLocation.parseISO6709("+32.0/"))          // lat only
    }

    func testMetadataRoundTripsLocationAndOldFilesDecodeWithoutIt() throws {
        var metadata = ImportMetadata(importedAt: Date(), sourceHash: "h", sourceFileSize: 1,
                                      sourceExtension: "m4a", sourceFormat: "mp4")
        metadata.location = CapturedLocation(latitude: 32.08, longitude: 34.78,
                                             horizontalAccuracyMeters: 12)
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(ImportMetadata.self, from: data)
        XCTAssertEqual(decoded.location, metadata.location)

        // Pre-location metadata.json files must keep decoding.
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old.removeValue(forKey: "location")
        let oldData = try JSONSerialization.data(withJSONObject: old)
        XCTAssertNil(try JSONDecoder().decode(ImportMetadata.self, from: oldData).location)
    }
}
