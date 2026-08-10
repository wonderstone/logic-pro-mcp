import Foundation

enum ACEAudioDeltaAdoptionContract {
    static let schemaVersion = "logic_ace_audio_delta_adoption_receipt/v1"
    static let defaultGeometryTolerancePixels = 8.0
    static let defaultDurationToleranceBeats = 1.0
}

struct ACEAudioDeltaAdoptionSpec: Codable, Equatable, Sendable {
    var planID: String
    var operationID: String
    var targetProjectPath: String
    var startingProjectSHA256: String
    var baselineProjectSHA256: String
    var beforeTrackCount: Int
    var beforeRegionCount: Int
    var currentTrackCount: Int
    var currentRegionCount: Int
    var newTrackName: String
    var sourceBaseName: String
    var duplicateRegionName: String
    var preservedTrackNames: [String]
    var preservedRegionNames: [String]
    var source: ACEAudioSource
    var trackTag: String
    var regionTag: String
    var placement: ACEPlacementCoordinates

    enum CodingKeys: String, CodingKey {
        case planID = "plan_id"
        case operationID = "operation_id"
        case targetProjectPath = "target_project_path"
        case startingProjectSHA256 = "starting_project_sha256"
        case baselineProjectSHA256 = "baseline_project_sha256"
        case beforeTrackCount = "before_track_count"
        case beforeRegionCount = "before_region_count"
        case currentTrackCount = "current_track_count"
        case currentRegionCount = "current_region_count"
        case newTrackName = "new_track_name"
        case sourceBaseName = "source_base_name"
        case duplicateRegionName = "duplicate_region_name"
        case preservedTrackNames = "preserved_track_names"
        case preservedRegionNames = "preserved_region_names"
        case source
        case trackTag = "track_tag"
        case regionTag = "region_tag"
        case placement
    }
}

struct ACEAXRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var minX: Double { x }
    var maxX: Double { x + width }
    var midX: Double { x + width / 2.0 }
}

struct ACEAudioDeltaGeometry: Codable, Equatable, Sendable {
    var status: String
    var verified: Bool
    var reasonCode: String
    var requestedBar: Int
    var requestedBeat: Double
    var requestedTick: Int
    var observedBar: Double?
    var observedBeat: Double?
    var timeRuler: ACEAXRect?
    var barOnePlayhead: ACEAXRect?
    var barTwoPlayhead: ACEAXRect?
    var targetRegion: ACEAXRect?
    var pixelsPerBeat: Double?
    var estimatedDurationBeats: Double?
    var startAlignmentPixels: Double?
    var geometryTolerancePixels: Double
    var durationToleranceBeats: Double
    var basis: String?
    var observedAt: Date

    enum CodingKeys: String, CodingKey {
        case status
        case verified
        case reasonCode = "reason_code"
        case requestedBar = "requested_bar"
        case requestedBeat = "requested_beat"
        case requestedTick = "requested_tick"
        case observedBar = "observed_bar"
        case observedBeat = "observed_beat"
        case timeRuler = "time_ruler"
        case barOnePlayhead = "bar_one_playhead"
        case barTwoPlayhead = "bar_two_playhead"
        case targetRegion = "target_region"
        case pixelsPerBeat = "pixels_per_beat"
        case estimatedDurationBeats = "estimated_duration_beats"
        case startAlignmentPixels = "start_alignment_pixels"
        case geometryTolerancePixels = "geometry_tolerance_pixels"
        case durationToleranceBeats = "duration_tolerance_beats"
        case basis
        case observedAt = "observed_at"
    }

    static func unavailable(
        requestedBar: Int,
        requestedBeat: Double,
        requestedTick: Int,
        reasonCode: String,
        observedAt: Date = Date()
    ) -> ACEAudioDeltaGeometry {
        ACEAudioDeltaGeometry(
            status: "not_verified",
            verified: false,
            reasonCode: reasonCode,
            requestedBar: requestedBar,
            requestedBeat: requestedBeat,
            requestedTick: requestedTick,
            observedBar: nil,
            observedBeat: nil,
            timeRuler: nil,
            barOnePlayhead: nil,
            barTwoPlayhead: nil,
            targetRegion: nil,
            pixelsPerBeat: nil,
            estimatedDurationBeats: nil,
            startAlignmentPixels: nil,
            geometryTolerancePixels: ACEAudioDeltaAdoptionContract.defaultGeometryTolerancePixels,
            durationToleranceBeats: ACEAudioDeltaAdoptionContract.defaultDurationToleranceBeats,
            basis: nil,
            observedAt: observedAt
        )
    }
}

