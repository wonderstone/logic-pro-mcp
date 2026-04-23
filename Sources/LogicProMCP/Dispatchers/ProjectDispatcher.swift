import ApplicationServices
import Foundation
import MCP

struct ProjectDispatcher {
    static let tool = Tool(
        name: "logic_project",
        description: """
            Project lifecycle in Logic Pro. \
            Commands: new, open, save, save_as, close, bounce, silent_bounce, export_selected_midi_bridge, import_midi_bridge, replace_selected_region_midi_bridge, launch, quit. \
            Params by command: \
            open -> { path: String }; \
            save_as -> { path: String }; \
            bounce -> {} (opens bounce dialog); \
            silent_bounce -> { filename?: String } (automated bounce to WAV, returns file path); \
                export_selected_midi_bridge -> { output_path?: String } (prepares a human-confirmed MIDI export handoff for the current selection; does not press Save automatically); \
                import_midi_bridge -> { path: String } (resets the playhead to 1.1.1.1, then imports a MIDI file into the current project); \
                replace_selected_region_midi_bridge -> { path: String } (deletes current selection, resets the playhead to 1.1.1.1, then imports MIDI file).
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Project command to execute"),
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
        case "new":
            let result = await router.route(operation: "project.new")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "open":
            let path = params["path"]?.stringValue ?? ""
            guard !path.isEmpty else {
                return CallTool.Result(content: [.text("open requires 'path' param")], isError: true)
            }
            let result = await router.route(
                operation: "project.open",
                params: ["path": path]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "save":
            let result = await router.route(operation: "project.save")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "save_as":
            let path = params["path"]?.stringValue ?? ""
            guard !path.isEmpty else {
                return CallTool.Result(content: [.text("save_as requires 'path' param")], isError: true)
            }
            let result = await router.route(
                operation: "project.save_as",
                params: ["path": path]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "close":
            let result = await router.route(operation: "project.close")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "bounce":
            let result = await router.route(operation: "project.bounce")
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "silent_bounce":
            let filename = params["filename"]?.stringValue ?? "bounce_output"
            return await silentBounce(filename: filename)

        case "export_selected_midi_bridge":
            let outputPath = params["output_path"]?.stringValue
            return await exportSelectedMIDI(outputPath: outputPath, cache: cache)

        case "import_midi_bridge":
            let path = params["path"]?.stringValue ?? ""
            guard !path.isEmpty else {
                return CallTool.Result(content: [.text("import_midi_bridge requires 'path' param")], isError: true)
            }
            return await importMIDI(path: path)

        case "replace_selected_region_midi_bridge":
            let path = params["path"]?.stringValue ?? ""
            guard !path.isEmpty else {
                return CallTool.Result(content: [.text("replace_selected_region_midi_bridge requires 'path' param")], isError: true)
            }
            let deleteResult = await router.route(operation: "edit.delete")
            guard deleteResult.isSuccess else {
                return CallTool.Result(content: [.text("Failed to delete current selection before import: \(deleteResult.message)")], isError: true)
            }
            return await importMIDI(path: path, replaceMode: true)

        case "launch":
            if ProcessUtils.isLogicProRunning {
                return CallTool.Result(content: [.text("Logic Pro is already running")], isError: false)
            }
            let script = "tell application \"Logic Pro\" to activate"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            do {
                try process.run()
                process.waitUntilExit()
                return CallTool.Result(content: [.text("Logic Pro launched")], isError: false)
            } catch {
                return CallTool.Result(content: [.text("Failed to launch Logic Pro: \(error)")], isError: true)
            }

        case "quit":
            if !ProcessUtils.isLogicProRunning {
                return CallTool.Result(content: [.text("Logic Pro is not running")], isError: false)
            }
            let script = "tell application \"Logic Pro\" to quit"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            do {
                try process.run()
                process.waitUntilExit()
                return CallTool.Result(content: [.text("Logic Pro quit")], isError: false)
            } catch {
                return CallTool.Result(content: [.text("Failed to quit Logic Pro: \(error)")], isError: true)
            }

        default:
            return CallTool.Result(
                content: [.text("Unknown project command: \(command). Available: new, open, save, save_as, close, bounce, silent_bounce, export_selected_midi_bridge, import_midi_bridge, replace_selected_region_midi_bridge, launch, quit")],
                isError: true
            )
        }
    }

    // MARK: - Silent Bounce

    /// Automated bounce: opens bounce dialog, sets WAVE format, sets filename, clicks Bounce.
    /// Uses osascript subprocess (not NSAppleScript) to ensure TCC/Apple Events permissions work.
    private static func silentBounce(filename: String) async -> CallTool.Result {
        let escaped = filename.replacingOccurrences(of: "\"", with: "\\\"")
        let processName = ServerConfig.logicProProcessName.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Logic Pro" to activate
        delay 0.5

        tell application "System Events"
            tell process "\(processName)"

                -- Step 1: Open Bounce dialog via menu (with retry)
                set menuClicked to false
                repeat 3 times
                    try
                        tell menu bar 1
                            tell menu bar item "File"
                                tell menu 1
                                    tell menu item "Bounce"
                                        tell menu 1
                                            click last menu item
                                        end tell
                                    end tell
                                end tell
                            end tell
                        end tell
                        set menuClicked to true
                        exit repeat
                    on error
                        delay 1.0
                    end try
                end repeat

                if not menuClicked then
                    return "ERROR:Could not click Bounce menu item"
                end if

                delay 2.0

                -- Step 2: Wait for Bounce dialog to appear (increased timeout)
                set dialogFound to false
                repeat 30 times
                    try
                        set w to window 1
                        set wName to name of w as text
                        if wName contains "Bounce" then
                            set dialogFound to true
                            exit repeat
                        end if
                    end try
                    delay 0.5
                end repeat

                if not dialogFound then
                    return "ERROR:Bounce dialog did not appear"
                end if

                -- Step 3: Params dialog \u{2014} ensure Wave format, click OK
                set bounceWin to window 1
                set hasOK to false
                try
                    set okBtn to button "OK" of bounceWin
                    set hasOK to true
                end try

                if hasOK then
                    try
                        set allPopups to every pop up button of (entire contents of bounceWin)
                        repeat with p in allPopups
                            try
                                set pVal to value of p as text
                                if pVal is "AIFF" or pVal is "CAF" then
                                    click p
                                    delay 0.3
                                    try
                                        click menu item "Wave" of menu 1 of p
                                    on error
                                        try
                                            click menu item "WAVE" of menu 1 of p
                                        end try
                                    end try
                                    delay 0.3
                                end if
                            end try
                        end repeat
                    end try

                    click button "OK" of bounceWin
                    delay 1.5
                end if

                -- Step 4: Wait for save dialog (has Bounce button)
                set saveReady to false
                repeat 15 times
                    try
                        set w to window 1
                        set bb to button "Bounce" of w
                        set saveReady to true
                        exit repeat
                    end try
                    delay 0.5
                end repeat

                if not saveReady then
                    return "ERROR:Save dialog did not appear"
                end if

                -- Step 5: Set filename
                set value of text field 1 of window 1 to "\(escaped)"
                delay 0.3

                -- Step 6: Click Bounce
                click button "Bounce" of window 1

                -- Step 7: Wait for bounce to complete (dialog closes)
                set bounceComplete to false
                repeat 120 times
                    delay 0.5
                    try
                        set w to window 1
                        set wName to name of w as text
                        if wName does not contain "Bounce" then
                            set bounceComplete to true
                            exit repeat
                        end if
                    on error
                        set bounceComplete to true
                        exit repeat
                    end try
                end repeat

                if bounceComplete then
                    return "SUCCESS"
                else
                    return "ERROR:Bounce timed out"
                end if

            end tell
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if output.hasPrefix("ERROR:") {
                let errorMsg = String(output.dropFirst(6))
                return CallTool.Result(
                    content: [.text("{\"error\":\"\(errorMsg)\"}")],
                    isError: true
                )
            }

            // Build the expected file path
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            let bouncesDir = "\(homeDir)/Music/Logic/Bounces"
            let filePath = "\(bouncesDir)/\(filename).wav"

            // Check if file exists
            let fileExists = FileManager.default.fileExists(atPath: filePath)

            let json = """
            {"success":true,"filename":"\(filename).wav","path":"\(filePath)","exists":\(fileExists)}
            """
            return CallTool.Result(content: [.text(json)], isError: false)

        } catch {
            return CallTool.Result(
                content: [.text("{\"error\":\"Failed to run osascript: \(error)\"}")],
                isError: true
            )
        }
    }

    private static func exportSelectedMIDI(
        outputPath: String?,
        cache: StateCache
    ) async -> CallTool.Result {
        let requestedURL: URL
        if let outputPath, !outputPath.isEmpty {
            requestedURL = URL(fileURLWithPath: outputPath)
        } else {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("logic-pro-mcp-midi-exports", isDirectory: true)
            requestedURL = directory.appendingPathComponent("logic_selection_\(timestampString()).mid")
        }

        let directoryURL = requestedURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            return CallTool.Result(content: [.text("{\"error\":\"Failed to create export directory: \(escapeJSON(error.localizedDescription))\"}")], isError: true)
        }

        let selection = await cache.getSelection()
        let project = await cache.getProject()
        let receipt = MIDIBridgeExportState(
            status: "manual_required",
            exportPath: requestedURL.path,
            sourceProjectName: project.name,
            selectedRegionCount: selection.selectedRegionCount,
            selectedRegionNames: selection.selectedRegionNames,
            exportedAt: Date()
        )
        await cache.updateLastMIDIBridgeExport(receipt)

        let json = """
        {"success":false,"status":"manual_required","requestedPath":"\(escapeJSON(requestedURL.path))","selectedRegionCount":\(selection.selectedRegionCount),"selectedRegionNames":\(jsonArray(selection.selectedRegionNames)),"error":"Human must complete the Logic Pro Save MIDI dialog manually.","recommended_next_step":"In Logic Pro, export the current selection as MIDI and save it to the requested path, then retry the read or patch step with the saved file.","scope":"selected_region_only"}
        """
        return CallTool.Result(content: [.text(json)], isError: false)
    }

    private static func importMIDI(path: String, replaceMode: Bool = false) async -> CallTool.Result {
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CallTool.Result(content: [.text("{\"error\":\"MIDI file not found: \(escapeJSON(fileURL.path))\"}")], isError: true)
        }

        let resetResult = resetImportCursorToProjectStart()
        if resetResult.exitCode != 0 || resetResult.output.hasPrefix("ERROR:") {
            let resetMessage = resetResult.output.hasPrefix("ERROR:")
                ? String(resetResult.output.dropFirst(6))
                : (resetResult.stderr.isEmpty ? resetResult.output : resetResult.stderr)
            return CallTool.Result(content: [.text("{\"error\":\"Failed to reset import cursor: \(escapeJSON(resetMessage))\"}")], isError: true)
        }

        let finderPasteResult = importMIDIViaFinderPaste(path: fileURL.path)
        if finderPasteResult.exitCode == 0, !finderPasteResult.output.hasPrefix("ERROR:") {
            let json = """
            {"success":true,"path":"\(escapeJSON(fileURL.path))","mode":"\(replaceMode ? "replace_selected_region" : "import_only")","importAnchor":"1.1.1.1","importMethod":"finder_copy_paste","verification":"manual_or_followup_read_required"}
            """
            return CallTool.Result(content: [.text(json)], isError: false)
        }

        let dialogResult = importMIDIViaDialog(path: fileURL.path)
        if dialogResult.output.hasPrefix("ERROR:") {
            let dialogMessage = String(dialogResult.output.dropFirst(6))
            let finderMessage = finderPasteResult.output.hasPrefix("ERROR:")
                ? String(finderPasteResult.output.dropFirst(6))
                : (finderPasteResult.stderr.isEmpty ? finderPasteResult.output : finderPasteResult.stderr)
            return CallTool.Result(content: [.text("{\"error\":\"MIDI import failed via finder_copy_paste and dialog fallback. finder_copy_paste=\(escapeJSON(finderMessage)); dialog=\(escapeJSON(dialogMessage))\"}")], isError: true)
        }
        if dialogResult.exitCode != 0 {
            let finderMessage = finderPasteResult.output.hasPrefix("ERROR:")
                ? String(finderPasteResult.output.dropFirst(6))
                : (finderPasteResult.stderr.isEmpty ? finderPasteResult.output : finderPasteResult.stderr)
            let dialogMessage = dialogResult.stderr.isEmpty ? dialogResult.output : dialogResult.stderr
            return CallTool.Result(content: [.text("{\"error\":\"MIDI import failed via finder_copy_paste and dialog fallback. finder_copy_paste=\(escapeJSON(finderMessage)); dialog=\(escapeJSON(dialogMessage))\"}")], isError: true)
        }

        let json = """
        {"success":true,"path":"\(escapeJSON(fileURL.path))","mode":"\(replaceMode ? "replace_selected_region" : "import_only")","importAnchor":"1.1.1.1","importMethod":"dialog_fallback","verification":"manual_or_followup_read_required"}
        """
        return CallTool.Result(content: [.text(json)], isError: false)
    }

    private static func importMIDIViaFinderPaste(path: String) -> OsaScriptResult {
        let fileText = appleScriptEscaped(path)
        let processName = ServerConfig.logicProProcessName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        set midiFile to POSIX file "\(fileText)"

        tell application "Finder"
            activate
            reveal midiFile
            delay 0.6
            select midiFile
        end tell

        delay 0.6

        tell application "System Events"
            keystroke "c" using {command down}
        end tell

        delay 0.4

        tell application "Logic Pro" to activate
        delay 0.8

        tell application "System Events"
            tell process "\(processName)"
                keystroke "v" using {command down}
                delay 1.0
            end tell
        end tell
        """
        return runOsaScript(source: script)
    }

