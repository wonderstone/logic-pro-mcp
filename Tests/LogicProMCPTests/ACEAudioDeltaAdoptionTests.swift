import Foundation
import XCTest
@testable import LogicProMCP

final class ACEAudioDeltaAdoptionTests: XCTestCase {
    private let startingDigest = String(repeating: "a", count: 64)
    private let baselineDigest = String(repeating: "b", count: 64)
    private let sourceBaseName = "2026-04-14-memory-montage-electric-guitar-arc"
    private let trackTag = "ACE-P4A-ms-ace-logic-p5a-20260810-memory-montage-AUDIO-432dc357e406"
    private let regionTag = "ACE-P4A-REGION-op-ace-memory-montage-p5a-20260810-432dc357e4067fc5e80c45c907d69906c7c69158f1da71e4069ea6d2dfc307b7"

    func testExactFourTrackFiveRegionDeltaAdmitsCleanupAndStableTagShape() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let spec = makeSpec(projectPath: fixture.project.path, source: fixture.source, sourceDigest: fixture.sourceDigest)
        let before = makeStartingSnapshot(projectPath: fixture.project.path)

        XCTAssertTrue(ACEAudioDeltaAdoptionValidator.validateStartingDelta(before, spec: spec).isEmpty)

        let cleanup = makeCleanupSnapshot(projectPath: fixture.project.path)
        XCTAssertTrue(ACEAudioDeltaAdoptionValidator.validateAfterCleanup(cleanup, spec: spec).isEmpty)

