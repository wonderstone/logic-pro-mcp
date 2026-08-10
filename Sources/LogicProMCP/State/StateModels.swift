import Foundation

/// Describes how stable an identity is for the current state surface.
///
/// Accessibility readback currently exposes visible order and synthetic IDs for
/// tracks and regions. Those values are useful for display and follow-up reads,
/// but they are not safe destructive-mutation keys.
enum StateIdentityStability: String, Sendable, Codable, Equatable {
    case stable
    case visibleOnly = "visible_only"
    case synthetic
    case unknown

    var canAuthorizeMutation: Bool {
        self == .stable
    }
}

/// Project identity carried alongside cached state.
struct ProjectIdentity: Sendable, Codable, Equatable {
    var value: String?
    var digest: String?
    var stability: StateIdentityStability
    var source: String
    var note: String

    static let unknown = ProjectIdentity(
        value: nil,
        digest: nil,
        stability: .unknown,
        source: "unavailable",
        note: "Project identity was not established by a stable source."
    )

    static func stable(
        path: String,
        source: String = "project_file_path",
        digest: String? = nil
    ) -> ProjectIdentity {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedDigest = digest?.lowercased()
        let note: String
        if let normalizedDigest {
            note = "Project file path and directory SHA-256 are the stable project identity (\(normalizedDigest))."
        } else {
            note = "Project file path is the stable project identity."
        }
        return ProjectIdentity(
            value: normalized,
            digest: normalizedDigest,
            stability: .stable,
            source: source,
            note: note
        )
    }

    static func visibleOnly(name: String, source: String = "accessibility_window_title") -> ProjectIdentity {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .unknown }
        return ProjectIdentity(
            value: normalized,
            digest: nil,
            stability: .visibleOnly,
            source: source,
            note: "Window-title identity is visible-only and is not a stable mutation key."
        )
    }

    var isKnown: Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && stability != .unknown
    }

    var canAuthorizeMutation: Bool {
        isKnown && stability == .stable
    }

    func matches(_ other: ProjectIdentity) -> Bool {
        guard isKnown, other.isKnown else { return false }
        return value == other.value && digest == other.digest && stability == other.stability
    }
}

/// Transport state from Logic Pro.
struct TransportState: Sendable, Codable {
    var isPlaying: Bool = false
    var isRecording: Bool = false
    var isPaused: Bool = false
    var isCycleEnabled: Bool = false
    var isMetronomeEnabled: Bool = false
    var tempo: Double = 120.0
    var position: String = "1.1.1.1"  // Bar.Beat.Division.Tick
    var timePosition: String = "00:00:00.000"
    var sampleRate: Int = 44100
    var lastUpdated: Date = .distantPast
}

/// Track types in Logic Pro.
enum TrackType: String, Sendable, Codable {
    case audio
    case softwareInstrument = "software_instrument"
    case drummer
    case externalMIDI = "external_midi"
    case aux
    case bus
    case master
    case unknown
}

/// A single track's state.
struct TrackState: Sendable, Codable, Identifiable, Equatable {
    let id: Int          // 0-based index
    var name: String
    var type: TrackType
    var isMuted: Bool = false
    var isSoloed: Bool = false
    var isArmed: Bool = false
    var isSelected: Bool = false
    var volume: Double = 0.0   // Raw track-header slider value (not normalized dB)
    var pan: Double = 0.0      // Pan readout when exposed by AX; center is 0
    var color: String?
    var projectIdentity: ProjectIdentity = .unknown
    var generation: UInt64 = 0
    var identityStability: StateIdentityStability = .synthetic
    var identityScope: String = "visible_only"
    var identityNote: String = "Track IDs are visible-order indices and are not stable mutation keys."
    /// Present only when an explicit operation tag was observed under a
    /// stable project identity. Visible-order `id` remains display-only.
    var stableID: String?
}

/// Mixer channel strip state (extends track with routing info).
struct ChannelStripState: Sendable, Codable {
    var trackIndex: Int
    var volume: Double = 0.0
    var pan: Double = 0.0
    var sends: [SendState] = []
    var input: String?
    var output: String?
    var eqEnabled: Bool = false
    var plugins: [PluginSlotState] = []
}

/// A send on a channel strip.
struct SendState: Sendable, Codable {
    var index: Int
    var destination: String
    var level: Double
    var isPreFader: Bool
}

