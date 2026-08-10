import Foundation
import MCP

struct ProjectDispatcher {
    static let tool = Tool(
        name: "logic_project",
        description: """
            Project lifecycle in Logic Pro. \
            Commands: \(CommandRegistry.commandList(for: "logic_project")). \
            Params by command: \
            open -> { path: String }; \
            bounce -> {} (opens bounce dialog); \
            silent_bounce -> { filename?: String } (automated bounce to WAV, returns file path); \
                export_selected_midi_bridge -> { output_path?: String } (prepares a human-confirmed MIDI export handoff for the current selection; does not press Save automatically); \
                import_midi_bridge -> { path: String } (dispatches a MIDI import after resetting the playhead; result remains unverified); \
                replace_selected_region_midi_bridge -> { path: String } (preflight only; automatic replacement is manual-required until rollback and postcondition proof exist); \
                bind_disposable_project -> { path: String, sha256: String, expires_at: String } (local expiring path/digest binding; does not open or mutate Logic); \
                verify_keeper_digest -> { path: String, sha256?: String, native_source_basename?: String } (read-only separate keeper digest receipt); \
                preview_ace_audio_placement -> { handoff_json: String } or explicit plan fields (read-only preview); \
                authorize_ace_audio_placement -> { plan_id: String, confirmation_id: String, confirmed_by: String, confirmed_at: String }; \
                place_ace_audio -> { plan_id: String } (new-track-only guarded dispatch with fresh readback); \
                tag_ace_audio_after_import -> { exact prior single-dispatch proof plus source/tag/count/confirmation fields } (tag-only continuation; never imports); \
                verify_ace_audio_placement -> { target_project_path: String, asset_path: String, asset_sha256: String, keeper_digest_receipt_json: String } (fresh-process source/identity/placement readback only); \
                rollback_ace_audio_placement -> { plan_id: String, rollback_confirmation_id: String, rollback_confirmed_by: String, rollback_confirmed_at: String } (bounded created-layer rollback only); \
                adopt_ace_audio_delta -> { exact P5G delta spec plus confirmation fields } (no import; removes only the exact named _1 duplicate, tags the remaining source, saves, and proves AX geometry); \
                verify_ace_audio_delta -> { exact P5G delta spec } (fresh-process tag/source/placement verification only); \
                rollback_ace_audio_delta -> { exact P5G delta spec } (manual-required tag-bounded rollback evidence; no automatic delete).
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
            if let error = CommandRegistry.validationError(tool: "logic_project", command: command, params: params) {
                return CallTool.Result(content: [.text(error)], isError: true)
            }
            let path = params["path"]?.stringValue ?? ""
            let result = await router.route(
                operation: "project.open",
                params: ["path": path]
            )
            return CallTool.Result(content: [.text(result.message)], isError: !result.isSuccess)

        case "save":
            let result = await router.route(operation: "project.save")
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
            if let error = CommandRegistry.validationError(tool: "logic_project", command: command, params: params) {
                let snapshot = await cache.authoritySnapshot()
                return operationResult(
                    operation: command,
                    parameters: [:],
                    status: "rejected",
                    mutation: "not_started",
                    verification: "unavailable",
                    error: error,
                    preconditions: operationPreconditions(
                        snapshot: snapshot,
                        sourceValid: false,
                        failures: [error]
                    ),
                    projectIdentity: snapshot.projectIdentity,
                    generation: snapshot.generation
                )
            }
            let path = params["path"]?.stringValue ?? ""
            return await importMIDI(path: path, cache: cache)

        case "replace_selected_region_midi_bridge":
            if let error = CommandRegistry.validationError(tool: "logic_project", command: command, params: params) {
                let snapshot = await cache.authoritySnapshot()
                return operationResult(
                    operation: command,
                    parameters: [:],
                    status: "rejected",
                    mutation: "not_started",
                    verification: "unavailable",
                    error: error,
                    preconditions: operationPreconditions(
                        snapshot: snapshot,
                        sourceValid: false,
                        failures: [error]
                    ),
                    projectIdentity: snapshot.projectIdentity,
                    generation: snapshot.generation
                )
            }
            let path = params["path"]?.stringValue ?? ""
            if let sourceError = validateMIDIInput(path: path) {
                let snapshot = await cache.authoritySnapshot()
                return operationResult(
                    operation: command,
                    parameters: ["path": path],
                    status: "rejected",
                    mutation: "not_started",
                    verification: "unavailable",
                    error: sourceError,
                    preconditions: operationPreconditions(
                        snapshot: snapshot,
                        sourcePath: path,
                        sourceValid: false,
                        failures: [sourceError]
                    ),
                    projectIdentity: snapshot.projectIdentity,
                    generation: snapshot.generation,
                    sourcePath: path
                )
            }
            let authority = await cache.selectionAuthority()
            let statusMessage = authority.authorized
                ? "Automatic replacement is disabled because rollback and reliable postcondition verification are unavailable."
                : "Automatic replacement was not authorized: \(authority.message)"
            return operationResult(
                operation: command,
                parameters: ["path": path],
                status: "manual_required",
                mutation: "not_started",
                verification: "unavailable",
                error: statusMessage,
                preconditions: operationPreconditions(
                    authority: authority,
                    sourcePath: path,
                    sourceValid: true
                ),
                projectIdentity: authority.projectIdentity,
                generation: authority.generation,
                sourcePath: path,
                selectedRegionID: authority.selectedRegionIDs.first
            )

        case "bind_disposable_project", "verify_keeper_digest", "preview_ace_audio_placement", "authorize_ace_audio_placement", "place_ace_audio", "tag_ace_audio_after_import", "verify_ace_audio_placement", "rollback_ace_audio_placement", "adopt_ace_audio_delta", "verify_ace_audio_delta", "rollback_ace_audio_delta":
            return await ACEAudioPlacementCoordinator.handle(
                command: command,
                params: params,
                router: router,
                cache: cache
            )

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
            let available = CommandRegistry.commandList(for: "logic_project")
            return CallTool.Result(
                content: [.text("Unknown project command: \(command). Available: \(available)")],
                isError: true
            )
        }
    }

    // MARK: - Silent Bounce

    /// Automated bounce: opens bounce dialog, sets WAVE format, sets filename, clicks Bounce.
    /// Uses osascript subprocess (not NSAppleScript) to ensure TCC/Apple Events permissions work.
    private static func silentBounce(filename: String) async -> CallTool.Result {
        guard let logicPID = ProcessUtils.logicProPID() else {
            return CallTool.Result(content: [.text("{\"error\":\"Logic Pro target process is unavailable; no bounce started\"}")], isError: true)
        }
        let escaped = filename.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "System Events"
            tell first process whose unix id is \(logicPID)
                set frontmost to true
                delay 0.5

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
                set bounceWin to missing value
                repeat 30 times
                    try
                        repeat with candidate in windows
                            set candidateWindow to contents of candidate
                            if (name of candidateWindow as text) contains "Bounce" then
                                set bounceWin to candidateWindow
                                set dialogFound to true
                                exit repeat
                            end if
                        end repeat
                        if dialogFound then exit repeat
                    end try
                    delay 0.5
                end repeat

                if not dialogFound then
                    return "ERROR:Bounce dialog did not appear"
                end if

                -- Step 3: Params dialog \u{2014} ensure Wave format, click OK
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
                else
                    -- Logic's current Bounce panel can expose its controls
                    -- only through a custom split group. Return is its
                    -- default OK action; do not wait for a direct AX button
                    -- that is not present.
                    key code 36
                    delay 1.5
                end if

                -- Step 4: Wait for save dialog (has Bounce button)
                set saveReady to false
                set saveWin to missing value
                set saveField to missing value
                set saveButton to missing value
                repeat 15 times
                    try
                        repeat with candidate in windows
                            set candidateWindow to contents of candidate
                            if (name of candidateWindow as text) contains "Bounce" then
                                try
                                    set splitGroup to first UI element of candidateWindow
                                    repeat with element in UI elements of splitGroup
                                        set candidateElement to contents of element
                                        set candidateRole to role of candidateElement as text
                                        if candidateRole is "AXTextField" then
                                            try
                                                if (name of candidateElement as text) is "Save As:" then
                                                    set saveField to candidateElement
                                                end if
                                            end try
                                        else if candidateRole is "AXButton" then
                                            try
                                                if (name of candidateElement as text) is "Bounce" then
                                                    set saveButton to candidateElement
                                                end if
                                            end try
                                        end if
                                    end repeat
                                    if saveField is not missing value and saveButton is not missing value then
                                        set saveWin to candidateWindow
                                        set saveReady to true
                                        exit repeat
                                    end if
                                end try
                            end if
                        end repeat
                        if saveReady then exit repeat
                    end try
                    delay 0.5
                end repeat

                if not saveReady then
                    return "ERROR:Save dialog did not appear"
                end if

                -- Step 5: Set filename
                set value of saveField to "\(escaped)"
                delay 0.3

                -- Step 6: Click Bounce
                click saveButton

                -- Step 7: Wait for bounce to complete (dialog closes)
                set bounceComplete to false
                repeat 120 times
                    delay 0.5
                    set bounceWindowStillOpen to false
                    repeat with candidate in windows
                        try
                            if (name of candidate as text) contains "Bounce" then
                                set bounceWindowStillOpen to true
                                exit repeat
                            end if
                        end try
                    end repeat
                    if not bounceWindowStillOpen then
                        set bounceComplete to true
                        exit repeat
                    end if
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
        let selection = await cache.getSelection()
        let readback = await cache.selectionReadback()
        if !readback.authorized {
            let snapshot = await cache.authoritySnapshot(at: readback.checkedAt)
            return operationResult(
                operation: "export_selected_midi_bridge",
                parameters: outputPath.map { ["output_path": $0] } ?? [:],
                status: "rejected",
                mutation: "not_started",
                verification: "unavailable",
                error: "export_selected_midi_bridge \(readback.message)",
                preconditions: operationPreconditions(authority: readback, snapshot: snapshot),
                projectIdentity: readback.projectIdentity,
                generation: readback.generation
            )
        }

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
            let snapshot = await cache.authoritySnapshot(at: readback.checkedAt)
            let message = "Failed to create export directory: \(error.localizedDescription)"
            return operationResult(
                operation: "export_selected_midi_bridge",
                parameters: outputPath.map { ["output_path": $0] } ?? [:],
                status: "rejected",
                mutation: "not_started",
                verification: "unavailable",
                error: message,
                preconditions: operationPreconditions(
                    authority: readback,
                    snapshot: snapshot,
                    sourcePath: requestedURL.path,
                    sourceValid: false,
                    failures: [message]
                ),
                projectIdentity: snapshot.projectIdentity,
                generation: snapshot.generation
            )
        }

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

        let snapshot = await cache.authoritySnapshot(at: readback.checkedAt)
        let message = "Human must complete the Logic Pro Save MIDI dialog manually."
        return operationResult(
            operation: "export_selected_midi_bridge",
            parameters: ["output_path": requestedURL.path],
            status: "manual_required",
            mutation: "not_started",
            verification: "unavailable",
            error: message,
            preconditions: operationPreconditions(
                authority: readback,
                snapshot: snapshot,
                sourcePath: requestedURL.path,
                sourceValid: true
            ),
            projectIdentity: snapshot.projectIdentity,
            generation: snapshot.generation,
            requestedPath: requestedURL.path,
            selectedRegionCount: selection.selectedRegionCount,
            selectedRegionNames: selection.selectedRegionNames,
            recommendedNextStep: "In Logic Pro, export the current selection as MIDI and save it to the requested path, then retry the read or patch step with the saved file.",
            scope: "selected_region_only"
        )
    }

    private static func importMIDI(path: String, cache: StateCache) async -> CallTool.Result {
        let fileURL = URL(fileURLWithPath: path)
        let initialSnapshot = await cache.authoritySnapshot()
        if let sourceError = validateMIDIInput(path: path) {
            return operationResult(
                operation: "import_midi_bridge",
                parameters: ["path": path],
                status: "rejected",
                mutation: "not_started",
                verification: "unavailable",
                error: sourceError,
                preconditions: operationPreconditions(
                    snapshot: initialSnapshot,
                    sourcePath: path,
                    sourceValid: false,
                    failures: [sourceError]
                ),
                projectIdentity: initialSnapshot.projectIdentity,
                generation: initialSnapshot.generation,
                path: path
            )
        }

        let projectAuthority = await cache.projectAuthority()
        guard projectAuthority.authorized else {
            return operationResult(
                operation: "import_midi_bridge",
                parameters: ["path": path],
                status: "rejected",
                mutation: "not_started",
                verification: "unavailable",
                error: projectAuthority.message,
                preconditions: operationPreconditions(
                    authority: projectAuthority,
                    sourcePath: path,
                    sourceValid: true
                ),
                projectIdentity: projectAuthority.projectIdentity,
                generation: projectAuthority.generation,
                path: path
            )
        }

        let resetResult = resetImportCursorToProjectStart()
        if resetResult.exitCode != 0 || resetResult.output.hasPrefix("ERROR:") {
            let resetMessage = resetResult.output.hasPrefix("ERROR:")
                ? String(resetResult.output.dropFirst(6))
                : (resetResult.stderr.isEmpty ? resetResult.output : resetResult.stderr)
            let message = "Failed to reset import cursor: \(resetMessage)"
            return operationResult(
                operation: "import_midi_bridge",
                parameters: ["path": path],
                status: "failed",
                mutation: "not_started",
                verification: "unavailable",
                error: message,
                preconditions: operationPreconditions(
                    authority: projectAuthority,
                    sourcePath: path,
                    sourceValid: true,
                    failures: [message]
                ),
                projectIdentity: projectAuthority.projectIdentity,
                generation: projectAuthority.generation,
                path: path
            )
        }

        let finderPasteResult = importMIDIViaFinderPaste(path: fileURL.path)
        if finderPasteResult.exitCode == 0, !finderPasteResult.output.hasPrefix("ERROR:") {
            let message = "MIDI import was dispatched, but resulting region identity, position, and source could not be verified; do not continue automatically."
            return operationResult(
                operation: "import_midi_bridge",
                parameters: ["path": path],
                status: "dispatched_unverified",
                mutation: "dispatched",
                verification: "not_verified",
                error: message,
                preconditions: operationPreconditions(
                    authority: projectAuthority,
                    sourcePath: path,
                    sourceValid: true
                ),
                projectIdentity: projectAuthority.projectIdentity,
                generation: projectAuthority.generation,
                path: path,
                mode: "import_only",
                importAnchor: "1.1.1.1",
                importMethod: "finder_copy_paste"
            )
        }

        let dialogResult = importMIDIViaDialog(path: fileURL.path)
        if dialogResult.output.hasPrefix("ERROR:") {
            let dialogMessage = String(dialogResult.output.dropFirst(6))
            let finderMessage = finderPasteResult.output.hasPrefix("ERROR:")
                ? String(finderPasteResult.output.dropFirst(6))
                : (finderPasteResult.stderr.isEmpty ? finderPasteResult.output : finderPasteResult.stderr)
            let message = "MIDI import failed via finder_copy_paste and dialog fallback. finder_copy_paste=\(finderMessage); dialog=\(dialogMessage)"
            return operationResult(
                operation: "import_midi_bridge",
                parameters: ["path": path],
                status: "failed",
                mutation: "dispatched",
                verification: "unavailable",
                error: message,
                preconditions: operationPreconditions(
                    authority: projectAuthority,
                    sourcePath: path,
                    sourceValid: true,
                    failures: [message]
                ),
                projectIdentity: projectAuthority.projectIdentity,
                generation: projectAuthority.generation,
                path: path,
                mode: "import_only"
            )
        }
        if dialogResult.exitCode != 0 {
            let finderMessage = finderPasteResult.output.hasPrefix("ERROR:")
                ? String(finderPasteResult.output.dropFirst(6))
                : (finderPasteResult.stderr.isEmpty ? finderPasteResult.output : finderPasteResult.stderr)
            let dialogMessage = dialogResult.stderr.isEmpty ? dialogResult.output : dialogResult.stderr
            let message = "MIDI import failed via finder_copy_paste and dialog fallback. finder_copy_paste=\(finderMessage); dialog=\(dialogMessage)"
            return operationResult(
                operation: "import_midi_bridge",
                parameters: ["path": path],
                status: "failed",
                mutation: "dispatched",
                verification: "unavailable",
                error: message,
                preconditions: operationPreconditions(
                    authority: projectAuthority,
                    sourcePath: path,
                    sourceValid: true,
                    failures: [message]
                ),
                projectIdentity: projectAuthority.projectIdentity,
                generation: projectAuthority.generation,
                path: path,
                mode: "import_only"
            )
        }

        let message = "MIDI import was dispatched, but resulting region identity, position, and source could not be verified; do not continue automatically."
        return operationResult(
            operation: "import_midi_bridge",
            parameters: ["path": path],
            status: "dispatched_unverified",
            mutation: "dispatched",
            verification: "not_verified",
            error: message,
            preconditions: operationPreconditions(
                authority: projectAuthority,
                sourcePath: path,
                sourceValid: true
            ),
            projectIdentity: projectAuthority.projectIdentity,
            generation: projectAuthority.generation,
            path: path,
            mode: "import_only",
            importAnchor: "1.1.1.1",
            importMethod: "dialog_fallback"
        )
    }

    /// Validate every source-file precondition before a Logic-facing import or replace
    /// flow can perform any UI mutation.
    private static func validateMIDIInput(path: String) -> String? {
        let fileURL = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return "MIDI source file not found: \(fileURL.path); no mutation started"
        }
        guard fileManager.isReadableFile(atPath: fileURL.path) else {
            return "MIDI source file is not readable: \(fileURL.path); no mutation started"
        }
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return "MIDI source path is not a regular file: \(fileURL.path); no mutation started"
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                return "MIDI source file is empty: \(fileURL.path); no mutation started"
            }
        } catch {
            return "MIDI source file cannot be inspected: \(fileURL.path); no mutation started"
        }
        return nil
    }

    private static func operationResult(
        operation: String,
        parameters: [String: String],
        status: String,
        mutation: String,
        verification: String,
        success: Bool = false,
        error: String?,
        preconditions: OperationPreconditions,
        projectIdentity: ProjectIdentity,
        generation: UInt64,
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
    ) -> CallTool.Result {
        let receipt = OperationReceipt(
            operation: operation,
            parameters: parameters,
            preconditions: preconditions,
            mutation: mutation,
            verification: verification,
            projectIdentity: projectIdentity,
            generation: generation,
            status: status,
            success: success,
            error: error,
            path: path,
            sourcePath: sourcePath,
            selectedRegionID: selectedRegionID,
            requestedPath: requestedPath,
            selectedRegionCount: selectedRegionCount,
            selectedRegionNames: selectedRegionNames,
            mode: mode,
            importAnchor: importAnchor,
            importMethod: importMethod,
            recommendedNextStep: recommendedNextStep,
            scope: scope
        )
        return CallTool.Result(
            content: [.text(encodeCompactJSON(receipt))],
            isError: !success
        )
    }

    private static func operationPreconditions(
        authority: StateAuthorityCheck? = nil,
        snapshot: CacheAuthoritySnapshot? = nil,
        sourcePath: String? = nil,
        sourceValid: Bool? = nil,
        failures: [String] = []
    ) -> OperationPreconditions {
        let projectIdentity = authority?.projectIdentity ?? snapshot?.projectIdentity ?? .unknown
        let selectedProjectIdentity = authority?.selectionProjectIdentity
            ?? snapshot?.selectionProjectIdentity
            ?? .unknown
        let selectedRegionIDs = authority?.selectedRegionIDs ?? []
        let authorityFailures = authority.map { $0.authorized ? [] : [$0.reasonCode] } ?? []
        let combinedFailures = Array(Set(failures + authorityFailures)).sorted()

        return OperationPreconditions(
            stateAuthority: authority.map { $0.authorized ? "passed" : "rejected" } ?? "not_checked",
            sourcePath: sourcePath,
            sourceValid: sourceValid,
            selectionFresh: authority?.selectionFresh ?? snapshot.map { $0.selectionAgeSeconds <= $0.selectionMaximumAgeSeconds },
            selectionAgeSeconds: authority?.observedAgeSeconds ?? snapshot?.selectionAgeSeconds,
            maximumAgeSeconds: authority?.maximumAgeSeconds ?? snapshot?.selectionMaximumAgeSeconds,
            selectedRegionCount: authority?.selectedRegionCount,
            selectedRegionIDs: selectedRegionIDs,
            selectedRegionIdentityStability: authority?.selectedRegionIdentityStability
                ?? snapshot?.selectionIdentityStability
                ?? .unknown,
            projectIdentity: projectIdentity,
            selectionProjectIdentity: selectedProjectIdentity,
            projectIdentityKnown: projectIdentity.isKnown,
            projectIdentityMatches: authority?.projectIdentityMatches,
            generationCompatible: authority?.generationCompatible,
            cacheGeneration: authority?.generation ?? snapshot?.generation ?? 0,
            stateGeneration: authority?.selectionGeneration ?? snapshot?.selectionGeneration ?? 0,
            failures: combinedFailures
        )
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

}
