import XCTest
@testable import SilkwebCore

final class SilkwebCoreTests: XCTestCase {
    func testVersion() {
        XCTAssertFalse(SilkwebCore.version.isEmpty)
    }
}
