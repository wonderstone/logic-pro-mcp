import Foundation
import MCP
import XCTest
@testable import LogicProMCP

final class ACEAudioPlacementTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    func testOperationTagIdentityIsDeterministicAcrossFreshReadsAndNeverUsesVisibleOrder() {
        let path = "/tmp/operation-tag-project.logicx"
        let project = ProjectIdentity.stable(path: path, digest: String(repeating: "a", count: 64))
        let trackTag = "ACE-P4A-plan-fixed-AUDIO-source"
        let regionTag = "ACE-P4A-REGION-operation-fixed-source"

        let firstTrackID = OperationTagIdentity.trackID(projectIdentity: project, operationTag: trackTag)
        let secondTrackID = OperationTagIdentity.trackID(
            projectIdentity: .stable(path: path, digest: String(repeating: "b", count: 64)),
            operationTag: trackTag
        )
        XCTAssertEqual(firstTrackID, secondTrackID)
        XCTAssertEqual(
            OperationTagIdentity.operationTag(in: "Audio | \(trackTag)"),
            trackTag
        )
        XCTAssertNotEqual(
            firstTrackID,
            OperationTagIdentity.trackID(projectIdentity: project, operationTag: "ACE-P4A-other")
        )
        XCTAssertNotNil(
            OperationTagIdentity.regionID(
                projectIdentity: project,
                trackOperationTag: trackTag,
                regionOperationTag: regionTag
            )
        )
        XCTAssertNil(
            OperationTagIdentity.trackID(
                projectIdentity: .visibleOnly(name: "operation-tag-project"),
                operationTag: trackTag
            )
        )
        XCTAssertNil(OperationTagIdentity.operationTag(in: "track-3-region-0"))
    }

    func testAssetRegionIdentityUsesStableTrackParentNativeBasenameAndKeeperDigest() {
        let project = ProjectIdentity.stable(path: "/tmp/p5i.logicx", digest: String(repeating: "a", count: 64))
        let trackTag = "ACE-P4A-plan-fixed-AUDIO-source"
        let basename = "memory-montage-electric-guitar-arc"
        let digest = String(repeating: "b", count: 64)

        let first = OperationTagIdentity.assetRegionID(
            projectIdentity: project,
            trackOperationTag: trackTag,
            nativeSourceBasename: basename,
            keeperSHA256: digest
        )
        let second = OperationTagIdentity.assetRegionID(
            projectIdentity: .stable(path: "/tmp/p5i.logicx", digest: String(repeating: "c", count: 64)),
            trackOperationTag: trackTag,
            nativeSourceBasename: basename,
            keeperSHA256: digest
        )

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(
            first,
            OperationTagIdentity.assetRegionID(
                projectIdentity: project,
                trackOperationTag: trackTag,
                nativeSourceBasename: "other-source",
                keeperSHA256: digest
            )
        )
        XCTAssertNotEqual(
            first,
            OperationTagIdentity.assetRegionID(
                projectIdentity: project,
                trackOperationTag: trackTag,
                nativeSourceBasename: basename,
                keeperSHA256: String(repeating: "c", count: 64)
            )
        )
        XCTAssertNil(
            OperationTagIdentity.assetRegionID(
                projectIdentity: .visibleOnly(name: "p5i"),
                trackOperationTag: trackTag,
                nativeSourceBasename: basename,
                keeperSHA256: digest
            )
        )
    }

    func testKeeperDigestReceiptFailsClosedOnPathBasenameAndDigestDrift() throws {
        let fixture = try makeFixture(name: "keeper-receipt")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = ACEAudioSource(
            assetID: "asset-keeper",
            path: fixture.source.path,
            sha256: fixture.sourceDigest,
            format: "wav"
        )
        let valid = keeperReceipt(for: source)
        XCTAssertTrue(ACEAudioPlacementValidator.validateKeeperDigestReceipt(valid, source: source).isEmpty)

        var wrongPath = valid
        wrongPath.path = fixture.root.appendingPathComponent("other.wav").path
        XCTAssertTrue(
            ACEAudioPlacementValidator.validateKeeperDigestReceipt(wrongPath, source: source)
                .contains { $0.code == "ace_keeper_digest_receipt_path_mismatch" }
        )

        var wrongBasename = valid
        wrongBasename.nativeSourceBasename = "wrong-native-name"
        XCTAssertTrue(
            ACEAudioPlacementValidator.validateKeeperDigestReceipt(wrongBasename, source: source)
                .contains { $0.code == "ace_keeper_digest_receipt_basename_mismatch" }
        )

        try Data(repeating: 0x42, count: 128).write(to: fixture.source, options: .atomic)
        XCTAssertTrue(
            ACEAudioPlacementValidator.validateKeeperDigestReceipt(valid, source: source)
                .contains { $0.code == "ace_keeper_digest_receipt_drift" }
        )
    }

    func testKeeperDigestCommandIssuesSeparateReceiptWithoutMutation() async throws {
        let fixture = try makeFixture(name: "keeper-command")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let harness = ACEPlacementHarness(projectPath: fixture.project.path, assetSHA256: fixture.sourceDigest)
        let router = ChannelRouter()
        let cache = StateCache()
        await router.register(ACEPlacementChannel(id: .accessibility, harness: harness))

        let result = await ProjectDispatcher.handle(
            command: "verify_keeper_digest",
            params: [
                "path": .string(fixture.source.path),
                "sha256": .string(fixture.sourceDigest),
                "native_source_basename": .string("ace-layer"),
            ],
            router: router,
            cache: cache
        )
        let receipt = try jsonObject(from: result)
        XCTAssertFalse(result.isError == true)
        XCTAssertEqual(receipt["schema_version"] as? String, ACEAssetRegionIdentityContract.keeperDigestReceiptSchemaVersion)
        XCTAssertEqual(receipt["status"] as? String, "verified")
        XCTAssertEqual(receipt["sha256"] as? String, fixture.sourceDigest)
        XCTAssertEqual(receipt["native_source_basename"] as? String, "ace-layer")
        let operationsAfterReceipt = await harness.operations()
        XCTAssertEqual(operationsAfterReceipt, [])

        let rejected = await ProjectDispatcher.handle(
            command: "verify_keeper_digest",
            params: [
                "path": .string(fixture.source.path),
                "sha256": .string(String(repeating: "0", count: 64)),
            ],
            router: router,
            cache: cache
        )
        XCTAssertTrue(rejected.isError == true)
        XCTAssertTrue(resultText(rejected).contains("ace_keeper_expected_digest_mismatch"))
        let operationsAfterRejection = await harness.operations()
        XCTAssertEqual(operationsAfterRejection, [])
    }

    func testDisposableBindingExpiresAndDoesNotComeFromVisibleOnlyIdentity() throws {
        let fixture = try makeFixture(name: "binding")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let binding = DisposableProjectBinding(
            bindingID: "binding-fixed",
            path: fixture.project.path,
            projectSHA256: fixture.projectDigest,
            authority: ACEAudioPlacementContract.disposableProjectAuthority,
            issuedAt: fixedNow.addingTimeInterval(-1),
            expiresAt: fixedNow.addingTimeInterval(60),
            originalProjectPath: "/tmp/ace-p4a-original.logicx",
            originalProjectPreserved: true
        )
        var current = ProjectInfo(
            name: "Disposable Copy",
            filePath: fixture.project.path,
            lastUpdated: fixedNow
        )
        current.projectIdentity = .stable(path: fixture.project.path)
        current.generation = 4

        XCTAssertTrue(
            ACEAudioPlacementValidator.validateBinding(
                binding,
                currentProject: current,
                cacheGeneration: 4,
                now: fixedNow
            ).isEmpty
        )

        let expiredCodes = Set(
            ACEAudioPlacementValidator.validateBinding(
                binding,
                currentProject: current,
                cacheGeneration: 4,
                now: fixedNow.addingTimeInterval(61)
            ).map(\.code)
        )
        XCTAssertTrue(expiredCodes.contains("logic_binding_expired"))

        var invalidWindow = binding
        invalidWindow.issuedAt = fixedNow
        invalidWindow.expiresAt = fixedNow.addingTimeInterval(-1)
        let invalidWindowCodes = Set(ACEAudioPlacementValidator.validateBinding(invalidWindow, now: fixedNow).map(\.code))
        XCTAssertTrue(invalidWindowCodes.contains("logic_binding_window_invalid"))

        var visibleOnly = current
        visibleOnly.filePath = nil
        visibleOnly.projectIdentity = .visibleOnly(name: "Disposable Copy")
        let visibleOnlyCodes = Set(
            ACEAudioPlacementValidator.validateBinding(
                binding,
                currentProject: visibleOnly,
                cacheGeneration: 4,
                now: fixedNow
            ).map(\.code)
        )
        XCTAssertTrue(visibleOnlyCodes.contains("logic_project_path_unavailable"))
        XCTAssertTrue(visibleOnlyCodes.contains("logic_project_identity_unstable"))
    }

    func testPreviewRequiresExplicitBindingBeforeAnyChannelOperation() async throws {
        let harness = ACEPlacementHarness(projectPath: "/tmp/unused-p4a.logicx", assetSHA256: String(repeating: "a", count: 64))
        let channel = ACEPlacementChannel(id: .accessibility, harness: harness)
        let router = ChannelRouter()
        await router.register(channel)

        let result = await ProjectDispatcher.handle(
            command: "preview_ace_audio_placement",
            params: ["plan_id": .string("plan-without-binding")],
            router: router,
            cache: StateCache()
        )
        let object = try jsonObject(from: result)

        XCTAssertTrue(result.isError == true)
        XCTAssertEqual(object["status"] as? String, "rejected")
        let issues = try XCTUnwrap(object["validation_issues"] as? [[String: Any]])
        XCTAssertEqual(issues.first?["code"] as? String, "logic_disposable_binding_missing")
        let operations = await harness.operations()
        XCTAssertEqual(operations, [])
    }

    func testUIImportTimeoutReceiptStopsTaggingReadbackAndRetry() async throws {
        let scenario = try await makeScenario(
            name: "ui-import-timeout",
            ambiguous: false,
            uiImportResult: .error("stage=ui_import status=timed_out outcome=unknown detail=child-terminated")
        )
        defer { try? FileManager.default.removeItem(at: scenario.fixture.root) }

        await prepareAuthorizedScenario(scenario)
        let result = await ProjectDispatcher.handle(
            command: "place_ace_audio",
            params: ["plan_id": .string(scenario.planID)],
            router: scenario.router,
            cache: scenario.cache
        )
        let object = try jsonObject(from: result)
        let stages = try XCTUnwrap(object["stage_receipts"] as? [[String: Any]])

        XCTAssertEqual(object["status"] as? String, "dispatch_unknown")
        XCTAssertEqual(stages.map { $0["stage"] as? String }, ["ui_import", "tagging", "readback"])
        XCTAssertEqual(stages[0]["status"] as? String, "timed_out")
        XCTAssertEqual(stages[0]["outcome"] as? String, "unknown")
        XCTAssertEqual(stages[1]["status"] as? String, "not_started")
        XCTAssertEqual(stages[2]["status"] as? String, "not_started")

        let operations = await scenario.harness.operations()
        XCTAssertEqual(operations.filter { $0 == "project.import_audio" }.count, 1)
        XCTAssertFalse(operations.contains("project.tag_imported_audio"))
        XCTAssertEqual(operations.filter { $0 == "region.get_regions" }.count, 1)
        XCTAssertFalse(operations.contains("project.read_ace_audio_placement_geometry"))
    }

    func testTaggingTimeoutReceiptStopsReadbackWithoutSecondImport() async throws {
        let scenario = try await makeScenario(
            name: "tagging-timeout",
            ambiguous: false,
            tagResult: .error("stage=tagging status=timed_out outcome=unknown detail=tag-budget")
        )
        defer { try? FileManager.default.removeItem(at: scenario.fixture.root) }

        await prepareAuthorizedScenario(scenario)
        let result = await ProjectDispatcher.handle(
            command: "place_ace_audio",
            params: ["plan_id": .string(scenario.planID)],
            router: scenario.router,
            cache: scenario.cache
        )
        let object = try jsonObject(from: result)
        let stages = try XCTUnwrap(object["stage_receipts"] as? [[String: Any]])

        XCTAssertEqual(object["status"] as? String, "dispatched_unverified")
        XCTAssertEqual(stages[0]["outcome"] as? String, "dispatched")
        XCTAssertEqual(stages[1]["status"] as? String, "timed_out")
        XCTAssertEqual(stages[1]["outcome"] as? String, "unknown")
        XCTAssertEqual(stages[2]["status"] as? String, "not_started")

        let operations = await scenario.harness.operations()
        XCTAssertEqual(operations.filter { $0 == "project.import_audio" }.count, 1)
        XCTAssertEqual(operations.filter { $0 == "project.tag_imported_audio" }.count, 1)
        XCTAssertEqual(operations.filter { $0 == "region.get_regions" }.count, 1)
        XCTAssertFalse(operations.contains("project.read_ace_audio_placement_geometry"))
    }

    func testVerifiedPlacementReceiptContainsOrderedBoundedStagesAndOneImport() async throws {
        let scenario = try await makeScenario(name: "three-stage-success", ambiguous: false)
        defer { try? FileManager.default.removeItem(at: scenario.fixture.root) }

        await prepareAuthorizedScenario(scenario)
        let result = await ProjectDispatcher.handle(
            command: "place_ace_audio",
            params: ["plan_id": .string(scenario.planID)],
            router: scenario.router,
            cache: scenario.cache
        )
        let object = try jsonObject(from: result)
        let stages = try XCTUnwrap(object["stage_receipts"] as? [[String: Any]])

        XCTAssertEqual(object["status"] as? String, "verified_success")
        XCTAssertEqual(stages.map { $0["stage"] as? String }, ["ui_import", "tagging", "readback"])
        XCTAssertEqual(stages.map { $0["status"] as? String }, ["completed", "completed", "completed"])
        XCTAssertEqual(stages.map { $0["outcome"] as? String }, ["dispatched", "tagged", "verified"])
        XCTAssertTrue(stages.allSatisfy { ($0["elapsed_ms"] as? Int ?? -1) >= 0 })
        XCTAssertTrue(stages.allSatisfy { ($0["attempt"] as? Int ?? 0) >= 1 })

        let operations = await scenario.harness.operations()
        XCTAssertEqual(operations.filter { $0 == "project.import_audio" }.count, 1)
        XCTAssertEqual(operations.filter { $0 == "project.tag_imported_audio" }.count, 1)
        XCTAssertEqual(operations.filter { $0 == "project.read_ace_audio_placement_geometry" }.count, 1)
    }

    func testVisibleOnlyProjectReadbackRejectsBeforeDispatch() async throws {
        var visibleOnlyProject = ProjectInfo(name: "Visible Title", lastUpdated: Date())
        visibleOnlyProject.projectIdentity = .visibleOnly(name: "Visible Title")
        let scenario = try await makeScenario(name: "visible-only-project", ambiguous: false, projectReadback: visibleOnlyProject)
        defer { try? FileManager.default.removeItem(at: scenario.fixture.root) }

        await prepareAuthorizedScenario(scenario)
        let place = await ProjectDispatcher.handle(
            command: "place_ace_audio",
            params: ["plan_id": .string(scenario.planID)],
            router: scenario.router,
            cache: scenario.cache
        )
        let object = try jsonObject(from: place)

        XCTAssertTrue(place.isError == true)
        XCTAssertEqual(object["status"] as? String, "rejected")
        XCTAssertTrue(
            ((object["validation_issues"] as? [[String: Any]]) ?? [])
                .contains { $0["code"] as? String == "logic_before_readback_unavailable" }
        )
        let operations = await scenario.harness.operations()
        XCTAssertFalse(operations.contains("project.import_audio"))
    }

    func testDifferentObservedProjectPathRejectsWithoutUsingBindingPath() async throws {
        var differentProject = ProjectInfo(
            name: "Different Project",
            filePath: "/tmp/different-open-project.logicx",
            lastUpdated: Date()
        )
        differentProject.projectIdentity = .stable(path: "/tmp/different-open-project.logicx")
        let scenario = try await makeScenario(name: "different-project", ambiguous: false, projectReadback: differentProject)
        defer { try? FileManager.default.removeItem(at: scenario.fixture.root) }

        await prepareAuthorizedScenario(scenario)
        let place = await ProjectDispatcher.handle(
            command: "place_ace_audio",
            params: ["plan_id": .string(scenario.planID)],
            router: scenario.router,
            cache: scenario.cache
        )
        let object = try jsonObject(from: place)

        XCTAssertTrue(place.isError == true)
        XCTAssertEqual(object["status"] as? String, "rejected")
        let operations = await scenario.harness.operations()
        XCTAssertFalse(operations.contains("project.import_audio"))
        XCTAssertFalse(resultText(place).contains("\"project_path\":\"\(scenario.fixture.project.path)\""))
    }

    func testSyntheticExistingBeforeReadbackRemainsExplicitlyUnstable() async throws {
        let scenario = try await makeScenario(
            name: "synthetic-before",
            ambiguous: false,
            beforeIdentityStability: .synthetic
        )
        defer { try? FileManager.default.removeItem(at: scenario.fixture.root) }

        await prepareAuthorizedScenario(scenario)
        let place = await ProjectDispatcher.handle(
            command: "place_ace_audio",
            params: ["plan_id": .string(scenario.planID)],
            router: scenario.router,
            cache: scenario.cache
        )
        let object = try jsonObject(from: place)

        XCTAssertFalse(place.isError == true, resultText(place))
        XCTAssertEqual(object["status"] as? String, "verified_success")
        let beforeTrack = ((object["before"] as? [String: Any])?["tracks"] as? [[String: Any]])?.first
        XCTAssertEqual(beforeTrack?["identityStability"] as? String, "synthetic")
        XCTAssertEqual(beforeTrack?["identityScope"] as? String, "visible_only")
        let createdTrack = ((object["after"] as? [String: Any])?["tracks"] as? [[String: Any]])?.last
        XCTAssertEqual(createdTrack?["identityStability"] as? String, "stable")
        XCTAssertEqual(createdTrack?["identityScope"] as? String, "project_bound")
        let operations = await scenario.harness.operations()
        XCTAssertTrue(operations.contains("project.import_audio"))
    }

    func testSyntheticAfterReadbackCannotVerifyOrRollback() async throws {
        let scenario = try await makeScenario(
            name: "synthetic-after",
            ambiguous: false,
            afterIdentityStability: .synthetic
        )
        defer { try? FileManager.default.removeItem(at: scenario.fixture.root) }

        await prepareAuthorizedScenario(scenario)
        let place = await ProjectDispatcher.handle(
            command: "place_ace_audio",
            params: ["plan_id": .string(scenario.planID)],
            router: scenario.router,
            cache: scenario.cache
        )
        let placedObject = try jsonObject(from: place)
        XCTAssertTrue(place.isError == true)
        XCTAssertEqual(placedObject["status"] as? String, "dispatched_unverified")
        XCTAssertTrue(
            ["logic_readback_identity_unstable", "logic_readback_track_identity_ambiguous"]
                .contains((placedObject["readback"] as? [String: Any])?["reason_code"] as? String)
        )

        let rollback = await ProjectDispatcher.handle(
            command: "rollback_ace_audio_placement",
            params: confirmationParams(planID: scenario.planID, rollback: true),
            router: scenario.router,
            cache: scenario.cache
        )
        let rollbackObject = try jsonObject(from: rollback)
        XCTAssertTrue(rollback.isError == true)
        XCTAssertEqual(rollbackObject["status"] as? String, "manual_required")
        let operations = await scenario.harness.operations()
        XCTAssertFalse(operations.contains("track.select"))
        XCTAssertFalse(operations.contains("track.delete"))
    }

    func testAssetPlanValidationRejectsDigestPathExistingTrackAndInvalidPlacement() throws {
        let fixture = try makeFixture(name: "validation")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let binding = DisposableProjectBinding(
            bindingID: "binding-validation",
            path: fixture.project.path,
            projectSHA256: fixture.projectDigest,
            authority: ACEAudioPlacementContract.disposableProjectAuthority,
            issuedAt: fixedNow.addingTimeInterval(-1),
            expiresAt: fixedNow.addingTimeInterval(60),
            originalProjectPath: "/tmp/ace-p4a-original-validation.logicx",
            originalProjectPreserved: true
        )
        let source = ACEAudioSource(
            assetID: "asset-validation",
            path: fixture.source.path,
            sha256: String(repeating: "b", count: 64),
            format: "wav"
        )
        let plan = ACEAudioPlacementPlan(
            schemaVersion: ACEAudioPlacementContract.planSchemaVersion,
            planID: "plan-validation",
            operationID: "operation-validation",
            roleID: "accompaniment",
            roleDescription: "bounded accompaniment",
            claimBoundary: "intent only",
            asset: source,
            targetProjectPath: "/tmp/wrong-project.logicx",
            targetProjectSHA256: fixture.projectDigest,
            bindingID: binding.bindingID,
            trackPolicy: "existing_stable_track",
            trackName: "Existing",
            trackTag: "ACE-P4A-validation",
            regionTag: "ACE-P4A-REGION-validation",
            placement: ACEPlacementCoordinates(bar: 2, beat: 5, tick: -1, durationBeats: 0, beatsPerBar: 4),
            tempoMode: "preserve_project_tempo",
            automaticTimeStretch: false,
            gainDB: 0,
            fadeInSeconds: 0,
            fadeOutSeconds: 0,
            collisionMode: "reject_if_collision",
            existingContentAction: "leave_unchanged",
            rollbackStrategy: ACEAudioPlacementContract.defaultRollbackStrategy,
            rollbackRequired: true,
            rollbackReceiptRequired: true
        )

        let codes = Set(ACEAudioPlacementValidator.validatePlan(plan, binding: binding).map(\.code))
        XCTAssertTrue(codes.contains("logic_target_binding_mismatch"))
        XCTAssertTrue(codes.contains("logic_existing_track_target_rejected"))
        XCTAssertTrue(codes.contains("logic_placement_invalid"))
        XCTAssertTrue(codes.contains("ace_asset_digest_mismatch"))
    }

    func testSafeHandoffCollisionActionAndAppendPolicyRemainNonDestructive() throws {
        let fixture = try makeFixture(name: "collision")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let binding = DisposableProjectBinding(
            bindingID: "binding-collision",
            path: fixture.project.path,
            projectSHA256: fixture.projectDigest,
            authority: ACEAudioPlacementContract.disposableProjectAuthority,
            issuedAt: fixedNow.addingTimeInterval(-1),
            expiresAt: fixedNow.addingTimeInterval(60),
            originalProjectPath: "/tmp/ace-p4a-original-collision.logicx",
            originalProjectPreserved: true
        )
        let source = ACEAudioSource(
            assetID: "asset-collision",
            path: fixture.source.path,
            sha256: fixture.sourceDigest,
            format: "wav"
        )
        let plan = makePlan(
            binding: binding,
            source: source,
            collisionMode: "append_on_new_track",
            existingContentAction: "leave_unchanged"
        )

        let codes = Set(ACEAudioPlacementValidator.validatePlan(plan, binding: binding).map(\.code))
        XCTAssertFalse(codes.contains("logic_destructive_collision"))
    }

    func testReceiptSerializationContainsTruthfulBeforeAfterReadbackAndRollbackFields() throws {
        let binding = DisposableProjectBinding(
            bindingID: "binding-receipt",
            path: "/tmp/disposable-receipt.logicx",
            projectSHA256: String(repeating: "a", count: 64),
            authority: ACEAudioPlacementContract.disposableProjectAuthority,
            issuedAt: fixedNow,
            expiresAt: fixedNow.addingTimeInterval(300),
            originalProjectPath: "/tmp/original-receipt.logicx",
            originalProjectPreserved: true
        )
        let source = ACEAudioSource(
            assetID: "asset-receipt",
            path: "/tmp/asset-receipt.wav",
            sha256: String(repeating: "b", count: 64),
            format: "wav"
        )
        let plan = makePlan(binding: binding, source: source)
        let snapshot = ACEPlacementSnapshot(
            observedAt: fixedNow,
            projectPath: binding.path,
            projectSHA256: binding.projectSHA256,
            generation: 1,
            tracks: [TrackState(id: 0, name: "Existing", type: .audio)],
            regions: []
        )
        let after = ACEPlacementSnapshot(
            observedAt: fixedNow.addingTimeInterval(1),
            projectPath: binding.path,
            projectSHA256: String(repeating: "c", count: 64),
            generation: 1,
            tracks: [
                TrackState(id: 0, name: "Existing", type: .audio),
                TrackState(id: 1, name: plan.trackTag, type: .audio),
            ],
            regions: []
        )
        let receipt = ACEAudioPlacementReceipt(
            receiptID: "receipt-fixed",
            operationID: plan.operationID,
            planID: plan.planID,
            phase: "verified_readback",
            status: "verified_success",
            success: true,
            issuedAt: fixedNow,
            binding: binding,
            asset: source,
            plan: plan,
            authorization: ACEPlacementAuthorization(
                required: true,
                status: "confirmed",
                confirmedBy: "test-user",
                confirmedAt: fixedNow,
                confirmationID: "confirmation-fixed"
            ),
            dispatch: ACEPlacementDispatchReceipt(
                status: "dispatched",
                method: "project.import_audio",
                receiptID: "dispatch-fixed",
                dispatchedAt: fixedNow.addingTimeInterval(1),
                sourceSHA256: source.sha256,
                message: "test dispatch"
            ),
            before: snapshot,
            after: after,
            readback: ACEPlacementReadback(
                status: "verified",
                verified: true,
                reasonCode: "logic_unique_created_layer_readback",
                observedAt: fixedNow.addingTimeInterval(2),
                projectIdentity: after.projectSHA256,
                projectPath: after.projectPath,
                assetSHA256: source.sha256,
                trackID: "1",
                regionID: "region-fixed",
                trackName: plan.trackTag,
                placement: plan.placement,
                identityKind: "operation_tag",
                evidenceURI: "logic://ace-audio/placements/plan-receipt/readback",
                assetRegionIdentity: nil
            ),
            rollback: ACEPlacementRollbackReceipt(
                status: "not_requested",
                strategy: plan.rollbackStrategy,
                mutation: "not_started",
                verification: "not_requested",
                reasonCode: "not_requested",
                receiptID: nil,
                startedAt: nil,
                completedAt: nil,
                trackID: nil,
                regionID: nil,
                evidenceURI: nil
            )
        )

        let first = encodeCompactJSON(receipt)
        let second = encodeCompactJSON(receipt)
        XCTAssertEqual(first, second)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        XCTAssertEqual(object["schema_version"] as? String, ACEAudioPlacementContract.receiptSchemaVersion)
        XCTAssertNotNil(object["before"] as? [String: Any])
        XCTAssertNotNil(object["after"] as? [String: Any])
        XCTAssertEqual((object["readback"] as? [String: Any])?["verified"] as? Bool, true)
        XCTAssertNotNil(object["rollback"] as? [String: Any])
    }

    func testVerifiedPlacementNeverAutomaticallyDeletesByVisibleTrackIndex() async throws {
        let scenario = try await makeScenario(name: "verified", ambiguous: false)
        defer { try? FileManager.default.removeItem(at: scenario.fixture.root) }

        let bind = await ProjectDispatcher.handle(
            command: "bind_disposable_project",
            params: scenario.bindingParams,
            router: scenario.router,
            cache: scenario.cache
        )
        XCTAssertFalse(bind.isError == true)

        let preview = await ProjectDispatcher.handle(
            command: "preview_ace_audio_placement",
            params: scenario.planParams,
            router: scenario.router,
            cache: scenario.cache
        )
        XCTAssertFalse(preview.isError == true)
        XCTAssertTrue(resultText(preview).contains("\"status\":\"preview_ready\""))

        let authorize = await ProjectDispatcher.handle(
            command: "authorize_ace_audio_placement",
            params: confirmationParams(planID: scenario.planID),
            router: scenario.router,
            cache: scenario.cache
        )
        XCTAssertFalse(authorize.isError == true, resultText(authorize))

        let place = await ProjectDispatcher.handle(
            command: "place_ace_audio",
            params: ["plan_id": .string(scenario.planID)],
            router: scenario.router,
            cache: scenario.cache
        )
        let placedObject = try jsonObject(from: place)
        XCTAssertFalse(place.isError == true, resultText(place))
        XCTAssertEqual(placedObject["status"] as? String, "verified_success")
        XCTAssertEqual((placedObject["dispatch"] as? [String: Any])?["status"] as? String, "dispatched")
        XCTAssertEqual((placedObject["readback"] as? [String: Any])?["verified"] as? Bool, true)
        XCTAssertEqual((placedObject["readback"] as? [String: Any])?["asset_sha256"] as? String, scenario.fixture.sourceDigest)
        XCTAssertNotNil(placedObject["before"] as? [String: Any])
        XCTAssertNotNil(placedObject["after"] as? [String: Any])

        let afterDigest = (placedObject["after"] as? [String: Any])?["project_sha256"] as? String
        XCTAssertNotEqual(afterDigest, scenario.fixture.projectDigest)
        let operationsBeforeRollback = await scenario.harness.operations()
        XCTAssertTrue(operationsBeforeRollback.contains("project.import_audio"))
        XCTAssertFalse(operationsBeforeRollback.contains("track.delete"))

        let rollback = await ProjectDispatcher.handle(
            command: "rollback_ace_audio_placement",
            params: confirmationParams(planID: scenario.planID, rollback: true),
            router: scenario.router,
            cache: scenario.cache
        )
        let rollbackObject = try jsonObject(from: rollback)
        XCTAssertTrue(rollback.isError == true)
        XCTAssertEqual(rollbackObject["status"] as? String, "manual_required")
        XCTAssertEqual((rollbackObject["rollback"] as? [String: Any])?["verification"] as? String, "unavailable")
        XCTAssertEqual((rollbackObject["rollback"] as? [String: Any])?["reason_code"] as? String, "logic_rollback_atomic_delete_key_unavailable")
        let rollbackOperations = await scenario.harness.operations()
        XCTAssertFalse(rollbackOperations.contains("track.select"))
        XCTAssertFalse(rollbackOperations.contains("track.delete"))
    }

    func testFreshProcessPlacementVerificationProvesNativeAssetIdentity() async throws {
        let scenario = try await makeScenario(name: "fresh-process", ambiguous: false)
        defer { try? FileManager.default.removeItem(at: scenario.fixture.root) }
        await prepareAuthorizedScenario(scenario)

        let placed = await ProjectDispatcher.handle(
            command: "place_ace_audio",
            params: ["plan_id": .string(scenario.planID)],
            router: scenario.router,
            cache: scenario.cache
        )
        XCTAssertFalse(placed.isError == true, resultText(placed))
        let placedObject = try jsonObject(from: placed)
        XCTAssertEqual(placedObject["status"] as? String, "verified_success")
        let placedReadback = try XCTUnwrap(placedObject["readback"] as? [String: Any])
        XCTAssertEqual(placedReadback["identity_kind"] as? String, ACEAssetRegionIdentityContract.identityKind)
        XCTAssertEqual(placedReadback["asset_sha256"] as? String, scenario.fixture.sourceDigest)
        let identity = try XCTUnwrap(placedReadback["asset_region_identity"] as? [String: Any])
        XCTAssertEqual(identity["native_source_basename"] as? String, "ace-layer")
        XCTAssertEqual(identity["observed_region_name"] as? String, "ace-layer")

        let freshRouter = ChannelRouter()
        await freshRouter.register(ACEPlacementChannel(id: .accessibility, harness: scenario.harness))
        let freshCache = StateCache()
        let receiptJSON = try XCTUnwrap(scenario.planParams["keeper_digest_receipt_json"]?.stringValue)
        let verified = await ProjectDispatcher.handle(
            command: "verify_ace_audio_placement",
            params: [
                "plan_id": .string(scenario.planID),
                "operation_id": .string("operation-fresh-process"),
                "target_project_path": .string(scenario.fixture.project.path),
                "asset_path": .string(scenario.fixture.source.path),
                "asset_sha256": .string(scenario.fixture.sourceDigest),
                "role_id": .string("accompaniment"),
                "role_description": .string("bounded accompaniment"),
                "claim_boundary": .string("intent only"),
                "bar": .int(2),
                "beat": .double(1),
                "tick": .int(0),
                "duration_beats": .double(4),
                "beats_per_bar": .int(4),
                "track_policy": .string("create_new_track"),
                "tempo_mode": .string("preserve_project_tempo"),
                "automatic_time_stretch": .bool(false),
                "collision_mode": .string("reject_if_collision"),
                "existing_content_action": .string("leave_unchanged"),
                "rollback_strategy": .string(ACEAudioPlacementContract.defaultRollbackStrategy),
                "rollback_required": .bool(true),
                "rollback_receipt_required": .bool(true),
                "keeper_digest_receipt_json": .string(receiptJSON),
                "expected_track_count": .int(2),
                "expected_region_count": .int(2),
                "expected_before_project_sha256": .string(scenario.fixture.projectDigest),
            ],
            router: freshRouter,
            cache: freshCache
        )
        let verifiedObject = try jsonObject(from: verified)
        XCTAssertFalse(verified.isError == true, resultText(verified))
        XCTAssertEqual(verifiedObject["status"] as? String, "verified_fresh_process")
        let verifiedAfter = try XCTUnwrap(verifiedObject["after"] as? [String: Any])
        XCTAssertEqual((verifiedAfter["tracks"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((verifiedAfter["regions"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((verifiedObject["readback"] as? [String: Any])?["verified"] as? Bool, true)
        XCTAssertEqual((verifiedObject["readback"] as? [String: Any])?["identity_kind"] as? String, ACEAssetRegionIdentityContract.identityKind)
        XCTAssertEqual((verifiedObject["rollback"] as? [String: Any])?["status"] as? String, "manual_required")
        let instructions = ((verifiedObject["rollback"] as? [String: Any])?["instructions"] as? [String]) ?? []
        XCTAssertFalse(instructions.isEmpty)
    }

    func testAmbiguousReadbackIsDispatchedUnverifiedAndDoesNotRollbackAutomatically() async throws {
        let scenario = try await makeScenario(name: "ambiguous", ambiguous: true)
        defer { try? FileManager.default.removeItem(at: scenario.fixture.root) }

        _ = await ProjectDispatcher.handle(
            command: "bind_disposable_project",
            params: scenario.bindingParams,
            router: scenario.router,
            cache: scenario.cache
        )
        _ = await ProjectDispatcher.handle(
            command: "preview_ace_audio_placement",
            params: scenario.planParams,
            router: scenario.router,
            cache: scenario.cache
        )
        _ = await ProjectDispatcher.handle(
            command: "authorize_ace_audio_placement",
            params: confirmationParams(planID: scenario.planID),
            router: scenario.router,
            cache: scenario.cache
        )

        let place = await ProjectDispatcher.handle(
            command: "place_ace_audio",
            params: ["plan_id": .string(scenario.planID)],
            router: scenario.router,
            cache: scenario.cache
        )
        let object = try jsonObject(from: place)
        XCTAssertTrue(place.isError == true)
        XCTAssertEqual(object["status"] as? String, "dispatched_unverified")
        XCTAssertEqual((object["readback"] as? [String: Any])?["verified"] as? Bool, false)
        XCTAssertEqual((object["readback"] as? [String: Any])?["reason_code"] as? String, "logic_readback_region_identity_ambiguous")
        let operations = await scenario.harness.operations()
        XCTAssertFalse(operations.contains("track.delete"))
    }

    func testRollbackWithoutVerifiedCreatedIdentityIsManualRequired() async throws {
        let harness = ACEPlacementHarness(projectPath: "/tmp/unused-rollback.logicx", assetSHA256: String(repeating: "a", count: 64))
        let router = ChannelRouter()
        await router.register(ACEPlacementChannel(id: .accessibility, harness: harness))
        let result = await ProjectDispatcher.handle(
            command: "rollback_ace_audio_placement",
            params: ["plan_id": .string("missing-plan")],
            router: router,
            cache: StateCache()
        )
        let object = try jsonObject(from: result)

        XCTAssertTrue(result.isError == true)
        XCTAssertEqual(object["status"] as? String, "manual_required")
        XCTAssertEqual((object["rollback"] as? [String: Any])?["status"] as? String, "manual_required")
        let operations = await harness.operations()
        XCTAssertEqual(operations, [])
    }

    // MARK: - Fixtures and scenario helpers

    private struct Fixture {
        let root: URL
        let project: URL
        let source: URL
        let projectDigest: String
        let sourceDigest: String
    }

    private struct Scenario {
        let fixture: Fixture
        let cache: StateCache
        let router: ChannelRouter
        let harness: ACEPlacementHarness
        let bindingParams: [String: Value]
        let planParams: [String: Value]
        let planID: String
    }

    private func makeFixture(name: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("logic-pro-mcp-p4a-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("disposable-copy.logicx", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try Data("stable disposable project fixture".utf8)
            .write(to: project.appendingPathComponent("project-content.txt"), options: .atomic)
        let source = root.appendingPathComponent("ace-layer.wav")
        try Data(repeating: 0x41, count: 128).write(to: source, options: .atomic)
        return Fixture(
            root: root,
            project: project,
            source: source,
            projectDigest: try ACEFileDigest.sha256(at: project.path),
            sourceDigest: try ACEFileDigest.sha256(at: source.path)
        )
    }

    private func makePlan(
        binding: DisposableProjectBinding,
        source: ACEAudioSource,
        collisionMode: String = "reject_if_collision",
        existingContentAction: String = "reject"
    ) -> ACEAudioPlacementPlan {
        ACEAudioPlacementPlan(
            schemaVersion: ACEAudioPlacementContract.planSchemaVersion,
            planID: "plan-fixed",
            operationID: "operation-fixed",
            roleID: "accompaniment",
            roleDescription: "bounded accompaniment",
            claimBoundary: "intent only",
            asset: source,
            targetProjectPath: binding.path,
            targetProjectSHA256: binding.projectSHA256,
            bindingID: binding.bindingID,
            trackPolicy: "create_new_track",
            trackName: "ACE-P4A-plan-fixed",
            trackTag: ACEAudioPlacementValidator.makeTrackTag(planID: "plan-fixed", assetSHA256: source.sha256),
            regionTag: ACEAudioPlacementValidator.makeRegionTag(operationID: "operation-fixed", assetSHA256: source.sha256),
            placement: ACEPlacementCoordinates(bar: 2, beat: 1, tick: 0, durationBeats: 4, beatsPerBar: 4),
            tempoMode: "preserve_project_tempo",
            automaticTimeStretch: false,
            gainDB: 0,
            fadeInSeconds: 0,
            fadeOutSeconds: 0,
            collisionMode: collisionMode,
            existingContentAction: existingContentAction,
            rollbackStrategy: ACEAudioPlacementContract.defaultRollbackStrategy,
            rollbackRequired: true,
            rollbackReceiptRequired: true,
            keeperDigestReceipt: keeperReceipt(for: source)
        )
    }

    private func keeperReceipt(for source: ACEAudioSource) -> ACEKeeperDigestReceipt {
        ACEKeeperDigestReceipt(
            schemaVersion: ACEAssetRegionIdentityContract.keeperDigestReceiptSchemaVersion,
            receiptID: "keeper-receipt-(source.assetID)",
            status: "verified",
            path: ACEFileDigest.normalizedPath(source.path),
            nativeSourceBasename: source.nativeSourceBasename,
            sha256: source.sha256,
            verifiedAt: fixedNow,
            verifiedBy: "test/keeper-verifier"
        )
    }

    private func makeScenario(
        name: String,
        ambiguous: Bool,
        projectReadback: ProjectInfo? = nil,
        beforeIdentityStability: StateIdentityStability = .stable,
        afterIdentityStability: StateIdentityStability? = nil,
        uiImportResult: ChannelResult? = nil,
        tagResult: ChannelResult? = nil
    ) async throws -> Scenario {
        let fixture = try makeFixture(name: name)
        let planID = "plan-\(name)"
        let operationID = "operation-\(name)"
        let trackTag = ACEAudioPlacementValidator.makeTrackTag(planID: planID, assetSHA256: fixture.sourceDigest)
        let regionTag = ACEAudioPlacementValidator.makeRegionTag(operationID: operationID, assetSHA256: fixture.sourceDigest)
        let harness = ACEPlacementHarness(
            projectPath: fixture.project.path,
            assetSHA256: fixture.sourceDigest,
            nativeSourceBasename: fixture.source.deletingPathExtension().lastPathComponent,
            trackTag: trackTag,
            regionTag: regionTag,
            ambiguous: ambiguous,
            projectReadback: projectReadback,
            beforeIdentityStability: beforeIdentityStability,
            afterIdentityStability: afterIdentityStability,
            uiImportResult: uiImportResult,
            tagResult: tagResult
        )
        let accessibility = ACEPlacementChannel(id: .accessibility, harness: harness)
        let appleScript = ACEPlacementChannel(id: .appleScript, harness: harness)
        let router = ChannelRouter()
        await router.register(accessibility)
        await router.register(appleScript)

        var project = ProjectInfo(name: "P4A Disposable", filePath: fixture.project.path, lastUpdated: Date())
        project.projectIdentity = .stable(path: fixture.project.path)
        let cache = StateCache()
        await cache.updateProject(project)

        let bindingParams: [String: Value] = [
            "binding_id": .string("binding-\(name)"),
            "path": .string(fixture.project.path),
            "sha256": .string(fixture.projectDigest),
            "original_project_path": .string("/tmp/ace-p4a-original-\(name).logicx"),
            "expires_at": .string(iso8601(Date().addingTimeInterval(300))),
        ]
        let planParams: [String: Value] = [
            "plan_id": .string(planID),
            "operation_id": .string(operationID),
            "asset_id": .string("asset-\(name)"),
            "asset_path": .string(fixture.source.path),
            "asset_sha256": .string(fixture.sourceDigest),
            "format": .string("wav"),
            "role_id": .string("accompaniment"),
            "role_description": .string("bounded accompaniment"),
            "claim_boundary": .string("intent only"),
            "bar": .int(2),
            "beat": .double(1),
            "tick": .int(0),
            "duration_beats": .double(4),
            "beats_per_bar": .int(4),
            "track_policy": .string("create_new_track"),
            "tempo_mode": .string("preserve_project_tempo"),
            "automatic_time_stretch": .bool(false),
            "collision_mode": .string("reject_if_collision"),
            "existing_content_action": .string("leave_unchanged"),
            "rollback_strategy": .string(ACEAudioPlacementContract.defaultRollbackStrategy),
            "rollback_required": .bool(true),
            "rollback_receipt_required": .bool(true),
            "keeper_digest_receipt_json": .string(encodeCompactJSON(keeperReceipt(for: ACEAudioSource(
                assetID: "asset-(name)",
                path: fixture.source.path,
                sha256: fixture.sourceDigest,
                format: "wav"
            )))),
        ]
        return Scenario(
            fixture: fixture,
            cache: cache,
            router: router,
            harness: harness,
            bindingParams: bindingParams,
            planParams: planParams,
            planID: planID
        )
    }

    private func prepareAuthorizedScenario(_ scenario: Scenario) async {
        _ = await ProjectDispatcher.handle(
            command: "bind_disposable_project",
            params: scenario.bindingParams,
            router: scenario.router,
            cache: scenario.cache
        )
        _ = await ProjectDispatcher.handle(
            command: "preview_ace_audio_placement",
            params: scenario.planParams,
            router: scenario.router,
            cache: scenario.cache
        )
        _ = await ProjectDispatcher.handle(
            command: "authorize_ace_audio_placement",
            params: confirmationParams(planID: scenario.planID),
            router: scenario.router,
            cache: scenario.cache
        )
    }

    private func confirmationParams(planID: String, rollback: Bool = false) -> [String: Value] {
        if rollback {
            return [
                "plan_id": .string(planID),
                "rollback_confirmation_id": .string("rollback-confirmation-\(planID)"),
                "rollback_confirmed_by": .string("test-user"),
                "rollback_confirmed_at": .string(iso8601(Date().addingTimeInterval(-1))),
            ]
        }
        return [
            "plan_id": .string(planID),
            "confirmation_id": .string("confirmation-\(planID)"),
            "confirmed_by": .string("test-user"),
            "confirmed_at": .string(iso8601(Date().addingTimeInterval(-1))),
        ]
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func jsonObject(from result: CallTool.Result) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(resultText(result).utf8)) as? [String: Any])
    }

    private func resultText(_ result: CallTool.Result) -> String {
        for content in result.content {
            if case let .text(text, _, _) = content { return text }
        }
        return ""
    }
}

private actor ACEPlacementHarness {
    let projectPath: String
    let assetSHA256: String
    let nativeSourceBasename: String
    let trackTag: String
    let regionTag: String
    let ambiguous: Bool
    let projectReadback: ProjectInfo
    let beforeIdentityStability: StateIdentityStability
    let afterIdentityStability: StateIdentityStability?
    let uiImportResult: ChannelResult?
    let tagResult: ChannelResult?
    private var imported = false
    private var deleted = false
    private var operationLog: [String] = []

    init(
        projectPath: String,
        assetSHA256: String,
        nativeSourceBasename: String = "ace-layer",
        trackTag: String = "ACE-P4A-test",
        regionTag: String = "ACE-P4A-REGION-test",
        ambiguous: Bool = false,
        projectReadback: ProjectInfo? = nil,
        beforeIdentityStability: StateIdentityStability = .stable,
        afterIdentityStability: StateIdentityStability? = nil,
        uiImportResult: ChannelResult? = nil,
        tagResult: ChannelResult? = nil
    ) {
        self.projectPath = projectPath
        self.assetSHA256 = assetSHA256
        self.nativeSourceBasename = nativeSourceBasename
        self.trackTag = trackTag
        self.regionTag = regionTag
        self.ambiguous = ambiguous
        if let projectReadback {
            self.projectReadback = projectReadback
        } else {
            var defaultProject = ProjectInfo(name: "P4A Disposable", filePath: projectPath, lastUpdated: Date())
            defaultProject.projectIdentity = .stable(path: projectPath)
            self.projectReadback = defaultProject
        }
        self.beforeIdentityStability = beforeIdentityStability
        self.afterIdentityStability = afterIdentityStability
        self.uiImportResult = uiImportResult
        self.tagResult = tagResult
    }

    func execute(operation: String, params: [String: String]) -> ChannelResult {
        operationLog.append(operation)
        switch operation {
        case "project.get_info":
            return .success(encodeCompactJSON(projectReadback))
        case "track.get_tracks":
            return .success(encodeCompactJSON(tracks()))
        case "region.get_regions":
            return .success(encodeCompactJSON(regions()))
        case "project.read_ace_audio_placement_geometry":
            let bar = Int(params["bar"] ?? "") ?? 0
            let beat = Double(params["beat"] ?? "") ?? 0
            let tick = Int(params["tick"] ?? "") ?? 0
            let duration = Double(params["duration_beats"] ?? "") ?? 0
            return .success(encodeCompactJSON(ACEAudioDeltaGeometry(
                status: "verified",
                verified: true,
                reasonCode: "test_geometry",
                requestedBar: bar,
                requestedBeat: beat,
                requestedTick: tick,
                observedBar: Double(bar),
                observedBeat: beat,
                timeRuler: nil,
                barOnePlayhead: nil,
                barTwoPlayhead: nil,
                targetRegion: nil,
                pixelsPerBeat: 10,
                estimatedDurationBeats: duration,
                startAlignmentPixels: 0,
                geometryTolerancePixels: ACEAudioDeltaAdoptionContract.defaultGeometryTolerancePixels,
                durationToleranceBeats: ACEAudioDeltaAdoptionContract.defaultDurationToleranceBeats,
                basis: "deterministic test geometry",
                observedAt: Date()
            )))
        case "project.tag_imported_audio":
            if let tagResult { return tagResult }
            return .success("{\"verification\":\"direct_readback\",\"region_name_mutation\":\"not_issued\"}")
        case "project.import_audio":
            if let uiImportResult { return uiImportResult }
            imported = true
            touchProject(marker: "imported")
            return .success("{\"imported\":true}")
        case "track.select":
            return .success("{\"selected\":true}")
        case "track.delete":
            deleted = true
            touchProject(marker: "rollback")
            return .success("{\"deleted\":true}")
        default:
            return .error("unsupported test operation: \(operation)")
        }
    }

    func operations() -> [String] { operationLog }

    private func tracks() -> [TrackState] {
        let identity = projectReadback.projectIdentity
        // Existing AX rows remain visible-only even when the fixture's old
        // `beforeIdentityStability` default was `.stable`. Only the tagged
        // created row receives a stable operation-tag identity.
        let existingStability: StateIdentityStability = beforeIdentityStability == .stable
            ? .synthetic
            : beforeIdentityStability
        let existingScope = existingStability == .stable ? "project_bound" : "visible_only"
        let existing = TrackState(
            id: 0,
            name: "Existing",
            type: .audio,
            projectIdentity: identity,
            generation: 1,
            identityStability: existingStability,
            identityScope: existingScope
        )
        guard imported && !deleted else { return [existing] }
        let createdStability = afterIdentityStability ?? .stable
        let createdScope = createdStability == .stable ? "project_bound" : "visible_only"
        let created = TrackState(
            id: 1,
            name: trackTag,
            type: .audio,
            projectIdentity: identity,
            generation: 1,
            identityStability: createdStability,
            identityScope: createdScope,
            stableID: createdStability == .stable
                ? OperationTagIdentity.trackID(projectIdentity: identity, operationTag: trackTag)
                : nil
        )
        return [existing, created]
    }

    private func regions() -> [RegionState] {
        let identity = projectReadback.projectIdentity
        let existingStability: StateIdentityStability = beforeIdentityStability == .stable
            ? .synthetic
            : beforeIdentityStability
        let existingScope = existingStability == .stable ? "project_bound" : "visible_only"
        let existing = RegionState(
            id: "existing-region",
            name: "Existing Region",
            trackIndex: 0,
            trackName: "Existing",
            startPosition: "1.1.0",
            endPosition: "2.1.0",
            length: "4.0",
            projectIdentity: identity,
            generation: 1,
            identityStability: existingStability,
            identityScope: existingScope
        )
        guard imported && !deleted else { return [existing] }
        // A native-name Logic region has no operation-tag stable ID. Its
        // separate asset-region identity is derived by the coordinator from
        // the stable tagged parent track plus the keeper receipt.
        let createdStability: StateIdentityStability = .synthetic
        let createdTrackStable = (afterIdentityStability ?? .stable) == .stable
        let createdScope = "visible_only"
        let name = ambiguous ? "Imported Audio (ambiguous)" : nativeSourceBasename
        let created = RegionState(
            id: "created-region",
            name: name,
            trackIndex: 1,
            trackName: trackTag,
            startPosition: "2.1.0",
            endPosition: "3.1.0",
            length: "4.0",
            projectIdentity: identity,
            generation: 1,
            identityStability: createdStability,
            identityScope: createdScope,
            stableID: nil,
            trackStableID: createdTrackStable
                ? OperationTagIdentity.trackID(projectIdentity: identity, operationTag: trackTag)
                : nil
        )
        return [existing, created]
    }

    private func touchProject(marker: String) {
        let markerURL = URL(fileURLWithPath: projectPath).appendingPathComponent("\(marker).marker")
        try? Data(marker.utf8).write(to: markerURL, options: .atomic)
    }
}

private actor ACEPlacementChannel: Channel {
    nonisolated let id: ChannelID
    let harness: ACEPlacementHarness

    init(id: ChannelID, harness: ACEPlacementHarness) {
        self.id = id
        self.harness = harness
    }

    func start() async throws {}
    func stop() async {}
    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        await harness.execute(operation: operation, params: params)
    }
    func healthCheck() async -> ChannelHealth { .healthy(detail: "deterministic P4A test channel") }
}
