import Foundation
import MCP
import XCTest
@testable import LogicProMCP

final class SwiftHardeningTests: XCTestCase {
    func testPublicRoutedCommandsHaveRouterEntries() {
        let keys = CommandRegistry.entries.map { "\($0.tool)::\($0.command)" }
        XCTAssertEqual(Set(keys).count, keys.count)

        for entry in CommandRegistry.entries where entry.surface == .routed {
            XCTAssertFalse(entry.operations.isEmpty, "\(entry.tool).\(entry.command) has no routed operation")
            for operation in entry.operations {
                XCTAssertTrue(
                    ChannelRouter.hasRoute(for: operation),
                    "\(entry.tool).\(entry.command) advertises missing route \(operation)"
                )
            }
        }

        for entry in CommandRegistry.entries where entry.surface != .routed {
            XCTAssertTrue(
                entry.operations.isEmpty,
                "\(entry.tool).\(entry.command) must not claim a routed operation"
            )
        }
    }

    func testRoutedRegistryCommandsAreRecognizedByTheirDispatchers() async {
        let channel = RecordingChannel(id: .cgEvent)
        let router = ChannelRouter()
        await router.register(channel)
        let cache = StateCache()

        for entry in CommandRegistry.entries where entry.surface == .routed {
            let result: CallTool.Result
            switch entry.tool {
            case "logic_transport":
                result = await TransportDispatcher.handle(command: entry.command, params: [:], router: router, cache: cache)
            case "logic_tracks":
                result = await TrackDispatcher.handle(command: entry.command, params: [:], router: router, cache: cache)
            case "logic_mixer":
                result = await MixerDispatcher.handle(command: entry.command, params: [:], router: router, cache: cache)
            case "logic_midi":
                result = await MIDIDispatcher.handle(command: entry.command, params: [:], router: router, cache: cache)
            case "logic_edit":
                result = await EditDispatcher.handle(command: entry.command, params: [:], router: router, cache: cache)
            case "logic_navigate":
                result = await NavigateDispatcher.handle(command: entry.command, params: [:], router: router, cache: cache)
            case "logic_project":
                result = await ProjectDispatcher.handle(command: entry.command, params: [:], router: router, cache: cache)
            default:
                XCTFail("routed command has no dispatcher: \(entry.tool).\(entry.command)")
                continue
            }

            XCTAssertFalse(
                resultText(result).hasPrefix("Unknown"),
                "registry command is not implemented by its dispatcher: \(entry.tool).\(entry.command)"
            )
        }
    }

    func testBridgeCommandsAreGuardedAndDoNotClaimAutomaticReplacement() {
        let importEntry = CommandRegistry.entry(for: "logic_project", command: "import_midi_bridge")
        let replaceEntry = CommandRegistry.entry(for: "logic_project", command: "replace_selected_region_midi_bridge")

        XCTAssertEqual(importEntry?.surface.rawValue, CommandRegistry.Surface.guarded.rawValue)
        XCTAssertEqual(replaceEntry?.surface.rawValue, CommandRegistry.Surface.guarded.rawValue)
        XCTAssertEqual(importEntry?.operations, [])
        XCTAssertEqual(replaceEntry?.operations, [])

        let capabilities = MIDIBridgeCapabilitiesState()
        XCTAssertEqual(capabilities.writeMode, "manual_required_no_automatic_replace")
        XCTAssertTrue(capabilities.caveat.contains("rollback"))
        XCTAssertTrue(capabilities.caveat.contains("postcondition"))
    }

    func testToolDescriptionsUseTheGuardedPublicCommandLists() {
        let tools = [
            TransportDispatcher.tool,
            TrackDispatcher.tool,
            MixerDispatcher.tool,
            MIDIDispatcher.tool,
            EditDispatcher.tool,
            NavigateDispatcher.tool,
            ProjectDispatcher.tool,
            SystemDispatcher.tool,
        ]

        for tool in tools {
            XCTAssertTrue(
                tool.description?.contains("Commands: \(CommandRegistry.commandList(for: tool.name))") == true,
                "\(tool.name) description is out of sync with the command registry"
            )
        }

        for unsupported in [
            "toggle_count_in",
            "save_as",
            "create_external_midi",
            "set_color",
            "normalize",
            "create_virtual_port",
            "mmc_locate",
            "goto_bar",
            "goto_marker",
            "delete_marker",
            "rename_marker",
            "set_zoom",
        ] {
            XCTAssertFalse(
                CommandRegistry.entries.contains { $0.command == unsupported },
                "unsupported command remains advertised: \(unsupported)"
            )
        }
    }

    func testReplaceRejectsMissingSourceBeforeAnyMutation() async throws {
        let channel = RecordingChannel(id: .cgEvent)
        let router = ChannelRouter()
        await router.register(channel)

        let cache = StateCache()
        await cache.updateSelection(freshSingleSelection())

        let result = await ProjectDispatcher.handle(
            command: "replace_selected_region_midi_bridge",
            params: ["path": .string("/tmp/logic-pro-mcp-missing-\(UUID().uuidString).mid")],
            router: router,
            cache: cache
        )

        XCTAssertTrue(result.isError == true)
        XCTAssertTrue(resultText(result).contains("not found"))
        let operations = await channel.operationsSnapshot()
        XCTAssertEqual(operations, [])
    }