/// A plugin slot.
struct PluginSlotState: Sendable, Codable {
    var index: Int
    var name: String
    var isBypassed: Bool
}

/// Region info.
struct RegionState: Sendable, Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var trackIndex: Int
    var trackName: String
    var startPosition: String   // Bar.Beat
    var endPosition: String
    var length: String
    var isSelected: Bool = false
    var isLooped: Bool = false
    var projectIdentity: ProjectIdentity = .unknown
    var generation: UInt64 = 0
    var identityStability: StateIdentityStability = .synthetic
    var identityScope: String = "visible_only"
    var identityNote: String = "Region IDs are derived from visible track order and are not stable mutation keys."
    /// Stable project-bound identity for an explicitly operation-tagged region.
    var stableID: String?
    /// Stable project-bound identity of the tagged parent track, when present.
    var trackStableID: String?
}

/// Current visible selection summary.
struct SelectionState: Sendable, Codable {
    var selectedTrackIndex: Int?
    var selectedTrackName: String?
    var selectedRegionIDs: [String] = []
    var selectedRegionNames: [String] = []
    var selectedRegionCount: Int = 0
    var scope: String = "visible_only"
    var lastUpdated: Date = .distantPast
    var projectIdentity: ProjectIdentity = .unknown
    var generation: UInt64 = 0
    var selectedRegionIdentityStability: StateIdentityStability = .unknown
    var identityScope: String = "visible_only"
    var identityNote: String = "Visible-only selection and synthetic region IDs cannot silently authorize destructive mutation."
}

/// Current Logic Pro window/view context.
struct ContextState: Sendable, Codable {
    var projectName: String = ""
    var windowTitle: String = ""
    var activeView: String = "unknown"
    var visibleTrackCount: Int = 0
    var visibleRegionCount: Int = 0
    var scope: String = "visible_only"
    var scopeNote: String = "Current Logic Pro readback is limited to objects visible in the current UI layout."
    var lastUpdated: Date = .distantPast
    var projectIdentity: ProjectIdentity = .unknown
    var generation: UInt64 = 0
}

/// One visible Event List row inside the current editor scope.
struct EditorEventRowState: Sendable, Codable, Identifiable {
    let id: String
    var rowIndex: Int
    var eventType: String
    var primaryValue: String?
    var isSelected: Bool = false
    var detailAvailability: String = "event_type_only"
}

/// Summary of the current Event List editor scope.
struct EditorState: Sendable, Codable {
    var windowTitle: String = ""
    var activeView: String = "unknown"
    var eventListVisible: Bool = false
    var rowCount: Int = 0
    var noteRowCount: Int = 0
    var detailAvailability: String = "event_type_only"
    var writeMode: String = "selection_relative"
    var writeCapabilities: [String] = []
    var scope: String = "event_list_visible_only"
    var scopeNote: String = "Event List readback currently proves row identity and event type; note value columns still require MIDI bridge export for full detail."
    var lastUpdated: Date = .distantPast
}

/// Receipt for the last MIDI bridge export performed through Logic Pro UI automation.
struct MIDIBridgeExportState: Sendable, Codable {
    var status: String = "none"
    var exportPath: String?
    var sourceProjectName: String?
    var selectedRegionCount: Int = 0
    var selectedRegionNames: [String] = []
    var exportedAt: Date?
}

/// Capability summary for the MIDI export/import bridge path.
struct MIDIBridgeCapabilitiesState: Sendable, Codable {
    var exportCommand: String = "logic_project.export_selected_midi_bridge"
    var importCommand: String = "logic_project.import_midi_bridge"
    var replaceCommand: String = "logic_project.replace_selected_region_midi_bridge"
    var readMode: String = "human_confirmed_selection_export_then_parse"
    var writeMode: String = "manual_required_no_automatic_replace"
    var scope: String = "selected_region_only"
    var caveat: String = "Bridge export stops at the Logic Pro Save MIDI dialog boundary, and replace is manual-required because this bridge has no rollback or reliable postcondition verification."
}

/// Marker info.
struct MarkerState: Sendable, Codable, Identifiable {
    let id: Int
    var name: String
    var position: String
}

/// Automation mode.
enum AutomationMode: String, Sendable, Codable {
    case off
    case read
    case touch
    case latch
    case write
}