struct ACEAudioDeltaRollbackEvidence: Codable, Equatable, Sendable {
    var status: String
    var mutation: String
    var verification: String
    var reasonCode: String
    var trackTag: String
    var regionTag: String
    var sourceSHA256: String
    var instructions: [String]

    static func manual(spec: ACEAudioDeltaAdoptionSpec, projectPath: String) -> ACEAudioDeltaRollbackEvidence {
        ACEAudioDeltaRollbackEvidence(
            status: "manual_required",
            mutation: "not_started",
            verification: "unavailable",
            reasonCode: "logic_rollback_requires_human_exact_tag_selection",
            trackTag: spec.trackTag,
            regionTag: spec.regionTag,
            sourceSHA256: spec.source.sha256,
            instructions: [
                "Keep the original project and keeper unchanged; operate only on \(projectPath).",
                "In Logic, locate the one track whose name contains the exact operation tag \(spec.trackTag).",
                "On that track, locate the one region whose name contains \(spec.regionTag) and the exact source SHA-256 \(spec.source.sha256).",
                "Human-confirm that both tags are unique, select that exact region, delete only it, then delete the track only if it is empty.",
                "Save the disposable and verify the tagged track/region are absent while all preserved names and counts match the pre-adoption evidence."
            ]
        )
    }
}

struct ACEAudioDeltaAdoptionReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = ACEAudioDeltaAdoptionContract.schemaVersion

    var schemaVersion: String
    var receiptVersion: Int
    var receiptID: String
    var planID: String
    var operationID: String
    var phase: String
    var status: String
    var success: Bool
    var issuedAt: Date
    var spec: ACEAudioDeltaAdoptionSpec?
    var before: ACEPlacementSnapshot?
    var after: ACEPlacementSnapshot?
    var removedDuplicateRegion: String?
    var trackID: String?
    var regionID: String?
    var sourceSHA256: String?
    var geometry: ACEAudioDeltaGeometry?
    var saveDispatch: ACEPlacementDispatchReceipt
    var finalProjectSHA256: String?
    var rollback: ACEAudioDeltaRollbackEvidence?
    var validationIssues: [ACEPlacementIssue]
    var error: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case receiptVersion = "receipt_version"
        case receiptID = "receipt_id"
        case planID = "plan_id"
        case operationID = "operation_id"
        case phase
        case status
        case success
        case issuedAt = "issued_at"
        case spec
        case before
        case after
        case removedDuplicateRegion = "removed_duplicate_region"
        case trackID = "track_id"
        case regionID = "region_id"
        case sourceSHA256 = "source_sha256"
        case geometry
        case saveDispatch = "save_dispatch"
        case finalProjectSHA256 = "final_project_sha256"
        case rollback
        case validationIssues = "validation_issues"
        case error
    }

    init(
        receiptID: String,
        planID: String,
        operationID: String,
        phase: String,
        status: String,
        success: Bool,
        issuedAt: Date = Date(),
        spec: ACEAudioDeltaAdoptionSpec? = nil,
        before: ACEPlacementSnapshot? = nil,
        after: ACEPlacementSnapshot? = nil,
        removedDuplicateRegion: String? = nil,
        trackID: String? = nil,
        regionID: String? = nil,
        sourceSHA256: String? = nil,
        geometry: ACEAudioDeltaGeometry? = nil,
        saveDispatch: ACEPlacementDispatchReceipt = ACEPlacementDispatchReceipt(status: "not_dispatched", method: nil, receiptID: nil, dispatchedAt: nil, sourceSHA256: nil, message: nil),
        finalProjectSHA256: String? = nil,
        rollback: ACEAudioDeltaRollbackEvidence? = nil,
        validationIssues: [ACEPlacementIssue] = [],
        error: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.receiptVersion = 1
        self.receiptID = receiptID
        self.planID = planID
        self.operationID = operationID
        self.phase = phase
        self.status = status
        self.success = success
        self.issuedAt = issuedAt
        self.spec = spec
        self.before = before
        self.after = after
        self.removedDuplicateRegion = removedDuplicateRegion
        self.trackID = trackID
        self.regionID = regionID
        self.sourceSHA256 = sourceSHA256
        self.geometry = geometry
        self.saveDispatch = saveDispatch
        self.finalProjectSHA256 = finalProjectSHA256
        self.rollback = rollback
        self.validationIssues = validationIssues
        self.error = error
    }
}