        let tagged = makeTaggedSnapshot(projectPath: fixture.project.path, sourceDigest: fixture.sourceDigest)
        XCTAssertTrue(ACEAudioDeltaAdoptionValidator.validateTagged(tagged, spec: spec).isEmpty)
    }

    func testAlreadyCleanFourTrackFourRegionStateIsAdmittedForResume() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var spec = makeSpec(projectPath: fixture.project.path, source: fixture.source, sourceDigest: fixture.sourceDigest)
        spec.currentRegionCount = 4
        let cleaned = makeCleanupSnapshot(projectPath: fixture.project.path)

        XCTAssertTrue(ACEAudioDeltaAdoptionValidator.validateSpec(spec).isEmpty)
        XCTAssertTrue(ACEAudioDeltaAdoptionValidator.validateAfterCleanup(cleaned, spec: spec).isEmpty)
    }

    func testPartialTrackTagStillAdmitsExactCleanupResume() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let spec = makeSpec(projectPath: fixture.project.path, source: fixture.source, sourceDigest: fixture.sourceDigest)
        var taggedTrack = makeCleanupSnapshot(projectPath: fixture.project.path)
        taggedTrack.tracks[3].name = trackTag
        taggedTrack.regions[3].trackName = trackTag

        XCTAssertTrue(ACEAudioDeltaAdoptionValidator.validateAfterCleanup(taggedTrack, spec: spec).isEmpty)
    }

    func testExactDeltaRefusesThirdRegionAndPreservesFailClosedBoundary() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let spec = makeSpec(projectPath: fixture.project.path, source: fixture.source, sourceDigest: fixture.sourceDigest)
        var thirdRegion = makeStartingSnapshot(projectPath: fixture.project.path)
        thirdRegion.regions.append(
            RegionState(
                id: "track-3-region-2",
                name: "unexpected-third-region",
                trackIndex: 3,
                trackName: "Audio 2",
                startPosition: "unknown",
                endPosition: "unknown",
                length: "unknown",
                projectIdentity: thirdRegion.tracks[3].projectIdentity
            )
        )

        let issues = ACEAudioDeltaAdoptionValidator.validateStartingDelta(thirdRegion, spec: spec)
        let codes = Set(issues.map(\.code))
        XCTAssertTrue(codes.contains("logic_adoption_delta_count_mismatch"))
        XCTAssertTrue(codes.contains("logic_adoption_created_layer_ambiguous"))
        XCTAssertFalse(codes.contains("logic_adoption_duplicate_name_not_exact"))
    }

    func testOnlyExactSourceSuffixOneIsAdoptable() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var spec = makeSpec(projectPath: fixture.project.path, source: fixture.source, sourceDigest: fixture.sourceDigest)
        spec.duplicateRegionName = sourceBaseName + "_2"

        let codes = Set(ACEAudioDeltaAdoptionValidator.validateSpec(spec).map(\.code))
        XCTAssertTrue(codes.contains("logic_adoption_duplicate_name_not_exact"))
    }

    func testGeometryRequiresIndependentBarOneReadbackAndDeclaredDuration() {
        let placement = ACEPlacementCoordinates(bar: 1, beat: 1, tick: 0, durationBeats: 330, beatsPerBar: 4)
        let verified = ACEAudioDeltaGeometry(
            status: "verified",
            verified: true,
            reasonCode: "logic_ax_timeline_playhead_geometry",
            requestedBar: 1,
            requestedBeat: 1,
            requestedTick: 0,
            observedBar: 1,
            observedBeat: 1,
            timeRuler: ACEAXRect(x: -4886, y: 315, width: 8274, height: 136),
            barOnePlayhead: ACEAXRect(x: -4493, y: 335, width: 10, height: 19),
            barTwoPlayhead: ACEAXRect(x: -4453, y: 335, width: 10, height: 19),
            targetRegion: ACEAXRect(x: -4493, y: 652, width: 13200, height: 69),
            pixelsPerBeat: 10,
            estimatedDurationBeats: 330,
            startAlignmentPixels: 0,
            geometryTolerancePixels: 8,
            durationToleranceBeats: 1,
            basis: "independent AX ruler/playhead geometry",
            observedAt: Date()
        )
        XCTAssertTrue(ACEAudioDeltaAdoptionValidator.validateGeometry(verified, placement: placement).isEmpty)

        let unavailable = ACEAudioDeltaGeometry.unavailable(
            requestedBar: 1,
            requestedBeat: 1,
            requestedTick: 0,
            reasonCode: "logic_adoption_geometry_actuation_or_frame_readback_failed"
        )
        XCTAssertFalse(ACEAudioDeltaAdoptionValidator.validateGeometry(unavailable, placement: placement).isEmpty)
    }

    func testNoStretchGeometryMayReportPositiveNativeDurationDifferentFromIntent() {
        let placement = ACEPlacementCoordinates(bar: 1, beat: 1, tick: 0, durationBeats: 330, beatsPerBar: 4)
        let native = ACEAudioDeltaGeometry(
            status: "verified",
            verified: true,
            reasonCode: "logic_ax_timeline_geometry_native_duration_no_stretch",
            requestedBar: 1,
            requestedBeat: 1,
            requestedTick: 0,
            observedBar: 1,
            observedBeat: 1,
            timeRuler: ACEAXRect(x: 0, y: 0, width: 100, height: 100),
            barOnePlayhead: ACEAXRect(x: 10, y: 0, width: 10, height: 10),
            barTwoPlayhead: ACEAXRect(x: 50, y: 0, width: 10, height: 10),
            targetRegion: ACEAXRect(x: 10, y: 0, width: 1140, height: 10),
            pixelsPerBeat: 10,
            estimatedDurationBeats: 285,
            startAlignmentPixels: 0,
            geometryTolerancePixels: 8,
            durationToleranceBeats: 1,
            basis: "native source geometry",
            observedAt: Date()
        )

        XCTAssertFalse(ACEAudioDeltaAdoptionValidator.validateGeometry(native, placement: placement).isEmpty)
        XCTAssertTrue(
            ACEAudioDeltaAdoptionValidator.validateGeometry(
                native,
                placement: placement,
                allowNativeDurationMismatch: true
            ).isEmpty
        )
    }

    func testExactAXDeleteRequiresBoundDocumentSingleNamedSelectionAndDeleteAction() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let valid = ACEExactAXActionContract.validateDeletePrecondition(
            observedProjectPath: fixture.project.path,
            expectedProjectPath: fixture.project.path,
            selectedRegionName: sourceBaseName + "_1",
            expectedRegionName: sourceBaseName + "_1",
            selectedRegionCount: 1,
            menuTitle: "Delete",
            menuRole: "AXMenuItem",
            menuActions: ["AXPress"]
        )
        XCTAssertTrue(valid.isEmpty)

        let wrongDocument = ACEExactAXActionContract.validateDeletePrecondition(
            observedProjectPath: fixture.root.appendingPathComponent("other.logicx").path,
            expectedProjectPath: fixture.project.path,
            selectedRegionName: sourceBaseName + "_1",
            expectedRegionName: sourceBaseName + "_1",
            selectedRegionCount: 1,
            menuTitle: "Delete",
            menuRole: "AXMenuItem",
            menuActions: ["AXPress"]
        )
        XCTAssertTrue(Set(wrongDocument.map(\.code)).contains("logic_adoption_exact_action_document_mismatch"))

        let broadSelection = ACEExactAXActionContract.validateDeletePrecondition(
            observedProjectPath: fixture.project.path,
            expectedProjectPath: fixture.project.path,
            selectedRegionName: sourceBaseName + "_1",
            expectedRegionName: sourceBaseName + "_1",
            selectedRegionCount: 2,
            menuTitle: "Delete",
            menuRole: "AXMenuItem",
            menuActions: ["AXPress"]
        )
        XCTAssertTrue(Set(broadSelection.map(\.code)).contains("logic_adoption_exact_action_selection_mismatch"))

        let wrongMenu = ACEExactAXActionContract.validateDeletePrecondition(
            observedProjectPath: fixture.project.path,
            expectedProjectPath: fixture.project.path,
            selectedRegionName: sourceBaseName + "_1",
            expectedRegionName: sourceBaseName + "_1",
            selectedRegionCount: 1,
            menuTitle: "Close",
            menuRole: "AXMenuItem",
            menuActions: ["AXPress"]
        )
        XCTAssertTrue(Set(wrongMenu.map(\.code)).contains("logic_adoption_exact_action_menu_mismatch"))
    }

    private struct Fixture {
        let root: URL
        let project: URL
        let source: URL
        let sourceDigest: String
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-pro-mcp-p5g-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("disposable.logicx", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try Data("p5g project fixture".utf8).write(to: project.appendingPathComponent("project-content.txt"), options: .atomic)
        let source = root.appendingPathComponent("source.wav")
        try Data(repeating: 0x51, count: 256).write(to: source, options: .atomic)
        return Fixture(
            root: root,
            project: project,
            source: source,
            sourceDigest: try ACEFileDigest.sha256(at: source.path)
        )
    }

    private func makeSpec(projectPath: String, source: URL, sourceDigest: String) -> ACEAudioDeltaAdoptionSpec {
        ACEAudioDeltaAdoptionSpec(
            planID: "ms-ace-logic-p5a-20260810-memory-montage",
            operationID: "op-ace-memory-montage-p5a-20260810",
            targetProjectPath: projectPath,
            startingProjectSHA256: startingDigest,
            baselineProjectSHA256: baselineDigest,
            beforeTrackCount: 3,
            beforeRegionCount: 3,
            currentTrackCount: 4,
            currentRegionCount: 5,
            newTrackName: "Audio 2",
            sourceBaseName: sourceBaseName,
            duplicateRegionName: sourceBaseName + "_1",
            preservedTrackNames: ["Dark Soul", "Dark Soul", "job_test_1"],
            preservedRegionNames: [
                "Dark Soul Chord Contour V8 Single Chord Bar, muted",
                "Dark Soul Chord Contour V8 Single Chord Bar",
                "job_test_1.1",
            ],
            source: ACEAudioSource(
                assetID: "asset-432dc357e406",
                path: source.path,
                sha256: sourceDigest,
                format: "wav"
            ),
            trackTag: trackTag,
            regionTag: regionTag,
            placement: ACEPlacementCoordinates(bar: 1, beat: 1, tick: 0, durationBeats: 330, beatsPerBar: 4)
        )
    }

    private func makeStartingSnapshot(projectPath: String) -> ACEPlacementSnapshot {
        let identity = ProjectIdentity.stable(path: projectPath, digest: startingDigest)
        let tracks = [
            makeTrack(index: 0, name: "Dark Soul", identity: identity),
            makeTrack(index: 1, name: "Dark Soul", identity: identity),
            makeTrack(index: 2, name: "job_test_1", identity: identity),
            makeTrack(index: 3, name: "Audio 2", identity: identity),
        ]
        let regions = [
            makeRegion(id: "r0", name: "Dark Soul Chord Contour V8 Single Chord Bar, muted", trackIndex: 0, trackName: "Dark Soul", identity: identity),
            makeRegion(id: "r1", name: "Dark Soul Chord Contour V8 Single Chord Bar", trackIndex: 1, trackName: "Dark Soul", identity: identity),
            makeRegion(id: "r2", name: "job_test_1.1", trackIndex: 2, trackName: "job_test_1", identity: identity),
            makeRegion(id: "r3", name: sourceBaseName, trackIndex: 3, trackName: "Audio 2", identity: identity),
            makeRegion(id: "r4", name: sourceBaseName + "_1", trackIndex: 3, trackName: "Audio 2", identity: identity),
        ]
        return ACEPlacementSnapshot(observedAt: Date(), projectPath: projectPath, projectSHA256: startingDigest, generation: 1, tracks: tracks, regions: regions)
    }

    private func makeCleanupSnapshot(projectPath: String) -> ACEPlacementSnapshot {
        var snapshot = makeStartingSnapshot(projectPath: projectPath)
        snapshot.regions.removeLast()
        snapshot.projectSHA256 = String(repeating: "c", count: 64)
        return snapshot
    }

    private func makeTaggedSnapshot(projectPath: String, sourceDigest: String) -> ACEPlacementSnapshot {
        let identity = ProjectIdentity.stable(path: projectPath, digest: String(repeating: "c", count: 64))
        let taggedTrackID = OperationTagIdentity.trackID(projectIdentity: identity, operationTag: trackTag)
        let taggedRegionID = OperationTagIdentity.regionID(projectIdentity: identity, trackOperationTag: trackTag, regionOperationTag: regionTag)
        let tracks = [
            makeTrack(index: 0, name: "Dark Soul", identity: identity),
            makeTrack(index: 1, name: "Dark Soul", identity: identity),
            makeTrack(index: 2, name: "job_test_1", identity: identity),
            makeTrack(index: 3, name: trackTag, identity: identity, stableID: taggedTrackID),
        ]
        let regions = [
            makeRegion(id: "r0", name: "Dark Soul Chord Contour V8 Single Chord Bar, muted", trackIndex: 0, trackName: "Dark Soul", identity: identity),
            makeRegion(id: "r1", name: "Dark Soul Chord Contour V8 Single Chord Bar", trackIndex: 1, trackName: "Dark Soul", identity: identity),
            makeRegion(id: "r2", name: "job_test_1.1", trackIndex: 2, trackName: "job_test_1", identity: identity),
            makeRegion(id: "r3", name: sourceBaseName + " | " + regionTag + " " + sourceDigest, trackIndex: 3, trackName: trackTag, identity: identity, stableID: taggedRegionID, trackStableID: taggedTrackID),
        ]
        return ACEPlacementSnapshot(observedAt: Date(), projectPath: projectPath, projectSHA256: String(repeating: "c", count: 64), generation: 2, tracks: tracks, regions: regions)
    }

    private func makeTrack(index: Int, name: String, identity: ProjectIdentity, stableID: String? = nil) -> TrackState {
        TrackState(
            id: index,
            name: name,
            type: .audio,
            projectIdentity: identity,
            identityStability: stableID == nil ? .synthetic : .stable,
            identityScope: stableID == nil ? "visible_only" : "project_bound",
            stableID: stableID
        )
    }

    private func makeRegion(id: String, name: String, trackIndex: Int, trackName: String, identity: ProjectIdentity, stableID: String? = nil, trackStableID: String? = nil) -> RegionState {
        RegionState(
            id: id,
            name: name,
            trackIndex: trackIndex,
            trackName: trackName,
            startPosition: "unknown",
            endPosition: "unknown",
            length: "unknown",
            projectIdentity: identity,
            identityStability: stableID == nil ? .synthetic : .stable,
            identityScope: stableID == nil ? "visible_only" : "project_bound",
            stableID: stableID,
            trackStableID: trackStableID
        )
    }
}