    func testReplaceRejectsMissingSelectionBeforeAnyMutation() async throws {
        let sourceURL = try makeTemporarySourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let channel = RecordingChannel(id: .cgEvent)
        let router = ChannelRouter()
        await router.register(channel)

        let result = await ProjectDispatcher.handle(
            command: "replace_selected_region_midi_bridge",
            params: ["path": .string(sourceURL.path)],
            router: router,
            cache: StateCache()
        )

        XCTAssertTrue(result.isError == true)
        XCTAssertTrue(resultText(result).contains("selected region"))
        let operations = await channel.operationsSnapshot()
        XCTAssertEqual(operations, [])
    }

    func testReplaceRejectsNonRegularSourceBeforeAnyMutation() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-pro-mcp-\(UUID().uuidString).mid", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let channel = RecordingChannel(id: .cgEvent)
        let router = ChannelRouter()
        await router.register(channel)
        let cache = StateCache()
        await cache.updateSelection(freshSingleSelection())

        let result = await ProjectDispatcher.handle(
            command: "replace_selected_region_midi_bridge",
            params: ["path": .string(directoryURL.path)],
            router: router,
            cache: cache
        )

        XCTAssertTrue(result.isError == true)
        XCTAssertTrue(resultText(result).contains("regular file"))
        let operations = await channel.operationsSnapshot()
        XCTAssertEqual(operations, [])
    }

    func testReplaceReturnsManualRequiredWithoutDeletingWhenVerificationIsUnavailable() async throws {
        let sourceURL = try makeTemporarySourceFile()
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let channel = RecordingChannel(id: .cgEvent)
        let router = ChannelRouter()
        await router.register(channel)

        let cache = StateCache()
        await cache.updateSelection(freshSingleSelection())

        let result = await ProjectDispatcher.handle(
            command: "replace_selected_region_midi_bridge",
            params: ["path": .string(sourceURL.path)],
            router: router,
            cache: cache
        )

        let text = resultText(result)
        XCTAssertTrue(result.isError == true)
        XCTAssertTrue(text.contains("\"status\":\"manual_required\""))
        XCTAssertTrue(text.contains("\"mutation\":\"not_started\""))
        XCTAssertTrue(text.contains("\"verification\":\"unavailable\""))
        let operations = await channel.operationsSnapshot()
        XCTAssertEqual(operations, [])
    }

    func testMissingMutationParametersAreRejectedBeforeRouting() async {
        let channel = RecordingChannel(id: .cgEvent)
        let router = ChannelRouter()
        await router.register(channel)
        let cache = StateCache()

        let cases: [(String, [String: Value], String)] = [
            ("delete", [:], "delete"),
            ("mute", ["index": .int(1)], "mute"),
        ]

        for (command, params, expected) in cases {
            let result = await TrackDispatcher.handle(
                command: command,
                params: params,
                router: router,
                cache: cache
            )
            XCTAssertTrue(result.isError == true)
            XCTAssertTrue(resultText(result).contains(expected))
        }

        let mixerResult = await MixerDispatcher.handle(
            command: "set_volume",
            params: ["track": .int(1)],
            router: router,
            cache: cache
        )
        XCTAssertTrue(mixerResult.isError == true)

        let transportResult = await TransportDispatcher.handle(
            command: "set_tempo",
            params: [:],
            router: router,
            cache: cache
        )
        XCTAssertTrue(transportResult.isError == true)

        let midiResult = await MIDIDispatcher.handle(
            command: "send_note",
            params: [:],
            router: router,
            cache: cache
        )
        XCTAssertTrue(midiResult.isError == true)

        let operations = await channel.operationsSnapshot()
        XCTAssertEqual(operations, [])
    }

    func testImportRejectsMissingPathBeforeAnyMutation() async {
        let channel = RecordingChannel(id: .cgEvent)
        let router = ChannelRouter()
        await router.register(channel)

        let result = await ProjectDispatcher.handle(
            command: "import_midi_bridge",
            params: [:],
            router: router,
            cache: StateCache()
        )

        XCTAssertTrue(result.isError == true)
        XCTAssertTrue(resultText(result).contains("path"))
        let operations = await channel.operationsSnapshot()
        XCTAssertEqual(operations, [])
    }

    private func makeTemporarySourceFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logic-pro-mcp-\(UUID().uuidString).mid")
        try Data([0x4D, 0x54, 0x68, 0x64]).write(to: url, options: .atomic)
        return url
    }

    private func freshSingleSelection() -> SelectionState {
        SelectionState(
            selectedRegionIDs: ["region-0"],
            selectedRegionNames: ["Source"],
            selectedRegionCount: 1,
            lastUpdated: Date()
        )
    }

    private func resultText(_ result: CallTool.Result) -> String {
        for content in result.content {
            if case let .text(text, _, _) = content {
                return text
            }
        }
        return ""
    }
}

private actor RecordingChannel: Channel {
    nonisolated let id: ChannelID
    private var operations: [String] = []

    init(id: ChannelID) {
        self.id = id
    }

    func start() async throws {}

    func stop() async {}

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        operations.append(operation)
        return .success("{\"recorded\":true}")
    }

    func healthCheck() async -> ChannelHealth {
        .healthy(detail: "test channel")
    }

    func operationsSnapshot() -> [String] {
        operations
    }
}