/// Project-level info.
struct ProjectInfo: Sendable, Codable {
    var name: String = ""
    var sampleRate: Int = 44100
    var bitDepth: Int = 24
    var tempo: Double = 120.0
    var timeSignature: String = "4/4"
    var trackCount: Int = 0
    var filePath: String?
    var lastUpdated: Date = .distantPast
    var projectIdentity: ProjectIdentity = .unknown
    var generation: UInt64 = 0

    /// Prefer an explicit identity, then use a readable project path, and finally
    /// retain a visible-only title identity for honest coherence reporting.
    var resolvedProjectIdentity: ProjectIdentity {
        if projectIdentity.isKnown { return projectIdentity }
        if let filePath, !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .stable(path: filePath)
        }
        return ProjectIdentity.visibleOnly(name: name)
    }
}

// The AX channel is also a compatibility boundary: older readback payloads may
// not carry the P2C authority metadata yet. Missing metadata must decode as
// unknown rather than preventing the cache from reporting a safe rejection.
extension RegionState {
    private enum CodingKeys: String, CodingKey {
        case id, name, trackIndex, trackName, startPosition, endPosition, length
        case isSelected, isLooped, projectIdentity, generation
        case identityStability, identityScope, identityNote, stableID, trackStableID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        trackIndex = try container.decode(Int.self, forKey: .trackIndex)
        trackName = try container.decode(String.self, forKey: .trackName)
        startPosition = try container.decode(String.self, forKey: .startPosition)
        endPosition = try container.decode(String.self, forKey: .endPosition)
        length = try container.decode(String.self, forKey: .length)
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
        isLooped = try container.decodeIfPresent(Bool.self, forKey: .isLooped) ?? false
        projectIdentity = try container.decodeIfPresent(ProjectIdentity.self, forKey: .projectIdentity) ?? .unknown
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        identityStability = try container.decodeIfPresent(StateIdentityStability.self, forKey: .identityStability) ?? .synthetic
        identityScope = try container.decodeIfPresent(String.self, forKey: .identityScope) ?? "visible_only"
        identityNote = try container.decodeIfPresent(String.self, forKey: .identityNote)
            ?? "Region IDs are derived from visible track order and are not stable mutation keys."
        stableID = try container.decodeIfPresent(String.self, forKey: .stableID)
        trackStableID = try container.decodeIfPresent(String.self, forKey: .trackStableID)
    }
}

extension TrackState {
    private enum CodingKeys: String, CodingKey {
        case id, name, type, isMuted, isSoloed, isArmed, isSelected, volume, pan, color
        case projectIdentity, generation, identityStability, identityScope, identityNote, stableID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(TrackType.self, forKey: .type)
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSoloed = try container.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
        isArmed = try container.decodeIfPresent(Bool.self, forKey: .isArmed) ?? false
        isSelected = try container.decodeIfPresent(Bool.self, forKey: .isSelected) ?? false
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.0
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0.0
        color = try container.decodeIfPresent(String.self, forKey: .color)
        projectIdentity = try container.decodeIfPresent(ProjectIdentity.self, forKey: .projectIdentity) ?? .unknown
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        identityStability = try container.decodeIfPresent(StateIdentityStability.self, forKey: .identityStability) ?? .synthetic
        identityScope = try container.decodeIfPresent(String.self, forKey: .identityScope) ?? "visible_only"
        identityNote = try container.decodeIfPresent(String.self, forKey: .identityNote)
            ?? "Track IDs are visible-order indices and are not stable mutation keys."
        stableID = try container.decodeIfPresent(String.self, forKey: .stableID)
    }
}

extension SelectionState {
    private enum CodingKeys: String, CodingKey {
        case selectedTrackIndex, selectedTrackName, selectedRegionIDs, selectedRegionNames
        case selectedRegionCount, scope, lastUpdated, projectIdentity, generation
        case selectedRegionIdentityStability, identityScope, identityNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedTrackIndex = try container.decodeIfPresent(Int.self, forKey: .selectedTrackIndex)
        selectedTrackName = try container.decodeIfPresent(String.self, forKey: .selectedTrackName)
        selectedRegionIDs = try container.decodeIfPresent([String].self, forKey: .selectedRegionIDs) ?? []
        selectedRegionNames = try container.decodeIfPresent([String].self, forKey: .selectedRegionNames) ?? []
        selectedRegionCount = try container.decodeIfPresent(Int.self, forKey: .selectedRegionCount) ?? selectedRegionIDs.count
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? "visible_only"
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? .distantPast
        projectIdentity = try container.decodeIfPresent(ProjectIdentity.self, forKey: .projectIdentity) ?? .unknown
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        selectedRegionIdentityStability = try container.decodeIfPresent(StateIdentityStability.self, forKey: .selectedRegionIdentityStability) ?? .unknown
        identityScope = try container.decodeIfPresent(String.self, forKey: .identityScope) ?? "visible_only"
        identityNote = try container.decodeIfPresent(String.self, forKey: .identityNote)
            ?? "Visible-only selection and synthetic region IDs cannot silently authorize destructive mutation."
    }
}