enum ACEAudioDeltaAdoptionValidator {
    static func validateSpec(_ spec: ACEAudioDeltaAdoptionSpec) -> [ACEPlacementIssue] {
        var issues: [ACEPlacementIssue] = []
        if spec.planID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_adoption_plan_id_missing", message: "adoption plan_id is required", path: "$.adoption.plan_id"))
        }
        if spec.operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_adoption_operation_id_missing", message: "adoption operation_id is required", path: "$.adoption.operation_id"))
        }
        if spec.targetProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_adoption_project_path_missing", message: "target project path is required", path: "$.adoption.target_project_path"))
        }
        if !ACEFileDigest.isSHA256(spec.startingProjectSHA256) || !ACEFileDigest.isSHA256(spec.baselineProjectSHA256) {
            issues.append(ACEPlacementIssue(code: "logic_adoption_project_digest_invalid", message: "starting and baseline project digests must be lowercase SHA-256 values", path: "$.adoption.project_sha256"))
        }
        if spec.beforeTrackCount < 0 || spec.beforeRegionCount < 0
            || spec.currentTrackCount != spec.beforeTrackCount + 1
            || (spec.currentRegionCount != spec.beforeRegionCount + 1
                && spec.currentRegionCount != spec.beforeRegionCount + 2) {
            issues.append(ACEPlacementIssue(code: "logic_adoption_delta_shape_invalid", message: "adoption requires the exact one-track delta with one or two known source regions", path: "$.adoption.delta"))
        }
        if spec.newTrackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || spec.sourceBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || spec.duplicateRegionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_adoption_source_names_missing", message: "new track, source base, and uniquely named duplicate are required", path: "$.adoption.source_names"))
        }
        if spec.duplicateRegionName != "\(spec.sourceBaseName)_1" {
            issues.append(ACEPlacementIssue(code: "logic_adoption_duplicate_name_not_exact", message: "only the exact source base-name suffix _1 may be removed", path: "$.adoption.duplicate_region_name"))
        }
        if spec.preservedTrackNames.isEmpty || spec.preservedRegionNames.isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_adoption_preservation_names_missing", message: "preserved track and region names are required for exact-delta admission", path: "$.adoption.preserved_names"))
        }
        if spec.preservedTrackNames.count != spec.beforeTrackCount
            || spec.preservedRegionNames.count != spec.beforeRegionCount {
            issues.append(ACEPlacementIssue(code: "logic_adoption_preservation_counts_invalid", message: "preserved names must account for every pre-existing track and region", path: "$.adoption.preserved_names"))
        }
        if OperationTagIdentity.operationTag(in: spec.trackTag) != spec.trackTag
            || OperationTagIdentity.operationTag(in: spec.regionTag) != spec.regionTag {
            issues.append(ACEPlacementIssue(code: "logic_adoption_operation_tags_invalid", message: "track_tag and region_tag must be explicit ACE operation tags", path: "$.adoption.tags"))
        }
        let placement = spec.placement
        if placement.bar != 1
            || placement.beat != 1.0
            || placement.tick != 0
            || placement.beatsPerBar != ACEAudioPlacementContract.defaultBeatsPerBar
            || !placement.durationBeats.isFinite
            || placement.durationBeats <= 0 {
            issues.append(ACEPlacementIssue(code: "logic_adoption_placement_invalid", message: "P5G adoption requires finite bar 1 beat 1 tick 0 placement, four beats per bar, and a positive duration", path: "$.adoption.placement"))
        }
        issues += ACEAudioPlacementValidator.validateSource(spec.source)
        if ACEFileDigest.normalizedPath(spec.targetProjectPath).isEmpty {
            issues.append(ACEPlacementIssue(code: "logic_adoption_project_path_invalid", message: "target project path is invalid", path: "$.adoption.target_project_path"))
        }
        return unique(issues)
    }

    static func validateStartingDelta(
        _ snapshot: ACEPlacementSnapshot,
        spec: ACEAudioDeltaAdoptionSpec
    ) -> [ACEPlacementIssue] {
        var issues = validateSpecWithoutSourceRead(spec)
        guard issues.isEmpty else { return issues }

        if snapshot.projectPath != ACEFileDigest.normalizedPath(spec.targetProjectPath)
            || snapshot.projectSHA256 != spec.startingProjectSHA256 {
            issues.append(ACEPlacementIssue(code: "logic_adoption_starting_project_mismatch", message: "live disposable path/digest is not the exact P5G starting state; no adoption mutation started", path: "$.before.project"))
        }
        if snapshot.tracks.count != spec.currentTrackCount || snapshot.regions.count != spec.currentRegionCount {
            issues.append(ACEPlacementIssue(code: "logic_adoption_delta_count_mismatch", message: "live track/region counts do not match the exact one-track/two-region delta; no adoption mutation started", path: "$.before.counts"))
        }

        let createdTracks = snapshot.tracks.filter { $0.name == spec.newTrackName }
        let createdRegions = snapshot.regions.filter { $0.trackName == spec.newTrackName }
        guard createdTracks.count == 1,
              createdRegions.filter({ $0.name == spec.sourceBaseName }).count == 1,
              createdRegions.filter({ $0.name == spec.duplicateRegionName }).count == 1,
              createdRegions.count == 2 else {
            issues.append(ACEPlacementIssue(code: "logic_adoption_created_layer_ambiguous", message: "the exact new layer must contain one source base region and one uniquely named _1 duplicate", path: "$.before.created_layer"))
            return unique(issues)
        }

        let preservedTracks = snapshot.tracks.filter { $0.name != spec.newTrackName }.map(\.name)
        let preservedRegions = snapshot.regions.filter { $0.trackName != spec.newTrackName }.map(\.name)
        if multiset(preservedTracks) != multiset(spec.preservedTrackNames) {
            issues.append(ACEPlacementIssue(code: "logic_adoption_preexisting_tracks_changed", message: "pre-existing track names do not exactly match the P5F before evidence", path: "$.before.tracks"))
        }
        if multiset(preservedRegions) != multiset(spec.preservedRegionNames) {
            issues.append(ACEPlacementIssue(code: "logic_adoption_preexisting_regions_changed", message: "pre-existing region names do not exactly match the P5F before evidence", path: "$.before.regions"))
        }
        if snapshot.tracks.filter({ OperationTagIdentity.operationTag(in: $0.name) != nil && $0.name != spec.newTrackName }).isEmpty == false
            || snapshot.regions.filter({ OperationTagIdentity.operationTag(in: $0.name) != nil && $0.trackName != spec.newTrackName }).isEmpty == false {
            issues.append(ACEPlacementIssue(code: "logic_adoption_preexisting_tagged_object", message: "pre-existing tagged objects cannot be adopted by visible delta; no mutation started", path: "$.before.identity"))
        }
        return unique(issues)
    }

    static func validateAfterCleanup(
        _ snapshot: ACEPlacementSnapshot,
        spec: ACEAudioDeltaAdoptionSpec
    ) -> [ACEPlacementIssue] {
        var issues: [ACEPlacementIssue] = []
        let expectedCleanedRegionCount = spec.beforeRegionCount + 1
        if snapshot.projectPath != ACEFileDigest.normalizedPath(spec.targetProjectPath)
            || snapshot.tracks.count != spec.currentTrackCount
            || snapshot.regions.count != expectedCleanedRegionCount {
            issues.append(ACEPlacementIssue(code: "logic_adoption_cleanup_postcondition_mismatch", message: "duplicate cleanup did not leave exactly one new track and one source region", path: "$.cleanup.after"))
        }
        let createdTracks = snapshot.tracks.filter {
            $0.name == spec.newTrackName
                || OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag
        }
        let createdTrackNames = Set(createdTracks.map(\.name))
        let createdRegions = snapshot.regions.filter { createdTrackNames.contains($0.trackName) }
        let exactSourceRegion = createdRegions.count == 1
            && (createdRegions.first?.name == spec.sourceBaseName
                || OperationTagIdentity.operationTag(in: createdRegions.first?.name ?? "") == spec.regionTag)
        if createdTracks.count != 1 || !exactSourceRegion {
            issues.append(ACEPlacementIssue(code: "logic_adoption_cleanup_target_mismatch", message: "cleanup did not leave the exact source base region on the exact new track", path: "$.cleanup.after.created_layer"))
        }
        if snapshot.regions.contains(where: { $0.name == spec.duplicateRegionName }) {
            issues.append(ACEPlacementIssue(code: "logic_adoption_duplicate_remains", message: "the uniquely named _1 duplicate remains after bounded cleanup", path: "$.cleanup.after.duplicate"))
        }
        let preservedTracks = snapshot.tracks.filter { !createdTrackNames.contains($0.name) }.map(\.name)
        let preservedRegions = snapshot.regions.filter { !createdTrackNames.contains($0.trackName) }.map(\.name)
        if multiset(preservedTracks) != multiset(spec.preservedTrackNames) {
            issues.append(ACEPlacementIssue(code: "logic_adoption_preexisting_tracks_changed", message: "pre-existing track names changed during duplicate cleanup", path: "$.cleanup.after.tracks"))
        }
        if multiset(preservedRegions) != multiset(spec.preservedRegionNames) {
            issues.append(ACEPlacementIssue(code: "logic_adoption_preexisting_regions_changed", message: "pre-existing region names changed during duplicate cleanup", path: "$.cleanup.after.regions"))
        }
        return unique(issues)
    }

    static func validateTagged(
        _ snapshot: ACEPlacementSnapshot,
        spec: ACEAudioDeltaAdoptionSpec
    ) -> [ACEPlacementIssue] {
        var issues = validateAfterTaggedShape(snapshot, spec: spec)
        guard let track = snapshot.tracks.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag }),
              let region = snapshot.regions.first(where: { OperationTagIdentity.operationTag(in: $0.name) == spec.regionTag }) else {
            issues.append(ACEPlacementIssue(code: "logic_adoption_tag_readback_missing", message: "unique operation-tag track and region readback is unavailable", path: "$.after.identity"))
            return unique(issues)
        }
        let preservedTracks = snapshot.tracks.filter { $0.name != track.name }.map(\.name)
        let preservedRegions = snapshot.regions.filter { $0.trackName != track.name }.map(\.name)
        if multiset(preservedTracks) != multiset(spec.preservedTrackNames) {
            issues.append(ACEPlacementIssue(code: "logic_adoption_preexisting_tracks_changed", message: "pre-existing track names changed before fresh-process verification", path: "$.after.tracks"))
        }
        if multiset(preservedRegions) != multiset(spec.preservedRegionNames) {
            issues.append(ACEPlacementIssue(code: "logic_adoption_preexisting_regions_changed", message: "pre-existing region names changed before fresh-process verification", path: "$.after.regions"))
        }
        let expectedTrackID = OperationTagIdentity.trackID(projectIdentity: track.projectIdentity, operationTag: spec.trackTag)
        let expectedRegionID = OperationTagIdentity.regionID(projectIdentity: region.projectIdentity, trackOperationTag: spec.trackTag, regionOperationTag: spec.regionTag)
        if track.identityStability != .stable || track.identityScope != "project_bound" || track.stableID != expectedTrackID {
            issues.append(ACEPlacementIssue(code: "logic_adoption_track_identity_unstable", message: "tagged track did not receive a deterministic project-bound identity", path: "$.after.tracks"))
        }
        if region.identityStability != .stable || region.identityScope != "project_bound" || region.stableID != expectedRegionID || region.trackStableID != expectedTrackID {
            issues.append(ACEPlacementIssue(code: "logic_adoption_region_identity_unstable", message: "tagged region did not receive a deterministic project-bound identity", path: "$.after.regions"))
        }
        if !region.name.contains(spec.sourceBaseName) || !region.name.contains(spec.source.sha256) || region.trackName != track.name {
            issues.append(ACEPlacementIssue(code: "logic_adoption_source_readback_mismatch", message: "tagged region does not preserve exact source-base and source-digest evidence", path: "$.after.source"))
        }
        return unique(issues)
    }

    static func validateGeometry(
        _ geometry: ACEAudioDeltaGeometry,
        placement: ACEPlacementCoordinates,
        allowNativeDurationMismatch: Bool = false
    ) -> [ACEPlacementIssue] {
        var issues: [ACEPlacementIssue] = []
        guard geometry.verified else {
            issues.append(ACEPlacementIssue(code: geometry.reasonCode, message: "independent AX timeline/playhead geometry did not verify exact placement", path: "$.geometry"))
            return issues
        }
        if geometry.observedBar != Double(placement.bar) || geometry.observedBeat != placement.beat {
            issues.append(ACEPlacementIssue(code: "logic_adoption_geometry_position_mismatch", message: "AX playhead position did not read back the requested bar/beat", path: "$.geometry.observed"))
        }
        if let alignment = geometry.startAlignmentPixels,
           abs(alignment) <= geometry.geometryTolerancePixels {
            // The independent region/playhead alignment is within tolerance.
        } else {
            issues.append(ACEPlacementIssue(code: "logic_adoption_geometry_start_mismatch", message: "tagged region start does not align with the bar-1 playhead within the measured tolerance", path: "$.geometry.start_alignment_pixels"))
        }
        if let duration = geometry.estimatedDurationBeats,
           abs(duration - placement.durationBeats) <= geometry.durationToleranceBeats
            || (allowNativeDurationMismatch && duration.isFinite && duration > 0) {
            // The independently measured width supports the declared duration.
        } else {
            issues.append(ACEPlacementIssue(code: "logic_adoption_geometry_duration_mismatch", message: "region width does not support the declared duration in beats", path: "$.geometry.estimated_duration_beats"))
        }
        return issues
    }

    private static func validateSpecWithoutSourceRead(_ spec: ACEAudioDeltaAdoptionSpec) -> [ACEPlacementIssue] {
        validateSpec(spec).filter { issue in
            !issue.code.hasPrefix("ace_asset_")
        }
    }

    private static func validateAfterTaggedShape(
        _ snapshot: ACEPlacementSnapshot,
        spec: ACEAudioDeltaAdoptionSpec
    ) -> [ACEPlacementIssue] {
        var issues: [ACEPlacementIssue] = []
        let expectedCleanedRegionCount = spec.beforeRegionCount + 1
        if snapshot.tracks.count != spec.currentTrackCount || snapshot.regions.count != expectedCleanedRegionCount {
            issues.append(ACEPlacementIssue(code: "logic_adoption_tagged_shape_mismatch", message: "tagged adoption readback does not have the exact cleaned track/region counts", path: "$.after.counts"))
        }
        if snapshot.tracks.filter({ OperationTagIdentity.operationTag(in: $0.name) == spec.trackTag }).count != 1 {
            issues.append(ACEPlacementIssue(code: "logic_adoption_track_tag_not_unique", message: "track operation tag is not unique", path: "$.after.tracks"))
        }
        if snapshot.regions.filter({ OperationTagIdentity.operationTag(in: $0.name) == spec.regionTag }).count != 1 {
            issues.append(ACEPlacementIssue(code: "logic_adoption_region_tag_not_unique", message: "region operation tag is not unique", path: "$.after.regions"))
        }
        return unique(issues)
    }

    private static func multiset(_ values: [String]) -> [String: Int] {
        values.reduce(into: [String: Int]()) { counts, value in
            counts[value, default: 0] += 1
        }
    }

    private static func unique(_ issues: [ACEPlacementIssue]) -> [ACEPlacementIssue] {
        var seen = Set<String>()
        return issues.filter { issue in
            seen.insert("\(issue.code)|\(issue.path ?? "")|\(issue.message)").inserted
        }
    }
}

