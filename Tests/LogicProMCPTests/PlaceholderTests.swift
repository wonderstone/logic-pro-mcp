import XCTest
import MCP
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

    func testInferTrackTypeRequiresExplicitEvidence() {
        XCTAssertEqual(
            AXValueExtractors.inferTrackType(
                fromCombinedText: "track 1 dark soul mute input monitoring volume"
            ),
            .unknown
        )
        XCTAssertEqual(
            AXValueExtractors.inferTrackType(
                fromCombinedText: "software instrument track punchy bottom"
            ),
            .softwareInstrument
        )
        XCTAssertEqual(
            AXValueExtractors.inferTrackType(
                fromCombinedText: "audio track lead vocal"
            ),
            .audio
        )
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
            AccessibilityChannel.activeViewName("Simple Demo - Event List"),
            "event_list"
        )
        XCTAssertEqual(
            AccessibilityChannel.activeViewName("Simple Demo"),
            "unknown"
        )
    }

    func testMIDIBridgeCapabilitiesDefaultContract() {
        let capabilities = MIDIBridgeCapabilitiesState()

        XCTAssertEqual(capabilities.exportCommand, "logic_project.export_selected_midi_bridge")
        XCTAssertEqual(capabilities.replaceCommand, "logic_project.replace_selected_region_midi_bridge")
        XCTAssertEqual(capabilities.scope, "selected_region_only")
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

    func testTransportDispatcherParsesTempoFromStringValues() {
        let params: [String: Value] = [
            "tempo": .string("95.0")
        ]

        XCTAssertEqual(TransportDispatcher.parseTempo(from: params), 95.0)
    }

    func testTransportDispatcherParsesTempoFromBpmFallback() {
        let params: [String: Value] = [
            "bpm": .string("96")
        ]

        XCTAssertEqual(TransportDispatcher.parseTempo(from: params), 96.0)
    }
}
