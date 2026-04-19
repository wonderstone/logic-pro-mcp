import Foundation

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
struct TrackState: Sendable, Codable, Identifiable {
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
struct RegionState: Sendable, Codable, Identifiable {
    let id: String
    var name: String
    var trackIndex: Int
    var trackName: String
    var startPosition: String   // Bar.Beat
    var endPosition: String
    var length: String
    var isSelected: Bool = false
    var isLooped: Bool = false
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
    var writeMode: String = "delete_selection_then_import_file"
    var scope: String = "selected_region_only"
    var caveat: String = "Bridge export now stops at the Logic Pro Save MIDI dialog boundary; a human must complete the save step before MuseFlow can parse the exported file."
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
}
