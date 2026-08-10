import Foundation
import AppKit

/// Utilities for finding and interacting with the Logic Pro process.
enum ProcessUtils {
    /// Returns the PID of Logic Pro if running, nil otherwise.
    static func logicProPID() -> pid_t? {
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: ServerConfig.logicProBundleID
        )
        guard !apps.isEmpty else { return nil }

        // Multiple Logic instances can coexist during a disposable-project
        // run. The active/frontmost instance is the only honest AX authority;
        // choosing the first launch-services result can silently bind a
        // different project.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier == ServerConfig.logicProBundleID,
           apps.contains(where: { $0.processIdentifier == frontmost.processIdentifier }) {
            return frontmost.processIdentifier
        }
        if let active = apps.first(where: { $0.isActive }) {
            return active.processIdentifier
        }
        return apps.first?.processIdentifier
    }

    /// Whether Logic Pro is currently running.
    static var isLogicProRunning: Bool {
        logicProPID() != nil
    }

    /// Bring Logic Pro to front (used sparingly — most operations don't need focus).
    static func activateLogicPro() -> Bool {
        guard let pid = logicProPID(),
              let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate()
    }
}