extension ContextState {
    private enum CodingKeys: String, CodingKey {
        case projectName, windowTitle, activeView, visibleTrackCount, visibleRegionCount
        case scope, scopeNote, lastUpdated, projectIdentity, generation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName) ?? ""
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle) ?? ""
        activeView = try container.decodeIfPresent(String.self, forKey: .activeView) ?? "unknown"
        visibleTrackCount = try container.decodeIfPresent(Int.self, forKey: .visibleTrackCount) ?? 0
        visibleRegionCount = try container.decodeIfPresent(Int.self, forKey: .visibleRegionCount) ?? 0
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? "visible_only"
        scopeNote = try container.decodeIfPresent(String.self, forKey: .scopeNote)
            ?? "Current Logic Pro readback is limited to objects visible in the current UI layout."
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? .distantPast
        projectIdentity = try container.decodeIfPresent(ProjectIdentity.self, forKey: .projectIdentity) ?? .unknown
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
    }
}

extension ProjectInfo {
    private enum CodingKeys: String, CodingKey {
        case name, sampleRate, bitDepth, tempo, timeSignature, trackCount, filePath
        case lastUpdated, projectIdentity, generation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate) ?? 44100
        bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth) ?? 24
        tempo = try container.decodeIfPresent(Double.self, forKey: .tempo) ?? 120.0
        timeSignature = try container.decodeIfPresent(String.self, forKey: .timeSignature) ?? "4/4"
        trackCount = try container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? .distantPast
        projectIdentity = try container.decodeIfPresent(ProjectIdentity.self, forKey: .projectIdentity) ?? .unknown
        generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
    }
}

/// Authority result returned by the cache before a guarded mutation boundary.
struct StateAuthorityCheck: Sendable, Codable {
    var authority: String
    var authorized: Bool
    var reasonCode: String
    var message: String
    var checkedAt: Date
    var observedAgeSeconds: TimeInterval
    var maximumAgeSeconds: TimeInterval
    var projectIdentity: ProjectIdentity
    var selectionProjectIdentity: ProjectIdentity
    var generation: UInt64
    var selectionGeneration: UInt64
    var projectIdentityMatches: Bool
    var generationCompatible: Bool
    var selectionFresh: Bool
    var selectedRegionCount: Int
    var selectedRegionIDs: [String]
    var selectedRegionIdentityStability: StateIdentityStability
    var scope: String
}

/// Cache metadata exposed by health/resource diagnostics and operation receipts.
struct CacheAuthoritySnapshot: Sendable, Codable {
    var checkedAt: Date
    var projectIdentity: ProjectIdentity
    var generation: UInt64
    var selectionProjectIdentity: ProjectIdentity
    var selectionGeneration: UInt64
    var selectionUpdatedAt: Date
    var selectionAgeSeconds: TimeInterval
    var selectionMaximumAgeSeconds: TimeInterval
    var selectionAuthorized: Bool
    var selectionIdentityStability: StateIdentityStability
    var projectUpdatedAt: Date
    var projectAgeSeconds: TimeInterval
}

/// Machine-readable operation request embedded in a versioned receipt.
struct OperationRequest: Sendable, Codable {
    var operation: String
    var parameters: [String: String]

    enum CodingKeys: String, CodingKey {
        case operation
        case parameters = "params"
    }
}

