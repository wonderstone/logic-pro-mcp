import Foundation
import MCP

struct ProjectDispatcher {
    static let tool = Tool(
        name: "logic_project",
        description: """
            Project lifecycle in Logic Pro. \
            Commands: new, open, save, save_as, close, bounce, silent_bounce, launch, quit. \
            Params by command: \
            open -> { path: String }; \
            save_as -> { path: String }; \
            bounce -> {} (opens bounce dialog); \
            silent_bounce -> { filename?: String } (automated bounce to WAV, returns file path); \
            launch/quit -> {} (app lifecycle); \
            Others -> {}
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
                content: [.text("Unknown project command: \(command). Available: new, open, save, save_as, close, bounce, silent_bounce, launch, quit")],
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
}