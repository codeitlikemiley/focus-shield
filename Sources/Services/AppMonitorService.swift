import AppKit
import Foundation

/// Monitors running applications and terminates blocked ones.
@MainActor
final class AppMonitorService {
    private var blockedBundleIDs: Set<String> = []
    private var blockedCLIPaths: Set<String> = []
    private var isMonitoring = false
    private var cliTimer: Timer?
    private var launchObserver: NSObjectProtocol?

    /// Updates the set of bundle IDs to block.
    func updateBlockedApps(_ bundleIDs: Set<String>) {
        blockedBundleIDs = bundleIDs
        checkMonitoringState()
        terminateBlockedApps()
    }
    
    /// Updates the set of CLI executable paths to block.
    func updateBlockedCLIs(_ paths: Set<String>) {
        blockedCLIPaths = paths
        checkMonitoringState()
        terminateBlockedCLIs()
    }
    
    private func checkMonitoringState() {
        let shouldMonitor = !blockedBundleIDs.isEmpty || !blockedCLIPaths.isEmpty
        if shouldMonitor && !isMonitoring {
            startMonitoring()
        } else if !shouldMonitor && isMonitoring {
            stopMonitoring()
        }
    }

    /// Scans /Applications for installed apps, returns display name + bundle ID.
    static func scanInstalledApps() -> [FocusShieldViewModel.InstalledApp] {
        var apps: [FocusShieldViewModel.InstalledApp] = []
        let fileManager = FileManager.default

        let searchPaths = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
        ]

        for searchPath in searchPaths {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: searchPath) else { continue }

            for item in contents where item.hasSuffix(".app") {
                let appPath = "\(searchPath)/\(item)"
                guard let bundle = Bundle(path: appPath),
                      let bundleID = bundle.bundleIdentifier else { continue }

                let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? item.replacingOccurrences(of: ".app", with: "")

                apps.append(FocusShieldViewModel.InstalledApp(name: displayName, bundleIdentifier: bundleID))
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }


    // MARK: - Private

    private func startMonitoring() {
        isMonitoring = true
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }

            Task { @MainActor in
                if self?.blockedBundleIDs.contains(bundleID) == true {
                    app.terminate()
                    // Force terminate if it doesn't respond
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if app.isTerminated == false {
                            app.forceTerminate()
                        }
                    }
                }
            }
        }
        
        cliTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.terminateBlockedCLIs()
            }
        }
    }

    private func stopMonitoring() {
        isMonitoring = false
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        cliTimer?.invalidate()
        cliTimer = nil
    }

    private func terminateBlockedApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  blockedBundleIDs.contains(bundleID) else { continue }
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if app.isTerminated == false {
                    app.forceTerminate()
                }
            }
        }
    }
    
    private func terminateBlockedCLIs() {
        guard !blockedCLIPaths.isEmpty else { return }
        
        let pathsToKill = blockedCLIPaths
        DispatchQueue.global(qos: .background).async {
            for path in pathsToKill {
                let processName = (path as NSString).lastPathComponent
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                // -9 sends SIGKILL, -c matches exact command name
                task.arguments = ["-9", "-c", processName]
                try? task.run()
            }
        }
    }

    private static func isGameOrEntertainment(bundleID: String, name: String) -> Bool {
        let gameKeywords = [
            "game", "chess", "solitaire", "puzzle", "arcade",
            "steam", "epic", "minecraft", "roblox", "blizzard",
            "riot", "ea.com", "ubisoft", "unity",
        ]
        let lowBundleID = bundleID.lowercased()
        let lowName = name.lowercased()

        return gameKeywords.contains { lowBundleID.contains($0) || lowName.contains($0) }
    }
}
