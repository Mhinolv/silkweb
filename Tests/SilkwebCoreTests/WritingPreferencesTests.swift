import Foundation
import XCTest
@testable import SilkwebCore

final class WritingPreferencesTests: XCTestCase {
    func testMissingAndExplicitPreferencesRoundTrip() throws {
        for json in ["{}", "{\"version\":0,\"unknown\":true}"] {
            let preferences = try JSONDecoder().decode(WritingPreferences.self, from: Data(json.utf8))
            XCTAssertEqual(preferences.fontFamily, "Menlo")
            XCTAssertEqual(preferences.fontSize, 15)
            XCTAssertEqual(preferences.lineHeight, 1.6)
            XCTAssertEqual(preferences.maximumWidth, 660)
        }
        for family in ["Menlo", "Helvetica", "future-font"] {
            for size in [1.0, 15, 144] {
                for spacing in [1.2, 1.35, 1.5, 1.6, 1.75, 2] {
                    for width in [1.0, 660, 720, 4096] {
                        let json = "{\"fontFamily\":\"\(family)\",\"fontSize\":\(size),\"lineHeight\":\(spacing),\"maximumWidth\":\(width)}"
                        let value = try JSONDecoder().decode(WritingPreferences.self, from: Data(json.utf8))
                        XCTAssertEqual(value.fontFamily, family)
                        XCTAssertEqual(value.fontSize, size)
                        XCTAssertEqual(value.lineHeight, spacing)
                        XCTAssertEqual(value.maximumWidth, width)
                        XCTAssertEqual(try JSONDecoder().decode(WritingPreferences.self, from: JSONEncoder().encode(value)), value)
                    }
                }
            }
        }
        let invalid = try JSONDecoder().decode(WritingPreferences.self, from: Data("{\"fontFamily\":\"\",\"fontSize\":0,\"lineHeight\":-1,\"maximumWidth\":0}".utf8))
        XCTAssertEqual(invalid, WritingPreferences())
    }
}
