import Foundation
import MCP

struct MixerDispatcher {
    static let tool = Tool(
        name: "logic_mixer",
        description: """
            Mixer actions in Logic Pro. \
            Commands: \(CommandRegistry.commandList(for: "logic_mixer")). \
            Params by command: \
            set_volume -> { track: Int, value: Float } (normalized 0.0-1.0); \
            set_pan -> { track: Int, value: Float } (-1.0 left to +1.0 right); \
            set_send -> { track: Int, bus: Int, value: Float }; \
            All exposed mixer writes require their target and value parameters.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Mixer command to execute"),
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
        case "set_volume":
            if let error = CommandRegistry.validationError(tool: "logic_mixer", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let track = params["track"]?.intValue, track >= 0,
                  let value = params["value"]?.doubleValue, (0.0...1.0).contains(value) else {
                return CallTool.Result(content: [.text("set_volume requires track >= 0 and value in 0.0...1.0")], isError: true)
            }
            let result = await router.route(
                operation: "mixer.set_volume",
                params: ["track": String(track), "index": String(track), "volume": String(value), "value": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_pan":
            if let error = CommandRegistry.validationError(tool: "logic_mixer", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let track = params["track"]?.intValue, track >= 0,
                  let value = params["value"]?.doubleValue, (-1.0...1.0).contains(value) else {
                return CallTool.Result(content: [.text("set_pan requires track >= 0 and value in -1.0...1.0")], isError: true)
            }
            let result = await router.route(
                operation: "mixer.set_pan",
                params: ["track": String(track), "index": String(track), "pan": String(value), "value": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "set_send":
            if let error = CommandRegistry.validationError(tool: "logic_mixer", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let track = params["track"]?.intValue, track >= 0,
                  let bus = params["bus"]?.intValue, bus >= 0,
                  let value = params["value"]?.doubleValue, (0.0...1.0).contains(value) else {
                return CallTool.Result(content: [.text("set_send requires track >= 0, bus >= 0, and value in 0.0...1.0")], isError: true)
            }
            let result = await router.route(
                operation: "mixer.set_send",
                params: ["track": String(track), "index": String(track), "send": String(bus), "send_index": String(bus), "level": String(value), "value": String(value)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown mixer command: \(command). Available: set_volume, set_pan, set_send")],
                isError: true
            )
        }
    }
}
