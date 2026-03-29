import Foundation
#if os(macOS)
import AppKit

/// Detects running browsers and provides graceful restart functionality.
enum BrowserService {

    /// Known browser bundle IDs.
    static let knownBrowsers: [(name: String, bundleID: String)] = [
        ("Safari", "com.apple.Safari"),
        ("Google Chrome", "com.google.Chrome"),
        ("Firefox", "org.mozilla.firefox"),
        ("Arc", "company.thebrowser.Browser"),
        ("Brave", "com.brave.Browser"),
        ("Microsoft Edge", "com.microsoft.edgemac"),
        ("Opera", "com.operasoftware.Opera"),
        ("Vivaldi", "com.vivaldi.Vivaldi"),
        ("Chromium", "org.chromium.Chromium"),
    ]

    /// Returns names of currently running browsers.
    static func runningBrowserNames() -> [String] {
        let running = NSWorkspace.shared.runningApplications
        let runningIDs = Set(running.compactMap { $0.bundleIdentifier })
        return knownBrowsers
            .filter { runningIDs.contains($0.bundleID) }
            .map { $0.name }
    }

    /// Returns bundle IDs of currently running browsers.
    static func runningBrowserBundleIDs() -> [String] {
        let running = NSWorkspace.shared.runningApplications
        let runningIDs = Set(running.compactMap { $0.bundleIdentifier })
        return knownBrowsers
            .filter { runningIDs.contains($0.bundleID) }
            .map { $0.bundleID }
    }

    /// Gracefully quits a browser and relaunches it after a short delay.
    /// Closes windows before quit so stale blocked tabs are not restored on relaunch.
    static func restartBrowsers(bundleIDs: [String]) async {
        // Step 1: Close windows and quit each browser so blocked tabs do not survive from session restore.
        for bundleID in bundleIDs {
            let script = """
tell application id "\(bundleID)"
    try
        close every window
    end try
    quit
end tell
"""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }

        // Step 2: Wait for browsers to fully quit and save session
        try? await Task.sleep(for: .seconds(2))

        // Step 3: Flush DNS caches
        let flush = Process()
        flush.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        flush.arguments = ["dscacheutil", "-flushcache"]
        flush.standardOutput = FileHandle.nullDevice
        flush.standardError = FileHandle.nullDevice
        try? flush.run()
        flush.waitUntilExit()

        let killResponder = Process()
        killResponder.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        killResponder.arguments = ["killall", "-HUP", "mDNSResponder"]
        killResponder.standardOutput = FileHandle.nullDevice
        killResponder.standardError = FileHandle.nullDevice
        try? killResponder.run()
        killResponder.waitUntilExit()

        // Step 4: Relaunch each browser
        try? await Task.sleep(for: .seconds(1))
        for bundleID in bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false // Don't steal focus
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
        }
    }
}
#endif
