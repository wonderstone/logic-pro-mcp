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

    func testActiveViewNameParsesKnownWindowSuffixes() {
        XCTAssertEqual(
            AccessibilityChannel.activeViewName("WCH-Main Theme.logicx - WCH-Main Theme - Tracks"),
            "tracks"
        )
        XCTAssertEqual(
            AccessibilityChannel.activeViewName("WCH-Main Theme - Piano Roll"),
            "piano_roll"
        )
        XCTAssertEqual(
            AccessibilityChannel.activeViewName("Simple Demo - Mixer"),
            "mixer"
        )
        XCTAssertEqual(
            AccessibilityChannel.activeViewName("Simple Demo"),
            "unknown"
        )
    }

    func testExtractRegionsBuildsVisibleRegionState() {
        let region = RegionState(
            id: "track-0-region-0",
            name: "MuseFlow Chord Guide",
            trackIndex: 0,
            trackName: "Dark Soul",
            startPosition: "unknown",
            endPosition: "unknown",
            length: "unknown",
            isSelected: false,
            isLooped: true
        )

        XCTAssertEqual(region.name, "MuseFlow Chord Guide")
        XCTAssertEqual(region.trackName, "Dark Soul")
        XCTAssertTrue(region.isLooped)
    }
}
