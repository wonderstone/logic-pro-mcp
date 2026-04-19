import XCTest
@testable import LogicProMCP

final class PlaceholderTests: XCTestCase {
    func testBinaryExists() throws {
        XCTAssertTrue(true)
    }

    func testParseTrackNameFromQuotedDescription() {
        XCTAssertEqual(
            AXValueExtractors.parseTrackName(from: "Track 1 “Dark Soul”"),
            "Dark Soul"
        )
        XCTAssertEqual(
            AXValueExtractors.parseTrackName(from: "Track 2 \"job_test_1\""),
            "job_test_1"
        )
    }

    func testParseTrackNameReturnsNilWithoutQuotedName() {
        XCTAssertNil(AXValueExtractors.parseTrackName(from: "Tracks header"))
    }

    func testNormalizedProjectTitleDropsViewSuffixAndFilePrefix() {
        XCTAssertEqual(
            AccessibilityChannel.normalizedProjectTitle(
                "WCH-Main Theme.logicx - WCH-Main Theme - Tracks"
            ),
            "WCH-Main Theme"
        )
        XCTAssertEqual(
            AccessibilityChannel.normalizedProjectTitle("Simple Demo - Mixer"),
            "Simple Demo"
        )
    }
}
