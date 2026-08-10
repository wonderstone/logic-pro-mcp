import MCP

/// The public command contract exposed by each dispatcher.
///
/// This is deliberately kept separate from the human-readable tool descriptions so
/// tests can verify that every advertised routed command has a router entry. Commands
/// that cannot prove a mutation are represented as guarded/local surfaces instead of
/// pretending to be verified routes.
enum CommandRegistry {
    enum Surface: String, Sendable {
        case routed
        case local
        case guarded
    }

    struct Entry: Sendable {
        let tool: String
        let command: String
        let operations: [String]
        let surface: Surface
        let requiredParameterSets: [[String]]
    }

    static let entries: [Entry] = [
        // Transport
        Entry(tool: "logic_transport", command: "play", operations: ["transport.play"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_transport", command: "stop", operations: ["transport.stop"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_transport", command: "record", operations: ["transport.record"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_transport", command: "pause", operations: ["transport.pause"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_transport", command: "rewind", operations: ["transport.rewind"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_transport", command: "fast_forward", operations: ["transport.fast_forward"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_transport", command: "toggle_cycle", operations: ["transport.toggle_cycle"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_transport", command: "toggle_metronome", operations: ["transport.toggle_metronome"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_transport", command: "set_tempo", operations: ["transport.set_tempo"], surface: .routed, requiredParameterSets: [["tempo"], ["bpm"]]),
        Entry(tool: "logic_transport", command: "goto_position", operations: ["transport.goto_position"], surface: .routed, requiredParameterSets: [["bar"], ["time"], ["position"]]),

        // Tracks
        Entry(tool: "logic_tracks", command: "select", operations: ["track.select"], surface: .routed, requiredParameterSets: [["index"], ["name"]]),
        Entry(tool: "logic_tracks", command: "create_audio", operations: ["track.create_audio"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_tracks", command: "create_instrument", operations: ["track.create_instrument"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_tracks", command: "create_drummer", operations: ["track.create_drummer"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_tracks", command: "delete", operations: ["track.select", "track.delete"], surface: .routed, requiredParameterSets: [["index"]]),
        Entry(tool: "logic_tracks", command: "duplicate", operations: ["track.select", "track.duplicate"], surface: .routed, requiredParameterSets: [["index"]]),
        Entry(tool: "logic_tracks", command: "rename", operations: ["track.rename"], surface: .routed, requiredParameterSets: [["index", "name"]]),
        Entry(tool: "logic_tracks", command: "mute", operations: ["track.set_mute"], surface: .routed, requiredParameterSets: [["index", "enabled"]]),
        Entry(tool: "logic_tracks", command: "solo", operations: ["track.set_solo"], surface: .routed, requiredParameterSets: [["index", "enabled"]]),
        Entry(tool: "logic_tracks", command: "arm", operations: ["track.set_arm"], surface: .routed, requiredParameterSets: [["index", "enabled"]]),

        // Mixer
        Entry(tool: "logic_mixer", command: "set_volume", operations: ["mixer.set_volume"], surface: .routed, requiredParameterSets: [["track", "value"]]),
        Entry(tool: "logic_mixer", command: "set_pan", operations: ["mixer.set_pan"], surface: .routed, requiredParameterSets: [["track", "value"]]),
        Entry(tool: "logic_mixer", command: "set_send", operations: ["mixer.set_send"], surface: .routed, requiredParameterSets: [["track", "bus", "value"]]),

        // MIDI
        Entry(tool: "logic_midi", command: "send_note", operations: ["midi.send_note"], surface: .routed, requiredParameterSets: [["note", "velocity", "channel", "duration_ms"]]),
        Entry(tool: "logic_midi", command: "send_chord", operations: ["midi.send_chord"], surface: .routed, requiredParameterSets: [["notes", "velocity", "channel", "duration_ms"]]),
        Entry(tool: "logic_midi", command: "send_cc", operations: ["midi.send_cc"], surface: .routed, requiredParameterSets: [["controller", "value", "channel"]]),
        Entry(tool: "logic_midi", command: "send_program_change", operations: ["midi.send_program_change"], surface: .routed, requiredParameterSets: [["program", "channel"]]),
        Entry(tool: "logic_midi", command: "send_pitch_bend", operations: ["midi.send_pitch_bend"], surface: .routed, requiredParameterSets: [["value", "channel"]]),
        Entry(tool: "logic_midi", command: "send_aftertouch", operations: ["midi.send_aftertouch"], surface: .routed, requiredParameterSets: [["value", "channel"]]),
        Entry(tool: "logic_midi", command: "send_sysex", operations: ["midi.send_sysex"], surface: .routed, requiredParameterSets: [["bytes"], ["data"]]),
        Entry(tool: "logic_midi", command: "mmc_play", operations: ["mmc.play"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_midi", command: "mmc_stop", operations: ["mmc.stop"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_midi", command: "mmc_record", operations: ["mmc.record_strobe"], surface: .routed, requiredParameterSets: []),

        // Editing
        Entry(tool: "logic_edit", command: "undo", operations: ["edit.undo"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_edit", command: "redo", operations: ["edit.redo"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_edit", command: "cut", operations: ["edit.cut"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_edit", command: "copy", operations: ["edit.copy"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_edit", command: "paste", operations: ["edit.paste"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_edit", command: "delete", operations: ["edit.delete"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_edit", command: "select_all", operations: ["edit.select_all"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_edit", command: "split", operations: ["edit.split"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_edit", command: "join", operations: ["edit.join"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_edit", command: "quantize", operations: ["edit.quantize"], surface: .routed, requiredParameterSets: [["value"]]),
        Entry(tool: "logic_edit", command: "bounce_in_place", operations: ["edit.bounce_in_place"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_edit", command: "duplicate", operations: ["edit.select_all", "edit.copy", "edit.paste"], surface: .routed, requiredParameterSets: []),

        // Navigation
        Entry(tool: "logic_navigate", command: "create_marker", operations: ["nav.create_marker"], surface: .routed, requiredParameterSets: [["name"]]),
        Entry(tool: "logic_navigate", command: "zoom_to_fit", operations: ["nav.zoom_to_fit"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_navigate", command: "toggle_view", operations: ["view.toggle_mixer", "view.toggle_piano_roll", "view.toggle_event_list", "view.toggle_score_editor", "view.toggle_step_editor", "view.toggle_library", "view.toggle_inspector", "automation.toggle_view"], surface: .routed, requiredParameterSets: [["view"]]),

        // Project lifecycle and guarded bridge surfaces
        Entry(tool: "logic_project", command: "new", operations: ["project.new"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_project", command: "open", operations: ["project.open"], surface: .routed, requiredParameterSets: [["path"]]),
        Entry(tool: "logic_project", command: "save", operations: ["project.save"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_project", command: "close", operations: ["project.close"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_project", command: "bounce", operations: ["project.bounce"], surface: .routed, requiredParameterSets: []),
        Entry(tool: "logic_project", command: "silent_bounce", operations: [], surface: .local, requiredParameterSets: []),
        Entry(tool: "logic_project", command: "export_selected_midi_bridge", operations: [], surface: .guarded, requiredParameterSets: []),
        Entry(tool: "logic_project", command: "import_midi_bridge", operations: [], surface: .guarded, requiredParameterSets: [["path"]]),
        Entry(tool: "logic_project", command: "replace_selected_region_midi_bridge", operations: [], surface: .guarded, requiredParameterSets: [["path"]]),
        Entry(tool: "logic_project", command: "bind_disposable_project", operations: [], surface: .guarded, requiredParameterSets: [["path", "sha256", "expires_at"]]),
        Entry(tool: "logic_project", command: "verify_keeper_digest", operations: [], surface: .guarded, requiredParameterSets: [["path"], ["asset_path"]]),
        Entry(tool: "logic_project", command: "preview_ace_audio_placement", operations: [], surface: .guarded, requiredParameterSets: [["handoff_json"], ["plan_id", "operation_id", "asset_path", "asset_sha256", "role_id", "claim_boundary", "bar", "beat", "duration_beats"]]),
        Entry(tool: "logic_project", command: "authorize_ace_audio_placement", operations: [], surface: .guarded, requiredParameterSets: [["plan_id", "confirmation_id", "confirmed_by", "confirmed_at"]]),
        Entry(tool: "logic_project", command: "place_ace_audio", operations: [], surface: .guarded, requiredParameterSets: [["plan_id"]]),
        Entry(tool: "logic_project", command: "tag_ace_audio_after_import", operations: [], surface: .guarded, requiredParameterSets: [["plan_id", "operation_id", "target_project_path", "expected_before_project_sha256", "asset_path", "asset_sha256", "keeper_digest_receipt_json", "track_tag", "region_tag", "native_source_basename", "before_track_count", "before_region_count", "expected_track_count", "expected_region_count", "preserved_track_names", "preserved_region_names", "confirmation_id", "confirmed_by", "confirmed_at"]]),
        Entry(tool: "logic_project", command: "verify_ace_audio_placement", operations: [], surface: .guarded, requiredParameterSets: [["target_project_path", "asset_path", "asset_sha256", "keeper_digest_receipt_json"], ["target_project_path", "asset_path", "asset_sha256", "keeper_digest_receipt"]]),
        Entry(tool: "logic_project", command: "rollback_ace_audio_placement", operations: [], surface: .guarded, requiredParameterSets: [["plan_id", "rollback_confirmation_id", "rollback_confirmed_by", "rollback_confirmed_at"], ["plan_id", "confirmation_id", "confirmed_by", "confirmed_at"]]),
        Entry(tool: "logic_project", command: "adopt_ace_audio_delta", operations: [], surface: .guarded, requiredParameterSets: [["plan_id", "operation_id", "target_project_path", "starting_project_sha256", "baseline_project_sha256", "before_track_count", "before_region_count", "current_track_count", "current_region_count", "new_track_name", "source_base_name", "duplicate_region_name", "preserved_track_names", "preserved_region_names", "asset_path", "asset_sha256", "track_tag", "region_tag", "bar", "beat", "tick", "duration_beats", "beats_per_bar", "confirmation_id", "confirmed_by", "confirmed_at"]]),
        Entry(tool: "logic_project", command: "verify_ace_audio_delta", operations: [], surface: .guarded, requiredParameterSets: [["plan_id", "operation_id", "target_project_path", "starting_project_sha256", "baseline_project_sha256", "before_track_count", "before_region_count", "current_track_count", "current_region_count", "new_track_name", "source_base_name", "duplicate_region_name", "preserved_track_names", "preserved_region_names", "asset_path", "asset_sha256", "track_tag", "region_tag", "bar", "beat", "tick", "duration_beats", "beats_per_bar"]]),
        Entry(tool: "logic_project", command: "rollback_ace_audio_delta", operations: [], surface: .guarded, requiredParameterSets: [["plan_id", "operation_id", "target_project_path", "starting_project_sha256", "baseline_project_sha256", "before_track_count", "before_region_count", "current_track_count", "current_region_count", "new_track_name", "source_base_name", "duplicate_region_name", "preserved_track_names", "preserved_region_names", "asset_path", "asset_sha256", "track_tag", "region_tag", "bar", "beat", "tick", "duration_beats", "beats_per_bar"]]),
        Entry(tool: "logic_project", command: "launch", operations: [], surface: .local, requiredParameterSets: []),
        Entry(tool: "logic_project", command: "quit", operations: [], surface: .local, requiredParameterSets: []),

        // System
        Entry(tool: "logic_system", command: "health", operations: [], surface: .local, requiredParameterSets: []),
        Entry(tool: "logic_system", command: "permissions", operations: [], surface: .local, requiredParameterSets: []),
        Entry(tool: "logic_system", command: "refresh_cache", operations: [], surface: .local, requiredParameterSets: []),
        Entry(tool: "logic_system", command: "help", operations: [], surface: .local, requiredParameterSets: []),
    ]

    static func entries(for tool: String) -> [Entry] {
        entries.filter { $0.tool == tool }
    }

    static func commandList(for tool: String) -> String {
        entries(for: tool).map(\.command).joined(separator: ", ")
    }

    static func entry(for tool: String, command: String) -> Entry? {
        entries.first { $0.tool == tool && $0.command == command }
    }

    /// Return a user-facing validation error, or nil when the command's required
    /// parameter alternatives are satisfied exactly once.
    static func validationError(
        tool: String,
        command: String,
        params: [String: Value]
    ) -> String? {
        guard let entry = entry(for: tool, command: command), !entry.requiredParameterSets.isEmpty else {
            return nil
        }

        let matched = entry.requiredParameterSets.filter { required in
            required.allSatisfy { key in isPresent(params[key]) }
        }
        if matched.count == 1 {
            return nil
        }

        let alternatives = entry.requiredParameterSets
            .map { "{\($0.joined(separator: ", "))}" }
            .joined(separator: " or ")
        if matched.count > 1 {
            return "\(command) requires exactly one of: \(alternatives)"
        }
        return "\(command) requires: \(alternatives)"
    }

    private static func isPresent(_ value: Value?) -> Bool {
        guard let value else { return false }
        if let string = value.stringValue {
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return value.intValue != nil
            || value.doubleValue != nil
            || value.boolValue != nil
            || value.arrayValue != nil
    }
}
