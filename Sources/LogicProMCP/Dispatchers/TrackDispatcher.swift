import Foundation
import MCP

struct TrackDispatcher {
    static let tool = Tool(
        name: "logic_tracks",
        description: """
            Track actions in Logic Pro. \
            Commands: \(CommandRegistry.commandList(for: "logic_tracks")). \
            Params by command: \
            select -> { index: Int } or { name: String }; \
            rename -> { index: Int, name: String }; \
            mute/solo/arm -> { index: Int, enabled: Bool }; \
            create_* -> {} (creates at current position); \
            delete/duplicate -> { index: Int }
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Track command to execute"),
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
        case "select":
            if let error = CommandRegistry.validationError(tool: "logic_tracks", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            if let index = params["index"]?.intValue {
                guard index >= 0 else {
                    return CallTool.Result(content: [.text("select requires a non-negative 'index' param")], isError: true)
                }
                let result = await router.route(
                    operation: "track.select",
                    params: ["index": String(index)]
                )
                return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
            }
            if let name = params["name"]?.stringValue {
                // Find track by name in cache
                let tracks = await cache.getTracks()
                if let track = tracks.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                    let result = await router.route(
                        operation: "track.select",
                        params: ["index": String(track.id)]
                    )
                    return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)
                }
                return CallTool.Result(content: [.text("No track found matching '\(name)'")], isError: true)
            }
            return CallTool.Result(content: [.text("select requires 'index' or 'name' param")], isError: true)

        case "create_audio":
            let result = await router.route(operation: "track.create_audio")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "create_instrument":
            let result = await router.route(operation: "track.create_instrument")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "create_drummer":
            let result = await router.route(operation: "track.create_drummer")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "delete":
            if let error = CommandRegistry.validationError(tool: "logic_tracks", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let index = params["index"]?.intValue, index >= 0 else {
                return CallTool.Result(content: [.text("delete requires a non-negative 'index' param")], isError: true)
            }
            let selectResult = await router.route(
                operation: "track.select",
                params: ["index": String(index)]
            )
            guard selectResult.isSuccess else {
                return CallTool.Result(content: [.text(selectResult.message)], isError: true)
            }
            let result = await router.route(operation: "track.delete")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "duplicate":
            if let error = CommandRegistry.validationError(tool: "logic_tracks", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let index = params["index"]?.intValue, index >= 0 else {
                return CallTool.Result(content: [.text("duplicate requires a non-negative 'index' param")], isError: true)
            }
            let selectResult = await router.route(
                operation: "track.select",
                params: ["index": String(index)]
            )
            guard selectResult.isSuccess else {
                return CallTool.Result(content: [.text(selectResult.message)], isError: true)
            }
            let result = await router.route(operation: "track.duplicate")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "rename":
            if let error = CommandRegistry.validationError(tool: "logic_tracks", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let index = params["index"]?.intValue, index >= 0,
                  let name = params["name"]?.stringValue,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return CallTool.Result(content: [.text("rename requires a non-negative 'index' and non-empty 'name'")], isError: true)
            }
            let result = await router.route(
                operation: "track.rename",
                params: ["index": String(index), "name": name]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "mute":
            if let error = CommandRegistry.validationError(tool: "logic_tracks", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let index = params["index"]?.intValue, index >= 0,
                  let enabled = params["enabled"]?.boolValue else {
                return CallTool.Result(content: [.text("mute requires a non-negative 'index' and 'enabled' param")], isError: true)
            }
            let result = await router.route(
                operation: "track.set_mute",
                params: ["index": String(index), "muted": String(enabled), "enabled": String(enabled)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "solo":
            if let error = CommandRegistry.validationError(tool: "logic_tracks", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let index = params["index"]?.intValue, index >= 0,
                  let enabled = params["enabled"]?.boolValue else {
                return CallTool.Result(content: [.text("solo requires a non-negative 'index' and 'enabled' param")], isError: true)
            }
            let result = await router.route(
                operation: "track.set_solo",
                params: ["index": String(index), "soloed": String(enabled), "enabled": String(enabled)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "arm":
            if let error = CommandRegistry.validationError(tool: "logic_tracks", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let index = params["index"]?.intValue, index >= 0,
                  let enabled = params["enabled"]?.boolValue else {
                return CallTool.Result(content: [.text("arm requires a non-negative 'index' and 'enabled' param")], isError: true)
            }
            let result = await router.route(
                operation: "track.set_arm",
                params: ["index": String(index), "armed": String(enabled), "enabled": String(enabled)]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown track command: \(command). Available: select, create_audio, create_instrument, create_drummer, delete, duplicate, rename, mute, solo, arm")],
                isError: true
            )
        }
    }
}