    private static func importMIDIViaDialog(path: String) -> OsaScriptResult {
        let processName = ServerConfig.logicProProcessName.replacingOccurrences(of: "\"", with: "\\\"")
        let fileText = appleScriptEscaped(path)
        let script = """
        tell application "Logic Pro" to activate
        delay 0.4

        tell application "System Events"
            tell process "\(processName)"
                click menu item "MIDI File…" of menu "Import" of menu item "Import" of menu "File" of menu bar item "File" of menu bar 1
                delay 1.0

                set dialogReady to false
                repeat 40 times
                    try
                        if exists button "Open" of window 1 then
                            set dialogReady to true
                            exit repeat
                        end if
                    end try
                    delay 0.25
                end repeat

                if not dialogReady then
                    return "ERROR:Import MIDI dialog did not appear"
                end if

                keystroke "G" using {command down, shift down}
                delay 0.5
                keystroke "\(fileText)"
                delay 0.2
                key code 36
                delay 0.8

                try
                    click button "Open" of window 1
                on error
                    try
                        click button "Open" of sheet 1 of window 1
                    on error
                        return "ERROR:Could not confirm MIDI import dialog"
                    end try
                end try
            end tell
        end tell
        """
        return runOsaScript(source: script)
    }

    private static func resetImportCursorToProjectStart() -> OsaScriptResult {
        let processName = ServerConfig.logicProProcessName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Logic Pro" to activate
        delay 0.3

        tell application "System Events"
            tell process "\(processName)"
                keystroke "/"
                delay 0.3
                keystroke "1.1.1.1"
                delay 0.1
                key code 36
                delay 0.6
            end tell
        end tell
        """
        return runOsaScript(source: script)
    }

    private struct OsaScriptResult {
        let output: String
        let stderr: String
        let exitCode: Int32
    }

    private struct DialogFinalizeResult {
        let success: Bool
        let message: String
    }

    private static func runOsaScript(source: String) -> OsaScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return OsaScriptResult(output: "", stderr: error.localizedDescription, exitCode: 1)
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return OsaScriptResult(output: output, stderr: error, exitCode: process.terminationStatus)
    }

    private static func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func errorJSONResult(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text("{\"error\":\"\(escapeJSON(message))\"}")], isError: true)
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapeJSON(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func jsonArray(_ values: [String]) -> String {
        let encoded = values.map { "\"\(escapeJSON($0))\"" }.joined(separator: ",")
        return "[\(encoded)]"
    }
}