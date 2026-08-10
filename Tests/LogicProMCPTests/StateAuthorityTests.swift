import Foundation
import MCP
import XCTest
@testable import LogicProMCP

final class StateAuthorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let projectPath = "/tmp/state-authority-project.logicx"

    func testFreshCoherentStableSelectionPassesAuthorityPreflight() async {
        let cache = StateCache()
        let projectIdentity = ProjectIdentity.stable(path: projectPath)
        var project = ProjectInfo(name: "State Authority", filePath: projectPath, lastUpdated: now)
        project.projectIdentity = projectIdentity
        await cache.updateProject(project)

        let generation = await cache.getGeneration()
        let selection = coherentSelection(
            at: now,
            projectIdentity: projectIdentity,
            generation: generation,
            identityStability: .stable
        )
        await cache.updateSelection(selection)

        let check = await cache.selectionAuthority(at: now.addingTimeInterval(4.999))

        XCTAssertTrue(check.authorized)
        XCTAssertEqual(check.reasonCode, "ok")
        XCTAssertEqual(check.maximumAgeSeconds, ServerConfig.selectionAuthorityMaxAge)
        XCTAssertEqual(check.generation, generation)
    }

    func testSelectionAuthorityRejectsStateOlderThanExplicitMaximumAge() async {
        let cache = await configuredCache()
        let selection = coherentSelection(
            at: now,
            projectIdentity: ProjectIdentity.stable(path: projectPath),
            generation: 1,
            identityStability: .stable
        )
        await cache.updateSelection(selection)

        let check = await cache.selectionAuthority(
            at: now.addingTimeInterval(ServerConfig.selectionAuthorityMaxAge + 0.001)
        )

        XCTAssertFalse(check.authorized)
        XCTAssertEqual(check.reasonCode, "stale_selection")
        XCTAssertTrue(check.message.contains("exceeds maximum"))
    }

    func testSelectionAuthorityRejectsUnknownProjectIdentity() async {
        let cache = StateCache()
        let selection = coherentSelection(
            at: now,
            projectIdentity: .unknown,
            generation: 0,
            identityStability: .stable
        )
        await cache.updateSelection(selection)

        let check = await cache.selectionAuthority(at: now)

        XCTAssertFalse(check.authorized)
        XCTAssertEqual(check.reasonCode, "unknown_project_identity")
    }

    func testSelectionAuthorityRejectsProjectMismatchAndGenerationMismatch() async {
        let cache = await configuredCache()
        let otherIdentity = ProjectIdentity.stable(path: "/tmp/other-project.logicx")

        await cache.updateSelection(
            coherentSelection(
                at: now,
                projectIdentity: otherIdentity,
                generation: 1,
                identityStability: .stable
            )
        )
        let mismatch = await cache.selectionAuthority(at: now)
        XCTAssertFalse(mismatch.authorized)
        XCTAssertEqual(mismatch.reasonCode, "project_mismatch")

        await cache.updateSelection(
            coherentSelection(
                at: now,
                projectIdentity: ProjectIdentity.stable(path: projectPath),
                generation: 99,
                identityStability: .stable
            )
        )
        let generationMismatch = await cache.selectionAuthority(at: now)
        XCTAssertFalse(generationMismatch.authorized)
        XCTAssertEqual(generationMismatch.reasonCode, "generation_mismatch")
    }

    func testSyntheticOrVisibleOnlyRegionIdentityCannotAuthorizeDestructiveMutation() async {
        let cache = await configuredCache()
        let identity = ProjectIdentity.stable(path: projectPath)

        await cache.updateSelection(
            coherentSelection(at: now, projectIdentity: identity, generation: 1, identityStability: .synthetic)
        )
        let synthetic = await cache.selectionAuthority(at: now)
        XCTAssertFalse(synthetic.authorized)
        XCTAssertEqual(synthetic.reasonCode, "unstable_region_identity")

        await cache.updateSelection(
            coherentSelection(at: now, projectIdentity: identity, generation: 1, identityStability: .visibleOnly)
        )
        let visibleOnly = await cache.selectionAuthority(at: now)
        XCTAssertFalse(visibleOnly.authorized)
        XCTAssertEqual(visibleOnly.reasonCode, "unstable_region_identity")
    }

    func testVisibleOnlyProjectIdentityCannotAuthorizeGuardedProjectMutation() async {
        let cache = StateCache()
        await cache.updateProject(ProjectInfo(name: "Window Title", lastUpdated: now))

        let check = await cache.projectAuthority(at: now)

        XCTAssertFalse(check.authorized)
        XCTAssertEqual(check.reasonCode, "unstable_project_identity")
    }

    func testProjectChangeAdvancesGenerationAndInvalidatesProjectBoundResources() async {
        let cache = await configuredCache()
        await cache.updateTracks([TrackState(id: 0, name: "Track", type: .audio)])
        await cache.updateRegions([
            RegionState(
                id: "track-0-region-0",
                name: "Visible Region",
                trackIndex: 0,
                trackName: "Track",
                startPosition: "1.1",
                endPosition: "2.1",
                length: "1.0"
            )
        ])
        let firstGeneration = await cache.getGeneration()
        let boundTrack = await cache.getTracks().first
        let boundRegion = await cache.getRegions().first
        XCTAssertEqual(boundTrack?.generation, firstGeneration)
        XCTAssertEqual(boundTrack?.projectIdentity, ProjectIdentity.stable(path: projectPath))
        XCTAssertEqual(boundRegion?.generation, firstGeneration)
        XCTAssertEqual(boundRegion?.projectIdentity, ProjectIdentity.stable(path: projectPath))

        await cache.updateProject(
            ProjectInfo(
                name: "Next Project",
                filePath: "/tmp/next-project.logicx",
                lastUpdated: now.addingTimeInterval(1)
            )
        )

        let secondGeneration = await cache.getGeneration()
        let remainingRegionCount = await cache.getRegions().count
        let remainingTrackCount = await cache.getTracks().count
        let selectionTimestamp = await cache.getSelection().lastUpdated
        XCTAssertEqual(secondGeneration, firstGeneration + 1)
        XCTAssertEqual(remainingRegionCount, 0)
        XCTAssertEqual(remainingTrackCount, 0)
        XCTAssertEqual(selectionTimestamp, .distantPast)
    }

    func testGuardedResponseContainsVersionedOperationReceiptContract() async throws {
        let cache = StateCache()
        let router = ChannelRouter()
        let missingPath = "/tmp/does-not-exist-state-authority.mid"

        let result = await ProjectDispatcher.handle(
            command: "replace_selected_region_midi_bridge",
            params: ["path": .string(missingPath)],
            router: router,
            cache: cache
        )
        let object = try jsonObject(from: result)

        XCTAssertEqual(object["schema_version"] as? String, OperationReceipt.currentSchemaVersion)
        XCTAssertEqual(object["receipt_version"] as? Int, 1)
        XCTAssertNotNil(object["request"] as? [String: Any])
        XCTAssertNotNil(object["preconditions"] as? [String: Any])
        XCTAssertEqual(object["mutation"] as? String, "not_started")
        XCTAssertEqual(object["verification"] as? String, "unavailable")
        XCTAssertNotNil(object["project_identity"] as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "rejected")
    }

    func testOperationReceiptSerializationIsVersionedAndDeterministic() throws {
        let identity = ProjectIdentity.stable(path: projectPath)
        let preconditions = OperationPreconditions(
            stateAuthority: "rejected",
            sourcePath: projectPath,
            sourceValid: false,
            selectionFresh: false,
            selectionAgeSeconds: 8.0,
            maximumAgeSeconds: 5.0,
            selectedRegionCount: 1,
            selectedRegionIDs: ["synthetic-region"],
            selectedRegionIdentityStability: .synthetic,
            projectIdentity: identity,
            selectionProjectIdentity: identity,
            projectIdentityKnown: true,
            projectIdentityMatches: true,
            generationCompatible: false,
            cacheGeneration: 3,
            stateGeneration: 2,
            failures: ["stale_selection"]
        )
        let receipt = OperationReceipt(
            receiptID: "receipt-1",
            operation: "replace_selected_region_midi_bridge",
            parameters: ["path": "/tmp/source.mid"],
            preconditions: preconditions,
            mutation: "not_started",
            verification: "unavailable",
            projectIdentity: identity,
            generation: 3,
            status: "manual_required",
            success: false,
            error: "state authority rejected",
            issuedAt: now
        )

        let first = encodeCompactJSON(receipt)
        let second = encodeCompactJSON(receipt)
        XCTAssertEqual(first, second)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        let nested = try XCTUnwrap(object["preconditions"] as? [String: Any])
        XCTAssertEqual(nested["state_authority"] as? String, "rejected")
        XCTAssertEqual(nested["generation_compatible"] as? Bool, false)
        XCTAssertEqual(nested["selected_region_identity_stability"] as? String, "synthetic")
        XCTAssertNotNil(nested["project_identity"] as? [String: Any])
        XCTAssertEqual(object["receipt_id"] as? String, "receipt-1")
    }

    private func configuredCache() async -> StateCache {
        let cache = StateCache()
        var project = ProjectInfo(name: "State Authority", filePath: projectPath, lastUpdated: now)
        project.projectIdentity = .stable(path: projectPath)
        await cache.updateProject(project)
        return cache
    }

    private func coherentSelection(
        at timestamp: Date,
        projectIdentity: ProjectIdentity,
        generation: UInt64,
        identityStability: StateIdentityStability
    ) -> SelectionState {
        SelectionState(
            selectedRegionIDs: ["stable-region"],
            selectedRegionNames: ["Region"],
            selectedRegionCount: 1,
            lastUpdated: timestamp,
            projectIdentity: projectIdentity,
            generation: generation,
            selectedRegionIdentityStability: identityStability,
            identityScope: identityStability == .stable ? "project_bound" : "visible_only"
        )
    }

    private func jsonObject(from result: CallTool.Result) throws -> [String: Any] {
        let text = result.content.compactMap { content -> String? in
            if case let .text(value, _, _) = content { return value }
            return nil
        }.first ?? ""
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
