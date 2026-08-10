import Foundation
import MCP

struct MIDIDispatcher {
    static let tool = Tool(
        name: "logic_midi",
        description: """
            MIDI operations in Logic Pro. \
            Commands: \(CommandRegistry.commandList(for: "logic_midi")). \
            Params by command: \
            send_note -> { note: Int, velocity: Int, channel: Int, duration_ms: Int }; \
            send_chord -> { notes: [Int], velocity: Int, channel: Int, duration_ms: Int }; \
            send_cc -> { controller: Int, value: Int, channel: Int }; \
            send_program_change -> { program: Int, channel: Int }; \
            send_pitch_bend -> { value: Int, channel: Int } (0-16383); \
            send_aftertouch -> { value: Int, channel: Int }; \
            send_sysex -> { bytes: [Int] } or { data: String } (hex)
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("MIDI command to execute"),
                ]),
                "params": .object([
                    "type": .string("object"),
                    "description": .string("Command-specific parameters"),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    )

    static func handle(
        command: String,
        params: [String: Value],
        router: ChannelRouter,
        cache: StateCache
    ) async -> CallTool.Result {
        switch command {
        case "send_note":
            if let error = CommandRegistry.validationError(tool: "logic_midi", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let note = params["note"]?.intValue, (0...127).contains(note),
                  let velocity = params["velocity"]?.intValue, (0...127).contains(velocity),
                  let channel = params["channel"]?.intValue, (0...15).contains(channel),
                  let durationMs = params["duration_ms"]?.intValue, durationMs >= 0 else {
                return CallTool.Result(content: [.text("send_note requires note/velocity 0...127, channel 0...15, and duration_ms >= 0")], isError: true)
            }
            let result = await router.route(
                operation: "midi.send_note",
                params: [
                    "note": String(note),
                    "velocity": String(velocity),
                    "channel": String(channel),
                    "duration_ms": String(durationMs),
                ]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_chord":
            if let error = CommandRegistry.validationError(tool: "logic_midi", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            // Accept either array of ints or comma-separated string
            let notesStr: String
            if let arr = params["notes"]?.arrayValue {
                guard !arr.isEmpty,
                      arr.allSatisfy({
                          guard let note = $0.intValue else { return false }
                          return (0...127).contains(note)
                      }) else {
                    return CallTool.Result(content: [.text("send_chord requires notes in the range 0...127")], isError: true)
                }
                notesStr = arr.compactMap { $0.intValue }.map(String.init).joined(separator: ",")
            } else {
                notesStr = params["notes"]?.stringValue ?? ""
            }
            let noteParts = notesStr.split(separator: ",", omittingEmptySubsequences: false)
            let notes = noteParts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !noteParts.isEmpty,
                  noteParts.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  notes.count == noteParts.count,
                  notes.allSatisfy({ (0...127).contains($0) }),
                  let velocity = params["velocity"]?.intValue, (0...127).contains(velocity),
                  let channel = params["channel"]?.intValue, (0...15).contains(channel),
                  let durationMs = params["duration_ms"]?.intValue, durationMs >= 0 else {
                return CallTool.Result(content: [.text("send_chord requires non-empty notes/velocity 0...127, channel 0...15, and duration_ms >= 0")], isError: true)
            }
            let result = await router.route(
                operation: "midi.send_chord",
                params: [
                    "notes": notesStr,
                    "velocity": String(velocity),
                    "channel": String(channel),
                    "duration_ms": String(durationMs),
                ]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_cc":
            if let error = CommandRegistry.validationError(tool: "logic_midi", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let controller = params["controller"]?.intValue, (0...127).contains(controller),
                  let value = params["value"]?.intValue, (0...127).contains(value),
                  let channel = params["channel"]?.intValue, (0...15).contains(channel) else {
                return CallTool.Result(content: [.text("send_cc requires controller/value 0...127 and channel 0...15")], isError: true)
            }
            let result = await router.route(
                operation: "midi.send_cc",
                params: [
                    "controller": String(controller),
                    "value": String(value),
                    "channel": String(channel),
                ]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_program_change":
            if let error = CommandRegistry.validationError(tool: "logic_midi", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let program = params["program"]?.intValue, (0...127).contains(program),
                  let channel = params["channel"]?.intValue, (0...15).contains(channel) else {
                return CallTool.Result(content: [.text("send_program_change requires program 0...127 and channel 0...15")], isError: true)
            }
            let result = await router.route(
                operation: "midi.send_program_change",
                params: ["program": String(program), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_pitch_bend":
            if let error = CommandRegistry.validationError(tool: "logic_midi", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let value = params["value"]?.intValue, (0...16383).contains(value),
                  let channel = params["channel"]?.intValue, (0...15).contains(channel) else {
                return CallTool.Result(content: [.text("send_pitch_bend requires value 0...16383 and channel 0...15")], isError: true)
            }
            let result = await router.route(
                operation: "midi.send_pitch_bend",
                params: ["value": String(value), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_aftertouch":
            if let error = CommandRegistry.validationError(tool: "logic_midi", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let value = params["value"]?.intValue, (0...127).contains(value),
                  let channel = params["channel"]?.intValue, (0...15).contains(channel) else {
                return CallTool.Result(content: [.text("send_aftertouch requires value 0...127 and channel 0...15")], isError: true)
            }
            let result = await router.route(
                operation: "midi.send_aftertouch",
                params: ["value": String(value), "channel": String(channel)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "send_sysex":
            if let error = CommandRegistry.validationError(tool: "logic_midi", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            let data: String
            if let bytes = params["bytes"]?.arrayValue {
                guard !bytes.isEmpty,
                      bytes.allSatisfy({
                          guard let byte = $0.intValue else { return false }
                          return (0...255).contains(byte)
                      }) else {
                    return CallTool.Result(content: [.text("send_sysex requires byte values in the range 0...255")], isError: true)
                }
                data = bytes.compactMap { $0.intValue }
                    .map { String(format: "%02X", $0) }
                    .joined(separator: " ")
            } else {
                data = params["data"]?.stringValue ?? ""
            }
            guard !data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return CallTool.Result(content: [.text("send_sysex requires non-empty bytes or data")], isError: true)
            }
            let result = await router.route(
                operation: "midi.send_sysex",
                params: ["bytes": data]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mmc_play":
            let result = await router.route(operation: "mmc.play")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mmc_stop":
            let result = await router.route(operation: "mmc.stop")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mmc_record":
            let result = await router.route(operation: "mmc.record_strobe")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown MIDI command: \(command). Available: send_note, send_chord, send_cc, send_program_change, send_pitch_bend, send_aftertouch, send_sysex, mmc_play, mmc_stop, mmc_record")],
                isError: true
            )
        }
    }
}
