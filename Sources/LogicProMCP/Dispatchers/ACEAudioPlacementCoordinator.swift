import Foundation
import MCP

enum ACEAudioPlacementCoordinator {
    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "bind_disposable_project":
            return await bindDisposableProject(params: params, cache: cache)
        case "verify_keeper_digest":
            return verifyKeeperDigest(params: params)
        case "preview_ace_audio_placement":
            return await preview(params: params, router: router, cache: cache)
        case "authorize_ace_audio_placement":
            return await authorize(params: params, cache: cache)
        case "place_ace_audio":
            return await place(params: params, router: router, cache: cache)
        case "tag_ace_audio_after_import":
            return await tagAfterSingleImport(params: params, router: router, cache: cache)
        case "verify_ace_audio_placement":
            return await verifyPlacement(params: params, router: router, cache: cache)
        case "rollback_ace_audio_placement":
            return await rollback(params: params, router: router, cache: cache)
        case "adopt_ace_audio_delta":
            return await adoptDelta(params: params, router: router, cache: cache)
        case "verify_ace_audio_delta":
            return await verifyDelta(params: params, router: router, cache: cache)
        case "rollback_ace_audio_delta":
            return await rollbackDelta(params: params, router: router, cache: cache)
        default:
            return CallTool.Result(content: [.text("Unknown ACE audio placement command: \(command)")], isError: true)
        }
    }

    private struct KeeperDigestVerificationFailure: Codable, Sendable {
        var status: String
        var success: Bool
        var path: String
        var nativeSourceBasename: String?
        var sha256: String?
        var validationIssues: [ACEPlacementIssue]

        enum CodingKeys: String, CodingKey {
            case status
            case success
            case path
            case nativeSourceBasename = "native_source_basename"
            case sha256
            case validationIssues = "validation_issues"
        }
    }

    private static func verifyKeeperDigest(params: [String: Value]) -> CallTool.Result {
        let rawPath = firstString(params, keys: ["path", "asset_path"]) ?? ""
        let normalizedPath = ACEFileDigest.normalizedPath(rawPath)
        let expectedSHA = firstString(params, keys: ["sha256", "asset_sha256"])
        let expectedBasename = firstString(params, keys: ["native_source_basename", "source_basename"])
        let observedBasename = ACEAudioSource.sourceBasename(for: rawPath)
        var issues: [ACEPlacementIssue] = []

        if rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(code: "ace_keeper_path_missing", message: "keeper path is required", path: "$.path"))
        } else if observedBasename == nil {
            issues.append(ACEPlacementIssue(code: "ace_keeper_basename_unavailable", message: "keeper path must provide a non-empty native source basename", path: "$.path"))
        }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: normalizedPath) {
            issues.append(ACEPlacementIssue(code: "ace_keeper_missing", message: "keeper path does not exist", path: "$.path"))
        } else if !fileManager.isReadableFile(atPath: normalizedPath) {
            issues.append(ACEPlacementIssue(code: "ace_keeper_unreadable", message: "keeper path is not readable", path: "$.path"))
        } else if let attributes = try? fileManager.attributesOfItem(atPath: normalizedPath),
                  (attributes[.type] as? FileAttributeType) != .typeRegular {
            issues.append(ACEPlacementIssue(code: "ace_keeper_not_regular", message: "keeper source must be a regular file", path: "$.path"))
        }

        var actualSHA: String?
        if issues.isEmpty {
            do {
                actualSHA = try ACEFileDigest.sha256(at: normalizedPath)
            } catch {
                issues.append(ACEPlacementIssue(code: "ace_keeper_digest_unavailable", message: "keeper digest could not be independently computed", path: "$.path"))
            }
        }
        if let expectedSHA,
           !ACEFileDigest.isSHA256(expectedSHA) {
            issues.append(ACEPlacementIssue(code: "ace_keeper_expected_digest_invalid", message: "expected keeper sha256 must be a lowercase SHA-256 digest", path: "$.sha256"))
        } else if let expectedSHA, let actualSHA, expectedSHA != actualSHA {
            issues.append(ACEPlacementIssue(code: "ace_keeper_expected_digest_mismatch", message: "keeper digest does not match the expected SHA-256", path: "$.sha256"))
        }
        if let expectedBasename,
           expectedBasename != observedBasename {
            issues.append(ACEPlacementIssue(code: "ace_keeper_expected_basename_mismatch", message: "keeper basename does not match the expected native source basename", path: "$.native_source_basename"))
        }

        guard issues.isEmpty,
              let actualSHA,
              let observedBasename else {
            let failure = KeeperDigestVerificationFailure(
                status: "rejected",
                success: false,
                path: normalizedPath,
                nativeSourceBasename: observedBasename,
                sha256: actualSHA,
                validationIssues: uniqueIssues(issues)
            )
            return CallTool.Result(content: [.text(encodeCompactJSON(failure))], isError: true)
        }

        let receipt = ACEKeeperDigestReceipt(
            schemaVersion: ACEAssetRegionIdentityContract.keeperDigestReceiptSchemaVersion,
            receiptID: firstString(params, keys: ["receipt_id"]) ?? "keeper-digest-(actualSHA.prefix(16))",
            status: "verified",
            path: normalizedPath,
            nativeSourceBasename: observedBasename,
            sha256: actualSHA,
            verifiedAt: Date(),
            verifiedBy: firstString(params, keys: ["verified_by"]) ?? "logic-pro-mcp/keeper-digest-verifier-v1"
        )
        return CallTool.Result(content: [.text(encodeCompactJSON(receipt))], isError: false)
    }

    // MARK: - Binding

    private static func bindDisposableProject(
        params: [String: Value],
        cache: StateCache
    ) async -> CallTool.Result {
        let now = Date()
        let path = firstString(params, keys: ["path", "project_path"]) ?? ""
        let digest = firstString(params, keys: ["sha256", "project_sha256"]) ?? ""
        let bindingID = firstString(params, keys: ["binding_id"]) ?? "binding-\(digest.prefix(16))"
        let authority = firstString(params, keys: ["authority"]) ?? ACEAudioPlacementContract.disposableProjectAuthority
        let originalPath = firstString(params, keys: ["original_project_path"])
        let originalPreserved = boolValue(params["original_project_preserved"]) ?? true
        let issuedAt = parseDate(firstString(params, keys: ["issued_at"])) ?? now
        let expiresAt = parseDate(firstString(params, keys: ["expires_at"])) ?? .distantPast

        let binding = DisposableProjectBinding(
            bindingID: bindingID,
            path: ACEFileDigest.normalizedPath(path),
            projectSHA256: digest,
            authority: authority,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            originalProjectPath: originalPath,
            originalProjectPreserved: originalPreserved
        )
        var issues: [ACEPlacementIssue] = []
        if parseDate(firstString(params, keys: ["expires_at"])) == nil {
            issues.append(ACEPlacementIssue(code: "logic_binding_expiry_invalid", message: "expires_at must be an ISO-8601 timestamp", path: "$.binding.expires_at"))
        }
        issues += ACEAudioPlacementValidator.validateBinding(binding, now: now)
        issues = uniqueIssues(issues)

        let receipt = ACEAudioPlacementReceipt(
            receiptID: receiptID(operationID: binding.bindingID, phase: "binding", status: issues.isEmpty ? "bound" : "rejected"),
            operationID: binding.bindingID,
            planID: binding.bindingID,
            phase: "binding",
            status: issues.isEmpty ? "bound" : "rejected",
            success: issues.isEmpty,
            issuedAt: now,
            binding: binding,
            asset: nil,
            plan: nil,
            authorization: .pending,
            dispatch: notDispatchedReceipt(),
            validationIssues: issues,
            error: issues.first?.message
        )
        if issues.isEmpty {
            await cache.updateDisposableProjectBinding(binding)
        }
        return await emit(receipt, cache: cache)
    }

    // MARK: - Preview and authorization

    private static func preview(
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        _ = router // Preview is deliberately local and does not touch a Logic channel.
        let now = Date()
        guard let binding = await cache.getDisposableProjectBinding() else {
            return await rejectedReceipt(
                operationID: firstString(params, keys: ["operation_id"]) ?? "ace-audio-preview",
                planID: firstString(params, keys: ["plan_id"]) ?? "ace-audio-preview",
                phase: "preview",
                errorCode: "logic_disposable_binding_missing",
                message: "no explicit disposable-project binding is active; no mutation started",
                cache: cache
            )
        }

        let currentProject = await cache.getProject()
        let generation = await cache.getGeneration()
        let bindingIssues = ACEAudioPlacementValidator.validateBinding(
            binding,
            currentProject: currentProject,
            cacheGeneration: generation,
            now: now
        )
        let built = buildPlan(params: params, binding: binding)
        let issues = uniqueIssues(bindingIssues + built.issues + ACEAudioPlacementValidator.validatePlan(built.plan, binding: binding))
        guard issues.isEmpty else {
            return await rejectedReceipt(
                operationID: built.plan.operationID,
                planID: built.plan.planID,
                phase: "preview",
                binding: binding,
                asset: built.plan.asset,
                plan: built.plan,
                issues: issues,
                cache: cache
            )
        }

        let session = ACEAudioPlacementSession(
            plan: built.plan,
            authorization: .pending,
            lastReceipt: nil
        )
        await cache.updateACEPlacementSession(session)
        let receipt = ACEAudioPlacementReceipt(
            receiptID: receiptID(operationID: built.plan.operationID, phase: "preview", status: "preview_ready"),
            operationID: built.plan.operationID,
            planID: built.plan.planID,
            phase: "preview",
            status: "preview_ready",
            success: true,
            issuedAt: now,
            binding: binding,
            asset: built.plan.asset,
            plan: built.plan,
            authorization: .pending,
            dispatch: notDispatchedReceipt(),
            validationIssues: [],
            error: nil
        )
        return await emit(receipt, cache: cache)
    }

    private static func authorize(
        params: [String: Value],
        cache: StateCache
    ) async -> CallTool.Result {
        let now = Date()
        let planID = firstString(params, keys: ["plan_id"]) ?? ""
        guard let session = await cache.getACEPlacementSession(planID: planID),
              let binding = await cache.getDisposableProjectBinding() else {
            return await rejectedReceipt(
                operationID: firstString(params, keys: ["operation_id"]) ?? planID,
                planID: planID,
                phase: "authorized_mutation_request",
                errorCode: "logic_preview_missing",
                message: "a valid preview and active disposable binding are required before authorization",
                cache: cache
            )
        }

        let currentProject = await cache.getProject()
        let generation = await cache.getGeneration()
        let confirmation = parseConfirmation(params: params)
        let issues = uniqueIssues(
            ACEAudioPlacementValidator.validateBinding(binding, currentProject: currentProject, cacheGeneration: generation, now: now)
                + ACEAudioPlacementValidator.validatePlan(session.plan, binding: binding)
                + validateConfirmation(confirmation, now: now)
        )
        guard issues.isEmpty else {
            return await rejectedReceipt(
                operationID: session.plan.operationID,
                planID: session.plan.planID,
                phase: "authorized_mutation_request",
                binding: binding,
                asset: session.plan.asset,
                plan: session.plan,
                authorization: confirmation,
                issues: issues,
                cache: cache
            )
        }

        var authorizedSession = session
        authorizedSession.authorization = confirmation
        await cache.updateACEPlacementSession(authorizedSession)
        let receipt = ACEAudioPlacementReceipt(
            receiptID: receiptID(operationID: session.plan.operationID, phase: "authorized_mutation_request", status: "authorized"),
            operationID: session.plan.operationID,
            planID: session.plan.planID,
            phase: "authorized_mutation_request",
            status: "authorized",
            success: true,
            issuedAt: now,
            binding: binding,
            asset: session.plan.asset,
            plan: session.plan,
            authorization: confirmation,
            dispatch: notDispatchedReceipt(),
            validationIssues: [],
            error: nil
        )
        return await emit(receipt, cache: cache)
    }

    // MARK: - Exact P5G delta adoption

    private static func adoptDelta(
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        Log.info("P5G adoption entered", subsystem: "aceAdoption")
        let built = buildAdoptionSpec(params: params)
        guard let spec = built.spec else {
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: built.operationID, phase: "adoption", status: "rejected"),
                    planID: built.planID,
                    operationID: built.operationID,
                    phase: "adoption",
                    status: "rejected",
                    success: false,
                    validationIssues: built.issues,
                    error: built.issues.first?.message
                )
            )
        }
        let confirmation = parseConfirmation(params: params)
        let specIssues = uniqueIssues(built.issues + ACEAudioDeltaAdoptionValidator.validateSpec(spec) + validateConfirmation(confirmation, now: Date()))
        Log.info("P5G adoption spec validation issues: \(specIssues.count)", subsystem: "aceAdoption")
        guard specIssues.isEmpty else {
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "adoption", status: "rejected"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "adoption",
                    status: "rejected",
                    success: false,
                    spec: spec,
                    validationIssues: specIssues,
                    error: specIssues.first?.message
                )
            )
        }

        guard let binding = await cache.getDisposableProjectBinding() else {
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "adoption", status: "rejected"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "adoption",
                    status: "rejected",
                    success: false,
                    spec: spec,
                    validationIssues: [ACEPlacementIssue(code: "logic_adoption_binding_missing", message: "an explicit disposable-project binding is required; no adoption mutation started")],
                    error: "an explicit disposable-project binding is required; no adoption mutation started"
                )
            )
        }
        guard binding.projectSHA256 == spec.startingProjectSHA256,
              ACEFileDigest.normalizedPath(binding.path) == ACEFileDigest.normalizedPath(spec.targetProjectPath) else {
            let issue = ACEPlacementIssue(code: "logic_adoption_binding_mismatch", message: "adoption is bound to a different disposable path or digest; no mutation started")
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "adoption", status: "rejected"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "adoption",
                    status: "rejected",
                    success: false,
                    spec: spec,
                    validationIssues: [issue],
                    error: issue.message
                )
            )
        }

        Log.info("P5G adoption requesting before snapshot", subsystem: "aceAdoption")
        guard let beforeResult = await freshSnapshotWithRetry(
            binding: binding,
            router: router,
            cache: cache,
            now: Date(),
            requireBindingDigest: true
        ) else {
            let issue = ACEPlacementIssue(code: "logic_adoption_before_readback_unavailable", message: "fresh exact-delta project/track/region readback was unavailable; no adoption mutation started")
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "adoption", status: "rejected"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "adoption",
                    status: "rejected",
                    success: false,
                    spec: spec,
                    validationIssues: [issue],
                    error: issue.message
                )
            )
        }
        Log.info("P5G adoption before snapshot received", subsystem: "aceAdoption")
        let before = beforeResult.snapshot
        let deltaIssues = ACEAudioDeltaAdoptionValidator.validateStartingDelta(before, spec: spec)
        let resumedAfterCleanup = !deltaIssues.isEmpty
            && ACEAudioDeltaAdoptionValidator.validateAfterCleanup(before, spec: spec).isEmpty
        guard deltaIssues.isEmpty || resumedAfterCleanup else {
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "adoption", status: "rejected"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "adoption",
                    status: "rejected",
                    success: false,
                    spec: spec,
                    before: before,
                    validationIssues: deltaIssues,
                    error: deltaIssues.first?.message
                )
            )
        }

        let channelParams = adoptionChannelParams(spec)
        var cleanup = before
        if !resumedAfterCleanup {
            let removeResult = await router.route(operation: "project.remove_ace_audio_delta_duplicate", params: channelParams)
            guard removeResult.isSuccess else {
                let issue = ACEPlacementIssue(code: "logic_adoption_duplicate_cleanup_failed", message: removeResult.message)
                return emitAdoption(
                    ACEAudioDeltaAdoptionReceipt(
                        receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "cleanup", status: "rejected"),
                        planID: spec.planID,
                        operationID: spec.operationID,
                        phase: "cleanup",
                        status: "rejected",
                        success: false,
                        spec: spec,
                        before: before,
                        removedDuplicateRegion: spec.duplicateRegionName,
                        validationIssues: [issue],
                        error: issue.message
                    )
                )
            }

            guard let cleanupResult = await freshSnapshotWithRetry(
                binding: binding,
                router: router,
                cache: cache,
                now: Date(),
                requireBindingDigest: false
            ) else {
                let issue = ACEPlacementIssue(code: "logic_adoption_cleanup_readback_unavailable", message: "duplicate cleanup was dispatched but the fresh cleanup snapshot was unavailable")
                return emitAdoption(
                    ACEAudioDeltaAdoptionReceipt(
                        receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "cleanup", status: "dispatched_unverified"),
                        planID: spec.planID,
                        operationID: spec.operationID,
                        phase: "cleanup",
                        status: "dispatched_unverified",
                        success: false,
                        spec: spec,
                        before: before,
                        removedDuplicateRegion: spec.duplicateRegionName,
                        validationIssues: [issue],
                        error: issue.message
                    )
                )
            }
            cleanup = cleanupResult.snapshot
            let cleanupIssues = ACEAudioDeltaAdoptionValidator.validateAfterCleanup(cleanup, spec: spec)
            guard cleanupIssues.isEmpty else {
                return emitAdoption(
                    ACEAudioDeltaAdoptionReceipt(
                        receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "cleanup", status: "dispatched_unverified"),
                        planID: spec.planID,
                        operationID: spec.operationID,
                        phase: "cleanup",
                        status: "dispatched_unverified",
                        success: false,
                        spec: spec,
                        before: before,
                        after: cleanup,
                        removedDuplicateRegion: spec.duplicateRegionName,
                        validationIssues: cleanupIssues,
                        error: cleanupIssues.first?.message
                    )
                )
            }
        }

        let tagResult = await router.route(operation: "project.tag_ace_audio_delta", params: channelParams)
        guard tagResult.isSuccess else {
            let issue = ACEPlacementIssue(code: "logic_adoption_tagging_failed", message: tagResult.message)
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "tagging", status: "dispatched_unverified"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "tagging",
                    status: "dispatched_unverified",
                    success: false,
                    spec: spec,
                    before: before,
                    after: cleanup,
                    removedDuplicateRegion: spec.duplicateRegionName,
                    validationIssues: [issue],
                    error: issue.message
                )
            )
        }

        guard let taggedResult = await freshSnapshotWithRetry(
            binding: binding,
            router: router,
            cache: cache,
            now: Date(),
            requireBindingDigest: false
        ) else {
            let issue = ACEPlacementIssue(code: "logic_adoption_tag_readback_unavailable", message: "tagging was dispatched but a fresh tagged snapshot was unavailable")
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "tagging", status: "dispatched_unverified"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "tagging",
                    status: "dispatched_unverified",
                    success: false,
                    spec: spec,
                    before: before,
                    after: cleanup,
                    removedDuplicateRegion: spec.duplicateRegionName,
                    validationIssues: [issue],
                    error: issue.message
                )
            )
        }
        let tagged = taggedResult.snapshot
        let tagIssues = ACEAudioDeltaAdoptionValidator.validateTagged(tagged, spec: spec)
        guard tagIssues.isEmpty else {
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "tagging", status: "dispatched_unverified"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "tagging",
                    status: "dispatched_unverified",
                    success: false,
                    spec: spec,
                    before: before,
                    after: tagged,
                    removedDuplicateRegion: spec.duplicateRegionName,
                    validationIssues: tagIssues,
                    error: tagIssues.first?.message
                )
            )
        }

        let saveResult = await router.route(operation: "project.save")
        let saveStatus = saveResult.isSuccess ? "dispatched" : "dispatch_failed"
        let saveDispatch = ACEPlacementDispatchReceipt(
            status: saveStatus,
            method: "project.save",
            receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "save", status: saveStatus),
            dispatchedAt: Date(),
            sourceSHA256: nil,
            message: saveResult.message
        )
        guard saveResult.isSuccess else {
            let issue = ACEPlacementIssue(code: "logic_adoption_save_failed", message: saveResult.message)
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "save", status: "dispatched_unverified"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "save",
                    status: "dispatched_unverified",
                    success: false,
                    spec: spec,
                    before: before,
                    after: tagged,
                    removedDuplicateRegion: spec.duplicateRegionName,
                    trackID: tagged.tracks.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag })?.stableID,
                    regionID: tagged.regions.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.regionTag })?.stableID,
                    sourceSHA256: spec.source.sha256,
                    saveDispatch: saveDispatch,
                    finalProjectSHA256: tagged.projectSHA256,
                    rollback: .manual(spec: spec, projectPath: tagged.projectPath),
                    validationIssues: [issue],
                    error: issue.message
                )
            )
        }

        var saved = tagged
        for attempt in 0..<12 {
            if let candidate = await freshSnapshot(
                binding: binding,
                router: router,
                cache: cache,
                now: Date(),
                requireBindingDigest: false
            )?.snapshot {
                saved = candidate
                if candidate.projectSHA256 != spec.startingProjectSHA256 {
                    break
                }
            }
            if attempt < 11 {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        guard saved.projectSHA256 != spec.startingProjectSHA256 else {
            let issue = ACEPlacementIssue(code: "logic_adoption_save_digest_unchanged", message: "save dispatch returned but the disposable digest did not change; after bounce is stopped")
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "save", status: "dispatched_unverified"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "save",
                    status: "dispatched_unverified",
                    success: false,
                    spec: spec,
                    before: before,
                    after: saved,
                    removedDuplicateRegion: spec.duplicateRegionName,
                    trackID: saved.tracks.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag })?.stableID,
                    regionID: saved.regions.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.regionTag })?.stableID,
                    sourceSHA256: spec.source.sha256,
                    saveDispatch: saveDispatch,
                    finalProjectSHA256: saved.projectSHA256,
                    rollback: .manual(spec: spec, projectPath: saved.projectPath),
                    validationIssues: [issue],
                    error: issue.message
                )
            )
        }

        let geometryResult = await router.route(
            operation: "project.read_ace_audio_delta_geometry",
            params: ["spec_json": encodeCompactJSON(spec)]
        )
        guard geometryResult.isSuccess,
              let geometry = decode(ACEAudioDeltaGeometry.self, from: geometryResult.message.data(using: .utf8) ?? Data()),
              ACEAudioDeltaAdoptionValidator.validateGeometry(geometry, placement: spec.placement).isEmpty else {
            let geometry = decode(ACEAudioDeltaGeometry.self, from: geometryResult.message.data(using: .utf8) ?? Data())
            let geometryIssues = geometry.map { ACEAudioDeltaAdoptionValidator.validateGeometry($0, placement: spec.placement) }
                ?? [ACEPlacementIssue(code: "logic_adoption_geometry_readback_unavailable", message: geometryResult.message)]
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "geometry", status: "dispatched_unverified"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "geometry",
                    status: "dispatched_unverified",
                    success: false,
                    spec: spec,
                    before: before,
                    after: saved,
                    removedDuplicateRegion: spec.duplicateRegionName,
                    trackID: saved.tracks.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag })?.stableID,
                    regionID: saved.regions.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.regionTag })?.stableID,
                    sourceSHA256: spec.source.sha256,
                    geometry: geometry,
                    saveDispatch: saveDispatch,
                    finalProjectSHA256: saved.projectSHA256,
                    rollback: .manual(spec: spec, projectPath: saved.projectPath),
                    validationIssues: geometryIssues,
                    error: geometryIssues.first?.message
                )
            )
        }

        let track = saved.tracks.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag })
        let region = saved.regions.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.regionTag })
        let receipt = ACEAudioDeltaAdoptionReceipt(
            receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "adoption", status: "verified_adopted"),
            planID: spec.planID,
            operationID: spec.operationID,
            phase: "verified_adopted",
            status: "verified_adopted",
            success: true,
            spec: spec,
            before: before,
            after: saved,
            removedDuplicateRegion: spec.duplicateRegionName,
            trackID: track?.stableID,
            regionID: region?.stableID,
            sourceSHA256: spec.source.sha256,
            geometry: geometry,
            saveDispatch: saveDispatch,
            finalProjectSHA256: saved.projectSHA256,
            rollback: .manual(spec: spec, projectPath: saved.projectPath)
        )
        return emitAdoption(receipt)
    }

    private static func verifyDelta(
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        let built = buildAdoptionSpec(params: params)
        guard let spec = built.spec else {
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: built.operationID, phase: "fresh_process_verification", status: "rejected"),
                    planID: built.planID,
                    operationID: built.operationID,
                    phase: "fresh_process_verification",
                    status: "rejected",
                    success: false,
                    validationIssues: built.issues,
                    error: built.issues.first?.message
                )
            )
        }
        let specIssues = uniqueIssues(built.issues + ACEAudioDeltaAdoptionValidator.validateSpec(spec))
        guard specIssues.isEmpty,
              let currentResult = await freshUnboundAdoptionSnapshot(spec: spec, router: router, cache: cache) else {
            let issue = specIssues.first ?? ACEPlacementIssue(code: "logic_adoption_fresh_readback_unavailable", message: "fresh-process project/track/region readback was unavailable")
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "fresh_process_verification", status: "rejected"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "fresh_process_verification",
                    status: "rejected",
                    success: false,
                    spec: spec,
                    validationIssues: [issue],
                    error: issue.message
                )
            )
        }
        let current = currentResult.snapshot
        var readbackIssues = ACEAudioDeltaAdoptionValidator.validateTagged(current, spec: spec)
        if current.projectPath != ACEFileDigest.normalizedPath(spec.targetProjectPath) {
            readbackIssues.append(ACEPlacementIssue(code: "logic_adoption_fresh_project_mismatch", message: "fresh process observed a different project path", path: "$.after.project_path"))
        }
        guard readbackIssues.isEmpty else {
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "fresh_process_verification", status: "dispatched_unverified"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "fresh_process_verification",
                    status: "dispatched_unverified",
                    success: false,
                    spec: spec,
                    after: current,
                    finalProjectSHA256: current.projectSHA256,
                    rollback: .manual(spec: spec, projectPath: current.projectPath),
                    validationIssues: uniqueIssues(readbackIssues),
                    error: readbackIssues.first?.message
                )
            )
        }
        let geometryResult = await router.route(
            operation: "project.read_ace_audio_delta_geometry",
            params: ["spec_json": encodeCompactJSON(spec)]
        )
        let geometry = decode(ACEAudioDeltaGeometry.self, from: geometryResult.message.data(using: .utf8) ?? Data())
        let geometryIssues = geometry.map { ACEAudioDeltaAdoptionValidator.validateGeometry($0, placement: spec.placement) }
            ?? [ACEPlacementIssue(code: "logic_adoption_fresh_geometry_unavailable", message: geometryResult.message)]
        let allIssues = uniqueIssues(geometryIssues)
        guard geometryResult.isSuccess, allIssues.isEmpty, let geometry else {
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "fresh_process_verification", status: "dispatched_unverified"),
                    planID: spec.planID,
                    operationID: spec.operationID,
                    phase: "fresh_process_verification",
                    status: "dispatched_unverified",
                    success: false,
                    spec: spec,
                    after: current,
                    geometry: geometry,
                    finalProjectSHA256: current.projectSHA256,
                    rollback: .manual(spec: spec, projectPath: current.projectPath),
                    validationIssues: allIssues,
                    error: allIssues.first?.message
                )
            )
        }
        let track = current.tracks.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag })
        let region = current.regions.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.regionTag })
        return emitAdoption(
            ACEAudioDeltaAdoptionReceipt(
                receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "fresh_process_verification", status: "verified_fresh_process"),
                planID: spec.planID,
                operationID: spec.operationID,
                phase: "verified_fresh_process",
                status: "verified_fresh_process",
                success: true,
                spec: spec,
                after: current,
                trackID: track?.stableID,
                regionID: region?.stableID,
                sourceSHA256: spec.source.sha256,
                geometry: geometry,
                finalProjectSHA256: current.projectSHA256,
                rollback: .manual(spec: spec, projectPath: current.projectPath)
            )
        )
    }

    private static func rollbackDelta(
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        let built = buildAdoptionSpec(params: params)
        guard let spec = built.spec else {
            return emitAdoption(
                ACEAudioDeltaAdoptionReceipt(
                    receiptID: adoptionReceiptID(operationID: built.operationID, phase: "rollback", status: "manual_required"),
                    planID: built.planID,
                    operationID: built.operationID,
                    phase: "rollback",
                    status: "manual_required",
                    success: false,
                    rollback: built.spec.map { .manual(spec: $0, projectPath: $0.targetProjectPath) },
                    validationIssues: built.issues,
                    error: built.issues.first?.message
                )
            )
        }
        let specIssues = uniqueIssues(built.issues + ACEAudioDeltaAdoptionValidator.validateSpec(spec))
        let current = await freshUnboundAdoptionSnapshot(spec: spec, router: router, cache: cache)?.snapshot
        let tagIssues = current.map { ACEAudioDeltaAdoptionValidator.validateTagged($0, spec: spec) } ?? [ACEPlacementIssue(code: "logic_adoption_rollback_tag_readback_unavailable", message: "current exact operation-tag readback was unavailable")]
        let allIssues = uniqueIssues(specIssues + tagIssues)
        let projectPath = current?.projectPath ?? spec.targetProjectPath
        let receipt = ACEAudioDeltaAdoptionReceipt(
            receiptID: adoptionReceiptID(operationID: spec.operationID, phase: "rollback", status: "manual_required"),
            planID: spec.planID,
            operationID: spec.operationID,
            phase: "manual_required",
            status: "manual_required",
            success: false,
            spec: spec,
            after: current,
            trackID: current?.tracks.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag })?.stableID,
            regionID: current?.regions.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.regionTag })?.stableID,
            sourceSHA256: spec.source.sha256,
            finalProjectSHA256: current?.projectSHA256,
            rollback: .manual(spec: spec, projectPath: projectPath),
            validationIssues: allIssues,
            error: "automatic rollback remains disabled; exact tag-bounded human rollback instructions are recorded"
        )
        return emitAdoption(receipt)
    }

    // MARK: - Placement

    private static func place(
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        let now = Date()
        let planID = firstString(params, keys: ["plan_id"]) ?? ""
        guard let session = await cache.getACEPlacementSession(planID: planID),
              let binding = await cache.getDisposableProjectBinding() else {
            return await rejectedReceipt(
                operationID: firstString(params, keys: ["operation_id"]) ?? planID,
                planID: planID,
                phase: "dispatched",
                errorCode: "logic_authorization_missing",
                message: "a confirmed ACE placement authorization is required before dispatch",
                cache: cache
            )
        }

        let currentProject = await cache.getProject()
        let generation = await cache.getGeneration()
        let confirmationIssues = validateConfirmation(session.authorization, now: now)
        let preflightIssues = uniqueIssues(
            ACEAudioPlacementValidator.validateBinding(binding, currentProject: currentProject, cacheGeneration: generation, now: now)
                + ACEAudioPlacementValidator.validatePlan(session.plan, binding: binding)
                + confirmationIssues
        )
        guard preflightIssues.isEmpty else {
            return await rejectedReceipt(
                operationID: session.plan.operationID,
                planID: session.plan.planID,
                phase: "dispatched",
                binding: binding,
                asset: session.plan.asset,
                plan: session.plan,
                authorization: session.authorization,
                issues: preflightIssues,
                cache: cache
            )
        }

        guard let beforeResult = await freshSnapshot(
            binding: binding,
            router: router,
            cache: cache,
            now: now,
            requireBindingDigest: true
        ) else {
            return await rejectedReceipt(
                operationID: session.plan.operationID,
                planID: session.plan.planID,
                phase: "dispatched",
                binding: binding,
                asset: session.plan.asset,
                plan: session.plan,
                authorization: session.authorization,
                errorCode: "logic_before_readback_unavailable",
                message: "fresh project-bound before readback was unavailable; no mutation started",
                cache: cache
            )
        }
        let before = beforeResult.snapshot
        let beforeIssues = validateNewTrackPreflight(snapshot: before, plan: session.plan)
        guard beforeIssues.isEmpty else {
            return await rejectedReceipt(
                operationID: session.plan.operationID,
                planID: session.plan.planID,
                phase: "dispatched",
                binding: binding,
                asset: session.plan.asset,
                plan: session.plan,
                authorization: session.authorization,
                before: before,
                issues: beforeIssues,
                cache: cache
            )
        }

        var stageReceipts = [
            ACEPlacementStageReceipt.notStarted(
                stage: ACEAudioPlacementContract.importStageUI,
                message: "stage has not started"
            ),
            ACEPlacementStageReceipt.notStarted(
                stage: ACEAudioPlacementContract.importStageTagging,
                message: "tagging waits for a completed UI-import dispatch"
            ),
            ACEPlacementStageReceipt.notStarted(
                stage: ACEAudioPlacementContract.importStageReadback,
                message: "readback waits for verified tagging"
            ),
        ]

        let dispatchTime = Date()
        let dispatchResult = await router.route(
            operation: "project.import_audio",
            params: [
                "path": session.plan.asset.path,
                "asset_sha256": session.plan.asset.sha256,
                "operation_id": session.plan.operationID,
                "plan_id": session.plan.planID,
                "track_name": session.plan.trackName,
                "track_tag": session.plan.trackTag,
                "region_tag": session.plan.regionTag,
                "bar": String(session.plan.placement.bar),
                "beat": String(session.plan.placement.beat),
                "tick": String(session.plan.placement.tick),
                "duration_beats": String(session.plan.placement.durationBeats),
                "beats_per_bar": String(session.plan.placement.beatsPerBar),
            ]
        )
        stageReceipts[0] = stageReceipt(
            stage: ACEAudioPlacementContract.importStageUI,
            startedAt: dispatchTime,
            attempt: 1,
            result: dispatchResult,
            successOutcome: "dispatched"
        )
        let dispatchStatus = dispatchResult.isSuccess
            ? "dispatched"
            : (stageReceipts[0].outcome == "unknown" ? "unknown" : "dispatch_failed")
        var dispatch = ACEPlacementDispatchReceipt(
            status: dispatchStatus,
            method: "project.import_audio",
            receiptID: receiptID(operationID: session.plan.operationID, phase: "dispatch", status: dispatchStatus),
            dispatchedAt: dispatchTime,
            sourceSHA256: session.plan.asset.sha256,
            message: dispatchResult.message
        )

        guard dispatchResult.isSuccess else {
            let unknownOutcome = stageReceipts[0].outcome == "unknown"
            let receipt = ACEAudioPlacementReceipt(
                receiptID: receiptID(
                    operationID: session.plan.operationID,
                    phase: ACEAudioPlacementContract.importStageUI,
                    status: unknownOutcome ? "dispatch_unknown" : "dispatch_rejected"
                ),
                operationID: session.plan.operationID,
                planID: session.plan.planID,
                phase: ACEAudioPlacementContract.importStageUI,
                status: unknownOutcome ? "dispatch_unknown" : "dispatch_rejected",
                success: false,
                issuedAt: Date(),
                binding: binding,
                asset: session.plan.asset,
                plan: session.plan,
                authorization: session.authorization,
                dispatch: dispatch,
                before: before,
                stageReceipts: stageReceipts,
                validationIssues: [ACEPlacementIssue(
                    code: unknownOutcome ? "logic_ui_import_outcome_unknown" : "logic_ui_import_failed",
                    message: unknownOutcome
                        ? "UI import stage ended without a receipt; mutation outcome is unknown and no retry, tagging, or readback was started."
                        : "UI import stage failed before a verified dispatch; no retry, tagging, or readback was started.",
                    path: "$.stage_receipts[0]"
                )],
                error: dispatchResult.message
            )
            await cache.updateLastACEAudioPlacementReceipt(receipt)
            return await emit(receipt, cache: cache, updateLast: false)
        }

        let tagStartedAt = Date()
        let tagResult = await router.route(
            operation: "project.tag_imported_audio",
            params: [
                "before_track_count": String(before.tracks.count),
                "before_region_count": String(before.regions.count),
                "track_tag": session.plan.trackTag,
                "region_tag": session.plan.regionTag,
                "asset_sha256": session.plan.asset.sha256,
                "native_source_basename": session.plan.asset.nativeSourceBasename,
                "keeper_digest_receipt_id": session.plan.keeperDigestReceipt?.receiptID ?? "",
            ]
        )
        stageReceipts[1] = stageReceipt(
            stage: ACEAudioPlacementContract.importStageTagging,
            startedAt: tagStartedAt,
            attempt: 1,
            result: tagResult,
            successOutcome: "tagged"
        )
        if !tagResult.isSuccess {
            // The import dispatch remains true. Tagging is a bounded phase and
            // its failure stops the pipeline; it is never relabeled as a
            // verified success and no second import is attempted.
            var message = dispatch.message ?? "audio import dispatched"
            message += " tagging_stage=failed: \(tagResult.message)"
            dispatch = ACEPlacementDispatchReceipt(
                status: dispatch.status,
                method: dispatch.method,
                receiptID: dispatch.receiptID,
                dispatchedAt: dispatch.dispatchedAt,
                sourceSHA256: dispatch.sourceSHA256,
                message: message
            )
            let receipt = ACEAudioPlacementReceipt(
                receiptID: receiptID(
                    operationID: session.plan.operationID,
                    phase: ACEAudioPlacementContract.importStageTagging,
                    status: "dispatched_unverified"
                ),
                operationID: session.plan.operationID,
                planID: session.plan.planID,
                phase: ACEAudioPlacementContract.importStageTagging,
                status: "dispatched_unverified",
                success: false,
                issuedAt: Date(),
                binding: binding,
                asset: session.plan.asset,
                plan: session.plan,
                authorization: session.authorization,
                dispatch: dispatch,
                before: before,
                stageReceipts: stageReceipts,
                validationIssues: [ACEPlacementIssue(
                    code: "logic_tagging_stage_failed",
                    message: "UI import was dispatched, but tagging did not complete; readback and rollback continuation are stopped.",
                    path: "$.stage_receipts[1]"
                )],
                error: tagResult.message
            )
            await cache.updateLastACEAudioPlacementReceipt(receipt)
            return await emit(receipt, cache: cache, updateLast: false)
        }

        let readbackStartedAt = Date()
        let readbackDeadline = readbackStartedAt.addingTimeInterval(ServerConfig.aceAudioReadbackTimeout)
        var afterResult: FreshSnapshotResult?
        var readbackAttempts = 0
        while readbackAttempts < ServerConfig.aceAudioReadbackAttempts,
              Date() < readbackDeadline {
            readbackAttempts += 1
            let candidate = await freshSnapshot(
                binding: binding,
                router: router,
                cache: cache,
                now: Date(),
                requireBindingDigest: false
            )
            afterResult = candidate
            if let snapshot = candidate?.snapshot,
               snapshot.tracks.count >= before.tracks.count + 1,
               snapshot.regions.count >= before.regions.count + 1 {
                break
            }
            if readbackAttempts < ServerConfig.aceAudioReadbackAttempts,
               Date() < readbackDeadline {
                let remaining = readbackDeadline.timeIntervalSinceNow
                try? await Task.sleep(
                    nanoseconds: UInt64(max(0.05, min(0.25, remaining)) * 1_000_000_000)
                )
            }
        }
        let after = afterResult?.snapshot
        var placementGeometry: ACEAudioDeltaGeometry?
        var geometryResult: ChannelResult?
        if after != nil, Date() < readbackDeadline {
            geometryResult = await router.route(
                operation: "project.read_ace_audio_placement_geometry",
                params: [
                    "target_project_path": session.plan.targetProjectPath,
                    "track_tag": session.plan.trackTag,
                    "native_source_basename": session.plan.asset.nativeSourceBasename,
                    "asset_sha256": session.plan.asset.sha256,
                    "bar": String(session.plan.placement.bar),
                    "beat": String(session.plan.placement.beat),
                    "tick": String(session.plan.placement.tick),
                    "duration_beats": String(session.plan.placement.durationBeats),
                    "beats_per_bar": String(session.plan.placement.beatsPerBar),
                ]
            )
            if let geometryResult {
                placementGeometry = decode(
                    ACEAudioDeltaGeometry.self,
                    from: geometryResult.message.data(using: .utf8) ?? Data()
                )
            }
        }
        let readback = after.map { evaluateReadback(before: before, after: $0, plan: session.plan, geometry: placementGeometry) }
            ?? ACEPlacementReadback(
                status: "not_verified",
                verified: false,
                reasonCode: "logic_after_readback_unavailable",
                observedAt: Date(),
                projectIdentity: after?.projectSHA256,
                projectPath: after?.projectPath,
                assetSHA256: nil,
                trackID: nil,
                regionID: nil,
                trackName: nil,
                placement: nil,
                identityKind: nil,
                evidenceURI: nil,
                assetRegionIdentity: nil
            )

        let verified = readback.verified
        let readbackStatus: String
        let readbackOutcome: String
        if verified {
            readbackStatus = "completed"
            readbackOutcome = "verified"
        } else if Date() >= readbackDeadline {
            readbackStatus = "timed_out"
            readbackOutcome = "unknown"
        } else {
            readbackStatus = "failed"
            readbackOutcome = "not_verified"
        }
        stageReceipts[2] = ACEPlacementStageReceipt(
            stage: ACEAudioPlacementContract.importStageReadback,
            status: readbackStatus,
            outcome: readbackOutcome,
            startedAt: readbackStartedAt,
            completedAt: Date(),
            elapsedMilliseconds: Int(Date().timeIntervalSince(readbackStartedAt) * 1_000),
            attempt: max(1, readbackAttempts),
            message: verified
                ? "fresh project, tagged-track, native-region, and geometry readback verified"
                : "fresh readback did not prove the exact created identity: \(readback.reasonCode)"
        )
        let status = verified ? "verified_success" : "dispatched_unverified"
        let phase = verified ? "verified_readback" : "dispatched"
        let error: String? = verified
            ? nil
            : dispatchResult.isSuccess
                ? "Audio import was dispatched, but the created layer did not receive a unique, fresh, source-bound readback; automatic continuation and rollback are stopped."
                : "Audio import dispatch returned an error; the outcome remains unverified and no continuation or rollback was started."
        let receipt = ACEAudioPlacementReceipt(
            receiptID: receiptID(operationID: session.plan.operationID, phase: phase, status: status),
            operationID: session.plan.operationID,
            planID: session.plan.planID,
            phase: phase,
            status: status,
            success: verified,
            issuedAt: Date(),
            binding: binding,
            asset: session.plan.asset,
            plan: session.plan,
            authorization: session.authorization,
            dispatch: dispatch,
            before: before,
            after: after,
            placementGeometry: placementGeometry,
            stageReceipts: stageReceipts,
            readback: readback,
            rollback: .notRequested(strategy: session.plan.rollbackStrategy),
            validationIssues: afterResult?.issues ?? [],
            error: error
        )
        await cache.updateLastACEAudioPlacementReceipt(receipt)
        return await emit(receipt, cache: cache, updateLast: false)
    }

    /// Continue the one already-dispatched import when the file picker crossed
    /// the UI boundary but the bounded tagging window began before Logic had
    /// materialized the new content row.  This command is deliberately tag-only:
    /// it requires fresh 4/4 evidence, preserves the original 3/3 names, and
    /// contains no project.import_audio route or retry path.
    private static func tagAfterSingleImport(
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        let now = Date()
        let planID = firstString(params, keys: ["plan_id"]) ?? ""
        let operationID = firstString(params, keys: ["operation_id"]) ?? planID
        let requestedPath = ACEFileDigest.normalizedPath(
            filePath(firstString(params, keys: ["target_project_path", "project_path"]) ?? "")
        )
        let expectedBeforeDigest = firstString(
            params,
            keys: ["expected_before_project_sha256", "starting_project_sha256"]
        ) ?? ""
        let priorDispatchCount = firstInt(params, keys: ["prior_import_dispatch_count"]) ?? 1

        guard !requestedPath.isEmpty,
              ACEFileDigest.isSHA256(expectedBeforeDigest),
              priorDispatchCount == 1 else {
            return await rejectedReceipt(
                operationID: operationID,
                planID: planID,
                phase: "tagging_recovery",
                errorCode: "logic_tagging_recovery_precondition_invalid",
                message: "tag-only continuation requires one prior import dispatch, an exact target path, and the clean before digest; no mutation started",
                cache: cache
            )
        }

        let projectResult = await router.route(operation: "project.get_info")
        guard projectResult.isSuccess,
              let projectData = projectResult.message.data(using: .utf8),
              let project = decode(ProjectInfo.self, from: projectData),
              let observedPath = canonicalObservedProjectPath(project),
              observedPath == requestedPath,
              let currentDigest = try? ACEFileDigest.sha256(at: observedPath) else {
            return await rejectedReceipt(
                operationID: operationID,
                planID: planID,
                phase: "tagging_recovery",
                errorCode: "logic_tagging_recovery_project_unavailable",
                message: "tag-only continuation could not prove the exact current P5K project identity; no mutation started",
                cache: cache
            )
        }

        let binding = DisposableProjectBinding(
            bindingID: "tag-recovery-(planID)",
            path: observedPath,
            projectSHA256: currentDigest,
            authority: ACEAudioPlacementContract.disposableProjectAuthority,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(300),
            originalProjectPath: firstString(params, keys: ["original_project_path"]),
            originalProjectPreserved: boolValue(params["original_project_preserved"]) ?? true
        )
        var planParams = params
        planParams["target_project_path"] = .string(observedPath)
        planParams["target_project_sha256"] = .string(currentDigest)
        let built = buildPlan(params: planParams, binding: binding)
        let confirmation = parseConfirmation(params: params)
        var planIssues = built.issues
            + ACEAudioPlacementValidator.validatePlan(built.plan, binding: binding)
            + validateConfirmation(confirmation, now: now)
        if currentDigest == expectedBeforeDigest {
            planIssues.append(ACEPlacementIssue(
                code: "logic_tagging_recovery_before_digest_unchanged",
                message: "the exact one-dispatch continuation did not observe a changed P5K project digest; no tag write started",
                path: "$.expected_before_project_sha256"
            ))
        }
        guard planIssues.isEmpty else {
            return await rejectedReceipt(
                operationID: built.plan.operationID,
                planID: built.plan.planID,
                phase: "tagging_recovery",
                binding: binding,
                asset: built.plan.asset,
                plan: built.plan,
                authorization: confirmation,
                issues: uniqueIssues(planIssues),
                cache: cache
            )
        }

        await cache.updateDisposableProjectBinding(binding)
        guard let beforeResult = await freshSnapshotWithRetry(
            binding: binding,
            router: router,
            cache: cache,
            now: Date(),
            requireBindingDigest: true
        ) else {
            return await rejectedReceipt(
                operationID: built.plan.operationID,
                planID: built.plan.planID,
                phase: "tagging_recovery",
                binding: binding,
                asset: built.plan.asset,
                plan: built.plan,
                authorization: confirmation,
                errorCode: "logic_tagging_recovery_readback_unavailable",
                message: "fresh post-dispatch 4/4 readback was unavailable; no tag write started",
                cache: cache
            )
        }
        let before = beforeResult.snapshot
        let beforeTrackCount = firstInt(params, keys: ["before_track_count"]) ?? -1
        let beforeRegionCount = firstInt(params, keys: ["before_region_count"]) ?? -1
        let expectedTrackCount = firstInt(params, keys: ["expected_track_count"]) ?? beforeTrackCount + 1
        let expectedRegionCount = firstInt(params, keys: ["expected_region_count"]) ?? beforeRegionCount + 1
        let preservedTrackNames = stringArray(params["preserved_track_names"]) ?? []
        let preservedRegionNames = stringArray(params["preserved_region_names"]) ?? []
        let nativeSourceBasename = firstString(params, keys: ["native_source_basename"]) ?? built.plan.asset.nativeSourceBasename
        var continuationIssues: [ACEPlacementIssue] = []
        if before.tracks.count != expectedTrackCount || before.regions.count != expectedRegionCount {
            continuationIssues.append(ACEPlacementIssue(
                code: "logic_tagging_recovery_count_mismatch",
                message: "tag-only continuation requires the exact expected post-dispatch track/region counts; no tag write started",
                path: "$.expected_track_count"
            ))
        }
        if beforeTrackCount < 0 || beforeRegionCount < 0
            || preservedTrackNames.count != beforeTrackCount
            || preservedRegionNames.count != beforeRegionCount
            || Array(before.tracks.prefix(max(0, beforeTrackCount))).map(\.name) != preservedTrackNames
            || Array(before.regions.prefix(max(0, beforeRegionCount))).map(\.name) != preservedRegionNames {
            continuationIssues.append(ACEPlacementIssue(
                code: "logic_tagging_recovery_existing_content_changed",
                message: "pre-existing track or native region names do not match the clean 3/3 preservation evidence; no tag write started",
                path: "$.preserved_region_names"
            ))
        }
        let selectedTracks = before.tracks.enumerated().filter { $0.element.isSelected }
        if selectedTracks.count != 1 || selectedTracks.first?.offset ?? -1 < beforeTrackCount {
            continuationIssues.append(ACEPlacementIssue(
                code: "logic_tagging_recovery_selection_ambiguous",
                message: "the selected post-dispatch track is not a unique new layer; no tag write started",
                path: "$.selected_track"
            ))
        }
        let sourceRegions = before.regions.filter {
            $0.trackIndex >= beforeTrackCount && $0.name == nativeSourceBasename
        }
        if sourceRegions.count != 1 {
            continuationIssues.append(ACEPlacementIssue(
                code: "logic_tagging_recovery_source_region_ambiguous",
                message: "the exact native keeper region is not unique on the newly imported layer; no tag write started",
                path: "$.native_source_basename"
            ))
        }
        let taggedTrackIndices = before.tracks.enumerated().compactMap { index, track in
            OperationTagIdentity.operationTag(in: track.name) == built.plan.trackTag ? index : nil
        }
        let alreadyTaggedExact = taggedTrackIndices.count == 1
            && selectedTracks.count == 1
            && selectedTracks[0].offset == taggedTrackIndices[0]
            && sourceRegions.count == 1
            && sourceRegions[0].trackIndex == taggedTrackIndices[0]
            && sourceRegions[0].trackName == built.plan.trackTag
        if !taggedTrackIndices.isEmpty && !alreadyTaggedExact {
            continuationIssues.append(ACEPlacementIssue(
                code: "logic_tagging_recovery_tag_collision",
                message: "the exact operation track tag already exists before tag-only continuation; no tag write started",
                path: "$.track_tag"
            ))
        }
        guard continuationIssues.isEmpty else {
            return await rejectedReceipt(
                operationID: built.plan.operationID,
                planID: built.plan.planID,
                phase: "tagging_recovery",
                binding: binding,
                asset: built.plan.asset,
                plan: built.plan,
                authorization: confirmation,
                before: before,
                issues: uniqueIssues(continuationIssues),
                cache: cache
            )
        }

        let priorDispatch = ACEPlacementDispatchReceipt(
            status: "dispatched",
            method: "project.import_audio (prior single dispatch)",
            receiptID: receiptID(operationID: built.plan.operationID, phase: "dispatch", status: "dispatched"),
            dispatchedAt: now,
            sourceSHA256: built.plan.asset.sha256,
            message: "exactly one prior UI import dispatch was observed; tag-only continuation issued no second import"
        )
        var stageReceipts = [
            ACEPlacementStageReceipt(
                stage: ACEAudioPlacementContract.importStageUI,
                status: "completed",
                outcome: "dispatched",
                startedAt: nil,
                completedAt: nil,
                elapsedMilliseconds: nil,
                attempt: 1,
                message: "prior place_ace_audio receipt proves one UI dispatch; this continuation did not import"
            ),
            ACEPlacementStageReceipt.notStarted(
                stage: ACEAudioPlacementContract.importStageTagging,
                message: "tag-only continuation has not started"
            ),
            ACEPlacementStageReceipt.notStarted(
                stage: ACEAudioPlacementContract.importStageReadback,
                message: "readback waits for tag-only continuation"
            ),
        ]

        if alreadyTaggedExact {
            // A prior tag call returned an unknown result, but the fresh
            // precondition readback now proves that its exact parent-track tag
            // landed.  Treat this as a read-only idempotent continuation: do
            // not issue the tag operation again.
            stageReceipts[1] = ACEPlacementStageReceipt(
                stage: ACEAudioPlacementContract.importStageTagging,
                status: "completed",
                outcome: "already_verified",
                startedAt: nil,
                completedAt: Date(),
                elapsedMilliseconds: 0,
                attempt: 1,
                message: "prior tag write returned unknown, but fresh readback proves the exact tagged track and native keeper region; no tag write issued"
            )
        } else {
            let tagStartedAt = Date()
            let tagResult = await router.route(
                operation: "project.tag_imported_audio",
                params: [
                    "before_track_count": String(beforeTrackCount),
                    "before_region_count": String(beforeRegionCount),
                    "track_tag": built.plan.trackTag,
                    "region_tag": built.plan.regionTag,
                    "asset_sha256": built.plan.asset.sha256,
                    "native_source_basename": nativeSourceBasename,
                    "keeper_digest_receipt_id": built.plan.keeperDigestReceipt?.receiptID ?? "",
                ]
            )
            stageReceipts[1] = stageReceipt(
                stage: ACEAudioPlacementContract.importStageTagging,
                startedAt: tagStartedAt,
                attempt: 1,
                result: tagResult,
                successOutcome: "tagged"
            )
            if !tagResult.isSuccess {
                let receipt = ACEAudioPlacementReceipt(
                    receiptID: receiptID(operationID: built.plan.operationID, phase: "tagging_recovery", status: "dispatched_unverified"),
                    operationID: built.plan.operationID,
                    planID: built.plan.planID,
                    phase: "tagging_recovery",
                    status: "dispatched_unverified",
                    success: false,
                    issuedAt: Date(),
                    binding: binding,
                    asset: built.plan.asset,
                    plan: built.plan,
                    authorization: confirmation,
                    dispatch: priorDispatch,
                    before: before,
                    stageReceipts: stageReceipts,
                    rollback: manualRollbackEvidence(plan: built.plan, readback: nil, projectPath: before.projectPath),
                    validationIssues: [ACEPlacementIssue(
                        code: "logic_tagging_recovery_failed",
                        message: "the exact existing imported layer was not tagged; no second import or readback continuation was issued",
                        path: "$.stage_receipts[1]"
                    )],
                    error: tagResult.message
                )
                await cache.updateACEPlacementSession(ACEAudioPlacementSession(plan: built.plan, authorization: confirmation, lastReceipt: receipt))
                return await emit(receipt, cache: cache, updateLast: false)
            }
        }

        let saveStartedAt = Date()
        let saveResult = await router.route(operation: "project.save")
        guard saveResult.isSuccess else {
            let receipt = ACEAudioPlacementReceipt(
                receiptID: receiptID(operationID: built.plan.operationID, phase: "tagging_recovery", status: "dispatched_unverified"),
                operationID: built.plan.operationID,
                planID: built.plan.planID,
                phase: "tagging_recovery",
                status: "dispatched_unverified",
                success: false,
                issuedAt: Date(),
                binding: binding,
                asset: built.plan.asset,
                plan: built.plan,
                authorization: confirmation,
                dispatch: priorDispatch,
                before: before,
                stageReceipts: stageReceipts,
                rollback: manualRollbackEvidence(plan: built.plan, readback: nil, projectPath: before.projectPath),
                validationIssues: [ACEPlacementIssue(
                    code: "logic_tagging_recovery_save_failed",
                    message: "tag write completed but save did not complete; no bounce or further mutation was issued",
                    path: "$.save"
                )],
                error: saveResult.message
            )
            await cache.updateACEPlacementSession(ACEAudioPlacementSession(plan: built.plan, authorization: confirmation, lastReceipt: receipt))
            return await emit(receipt, cache: cache, updateLast: false)
        }

        var afterResult: FreshSnapshotResult?
        for attempt in 0..<12 {
            if let candidate = await freshSnapshot(
                binding: binding,
                router: router,
                cache: cache,
                now: Date(),
                requireBindingDigest: false
            ) {
                afterResult = candidate
                if candidate.snapshot.tracks.count == expectedTrackCount,
                   candidate.snapshot.regions.count == expectedRegionCount {
                    break
                }
            }
            if attempt < 11 {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        let after = afterResult?.snapshot
        var geometry: ACEAudioDeltaGeometry?
        var geometryResult: ChannelResult?
        if after != nil {
            geometryResult = await router.route(
                operation: "project.read_ace_audio_placement_geometry",
                params: placementGeometryParams(plan: built.plan)
            )
            if let geometryResult {
                geometry = decode(
                    ACEAudioDeltaGeometry.self,
                    from: geometryResult.message.data(using: .utf8) ?? Data()
                )
            }
        }
        let readback = after.map {
            evaluateFreshReadback(
                snapshot: $0,
                plan: built.plan,
                geometry: geometry,
                expectedTrackCount: expectedTrackCount,
                expectedRegionCount: expectedRegionCount
            )
        } ?? .notRequested(reasonCode: "logic_tagging_recovery_readback_unavailable")
        stageReceipts[2] = ACEPlacementStageReceipt(
            stage: ACEAudioPlacementContract.importStageReadback,
            status: readback.verified ? "completed" : "failed",
            outcome: readback.verified ? "verified" : "not_verified",
            startedAt: saveStartedAt,
            completedAt: Date(),
            elapsedMilliseconds: max(0, Int(Date().timeIntervalSince(saveStartedAt) * 1_000)),
            attempt: 1,
            message: readback.verified
                ? "fresh tagged-track, native-region, and geometry readback verified after save"
                : "fresh tag/readback did not prove the exact created identity: (readback.reasonCode)"
        )
        let verified = readback.verified && geometryResult?.isSuccess == true
        var validationIssues = afterResult?.issues ?? []
        if !verified {
            validationIssues.append(ACEPlacementIssue(
                code: "logic_tagging_recovery_readback_failed",
                message: "tag-only continuation saved but exact fresh identity and geometry proof is incomplete; no bounce was issued",
                path: "$.stage_receipts[2]"
            ))
        }
        let receipt = ACEAudioPlacementReceipt(
            receiptID: receiptID(operationID: built.plan.operationID, phase: verified ? "tagging_recovery_verified" : "tagging_recovery", status: verified ? "verified_success" : "dispatched_unverified"),
            operationID: built.plan.operationID,
            planID: built.plan.planID,
            phase: verified ? "tagging_recovery_verified" : "tagging_recovery",
            status: verified ? "verified_success" : "dispatched_unverified",
            success: verified,
            issuedAt: Date(),
            binding: binding,
            asset: built.plan.asset,
            plan: built.plan,
            authorization: confirmation,
            dispatch: priorDispatch,
            before: before,
            after: after,
            placementGeometry: geometry,
            stageReceipts: stageReceipts,
            readback: readback,
            rollback: .notRequested(strategy: built.plan.rollbackStrategy),
            validationIssues: uniqueIssues(validationIssues),
            error: verified ? nil : "tag-only continuation did not produce a verified fresh placement"
        )
        await cache.updateACEPlacementSession(ACEAudioPlacementSession(plan: built.plan, authorization: confirmation, lastReceipt: receipt))
        return await emit(receipt, cache: cache, updateLast: false)
    }

    private static func verifyPlacement(
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        let planID = firstString(params, keys: ["plan_id"]) ?? ""
        let operationID = firstString(params, keys: ["operation_id"]) ?? ""
        let requestedPath = ACEFileDigest.normalizedPath(
            filePath(firstString(params, keys: ["target_project_path", "project_path"]) ?? "")
        )
        let projectResult = await router.route(operation: "project.get_info")
        guard projectResult.isSuccess,
              let projectData = projectResult.message.data(using: .utf8),
              let project = decode(ProjectInfo.self, from: projectData),
              let observedPath = canonicalObservedProjectPath(project) else {
            return await rejectedReceipt(
                operationID: operationID.isEmpty ? planID : operationID,
                planID: planID,
                phase: "fresh_process_verification",
                errorCode: "logic_fresh_project_readback_unavailable",
                message: "fresh-process project identity was unavailable; import outcome remains unverified",
                cache: cache
            )
        }
        guard !requestedPath.isEmpty,
              observedPath == requestedPath else {
            return await rejectedReceipt(
                operationID: operationID.isEmpty ? planID : operationID,
                planID: planID,
                phase: "fresh_process_verification",
                errorCode: "logic_fresh_project_mismatch",
                message: "fresh process observed a different project path; no verification was accepted",
                cache: cache
            )
        }
        guard let currentDigest = try? ACEFileDigest.sha256(at: observedPath) else {
            return await rejectedReceipt(
                operationID: operationID.isEmpty ? planID : operationID,
                planID: planID,
                phase: "fresh_process_verification",
                errorCode: "logic_fresh_project_digest_unavailable",
                message: "fresh process could not hash the saved disposable project; import outcome remains unverified",
                cache: cache
            )
        }

        let now = Date()
        let binding = DisposableProjectBinding(
            bindingID: "fresh-process-\(planID.isEmpty ? currentDigest.prefix(16) : Substring(planID))",
            path: observedPath,
            projectSHA256: currentDigest,
            authority: ACEAudioPlacementContract.disposableProjectAuthority,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(300),
            originalProjectPath: nil,
            originalProjectPreserved: true
        )
        var verificationParams = params
        verificationParams["target_project_path"] = .string(observedPath)
        verificationParams["target_project_sha256"] = .string(currentDigest)
        let built = buildPlan(params: verificationParams, binding: binding)
        let planIssues = uniqueIssues(
            built.issues + ACEAudioPlacementValidator.validatePlan(built.plan, binding: binding)
        )
        guard planIssues.isEmpty else {
            return await rejectedReceipt(
                operationID: built.plan.operationID,
                planID: built.plan.planID,
                phase: "fresh_process_verification",
                binding: binding,
                asset: built.plan.asset,
                plan: built.plan,
                issues: planIssues,
                cache: cache
            )
        }

        guard let currentResult = await freshSnapshotWithRetry(
            binding: binding,
            router: router,
            cache: cache,
            now: now,
            requireBindingDigest: true
        ) else {
            return await rejectedReceipt(
                operationID: built.plan.operationID,
                planID: built.plan.planID,
                phase: "fresh_process_verification",
                binding: binding,
                asset: built.plan.asset,
                plan: built.plan,
                errorCode: "logic_fresh_readback_unavailable",
                message: "fresh-process 4/4 project, track, and region readback was unavailable; import outcome remains unverified",
                cache: cache
            )
        }
        let current = currentResult.snapshot
        let expectedTrackCount = firstInt(params, keys: ["expected_track_count"]) ?? 4
        let expectedRegionCount = firstInt(params, keys: ["expected_region_count"]) ?? 4
        let geometryResult = await router.route(
            operation: "project.read_ace_audio_placement_geometry",
            params: placementGeometryParams(plan: built.plan)
        )
        let geometry = decode(
            ACEAudioDeltaGeometry.self,
            from: geometryResult.message.data(using: .utf8) ?? Data()
        )
        let readback = evaluateFreshReadback(
            snapshot: current,
            plan: built.plan,
            geometry: geometry,
            expectedTrackCount: expectedTrackCount,
            expectedRegionCount: expectedRegionCount
        )
        var verificationIssues = currentResult.issues
        if let expectedBeforeDigest = firstString(params, keys: ["expected_before_project_sha256", "starting_project_sha256"]),
           expectedBeforeDigest == current.projectSHA256 {
            verificationIssues.append(ACEPlacementIssue(
                code: "logic_saved_project_digest_unchanged",
                message: "fresh-process verification did not observe a saved disposable digest change",
                path: "$.after.project_sha256"
            ))
        }
        if !geometryResult.isSuccess || geometry?.verified != true {
            verificationIssues.append(ACEPlacementIssue(
                code: geometry?.reasonCode ?? "logic_fresh_geometry_unavailable",
                message: "independent fresh-process placement geometry was not verified",
                path: "$.placement_geometry"
            ))
        }
        if !readback.verified {
            verificationIssues.append(ACEPlacementIssue(
                code: readback.reasonCode,
                message: "fresh-process asset-region identity/source/placement readback was not verified",
                path: "$.readback"
            ))
        }
        verificationIssues = uniqueIssues(verificationIssues)
        let verified = verificationIssues.isEmpty && readback.verified
        let status = verified ? "verified_fresh_process" : "dispatched_unverified"
        let message = verified
            ? nil
            : "Import remains dispatched, but fresh-process 4/4 source-bound identity and placement proof is incomplete; no continuation or rollback mutation was started."
        let receipt = ACEAudioPlacementReceipt(
            receiptID: receiptID(operationID: built.plan.operationID, phase: "fresh_process_verification", status: status),
            operationID: built.plan.operationID,
            planID: built.plan.planID,
            phase: "fresh_process_verification",
            status: status,
            success: verified,
            issuedAt: Date(),
            binding: binding,
            asset: built.plan.asset,
            keeperDigestReceipt: built.plan.keeperDigestReceipt,
            plan: built.plan,
            authorization: .pending,
            dispatch: notDispatchedReceipt(),
            after: current,
            placementGeometry: geometry,
            readback: readback,
            rollback: manualRollbackEvidence(
                plan: built.plan,
                readback: readback,
                projectPath: current.projectPath
            ),
            validationIssues: verificationIssues,
            error: message
        )
        return await emit(receipt, cache: cache)
    }

    // MARK: - Bounded rollback

    private static func rollback(
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        let now = Date()
        let planID = firstString(params, keys: ["plan_id"]) ?? ""
        guard let session = await cache.getACEPlacementSession(planID: planID),
              let binding = await cache.getDisposableProjectBinding(),
              let priorReceipt = session.lastReceipt,
              priorReceipt.status == "verified_success",
              priorReceipt.readback.verified,
              priorReceipt.before != nil else {
            return await manualRollbackReceipt(
                operationID: firstString(params, keys: ["operation_id"]) ?? planID,
                planID: planID,
                reasonCode: "logic_rollback_requires_verified_created_identity",
                message: "rollback is manual-required because a uniquely verified created layer is unavailable",
                cache: cache
            )
        }

        guard session.plan.rollbackStrategy == ACEAudioPlacementContract.defaultRollbackStrategy else {
            return await manualRollbackReceipt(
                operationID: session.plan.operationID,
                planID: session.plan.planID,
                binding: binding,
                asset: session.plan.asset,
                plan: session.plan,
                authorization: session.authorization,
                priorReceipt: priorReceipt,
                reasonCode: "logic_rollback_strategy_manual_required",
                message: "automatic rollback is disabled because no stable atomic deletion key exists; manual handling is required",
                cache: cache
            )
        }

        let confirmation = parseConfirmation(
            params: params,
            idKeys: ["rollback_confirmation_id", "confirmation_id"],
            byKeys: ["rollback_confirmed_by", "confirmed_by", "authorized_by"],
            atKeys: ["rollback_confirmed_at", "confirmed_at", "authorized_at"]
        )
        let currentProject = await cache.getProject()
        let generation = await cache.getGeneration()
        let issues = uniqueIssues(
            ACEAudioPlacementValidator.validateBinding(
                binding,
                currentProject: currentProject,
                cacheGeneration: generation,
                now: now,
                verifyOnDisk: false
            )
                + ACEAudioPlacementValidator.validatePlan(session.plan, binding: binding)
                + validateConfirmation(confirmation, now: now)
        )
        guard issues.isEmpty else {
            return await manualRollbackReceipt(
                operationID: session.plan.operationID,
                planID: session.plan.planID,
                binding: binding,
                asset: session.plan.asset,
                plan: session.plan,
                authorization: confirmation,
                priorReceipt: priorReceipt,
                message: "rollback preconditions were not satisfied; no delete was started",
                issues: issues,
                cache: cache
            )
        }

        return await manualRollbackReceipt(
            operationID: session.plan.operationID,
            planID: session.plan.planID,
            binding: binding,
            asset: session.plan.asset,
            plan: session.plan,
            authorization: confirmation,
            priorReceipt: priorReceipt,
            reasonCode: "logic_rollback_atomic_delete_key_unavailable",
            message: "automatic rollback is manual-required because Logic exposes no stable atomic deletion key; no selection or delete was started",
            cache: cache
        )
    }

    // MARK: - Fresh readback and proof

    private struct FreshSnapshotResult {
        var snapshot: ACEPlacementSnapshot
        var issues: [ACEPlacementIssue]
        var observedAt: Date { snapshot.observedAt }
    }

    private static func freshSnapshot(
        binding: DisposableProjectBinding,
        router: ChannelRouter,
        cache: StateCache,
        now: Date,
        requireBindingDigest: Bool = true
    ) async -> FreshSnapshotResult? {
        let projectResult = await router.route(operation: "project.get_info")
        guard projectResult.isSuccess,
              let projectData = projectResult.message.data(using: .utf8),
              let project = decode(ProjectInfo.self, from: projectData) else {
            return nil
        }

        guard let observedProjectPath = canonicalObservedProjectPath(project) else {
            return nil
        }
        await cache.updateProject(project)
        let boundProject = await cache.getProject()
        let generation = await cache.getGeneration()
        guard let cachedObservedProjectPath = canonicalObservedProjectPath(boundProject),
              cachedObservedProjectPath == observedProjectPath else {
            return nil
        }
        // The AX project timestamp is produced during the read above. Use the
        // actual validation instant so a slow/fresh-process read is never
        // rejected merely because its honest readback timestamp is newer than
        // the caller's pre-dispatch timestamp.
        let validationNow = max(now, Date())
        let bindingIssues = ACEAudioPlacementValidator.validateBinding(
            binding,
            currentProject: boundProject,
            cacheGeneration: generation,
            now: validationNow,
            verifyOnDisk: requireBindingDigest
        )
        guard bindingIssues.isEmpty else {
            return nil
        }

        let tracksResult = await router.route(operation: "track.get_tracks")
        guard tracksResult.isSuccess,
              let tracksData = tracksResult.message.data(using: .utf8),
              let tracks = decode([TrackState].self, from: tracksData) else {
            return nil
        }
        await cache.updateTracks(tracks)
        let boundTracks = await cache.getTracks()

        let regionsResult = await router.route(operation: "region.get_regions")
        guard regionsResult.isSuccess,
              let regionsData = regionsResult.message.data(using: .utf8),
              let regions = decode([RegionState].self, from: regionsData) else {
            return nil
        }
        await cache.updateRegions(regions)
        let boundRegions = await cache.getRegions()

        let actualDigest: String
        do {
            actualDigest = try ACEFileDigest.sha256(at: observedProjectPath)
        } catch {
            return nil
        }
        if requireBindingDigest, actualDigest != binding.projectSHA256 { return nil }

        return FreshSnapshotResult(
            snapshot: ACEPlacementSnapshot(
                observedAt: boundProject.lastUpdated,
                projectPath: observedProjectPath,
                projectSHA256: actualDigest,
                generation: boundProject.generation,
                tracks: boundTracks,
                regions: boundRegions
            ),
            issues: []
        )
    }

    private static func freshSnapshotWithRetry(
        binding: DisposableProjectBinding,
        router: ChannelRouter,
        cache: StateCache,
        now: Date,
        requireBindingDigest: Bool = true
    ) async -> FreshSnapshotResult? {
        for attempt in 0..<12 {
            if let result = await freshSnapshot(
                binding: binding,
                router: router,
                cache: cache,
                now: now,
                requireBindingDigest: requireBindingDigest
            ) {
                return result
            }
            if attempt < 11 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        return nil
    }

    private static func canonicalObservedProjectPath(_ project: ProjectInfo) -> String? {
        guard let filePath = project.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filePath.isEmpty,
              project.projectIdentity.canAuthorizeMutation,
              let identityValue = project.projectIdentity.value,
              ACEFileDigest.normalizedPath(filePath) == ACEFileDigest.normalizedPath(identityValue) else {
            return nil
        }
        return ACEFileDigest.normalizedPath(filePath)
    }

    private static func validateNewTrackPreflight(snapshot: ACEPlacementSnapshot, plan: ACEAudioPlacementPlan) -> [ACEPlacementIssue] {
        guard coherentProjectBoundState(snapshot) else {
            return [ACEPlacementIssue(
                code: "logic_before_readback_identity_unstable",
                message: "before readback contains unknown or contradictory project/identity metadata; visible-only synthetic objects remain read-only",
                path: "$.before.identity"
            )]
        }
        let matchingTags = snapshot.tracks.filter {
            OperationTagIdentity.operationTag(in: $0.name) == plan.trackTag
        }
        guard matchingTags.isEmpty else {
            return [ACEPlacementIssue(code: "logic_track_tag_collision", message: "unique ACE track tag already exists in the before snapshot; no mutation started", path: "$.placement_plan.track.track_tag")]
        }
        return []
    }

    private static func evaluateReadback(
        before: ACEPlacementSnapshot,
        after: ACEPlacementSnapshot,
        plan: ACEAudioPlacementPlan,
        geometry: ACEAudioDeltaGeometry?
    ) -> ACEPlacementReadback {
        guard before.projectSHA256 == plan.targetProjectSHA256,
              before.projectPath == plan.targetProjectPath,
              after.projectPath == plan.targetProjectPath,
              after.projectPath == before.projectPath,
              after.tracks.count == before.tracks.count + 1,
              after.regions.count == before.regions.count + 1 else {
            return baseReadback(after: after, code: "logic_readback_project_mismatch")
        }
        guard coherentProjectBoundState(before), coherentProjectBoundState(after) else {
            return baseReadback(after: after, code: "logic_readback_identity_unstable")
        }
        guard unchangedExistingState(before: before, after: after) else {
            return baseReadback(after: after, code: "logic_readback_existing_content_changed")
        }
        return evaluateAssetRegionReadback(
            snapshot: after,
            plan: plan,
            geometry: geometry,
            expectedTrackCount: before.tracks.count + 1,
            expectedRegionCount: before.regions.count + 1
        )
    }

    private static func evaluateFreshReadback(
        snapshot: ACEPlacementSnapshot,
        plan: ACEAudioPlacementPlan,
        geometry: ACEAudioDeltaGeometry?,
        expectedTrackCount: Int,
        expectedRegionCount: Int
    ) -> ACEPlacementReadback {
        guard coherentProjectBoundState(snapshot) else {
            return baseReadback(after: snapshot, code: "logic_fresh_readback_identity_unstable")
        }
        return evaluateAssetRegionReadback(
            snapshot: snapshot,
            plan: plan,
            geometry: geometry,
            expectedTrackCount: expectedTrackCount,
            expectedRegionCount: expectedRegionCount
        )
    }

    private static func evaluateAssetRegionReadback(
        snapshot: ACEPlacementSnapshot,
        plan: ACEAudioPlacementPlan,
        geometry: ACEAudioDeltaGeometry?,
        expectedTrackCount: Int,
        expectedRegionCount: Int
    ) -> ACEPlacementReadback {
        guard snapshot.projectPath == plan.targetProjectPath,
              snapshot.tracks.count == expectedTrackCount,
              snapshot.regions.count == expectedRegionCount else {
            return baseReadback(after: snapshot, code: "logic_readback_count_mismatch")
        }
        guard let keeperReceipt = plan.keeperDigestReceipt,
              ACEAudioPlacementValidator.validateKeeperDigestReceipt(
                keeperReceipt,
                source: plan.asset,
                verifyOnDisk: true
              ).isEmpty else {
            return baseReadback(after: snapshot, code: "logic_keeper_digest_receipt_unverified")
        }

        let taggedTracks = snapshot.tracks.filter {
            OperationTagIdentity.operationTag(in: $0.name) == plan.trackTag
        }
        guard taggedTracks.count == 1,
              let track = taggedTracks.first,
              track.identityStability == .stable,
              track.identityScope == "project_bound",
              let stableTrackID = track.stableID,
              OperationTagIdentity.trackID(
                projectIdentity: track.projectIdentity,
                operationTag: plan.trackTag
              ) == stableTrackID,
              track.type == .audio || track.type == .unknown else {
            return baseReadback(after: snapshot, code: "logic_readback_track_identity_ambiguous")
        }

        let candidateRegions = snapshot.regions.filter {
            $0.trackName == track.name
                && $0.name == plan.asset.nativeSourceBasename
                && $0.trackStableID == stableTrackID
        }
        guard candidateRegions.count == 1,
              let region = candidateRegions.first else {
            return baseReadback(after: snapshot, code: "logic_readback_region_identity_ambiguous")
        }

        guard let geometry else {
            return baseReadback(after: snapshot, code: "logic_readback_geometry_unavailable")
        }
        guard geometry.requestedBar == plan.placement.bar,
              abs(geometry.requestedBeat - plan.placement.beat) < 0.0001,
              geometry.requestedTick == plan.placement.tick else {
            return baseReadback(after: snapshot, code: "logic_readback_placement_mismatch")
        }
        let geometryIssues = ACEAudioDeltaAdoptionValidator.validateGeometry(
            geometry,
            placement: plan.placement,
            allowNativeDurationMismatch: !plan.automaticTimeStretch
        )
        guard geometryIssues.isEmpty,
              let observedBar = geometry.observedBar,
              let observedBeat = geometry.observedBeat,
              let measuredDuration = geometry.estimatedDurationBeats else {
            return baseReadback(after: snapshot, code: "logic_readback_placement_mismatch")
        }
        let observedPlacement = ACEPlacementCoordinates(
            bar: Int(observedBar.rounded()),
            beat: observedBeat,
            tick: plan.placement.tick,
            durationBeats: measuredDuration,
            beatsPerBar: plan.placement.beatsPerBar
        )
        guard observedPlacement.bar == plan.placement.bar,
              abs(observedPlacement.beat - plan.placement.beat) < 0.0001,
              observedPlacement.tick == 0 else {
            return baseReadback(after: snapshot, code: "logic_readback_placement_mismatch")
        }
        guard let assetRegionID = OperationTagIdentity.assetRegionID(
            projectIdentity: track.projectIdentity,
            trackOperationTag: plan.trackTag,
            nativeSourceBasename: keeperReceipt.nativeSourceBasename,
            keeperSHA256: keeperReceipt.sha256
        ) else {
            return baseReadback(after: snapshot, code: "logic_readback_asset_identity_unavailable")
        }
        let identity = ACEAssetRegionIdentity(
            schemaVersion: ACEAssetRegionIdentityContract.schemaVersion,
            stableID: assetRegionID,
            projectPath: snapshot.projectPath,
            enclosingTrackID: stableTrackID,
            enclosingTrackTag: plan.trackTag,
            nativeSourceBasename: keeperReceipt.nativeSourceBasename,
            keeperSHA256: keeperReceipt.sha256,
            keeperDigestReceiptID: keeperReceipt.receiptID,
            observedRegionName: region.name,
            identityKind: ACEAssetRegionIdentityContract.identityKind,
            verified: true
        )
        return ACEPlacementReadback(
            status: "verified",
            verified: true,
            reasonCode: "logic_unique_created_asset_region_readback",
            observedAt: snapshot.observedAt,
            projectIdentity: snapshot.projectSHA256,
            projectPath: snapshot.projectPath,
            assetSHA256: keeperReceipt.sha256,
            trackID: stableTrackID,
            regionID: assetRegionID,
            trackName: track.name,
            placement: observedPlacement,
            identityKind: ACEAssetRegionIdentityContract.identityKind,
            evidenceURI: "logic://ace-audio/placements/\(plan.planID)/asset-region-readback",
            assetRegionIdentity: identity
        )
    }

    private static func baseReadback(
        after: ACEPlacementSnapshot,
        code: String
    ) -> ACEPlacementReadback {
        ACEPlacementReadback(
            status: "not_verified",
            verified: false,
            reasonCode: code,
            observedAt: after.observedAt,
            projectIdentity: after.projectSHA256,
            projectPath: after.projectPath,
            assetSHA256: nil,
            trackID: nil,
            regionID: nil,
            trackName: nil,
            placement: nil,
            identityKind: nil,
            evidenceURI: nil,
            assetRegionIdentity: nil
        )
    }

    private static func coherentProjectBoundState(_ snapshot: ACEPlacementSnapshot) -> Bool {
        guard snapshot.generation > 0, !snapshot.projectPath.isEmpty else { return false }
        return snapshot.tracks.allSatisfy { coherentIdentity($0, snapshot: snapshot) }
            && snapshot.regions.allSatisfy { coherentIdentity($0, snapshot: snapshot) }
    }

    private static func coherentIdentity(_ track: TrackState, snapshot: ACEPlacementSnapshot) -> Bool {
        coherentIdentity(
            projectIdentity: track.projectIdentity,
            generation: track.generation,
            identityStability: track.identityStability,
            identityScope: track.identityScope,
            stableID: track.stableID,
            snapshot: snapshot
        )
    }

    private static func coherentIdentity(_ region: RegionState, snapshot: ACEPlacementSnapshot) -> Bool {
        coherentIdentity(
            projectIdentity: region.projectIdentity,
            generation: region.generation,
            identityStability: region.identityStability,
            identityScope: region.identityScope,
            stableID: region.stableID,
            snapshot: snapshot
        )
    }

    private static func coherentIdentity(
        projectIdentity: ProjectIdentity,
        generation: UInt64,
        identityStability: StateIdentityStability,
        identityScope: String,
        stableID: String?,
        snapshot: ACEPlacementSnapshot
    ) -> Bool {
        guard projectIdentity.canAuthorizeMutation,
              projectIdentity.value.map(ACEFileDigest.normalizedPath) == snapshot.projectPath,
              generation == snapshot.generation else {
            return false
        }
        switch identityStability {
        case .stable:
            return identityScope == "project_bound" && stableID?.isEmpty == false
        case .synthetic, .visibleOnly:
            // Existing visible objects may remain display-only. They are
            // accepted for a coherent snapshot but never become mutation keys.
            return identityScope == "visible_only" && stableID == nil
        case .unknown:
            return false
        }
    }

    private static func unchangedExistingState(before: ACEPlacementSnapshot, after: ACEPlacementSnapshot) -> Bool {
        for track in before.tracks {
            guard let observed = after.tracks.first(where: { $0.id == track.id }),
                  observed.name == track.name,
                  observed.type == track.type,
                  observed.isMuted == track.isMuted,
                  observed.isSoloed == track.isSoloed,
                  observed.isArmed == track.isArmed,
                  observed.identityStability == track.identityStability,
                  observed.identityScope == track.identityScope,
                  observed.stableID == track.stableID else { return false }
        }
        for region in before.regions {
            guard let observed = after.regions.first(where: { $0.id == region.id }),
                  observed.name == region.name,
                  observed.trackIndex == region.trackIndex,
                  observed.startPosition == region.startPosition,
                  observed.endPosition == region.endPosition,
                  observed.length == region.length,
                  observed.identityStability == region.identityStability,
                  observed.identityScope == region.identityScope,
                  observed.stableID == region.stableID,
                  observed.trackStableID == region.trackStableID else { return false }
        }
        return true
    }

    private static func parsePlacement(region: RegionState, beatsPerBar: Int) -> ACEPlacementCoordinates? {
        let positionParts = region.startPosition.split(separator: ".")
        guard positionParts.count >= 2,
              let bar = Int(positionParts[0]),
              let beat = Double(positionParts[1]),
              bar >= 1,
              beat >= 1,
              let duration = Double(region.length),
              duration > 0 else { return nil }
        let tick = positionParts.count >= 3 ? Int(positionParts.last ?? "0") ?? 0 : 0
        return ACEPlacementCoordinates(bar: bar, beat: beat, tick: tick, durationBeats: duration, beatsPerBar: beatsPerBar)
    }

    private static func placementsMatch(_ lhs: ACEPlacementCoordinates, _ rhs: ACEPlacementCoordinates) -> Bool {
        lhs.bar == rhs.bar
            && abs(lhs.beat - rhs.beat) < 0.0001
            && lhs.tick == rhs.tick
            && abs(lhs.durationBeats - rhs.durationBeats) < 0.0001
    }

    // MARK: - Plan and parameter parsing

    private struct PlanBuildResult {
        var plan: ACEAudioPlacementPlan
        var issues: [ACEPlacementIssue]
    }

    private struct KeeperReceiptParseResult {
        var receipt: ACEKeeperDigestReceipt?
        var issues: [ACEPlacementIssue]
    }

    private static func buildPlan(params: [String: Value], binding: DisposableProjectBinding) -> PlanBuildResult {
        let (handoff, handoffIssues) = handoffObject(params)
        let planObject = object(handoff, path: ["placement_plan"]) ?? [:]
        let assetObject = object(handoff, path: ["asset"]) ?? [:]
        let sourceObject = object(assetObject, path: ["source"]) ?? [:]
        let audioObject = object(assetObject, path: ["audio"]) ?? [:]
        let roleObject = object(planObject, path: ["role"]) ?? [:]
        let targetObject = object(planObject, path: ["target_project"]) ?? [:]
        let trackObject = object(planObject, path: ["track"]) ?? [:]
        let placementObject = object(planObject, path: ["placement"]) ?? [:]
        let gridObject = object(placementObject, path: ["grid"]) ?? [:]
        let tempoObject = object(planObject, path: ["tempo_policy"]) ?? [:]
        let mixObject = object(planObject, path: ["mix"]) ?? [:]
        let collisionObject = object(planObject, path: ["collision_policy"]) ?? [:]
        let safetyObject = object(planObject, path: ["safety"]) ?? [:]
        let rollbackObject = object(safetyObject, path: ["rollback"]) ?? [:]
        let operationObject = object(handoff, path: ["operation"]) ?? [:]

        let keeperReceipt = parseKeeperDigestReceipt(params: params, handoff: handoff)
        var issues = handoffIssues + keeperReceipt.issues
        if let handoffSchema = stringValue(handoff?["schema_version"]), handoffSchema != ACEAudioPlacementContract.handoffSchemaVersion {
            issues.append(ACEPlacementIssue(code: "ace_handoff_incompatible", message: "handoff schema is outside the supported v1 reader boundary", path: "$.schema_version"))
        }

        let planID = firstString(params, keys: ["plan_id"]) ?? stringValue(planObject["plan_id"]) ?? ""
        let operationID = firstString(params, keys: ["operation_id"]) ?? stringValue(operationObject["operation_id"]) ?? ""
        let assetSHA = firstString(params, keys: ["asset_sha256", "sha256"]) ?? stringValue(sourceObject["sha256"]) ?? ""
        let assetPath = filePath(firstString(params, keys: ["asset_path", "audio_path", "path"]) ?? stringValue(sourceObject["uri"]) ?? "")
        let assetID = firstString(params, keys: ["asset_id"]) ?? stringValue(assetObject["asset_id"]) ?? "asset-\(assetSHA.prefix(12))"
        let format = firstString(params, keys: ["format", "audio_format"]) ?? stringValue(audioObject["format"]) ?? URL(fileURLWithPath: assetPath).pathExtension.lowercased()
        let roleID = firstString(params, keys: ["role_id"]) ?? stringValue(roleObject["role_id"]) ?? ""
        let roleDescription = firstString(params, keys: ["role_description", "description"]) ?? stringValue(roleObject["description"]) ?? ""
        let claimBoundary = firstString(params, keys: ["claim_boundary"]) ?? stringValue(roleObject["claim_boundary"]) ?? ""
        let targetPath = filePath(firstString(params, keys: ["target_project_path", "project_path"]) ?? stringValue(targetObject["path"]) ?? binding.path)
        let targetSHA = firstString(params, keys: ["target_project_sha256", "project_sha256"]) ?? stringValue(object(targetObject, path: ["identity"])?["value"]) ?? binding.projectSHA256
        let trackPolicy = firstString(params, keys: ["track_policy"]) ?? stringValue(trackObject["policy"]) ?? "create_new_track"
        let trackNameInput = firstString(params, keys: ["track_name"]) ?? stringValue(trackObject["track_name"])
        let tempoMode = firstString(params, keys: ["tempo_mode"]) ?? stringValue(tempoObject["mode"]) ?? "preserve_project_tempo"
        let automaticStretch = boolValue(params["automatic_time_stretch"]) ?? boolAny(tempoObject["automatic_time_stretch"]) ?? false
        let collisionMode = firstString(params, keys: ["collision_mode"]) ?? stringValue(collisionObject["mode"]) ?? "reject_if_collision"
        let existingContentAction = firstString(params, keys: ["existing_content_action"]) ?? stringValue(collisionObject["existing_content_action"]) ?? "reject"
        let rollbackStrategy = firstString(params, keys: ["rollback_strategy"]) ?? stringValue(rollbackObject["strategy"]) ?? ACEAudioPlacementContract.defaultRollbackStrategy
        let rollbackRequired = boolValue(params["rollback_required"]) ?? boolAny(rollbackObject["required"]) ?? true
        let rollbackReceiptRequired = boolValue(params["rollback_receipt_required"]) ?? boolAny(rollbackObject["receipt_required"]) ?? true

        let placement = ACEPlacementCoordinates(
            bar: firstInt(params, keys: ["bar"]) ?? intAny(placementObject["start"].flatMap { objectAny($0)?["bar"] }) ?? 0,
            beat: firstDouble(params, keys: ["beat"]) ?? doubleAny(placementObject["start"].flatMap { objectAny($0)?["beat"] }) ?? 0,
            tick: firstInt(params, keys: ["tick"]) ?? intAny(placementObject["start"].flatMap { objectAny($0)?["tick"] }) ?? 0,
            durationBeats: firstDouble(params, keys: ["duration_beats", "duration"]) ?? doubleAny(placementObject["duration_beats"]) ?? 0,
            beatsPerBar: firstInt(params, keys: ["beats_per_bar"]) ?? intAny(gridObject["beats_per_bar"]) ?? ACEAudioPlacementContract.defaultBeatsPerBar
        )

        let source = ACEAudioSource(
            assetID: assetID,
            path: assetPath,
            sha256: assetSHA,
            format: format.lowercased()
        )
        let generatedTrackTag = ACEAudioPlacementValidator.makeTrackTag(planID: planID, assetSHA256: assetSHA)
        let generatedRegionTag = ACEAudioPlacementValidator.makeRegionTag(operationID: operationID, assetSHA256: assetSHA)
        let trackTag = firstString(params, keys: ["track_tag"]) ?? stringValue(trackObject["track_tag"]) ?? generatedTrackTag
        let regionTag = firstString(params, keys: ["region_tag"]) ?? stringValue(planObject["region_tag"]) ?? generatedRegionTag
        let trackName = trackNameInput ?? trackTag
        let plan = ACEAudioPlacementPlan(
            schemaVersion: stringValue(planObject["schema_version"]) ?? ACEAudioPlacementContract.planSchemaVersion,
            planID: planID,
            operationID: operationID,
            roleID: roleID,
            roleDescription: roleDescription,
            claimBoundary: claimBoundary,
            asset: source,
            targetProjectPath: targetPath,
            targetProjectSHA256: targetSHA,
            bindingID: binding.bindingID,
            trackPolicy: trackPolicy,
            trackName: trackName,
            trackTag: trackTag,
            regionTag: regionTag,
            placement: placement,
            tempoMode: tempoMode,
            automaticTimeStretch: automaticStretch,
            gainDB: firstDouble(params, keys: ["gain_db"]) ?? doubleAny(mixObject["gain_db"]) ?? 0,
            fadeInSeconds: firstDouble(params, keys: ["fade_in_seconds"]) ?? doubleAny(mixObject["fade_in_seconds"]) ?? 0,
            fadeOutSeconds: firstDouble(params, keys: ["fade_out_seconds"]) ?? doubleAny(mixObject["fade_out_seconds"]) ?? 0,
            collisionMode: collisionMode,
            existingContentAction: existingContentAction,
            rollbackStrategy: rollbackStrategy,
            rollbackRequired: rollbackRequired,
            rollbackReceiptRequired: rollbackReceiptRequired,
            keeperDigestReceipt: keeperReceipt.receipt
        )
        if planID.isEmpty { issues.append(ACEPlacementIssue(code: "logic_plan_id_missing", message: "plan_id is required", path: "$.placement_plan.plan_id")) }
        if operationID.isEmpty { issues.append(ACEPlacementIssue(code: "logic_operation_id_missing", message: "operation_id is required", path: "$.operation.operation_id")) }
        return PlanBuildResult(plan: plan, issues: uniqueIssues(issues))
    }

    private static func parseKeeperDigestReceipt(
        params: [String: Value],
        handoff: [String: Any]?
    ) -> KeeperReceiptParseResult {
        let data: Data?
        if let json = params["keeper_digest_receipt_json"]?.stringValue {
            data = json.data(using: .utf8)
        } else if let value = params["keeper_digest_receipt"],
                  let objectValue = value.objectValue {
            let object = objectValue.reduce(into: [String: Any]()) { result, item in
                result[item.key] = anyValue(item.value)
            }
            data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } else if let handoffReceipt = object(handoff, path: ["asset", "keeper_digest_receipt"]) {
            data = try? JSONSerialization.data(withJSONObject: handoffReceipt, options: [.sortedKeys])
        } else {
            return KeeperReceiptParseResult(receipt: nil, issues: [])
        }

        guard let data else {
            return KeeperReceiptParseResult(
                receipt: nil,
                issues: [ACEPlacementIssue(code: "ace_keeper_digest_receipt_invalid", message: "keeper_digest_receipt must be valid JSON", path: "$.asset.keeper_digest_receipt")]
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let receipt = try? decoder.decode(ACEKeeperDigestReceipt.self, from: data) else {
            return KeeperReceiptParseResult(
                receipt: nil,
                issues: [ACEPlacementIssue(code: "ace_keeper_digest_receipt_invalid", message: "keeper_digest_receipt does not match the v1 receipt contract", path: "$.asset.keeper_digest_receipt")]
            )
        }
        return KeeperReceiptParseResult(receipt: receipt, issues: [])
    }

    // MARK: - Exact-delta helpers

    private struct AdoptionSpecBuildResult {
        var spec: ACEAudioDeltaAdoptionSpec?
        var issues: [ACEPlacementIssue]
        var planID: String
        var operationID: String
    }

    private static func buildAdoptionSpec(params: [String: Value]) -> AdoptionSpecBuildResult {
        let planID = firstString(params, keys: ["plan_id"]) ?? ""
        let operationID = firstString(params, keys: ["operation_id"]) ?? ""
        let targetProjectPath = filePath(firstString(params, keys: ["target_project_path", "project_path"]) ?? "")
        let startingProjectSHA256 = firstString(params, keys: ["starting_project_sha256", "project_sha256"]) ?? ""
        let baselineProjectSHA256 = firstString(params, keys: ["baseline_project_sha256"]) ?? ""
        let beforeTrackCount = firstInt(params, keys: ["before_track_count"]) ?? -1
        let beforeRegionCount = firstInt(params, keys: ["before_region_count"]) ?? -1
        let currentTrackCount = firstInt(params, keys: ["current_track_count"]) ?? -1
        let currentRegionCount = firstInt(params, keys: ["current_region_count"]) ?? -1
        let newTrackName = firstString(params, keys: ["new_track_name"]) ?? ""
        let sourceBaseName = firstString(params, keys: ["source_base_name"]) ?? ""
        let duplicateRegionName = firstString(params, keys: ["duplicate_region_name"]) ?? ""
        let preservedTrackNames = stringArray(params["preserved_track_names"]) ?? []
        let preservedRegionNames = stringArray(params["preserved_region_names"]) ?? []
        let sourcePath = filePath(firstString(params, keys: ["asset_path", "source_path"]) ?? "")
        let sourceSHA256 = firstString(params, keys: ["asset_sha256", "source_sha256"]) ?? ""
        let sourceFormat = (firstString(params, keys: ["format", "audio_format"]) ?? URL(fileURLWithPath: sourcePath).pathExtension).lowercased()
        let source = ACEAudioSource(
            assetID: firstString(params, keys: ["asset_id"]) ?? "asset-" + String(sourceSHA256.prefix(12)),
            path: sourcePath,
            sha256: sourceSHA256,
            format: sourceFormat
        )
        let trackTag = firstString(params, keys: ["track_tag"]) ?? ""
        let regionTag = firstString(params, keys: ["region_tag"]) ?? ""
        let placement = ACEPlacementCoordinates(
            bar: firstInt(params, keys: ["bar"]) ?? -1,
            beat: firstDouble(params, keys: ["beat"]) ?? -1,
            tick: firstInt(params, keys: ["tick"]) ?? -1,
            durationBeats: firstDouble(params, keys: ["duration_beats"]) ?? -1,
            beatsPerBar: firstInt(params, keys: ["beats_per_bar"]) ?? -1
        )
        let spec = ACEAudioDeltaAdoptionSpec(
            planID: planID,
            operationID: operationID,
            targetProjectPath: targetProjectPath,
            startingProjectSHA256: startingProjectSHA256,
            baselineProjectSHA256: baselineProjectSHA256,
            beforeTrackCount: beforeTrackCount,
            beforeRegionCount: beforeRegionCount,
            currentTrackCount: currentTrackCount,
            currentRegionCount: currentRegionCount,
            newTrackName: newTrackName,
            sourceBaseName: sourceBaseName,
            duplicateRegionName: duplicateRegionName,
            preservedTrackNames: preservedTrackNames,
            preservedRegionNames: preservedRegionNames,
            source: source,
            trackTag: trackTag,
            regionTag: regionTag,
            placement: placement
        )
        var issues = ACEAudioDeltaAdoptionValidator.validateSpec(spec)
        if params["preserved_track_names"] != nil && preservedTrackNames.isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_adoption_preserved_track_names_invalid", message: "preserved_track_names must be a non-empty string array", path: "$.adoption.preserved_track_names"))
        }
        if params["preserved_region_names"] != nil && preservedRegionNames.isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_adoption_preserved_region_names_invalid", message: "preserved_region_names must be a non-empty string array", path: "$.adoption.preserved_region_names"))
        }
        return AdoptionSpecBuildResult(
            spec: spec,
            issues: uniqueIssues(issues),
            planID: planID,
            operationID: operationID
        )
    }

    private static func stringArray(_ value: Value?) -> [String]? {
        if let values = value?.arrayValue {
            let strings = values.compactMap(\.stringValue)
            return strings.count == values.count ? strings : nil
        }
        if let json = value?.stringValue,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            return decoded
        }
        return nil
    }

    private static func adoptionChannelParams(_ spec: ACEAudioDeltaAdoptionSpec) -> [String: String] {
        [
            "spec_json": encodeCompactJSON(spec),
            "current_track_count": String(spec.currentTrackCount),
            "current_region_count": String(spec.currentRegionCount),
        ]
    }

    private static func freshUnboundAdoptionSnapshot(
        spec: ACEAudioDeltaAdoptionSpec,
        router: ChannelRouter,
        cache: StateCache
    ) async -> FreshSnapshotResult? {
        let projectResult = await router.route(operation: "project.get_info")
        guard projectResult.isSuccess,
              let projectData = projectResult.message.data(using: .utf8),
              let project = decode(ProjectInfo.self, from: projectData),
              let observedPath = canonicalObservedProjectPath(project),
              let actualDigest = try? ACEFileDigest.sha256(at: observedPath) else {
            return nil
        }
        let now = Date()
        let binding = DisposableProjectBinding(
            bindingID: "fresh-adoption-" + spec.planID,
            path: observedPath,
            projectSHA256: actualDigest,
            authority: ACEAudioPlacementContract.disposableProjectAuthority,
            issuedAt: now.addingTimeInterval(-1),
            expiresAt: now.addingTimeInterval(60),
            originalProjectPath: nil,
            originalProjectPreserved: true
        )
        return await freshSnapshotWithRetry(
            binding: binding,
            router: router,
            cache: cache,
            now: now,
            requireBindingDigest: true
        )
    }

    private static func emitAdoption(_ receipt: ACEAudioDeltaAdoptionReceipt) -> CallTool.Result {
        CallTool.Result(content: [.text(encodeCompactJSON(receipt))], isError: !receipt.success)
    }

    private static func adoptionReceiptID(operationID: String, phase: String, status: String) -> String {
        (operationID + "-" + phase + "-" + status).replacingOccurrences(of: " ", with: "-")
    }

    // MARK: - Receipt helpers

    private static func rejectedReceipt(
        operationID: String,
        planID: String,
        phase: String,
        binding: DisposableProjectBinding? = nil,
        asset: ACEAudioSource? = nil,
        plan: ACEAudioPlacementPlan? = nil,
        authorization: ACEPlacementAuthorization = .pending,
        before: ACEPlacementSnapshot? = nil,
        errorCode: String? = nil,
        message: String? = nil,
        issues: [ACEPlacementIssue] = [],
        cache: StateCache
    ) async -> CallTool.Result {
        var allIssues = issues
        if let errorCode, let message {
            allIssues.append(ACEPlacementIssue(code: errorCode, message: message))
        }
        allIssues = uniqueIssues(allIssues)
        let receipt = ACEAudioPlacementReceipt(
            receiptID: receiptID(operationID: operationID, phase: phase, status: "rejected"),
            operationID: operationID,
            planID: planID,
            phase: phase,
            status: "rejected",
            success: false,
            issuedAt: Date(),
            binding: binding,
            asset: asset,
            plan: plan,
            authorization: authorization,
            dispatch: notDispatchedReceipt(),
            before: before,
            validationIssues: allIssues,
            error: allIssues.first?.message
        )
        return await emit(receipt, cache: cache)
    }

    private static func manualRollbackReceipt(
        operationID: String,
        planID: String,
        binding: DisposableProjectBinding? = nil,
        asset: ACEAudioSource? = nil,
        plan: ACEAudioPlacementPlan? = nil,
        authorization: ACEPlacementAuthorization = .pending,
        priorReceipt: ACEAudioPlacementReceipt? = nil,
        before: ACEPlacementSnapshot? = nil,
        reasonCode: String = "logic_rollback_manual_required",
        message: String,
        issues: [ACEPlacementIssue] = [],
        cache: StateCache
    ) async -> CallTool.Result {
        let effectivePlan = plan ?? priorReceipt?.plan
        let effectiveReadback = priorReceipt?.readback
        let rollbackEvidence: ACEPlacementRollbackReceipt
        if let effectivePlan {
            rollbackEvidence = manualRollbackEvidence(
                plan: effectivePlan,
                readback: effectiveReadback,
                projectPath: binding?.path ?? priorReceipt?.after?.projectPath ?? effectivePlan.targetProjectPath,
                reasonCode: reasonCode
            )
        } else {
            rollbackEvidence = ACEPlacementRollbackReceipt(
                status: "manual_required",
                strategy: ACEAudioPlacementContract.defaultRollbackStrategy,
                mutation: "not_started",
                verification: "unavailable",
                reasonCode: reasonCode,
                receiptID: nil,
                startedAt: nil,
                completedAt: nil,
                trackID: nil,
                regionID: nil,
                evidenceURI: nil
            )
        }
        let receipt = ACEAudioPlacementReceipt(
            receiptID: receiptID(operationID: operationID, phase: "rollback", status: "manual_required"),
            operationID: operationID,
            planID: planID,
            phase: "rollback",
            status: "manual_required",
            success: false,
            issuedAt: Date(),
            binding: binding ?? priorReceipt?.binding,
            asset: asset ?? priorReceipt?.asset,
            plan: effectivePlan,
            authorization: authorization,
            dispatch: notDispatchedReceipt(),
            before: before,
            readback: priorReceipt?.readback ?? .notRequested(reasonCode: reasonCode),
            rollback: rollbackEvidence,
            validationIssues: uniqueIssues(issues + [ACEPlacementIssue(code: reasonCode, message: message)]),
            error: message
        )
        return await emit(receipt, cache: cache)
    }

    private static func manualRollbackEvidence(
        plan: ACEAudioPlacementPlan,
        readback: ACEPlacementReadback?,
        projectPath: String,
        reasonCode: String = "logic_rollback_atomic_delete_key_unavailable"
    ) -> ACEPlacementRollbackReceipt {
        let basename = plan.asset.nativeSourceBasename
        return ACEPlacementRollbackReceipt(
            status: "manual_required",
            strategy: plan.rollbackStrategy,
            mutation: "not_started",
            verification: "unavailable",
            reasonCode: reasonCode,
            receiptID: nil,
            startedAt: nil,
            completedAt: nil,
            trackID: readback?.trackID,
            regionID: readback?.regionID,
            evidenceURI: "logic://ace-audio/placements/\(plan.planID)/rollback-manual",
            projectPath: ACEFileDigest.normalizedPath(projectPath),
            trackTag: plan.trackTag,
            nativeSourceBasename: basename,
            keeperSHA256: plan.keeperDigestReceipt?.sha256 ?? plan.asset.sha256,
            instructions: [
                "No automatic selection or delete mutation was issued.",
                "Operate only on \(ACEFileDigest.normalizedPath(projectPath)); preserve the original project and keeper source.",
                "Locate exactly one track whose full name contains the exact tagged track \(plan.trackTag).",
                "On that track, locate exactly one region whose native name is exactly \(basename); independently verify keeper digest \(plan.keeperDigestReceipt?.sha256 ?? plan.asset.sha256) and receipt \(plan.keeperDigestReceipt?.receiptID ?? "missing") before selecting.",
                "Select only that source-bound region, delete only it, and delete the tagged track only if it is empty; do not rename any region or pre-existing object.",
                "Save the disposable and verify the tagged track/region are absent while the three pre-existing tracks, three pre-existing regions, their native names, and preservation hashes match the clean 3/3 evidence."
            ]
        )
    }

    private static func placementGeometryParams(plan: ACEAudioPlacementPlan) -> [String: String] {
        [
            "target_project_path": plan.targetProjectPath,
            "track_tag": plan.trackTag,
            "native_source_basename": plan.asset.nativeSourceBasename,
            "asset_sha256": plan.asset.sha256,
            "bar": String(plan.placement.bar),
            "beat": String(plan.placement.beat),
            "tick": String(plan.placement.tick),
            "duration_beats": String(plan.placement.durationBeats),
            "beats_per_bar": String(plan.placement.beatsPerBar),
            "automatic_time_stretch": String(plan.automaticTimeStretch),
        ]
    }

    private static func emit(
        _ receipt: ACEAudioPlacementReceipt,
        cache: StateCache,
        updateLast: Bool = true
    ) async -> CallTool.Result {
        if updateLast {
            await cache.updateLastACEAudioPlacementReceipt(receipt)
        }
        return CallTool.Result(content: [.text(encodeCompactJSON(receipt))], isError: !receipt.success)
    }

    private static func notDispatchedReceipt() -> ACEPlacementDispatchReceipt {
        ACEPlacementDispatchReceipt(status: "not_dispatched", method: nil, receiptID: nil, dispatchedAt: nil, sourceSHA256: nil, message: nil)
    }

    private static func stageReceipt(
        stage: String,
        startedAt: Date,
        attempt: Int,
        result: ChannelResult,
        successOutcome: String
    ) -> ACEPlacementStageReceipt {
        let completedAt = Date()
        let status = result.isSuccess
            ? "completed"
            : markerValue("status", in: result.message) ?? "failed"
        let outcome = result.isSuccess
            ? successOutcome
            : markerValue("outcome", in: result.message) ?? "unknown"
        return ACEPlacementStageReceipt(
            stage: stage,
            status: status,
            outcome: outcome,
            startedAt: startedAt,
            completedAt: completedAt,
            elapsedMilliseconds: max(0, Int(completedAt.timeIntervalSince(startedAt) * 1_000)),
            attempt: attempt,
            message: result.message
        )
    }

    private static func markerValue(_ key: String, in message: String) -> String? {
        let token = "\(key)="
        guard let start = message.range(of: token)?.upperBound else { return nil }
        let remainder = message[start...]
        if let end = remainder.firstIndex(of: " ") {
            return String(remainder[..<end])
        }
        return String(remainder)
    }

    private static func receiptID(operationID: String, phase: String, status: String) -> String {
        let value = "\(operationID)-\(phase)-\(status)"
        return value.replacingOccurrences(of: " ", with: "-")
    }

    // MARK: - Confirmation

    private static func parseConfirmation(
        params: [String: Value],
        idKeys: [String] = ["confirmation_id"],
        byKeys: [String] = ["confirmed_by", "authorized_by"],
        atKeys: [String] = ["confirmed_at", "authorized_at"]
    ) -> ACEPlacementAuthorization {
        ACEPlacementAuthorization(
            required: true,
            status: "confirmed",
            confirmedBy: firstString(params, keys: byKeys),
            confirmedAt: parseDate(firstString(params, keys: atKeys)),
            confirmationID: firstString(params, keys: idKeys)
        )
    }

    private static func validateConfirmation(_ confirmation: ACEPlacementAuthorization, now: Date) -> [ACEPlacementIssue] {
        var issues: [ACEPlacementIssue] = []
        guard confirmation.required, confirmation.status == "confirmed" else {
            issues.append(ACEPlacementIssue(code: "logic_confirmation_missing", message: "human confirmation is required before any Logic mutation", path: "$.operation.authorization"))
            return issues
        }
        if confirmation.confirmationID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append(ACEPlacementIssue(code: "logic_confirmation_missing", message: "confirmation_id is required before any Logic mutation", path: "$.operation.authorization.confirmation_id"))
        }
        if confirmation.confirmedBy?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append(ACEPlacementIssue(code: "logic_confirmation_missing", message: "confirmed_by is required before any Logic mutation", path: "$.operation.authorization.authorized_by"))
        }
        guard let confirmedAt = confirmation.confirmedAt else {
            issues.append(ACEPlacementIssue(code: "logic_confirmation_missing", message: "confirmed_at is required before any Logic mutation", path: "$.operation.authorization.authorized_at"))
            return issues
        }
        if confirmedAt > now {
            issues.append(ACEPlacementIssue(code: "logic_confirmation_in_future", message: "confirmation timestamp is ahead of the authority clock", path: "$.operation.authorization.authorized_at"))
        }
        if now.timeIntervalSince(confirmedAt) > ServerConfig.acePlacementConfirmationMaxAge {
            issues.append(ACEPlacementIssue(code: "logic_confirmation_expired", message: "human confirmation has expired; re-authorize the placement", path: "$.operation.authorization.authorized_at"))
        }
        return issues
    }

    // MARK: - Generic parsing helpers

    private static func firstString(_ params: [String: Value], keys: [String]) -> String? {
        for key in keys {
            if let value = params[key]?.stringValue,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstInt(_ params: [String: Value], keys: [String]) -> Int? {
        for key in keys {
            if let value = params[key]?.intValue { return value }
            if let value = params[key]?.doubleValue { return Int(value) }
            if let value = params[key]?.stringValue, let parsed = Int(value) { return parsed }
        }
        return nil
    }

    private static func firstDouble(_ params: [String: Value], keys: [String]) -> Double? {
        for key in keys {
            if let value = params[key]?.doubleValue { return value }
            if let value = params[key]?.intValue { return Double(value) }
            if let value = params[key]?.stringValue, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    private static func boolValue(_ value: Value?) -> Bool? {
        if let bool = value?.boolValue { return bool }
        if let int = value?.intValue { return int != 0 }
        if let string = value?.stringValue {
            switch string.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func filePath(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        if let url = URL(string: value), url.isFileURL { return url.path }
        return value
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func handoffObject(_ params: [String: Value]) -> ([String: Any]?, [ACEPlacementIssue]) {
        if let handoff = params["handoff"]?.objectValue {
            return (handoff.reduce(into: [String: Any]()) { $0[$1.key] = anyValue($1.value) }, [])
        }
        if let json = params["handoff_json"]?.stringValue {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, [ACEPlacementIssue(code: "ace_handoff_invalid", message: "handoff_json must be a JSON object", path: "$.handoff_json")])
            }
            return (object, [])
        }
        return (nil, [])
    }

    private static func anyValue(_ value: Value) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .data(_, let data): return data.base64EncodedString()
        case .array(let values): return values.map(anyValue)
        case .object(let values): return values.reduce(into: [String: Any]()) { $0[$1.key] = anyValue($1.value) }
        }
    }

    private static func object(_ root: [String: Any]?, path: [String]) -> [String: Any]? {
        guard let root else { return nil }
        var current: Any = root
        for key in path {
            guard let next = (current as? [String: Any])?[key] else { return nil }
            current = next
        }
        return current as? [String: Any]
    }

    private static func objectAny(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        return nil
    }

    private static func intAny(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func doubleAny(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func boolAny(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return Bool(value) }
        return nil
    }

    private static func uniqueIssues(_ issues: [ACEPlacementIssue]) -> [ACEPlacementIssue] {
        var seen = Set<String>()
        return issues.filter { issue in
            let key = "\(issue.code)|\(issue.path ?? "")|\(issue.message)"
            return seen.insert(key).inserted
        }
    }
}
