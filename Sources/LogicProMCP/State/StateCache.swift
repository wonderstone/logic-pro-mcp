import Foundation

/// Thread-safe in-memory cache for Logic Pro project state.
/// Read by tools for instant response; written by the StatePoller.
///
/// Project-bound state is normalized at the cache boundary so a selection or
/// resource read cannot silently outlive the project identity/generation that
/// produced it.
actor StateCache {
    private(set) var transport = TransportState()
    private(set) var tracks: [TrackState] = []
    private(set) var channelStrips: [ChannelStripState] = []
    private(set) var regions: [RegionState] = []
    private(set) var selection = SelectionState()
    private(set) var context = ContextState()
    private(set) var lastMIDIBridgeExport = MIDIBridgeExportState()
    private(set) var disposableProjectBinding: DisposableProjectBinding?
    private var acePlacementSessions: [String: ACEAudioPlacementSession] = [:]
    private(set) var lastACEAudioPlacementReceipt: ACEAudioPlacementReceipt?
    private(set) var markers: [MarkerState] = []
    private(set) var project = ProjectInfo()
    private(set) var automationMode = AutomationMode.off

    /// Identity and generation of the latest project snapshot accepted by the cache.
    private(set) var projectIdentity = ProjectIdentity.unknown
    private(set) var generation: UInt64 = 0

    /// Timestamp of last tool call — drives adaptive poll intervals.
    private(set) var lastToolAccess: Date = .distantPast

    // MARK: - Read access (tools call these)

    func getTransport() -> TransportState { transport }
    func getTracks() -> [TrackState] { tracks }
    func getTrack(at index: Int) -> TrackState? {
        guard tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }
    func getSelectedTrack() -> TrackState? {
        tracks.first(where: { $0.isSelected })
    }
    func getChannelStrips() -> [ChannelStripState] { channelStrips }
    func getChannelStrip(at index: Int) -> ChannelStripState? {
        channelStrips.first(where: { $0.trackIndex == index })
    }
    func getRegions() -> [RegionState] { regions }
    func getSelection() -> SelectionState { selection }
    func getContext() -> ContextState { context }
    func getLastMIDIBridgeExport() -> MIDIBridgeExportState { lastMIDIBridgeExport }
    func getDisposableProjectBinding() -> DisposableProjectBinding? { disposableProjectBinding }
    func getACEPlacementSession(planID: String) -> ACEAudioPlacementSession? { acePlacementSessions[planID] }
    func getLastACEAudioPlacementReceipt() -> ACEAudioPlacementReceipt? { lastACEAudioPlacementReceipt }
    func getMarkers() -> [MarkerState] { markers }
    func getProject() -> ProjectInfo { project }
    func getProjectIdentity() -> ProjectIdentity { projectIdentity }
    func getGeneration() -> UInt64 { generation }
    func getAutomationMode() -> AutomationMode { automationMode }

    // MARK: - Write access (poller calls these)

    func updateTransport(_ state: TransportState) {
        transport = state
    }

    func updateTracks(_ newTracks: [TrackState]) {
        tracks = newTracks.map { track in
            var bound = track
            if !bound.projectIdentity.isKnown {
                bound.projectIdentity = projectIdentity
            }
            if bound.generation == 0 {
                bound.generation = generation
            }
            return bound
        }
    }

    func updateTrack(at index: Int, mutator: (inout TrackState) -> Void) {
        guard tracks.indices.contains(index) else { return }
        mutator(&tracks[index])
    }

    func updateChannelStrips(_ strips: [ChannelStripState]) {
        channelStrips = strips
    }

    func updateRegions(_ newRegions: [RegionState]) {
        regions = newRegions.map { region in
            var bound = region
            if !bound.projectIdentity.isKnown {
                bound.projectIdentity = projectIdentity
            }
            if bound.generation == 0 {
                bound.generation = generation
            }
            return bound
        }
    }

    func updateSelection(_ newSelection: SelectionState) {
        var bound = newSelection
        if !bound.projectIdentity.isKnown {
            bound.projectIdentity = projectIdentity
        }
        if bound.generation == 0 {
            bound.generation = generation
        }
        selection = bound
    }

    func updateContext(_ newContext: ContextState) {
        var bound = newContext
        if !bound.projectIdentity.isKnown {
            bound.projectIdentity = projectIdentity
        }
        if bound.generation == 0 {
            bound.generation = generation
        }
        context = bound
    }

    func updateLastMIDIBridgeExport(_ newExport: MIDIBridgeExportState) {
        lastMIDIBridgeExport = newExport
    }

    func updateDisposableProjectBinding(_ binding: DisposableProjectBinding?) {
        disposableProjectBinding = binding
    }

    func updateACEPlacementSession(_ session: ACEAudioPlacementSession) {
        acePlacementSessions[session.plan.planID] = session
    }

    func updateLastACEAudioPlacementReceipt(_ receipt: ACEAudioPlacementReceipt) {
        lastACEAudioPlacementReceipt = receipt
        if var session = acePlacementSessions[receipt.planID] {
            session.lastReceipt = receipt
            acePlacementSessions[receipt.planID] = session
        }
    }

    func updateMarkers(_ newMarkers: [MarkerState]) {
        markers = newMarkers
    }

    func updateProject(_ info: ProjectInfo) {
        let incomingIdentity = info.resolvedProjectIdentity
        let identityChanged = !Self.identitiesEquivalent(projectIdentity, incomingIdentity)

        if generation == 0 {
            generation = 1
        } else if identityChanged {
            generation = generation == UInt64.max ? 1 : generation + 1
            invalidateProjectBoundState()
        }

        projectIdentity = incomingIdentity
        var bound = info
        bound.projectIdentity = incomingIdentity
        bound.generation = generation
        project = bound
    }

    func updateAutomationMode(_ mode: AutomationMode) {
        automationMode = mode
    }

    // MARK: - Cached-state authority

    /// Freshness/count-only readback used by non-destructive manual handoffs.
    func selectionReadback(
        at now: Date = Date(),
        maximumAge: TimeInterval = ServerConfig.selectionAuthorityMaxAge
    ) -> StateAuthorityCheck {
        makeSelectionReadbackCheck(at: now, maximumAge: maximumAge)
    }

    /// Guarded mutation authority. All project, generation, freshness, and
    /// identity checks are required before a cached selection can authorize a
    /// destructive operation.
    func selectionAuthority(
        at now: Date = Date(),
        maximumAge: TimeInterval = ServerConfig.selectionAuthorityMaxAge
    ) -> StateAuthorityCheck {
        var check = makeSelectionReadbackCheck(at: now, maximumAge: maximumAge)
        guard check.authorized else { return check }

        let projectKnown = projectIdentity.isKnown && selection.projectIdentity.isKnown
        let projectMatches = projectKnown && projectIdentity.matches(selection.projectIdentity)
        check.projectIdentityMatches = projectMatches
        guard projectKnown else {
            return rejected(check, reasonCode: "unknown_project_identity", message: "cached project identity is unknown; no mutation started")
        }
        guard projectMatches else {
            return rejected(check, reasonCode: "project_mismatch", message: "cached selection project identity does not match the current project; no mutation started")
        }
        guard projectIdentity.canAuthorizeMutation else {
            return rejected(
                check,
                reasonCode: "unstable_project_identity",
                message: "project identity is visible-only and cannot authorize destructive mutation; no mutation started"
            )
        }

        let generationCompatible = generation > 0 && selection.generation == generation
        check.generationCompatible = generationCompatible
        guard generationCompatible else {
            return rejected(check, reasonCode: "generation_mismatch", message: "cached selection generation does not match the current project generation; no mutation started")
        }

        guard selection.selectedRegionIdentityStability.canAuthorizeMutation else {
            return rejected(
                check,
                reasonCode: "unstable_region_identity",
                message: "visible-only or synthetic region identity cannot authorize destructive mutation; no mutation started"
            )
        }

        return check
    }

    /// Project authority for guarded operations that do not target a selected
    /// region, such as an import into the current project.
    func projectAuthority(
        at now: Date = Date(),
        maximumAge: TimeInterval = ServerConfig.projectAuthorityMaxAge,
        requireStableIdentity: Bool = true
    ) -> StateAuthorityCheck {
        let safeMaximumAge = max(0, maximumAge)
        let age = age(of: project.lastUpdated, at: now, maximumAge: safeMaximumAge)
        let fresh = project.lastUpdated != .distantPast && age >= 0 && age <= safeMaximumAge
        let check = StateAuthorityCheck(
            authority: "project",
            authorized: fresh,
            reasonCode: fresh ? "ok" : "stale_project",
            message: fresh ? "project snapshot is fresh" : "requires a fresh cached project snapshot; no mutation started",
            checkedAt: now,
            observedAgeSeconds: age,
            maximumAgeSeconds: safeMaximumAge,
            projectIdentity: projectIdentity,
            selectionProjectIdentity: selection.projectIdentity,
            generation: generation,
            selectionGeneration: selection.generation,
            projectIdentityMatches: projectIdentity.isKnown,
            generationCompatible: project.generation > 0 && project.generation == generation,
            selectionFresh: fresh,
            selectedRegionCount: selection.selectedRegionCount,
            selectedRegionIDs: selection.selectedRegionIDs,
            selectedRegionIdentityStability: selection.selectedRegionIdentityStability,
            scope: "project"
        )

        guard fresh else { return check }
        guard projectIdentity.isKnown else {
            return rejected(check, reasonCode: "unknown_project_identity", message: "cached project identity is unknown; no mutation started")
        }
        if requireStableIdentity, !projectIdentity.canAuthorizeMutation {
            return rejected(
                check,
                reasonCode: "unstable_project_identity",
                message: "project identity is visible-only and cannot authorize a guarded mutation; no mutation started"
            )
        }
        guard project.generation > 0, project.generation == generation else {
            return rejected(check, reasonCode: "generation_mismatch", message: "cached project generation is not compatible with the current cache generation; no mutation started")
        }
        return check
    }

    func authoritySnapshot(at now: Date = Date()) -> CacheAuthoritySnapshot {
        let selectionAge = age(
            of: selection.lastUpdated,
            at: now,
            maximumAge: ServerConfig.selectionAuthorityMaxAge
        )
        let projectAge = age(
            of: project.lastUpdated,
            at: now,
            maximumAge: ServerConfig.projectAuthorityMaxAge
        )
        return CacheAuthoritySnapshot(
            checkedAt: now,
            projectIdentity: projectIdentity,
            generation: generation,
            selectionProjectIdentity: selection.projectIdentity,
            selectionGeneration: selection.generation,
            selectionUpdatedAt: selection.lastUpdated,
            selectionAgeSeconds: selectionAge,
            selectionMaximumAgeSeconds: ServerConfig.selectionAuthorityMaxAge,
            selectionAuthorized: selectionAuthority(at: now).authorized,
            selectionIdentityStability: selection.selectedRegionIdentityStability,
            projectUpdatedAt: project.lastUpdated,
            projectAgeSeconds: projectAge
        )
    }

    // MARK: - Tool access tracking

    func recordToolAccess() {
        lastToolAccess = Date()
    }

    func timeSinceLastToolAccess() -> TimeInterval {
        Date().timeIntervalSince(lastToolAccess)
    }

    // MARK: - Bulk state for diagnostics

    struct CacheSnapshot: Sendable {
        let transportAge: TimeInterval
        let trackCount: Int
        let regionCount: Int
        let markerCount: Int
        let projectName: String
        let projectIdentity: ProjectIdentity
        let generation: UInt64
        let selectionGeneration: UInt64
        let selectionAge: TimeInterval
        let selectionMaximumAge: TimeInterval
        let selectionAuthority: Bool
        let selectionIdentityStability: StateIdentityStability
        let pollMode: String
    }

    func snapshot() -> CacheSnapshot {
        snapshot(at: Date())
    }

    func snapshot(at now: Date) -> CacheSnapshot {
        let idle = timeSinceLastToolAccess()
        let mode: String
        if idle < ServerConfig.lightIdleThreshold {
            mode = "active"
        } else if idle < ServerConfig.idleThreshold {
            mode = "light"
        } else {
            mode = "idle"
        }
        let authority = authoritySnapshot(at: now)
        return CacheSnapshot(
            transportAge: now.timeIntervalSince(transport.lastUpdated),
            trackCount: tracks.count,
            regionCount: regions.count,
            markerCount: markers.count,
            projectName: project.name,
            projectIdentity: projectIdentity,
            generation: generation,
            selectionGeneration: selection.generation,
            selectionAge: authority.selectionAgeSeconds,
            selectionMaximumAge: authority.selectionMaximumAgeSeconds,
            selectionAuthority: authority.selectionAuthorized,
            selectionIdentityStability: selection.selectedRegionIdentityStability,
            pollMode: mode
        )
    }

    // MARK: - Private authority helpers

    private func makeSelectionReadbackCheck(
        at now: Date,
        maximumAge: TimeInterval
    ) -> StateAuthorityCheck {
        let safeMaximumAge = max(0, maximumAge)
        let age = age(of: selection.lastUpdated, at: now, maximumAge: safeMaximumAge)
        let fresh = selection.lastUpdated != .distantPast && age >= 0 && age <= safeMaximumAge
        let check = StateAuthorityCheck(
            authority: "selection",
            authorized: fresh,
            reasonCode: fresh ? "ok" : "stale_selection",
            message: fresh ? "selection readback is fresh" : "requires a fresh selected region readback; no mutation started",
            checkedAt: now,
            observedAgeSeconds: age,
            maximumAgeSeconds: safeMaximumAge,
            projectIdentity: projectIdentity,
            selectionProjectIdentity: selection.projectIdentity,
            generation: generation,
            selectionGeneration: selection.generation,
            projectIdentityMatches: false,
            generationCompatible: false,
            selectionFresh: fresh,
            selectedRegionCount: selection.selectedRegionCount,
            selectedRegionIDs: selection.selectedRegionIDs,
            selectedRegionIdentityStability: selection.selectedRegionIdentityStability,
            scope: selection.scope
        )

        guard fresh else {
            if selection.lastUpdated == .distantPast {
                return rejected(check, reasonCode: "unknown_selection", message: "requires a fresh selected region readback; no mutation started")
            }
            if age < 0 {
                return rejected(check, reasonCode: "future_selection", message: "selection timestamp is ahead of the authority clock; no mutation started")
            }
            return rejected(check, reasonCode: "stale_selection", message: "selected-region cache is stale (age \(formatSeconds(age))s exceeds maximum \(formatSeconds(safeMaximumAge))s); no mutation started")
        }
        guard selection.selectedRegionCount == 1,
              selection.selectedRegionIDs.count == 1,
              let regionID = selection.selectedRegionIDs.first,
              !regionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rejected(check, reasonCode: "selection_cardinality", message: "requires exactly one selected region; no mutation started")
        }
        return check
    }

    private func rejected(
        _ check: StateAuthorityCheck,
        reasonCode: String,
        message: String
    ) -> StateAuthorityCheck {
        var rejected = check
        rejected.authorized = false
        rejected.reasonCode = reasonCode
        rejected.message = message
        return rejected
    }

    private func invalidateProjectBoundState() {
        tracks = []
        channelStrips = []
        regions = []
        selection = SelectionState()
        context = ContextState()
    }

    private func age(of timestamp: Date, at now: Date, maximumAge: TimeInterval) -> TimeInterval {
        guard timestamp != .distantPast else { return maximumAge + 1 }
        return now.timeIntervalSince(timestamp)
    }

    private func formatSeconds(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }

    private static func identitiesEquivalent(_ lhs: ProjectIdentity, _ rhs: ProjectIdentity) -> Bool {
        if !lhs.isKnown && !rhs.isKnown { return true }
        return lhs.matches(rhs)
    }
}
