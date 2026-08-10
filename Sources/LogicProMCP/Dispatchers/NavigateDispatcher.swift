import Foundation
import MCP

struct NavigateDispatcher {
    static let tool = Tool(
        name: "logic_navigate",
        description: """
            Navigation and markers in Logic Pro. \
            Commands: \(CommandRegistry.commandList(for: "logic_navigate")). \
            Params by command: \
            create_marker -> { name: String } (at current playhead); \
            toggle_view -> { view: String } ("mixer", "piano_roll", "score", \
            "step_editor", "event_list", "library", "inspector", "automation")
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Navigation command to execute"),
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
        case "create_marker":
            if let error = CommandRegistry.validationError(tool: "logic_navigate", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let name = params["name"]?.stringValue,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return CallTool.Result(content: [.text("create_marker requires a non-empty 'name' param")], isError: true)
            }
            let result = await router.route(
                operation: "nav.create_marker",
                params: ["name": name]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "zoom_to_fit":
            let result = await router.route(operation: "nav.zoom_to_fit")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "toggle_view":
            if let error = CommandRegistry.validationError(tool: "logic_navigate", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            guard let view = params["view"]?.stringValue,
                  !view.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return CallTool.Result(content: [.text("toggle_view requires a non-empty 'view' param")], isError: true)
            }
            let operation: String
            switch view {
            case "mixer": operation = "view.toggle_mixer"
            case "piano_roll": operation = "view.toggle_piano_roll"
            case "event_list": operation = "view.toggle_event_list"
            case "score": operation = "view.toggle_score_editor"
            case "step_editor": operation = "view.toggle_step_editor"
            case "library": operation = "view.toggle_library"
            case "inspector": operation = "view.toggle_inspector"
            case "automation": operation = "automation.toggle_view"
            default:
                return CallTool.Result(
                    content: [.text("Unknown view: \(view). Available: mixer, piano_roll, score, step_editor, event_list, library, inspector, automation")],
                    isError: true
                )
            }
            let result = await router.route(operation: operation)
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        default:
            return CallTool.Result(
                content: [.text("Unknown navigate command: \(command). Available: create_marker, zoom_to_fit, toggle_view")],
                isError: true
            )
        }
    }
}