/// Pure precondition contract for the one destructive AX action allowed by
/// P5H. Keeping this separate from AXUIElement calls makes the fail-closed
/// boundary testable without Logic Pro running.
enum ACEExactAXActionContract {
    static func validateDeletePrecondition(
        observedProjectPath: String?,
        expectedProjectPath: String,
        selectedRegionName: String?,
        expectedRegionName: String,
        selectedRegionCount: Int,
        menuTitle: String?,
        menuRole: String?,
        menuActions: [String]
    ) -> [ACEPlacementIssue] {
        var issues: [ACEPlacementIssue] = []
        let expectedPath = ACEFileDigest.normalizedPath(expectedProjectPath)
        if observedProjectPath.map(ACEFileDigest.normalizedPath) != expectedPath {
            issues.append(ACEPlacementIssue(
                code: "logic_adoption_exact_action_document_mismatch",
                message: "the exact delete action requires the bound disposable document to remain frontmost",
                path: "$.exact_action.document"
            ))
        }
        if selectedRegionCount != 1 || selectedRegionName != expectedRegionName {
            issues.append(ACEPlacementIssue(
                code: "logic_adoption_exact_action_selection_mismatch",
                message: "the exact delete action requires one selected AX region with the exact verified _1 name",
                path: "$.exact_action.selection"
            ))
        }
        if menuTitle != "Delete"
            || menuRole != "AXMenuItem"
            || !menuActions.contains("AXPress") {
            issues.append(ACEPlacementIssue(
                code: "logic_adoption_exact_action_menu_mismatch",
                message: "the exact delete action requires the enabled Delete AXMenuItem with AXPress",
                path: "$.exact_action.menu"
            ))
        }
        return issues
    }
}
