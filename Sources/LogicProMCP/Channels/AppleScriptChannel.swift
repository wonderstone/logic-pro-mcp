import Foundation
import Darwin

/// Channel that controls Logic Pro via AppleScript.
/// Very narrow scope: app lifecycle operations only (new, open, close project).
/// AppleScript is slow and modal, so it is used only when no better channel exists.
actor AppleScriptChannel: Channel {
    let id: ChannelID = .appleScript

    func start() async throws {
        Log.info("AppleScript channel started", subsystem: "appleScript")
    }

    func stop() async {
        Log.info("AppleScript channel stopped", subsystem: "appleScript")
    }

    func execute(operation: String, params: [String: String]) async -> ChannelResult {
        switch operation {
        case "project.new":
            return await runScript(newProjectScript())

        case "project.open":
            guard let path = params["path"] else {
                return .error("Missing 'path' parameter for project.open")
            }
            return await runScript(openProjectScript(path: path))

        case "project.close":
            let saving = params["saving"] ?? "yes"
            return await runScript(closeProjectScript(saving: saving))

        case "project.save":
            return await runScript(saveProjectScript())

        case "project.import_audio":
            return await importAudio(params: params)

        case "view.toggle_event_list":
            return await runScript(toggleEventListScript())

        // Transport fallbacks (AppleScript is last resort for these)
        case "transport.play":
            return await runScript(transportScript(action: "play"))
        case "transport.stop":
            return await runScript(transportScript(action: "stop"))
        case "transport.record":
            return await runScript(transportScript(action: "record"))
        case "transport.pause":
            return await runScript(transportScript(action: "pause"))

        default:
            return .error("Unsupported AppleScript operation: \(operation)")
        }
    }

    func healthCheck() async -> ChannelHealth {
        guard ProcessUtils.isLogicProRunning else {
            return .unavailable("Logic Pro is not running")
        }
        return .healthy(detail: "AppleScript ready")
    }

    // MARK: - Script execution

    private func runScript(_ source: String) async -> ChannelResult {
        // NSAppleScript must run on the main thread-ish context, but within
        // an actor we are already serialized. The actual execution is synchronous.
        var errorDict: NSDictionary?
        let script = NSAppleScript(source: source)
        let result = script?.executeAndReturnError(&errorDict)

        if let error = errorDict {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            let number = error[NSAppleScript.errorNumber] as? Int ?? -1
            Log.error("AppleScript error \(number): \(message)", subsystem: "appleScript")
            return .error("AppleScript error: \(message)")
        }

        let output = result?.stringValue ?? "OK"
        return .success("{\"result\":\"\(escapeJSON(output))\"}")
    }

    // MARK: - Script templates

    private func newProjectScript() -> String {
        let processName = escapeAppleScript(ServerConfig.logicProProcessName)
        return """
        tell application "Logic Pro"
            activate
            delay 0.5
        end tell
        tell application "System Events"
            tell process "\(processName)"
                click menu item "New..." of menu "File" of menu bar 1
            end tell
        end tell
        """
    }

    private func openProjectScript(path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Logic Pro"
            activate
            open POSIX file "\(escaped)"
        end tell
        """
    }

    private func closeProjectScript(saving: String) -> String {
        let saveClause: String
        switch saving.lowercased() {
        case "no", "false":
            saveClause = "saving no"
        case "ask":
            saveClause = "saving ask"
        default:
            saveClause = "saving yes"
        }
        return """
        tell application "Logic Pro"
            close front document \(saveClause)
        end tell
        """
    }

    private func saveProjectScript() -> String {
        """
        tell application "Logic Pro"
            save front document
        end tell
        """
    }

    private func importAudio(params: [String: String]) async -> ChannelResult {
        guard let logicPID = ProcessUtils.logicProPID() else {
            return .error("Logic Pro target process is unavailable; no mutation started")
        }
        guard let path = params["path"], !path.isEmpty,
              let assetSHA256 = params["asset_sha256"], ACEFileDigest.isSHA256(assetSHA256),
              let operationID = params["operation_id"], !operationID.isEmpty,
              let planID = params["plan_id"], !planID.isEmpty,
              let trackTag = params["track_tag"], !trackTag.isEmpty,
              let regionTag = params["region_tag"], !regionTag.isEmpty,
              let bar = Int(params["bar"] ?? ""), bar >= 1,
              let beat = Double(params["beat"] ?? ""), beat >= 1,
              let tick = Int(params["tick"] ?? ""), tick >= 0,
              let durationBeats = Double(params["duration_beats"] ?? ""), durationBeats > 0,
              let beatsPerBar = Int(params["beats_per_bar"] ?? ""), beatsPerBar >= 1,
              beat <= Double(beatsPerBar) else {
            return .error("project.import_audio requires a complete validated operation, source digest, tags, and bars/beats placement; no mutation started")
        }
        guard FileManager.default.fileExists(atPath: path),
              FileManager.default.isReadableFile(atPath: path) else {
            return .error("Audio source is missing or unreadable; no mutation started")
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
                return .error("Audio source must be a non-empty regular file; no mutation started")
            }
            guard try ACEFileDigest.sha256(at: path) == assetSHA256 else {
                return .error("Audio source digest changed before UI dispatch; no mutation started")
            }
        } catch {
            return .error("Audio source digest could not be verified; no mutation started")
        }
        let startedAt = Date()
        let execution = runBoundedScript(
            importAudioScript(
                path: path,
                trackTag: trackTag,
                regionTag: regionTag,
                operationID: operationID,
                planID: planID,
                bar: bar,
                beat: beat,
                tick: tick,
                durationBeats: durationBeats,
                logicPID: logicPID
            ),
            timeout: ServerConfig.aceAudioUIImportTimeout
        )
        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let detail = execution.output.isEmpty ? execution.stderr : execution.output

        switch execution.status {
        case .completed where execution.exitCode == 0:
            Log.info(
                "ACE stage ui_import completed in \(elapsedMilliseconds)ms; import is dispatched and tagging is a separate stage",
                subsystem: "appleScript"
            )
            return .success(importStageMessage(
                status: "completed",
                outcome: "dispatched",
                elapsedMilliseconds: elapsedMilliseconds,
                detail: detail
            ))
        case .timedOut:
            Log.error(
                "ACE stage ui_import timed out after \(elapsedMilliseconds)ms; import outcome is unknown and must not be retried",
                subsystem: "appleScript"
            )
            return .error(importStageMessage(
                status: "timed_out",
                outcome: "unknown",
                elapsedMilliseconds: elapsedMilliseconds,
                detail: detail.isEmpty ? "osascript child was terminated at the UI-import budget" : detail
            ))
        case .failed:
            let outcome = execution.started ? "unknown" : "not_started"
            Log.error(
                "ACE stage ui_import failed in \(elapsedMilliseconds)ms; outcome=\(outcome)",
                subsystem: "appleScript"
            )
            return .error(importStageMessage(
                status: "failed",
                outcome: outcome,
                elapsedMilliseconds: elapsedMilliseconds,
                detail: detail.isEmpty ? "osascript returned a non-zero status" : detail
            ))
        case .completed:
            // A completed child with a non-zero status is represented as a
            // failed UI stage above; this case only satisfies the exhaustive
            // enum switch for the guarded `where` branch.
            return .error(importStageMessage(
                status: "failed",
                outcome: execution.started ? "unknown" : "not_started",
                elapsedMilliseconds: elapsedMilliseconds,
                detail: detail.isEmpty ? "osascript completed without a zero exit status" : detail
            ))
        }
    }

    private enum BoundedScriptStatus: Sendable {
        case completed
        case timedOut
        case failed
    }

    private struct BoundedScriptExecution: Sendable {
        let status: BoundedScriptStatus
        let started: Bool
        let exitCode: Int32
        let output: String
        let stderr: String
    }

    /// Execute the UI-import script in a killable child process.  A synchronous
    /// NSAppleScript call cannot be bounded by the MCP task, which was the P5J
    /// failure mode.  Killing this child at the stage budget still leaves the
    /// mutation outcome explicitly unknown, so the coordinator stops without a
    /// retry or a tagging/readback continuation.
    private func runBoundedScript(_ source: String, timeout: TimeInterval) -> BoundedScriptExecution {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return BoundedScriptExecution(
                status: .failed,
                started: false,
                exitCode: 1,
                output: "",
                stderr: error.localizedDescription
            )
        }

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(0.75)
            while process.isRunning && Date() < terminateDeadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        if process.isRunning {
            process.waitUntilExit()
        }

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return BoundedScriptExecution(
            status: timedOut ? .timedOut : (process.terminationStatus == 0 ? .completed : .failed),
            started: true,
            exitCode: process.terminationStatus,
            output: output,
            stderr: error
        )
    }

    private func importStageMessage(
        status: String,
        outcome: String,
        elapsedMilliseconds: Int,
        detail: String
    ) -> String {
        let compactDetail = detail
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "stage=\(ACEAudioPlacementContract.importStageUI) status=\(status) outcome=\(outcome) elapsed_ms=\(elapsedMilliseconds) detail=\(compactDetail)"
    }

    private func importAudioScript(
        path: String,
        trackTag: String,
        regionTag: String,
        operationID: String,
        planID: String,
        bar: Int,
        beat: Double,
        tick: Int,
        durationBeats: Double,
        logicPID: pid_t
    ) -> String {
        let escapedPath = escapeAppleScript(path)
        let escapedTrackTag = escapeAppleScript(trackTag)
        let escapedRegionTag = escapeAppleScript(regionTag)
        let escapedOperationID = escapeAppleScript(operationID)
        let escapedPlanID = escapeAppleScript(planID)
        return """
        tell application "System Events"
            tell first process whose unix id is \(logicPID)
                set frontmost to true
                delay 0.4
                -- Set the playhead to the declared bar/beat before creating the
                -- new track. Readback remains the authority for the actual region.
                key code 47
                delay 0.3
                keystroke "\(bar).\(beat).\(tick).1"
                key code 36
                delay 0.5
                -- P4A always creates a new audio track; it never selects an existing
                -- track as a placement target and never deletes or overwrites content.
                key code 0 using {command down, option down}
                delay 0.5
                key code 36
                delay 0.5
                -- Import is deliberately left as a dispatch boundary. Fresh AX
                -- readback must prove the tagged track, tagged region, source digest,
                -- and bar/beat placement before the MCP surface reports success.
                click menu item "Audio File…" of menu "Import" of menu item "Import" of menu "File" of menu bar item "File" of menu bar 1
                delay 0.8
                -- The first Enter only opens the Go To sheet in Logic's file picker.
                -- Set and verify the exact source there, then press the picker Open
                -- button. Returning before this button is pressed leaves the picker
                -- open and makes the next tagging stage observe no content row.
                keystroke "g" using {command down, shift down}
                delay 0.4
                set sourcePathEntered to false
                repeat 20 times
                    try
                        set value of first text field of (second UI element of window 1) to "\(escapedPath)"
                        set sourcePathEntered to true
                        exit repeat
                    on error
                        delay 0.1
                    end try
                end repeat
                if not sourcePathEntered then
                    return "ERROR:source path Go To sheet did not become available"
                end if
                key code 36
                delay 0.5
                set openClicked to false
                repeat 30 times
                    try
                        tell window 1 to tell first UI element
                            click button "Open"
                        end tell
                        set openClicked to true
                        exit repeat
                    on error
                        delay 0.2
                    end try
                end repeat
                if not openClicked then
                    return "ERROR:exact source was selected but the file picker Open button was unavailable"
                end if
                set pickerClosed to false
                repeat 40 times
                    try
                        if (name of window 1 as text) does not contain "Open File" then
                            set pickerClosed to true
                            exit repeat
                        end if
                    on error
                        set pickerClosed to true
                        exit repeat
                    end try
                    delay 0.25
                end repeat
                if not pickerClosed then
                    return "ERROR:file picker remained open after the exact source Open action"
                end if
            end tell
        end tell
        return "audio_import_dispatched plan_id=\(escapedPlanID) operation_id=\(escapedOperationID) track_tag=\(escapedTrackTag) region_tag=\(escapedRegionTag) duration_beats=\(durationBeats)"
        """
    }

    private func transportScript(action: String) -> String {
        """
        tell application "Logic Pro"
            \(action)
        end tell
        """
    }

    private func toggleEventListScript() -> String {
        let processName = ServerConfig.logicProProcessName.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Logic Pro" to activate
        delay 0.3
        tell application "System Events"
            tell process "\(processName)"
                click menu item "Open Event List" of menu "Window" of menu bar item "Window" of menu bar 1
            end tell
        end tell
        """
    }

    // MARK: - Helpers

    private func escapeJSON(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private func escapeAppleScript(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