/// Preconditions recorded for a guarded operation, including rejected paths.
struct OperationPreconditions: Sendable, Codable {
    var stateAuthority: String
    var sourcePath: String?
    var sourceValid: Bool?
    var selectionFresh: Bool?
    var selectionAgeSeconds: TimeInterval?
    var maximumAgeSeconds: TimeInterval?
    var selectedRegionCount: Int?
    var selectedRegionIDs: [String]
    var selectedRegionIdentityStability: StateIdentityStability
    var projectIdentity: ProjectIdentity
    var selectionProjectIdentity: ProjectIdentity
    var projectIdentityKnown: Bool
    var projectIdentityMatches: Bool?
    var generationCompatible: Bool?
    var cacheGeneration: UInt64
    var stateGeneration: UInt64
    var failures: [String]

    enum CodingKeys: String, CodingKey {
        case stateAuthority = "state_authority"
        case sourcePath = "source_path"
        case sourceValid = "source_valid"
        case selectionFresh = "selection_fresh"
        case selectionAgeSeconds = "selection_age_seconds"
        case maximumAgeSeconds = "maximum_age_seconds"
        case selectedRegionCount = "selected_region_count"
        case selectedRegionIDs = "selected_region_ids"
        case selectedRegionIdentityStability = "selected_region_identity_stability"
        case projectIdentity = "project_identity"
        case selectionProjectIdentity = "selection_project_identity"
        case projectIdentityKnown = "project_identity_known"
        case projectIdentityMatches = "project_identity_matches"
        case generationCompatible = "generation_compatible"
        case cacheGeneration = "cache_generation"
        case stateGeneration = "state_generation"
        case failures
    }
}

/// Versioned receipt for a guarded mutation boundary.
struct OperationReceipt: Sendable, Codable {
    static let currentSchemaVersion = "logic_operation_receipt/v1"

    var schemaVersion: String
    var receiptVersion: Int
    var receiptID: String
    var operation: String
    var request: OperationRequest
    var preconditions: OperationPreconditions
    var mutation: String
    var verification: String
    var projectIdentity: ProjectIdentity
    var generation: UInt64
    var status: String
    var success: Bool
    var error: String?
    var issuedAt: Date

    // Compatibility details retained from the accepted P2B bridge responses.
    var path: String?
    var sourcePath: String?
    var selectedRegionID: String?
    var requestedPath: String?
    var selectedRegionCount: Int?
    var selectedRegionNames: [String]?
    var mode: String?
    var importAnchor: String?
    var importMethod: String?
    var recommendedNextStep: String?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case receiptVersion = "receipt_version"
        case receiptID = "receipt_id"
        case operation
        case request
        case preconditions
        case mutation
        case verification
        case projectIdentity = "project_identity"
        case generation
        case status
        case success
        case error
        case issuedAt = "issued_at"
        case path
        case sourcePath
        case selectedRegionID
        case requestedPath
        case selectedRegionCount
        case selectedRegionNames
        case mode
        case importAnchor
        case importMethod
        case recommendedNextStep
        case scope
    }

    init(
        receiptID: String = UUID().uuidString,
        operation: String,
        parameters: [String: String],
        preconditions: OperationPreconditions,
        mutation: String,
        verification: String,
        projectIdentity: ProjectIdentity,
        generation: UInt64,
        status: String,
        success: Bool,
        error: String?,
        issuedAt: Date = Date(),
        path: String? = nil,
        sourcePath: String? = nil,
        selectedRegionID: String? = nil,
        requestedPath: String? = nil,
        selectedRegionCount: Int? = nil,
        selectedRegionNames: [String]? = nil,
        mode: String? = nil,
        importAnchor: String? = nil,
        importMethod: String? = nil,
        recommendedNextStep: String? = nil,
        scope: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.receiptVersion = 1
        self.receiptID = receiptID
        self.operation = operation
        self.request = OperationRequest(operation: operation, parameters: parameters)
        self.preconditions = preconditions
        self.mutation = mutation
        self.verification = verification
        self.projectIdentity = projectIdentity
        self.generation = generation
        self.status = status
        self.success = success
        self.error = error
        self.issuedAt = issuedAt
        self.path = path
        self.sourcePath = sourcePath
        self.selectedRegionID = selectedRegionID
        self.requestedPath = requestedPath
        self.selectedRegionCount = selectedRegionCount
        self.selectedRegionNames = selectedRegionNames
        self.mode = mode
        self.importAnchor = importAnchor
        self.importMethod = importMethod
        self.recommendedNextStep = recommendedNextStep
        self.scope = scope
    }
}
