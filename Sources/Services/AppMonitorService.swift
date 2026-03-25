import AppKit
import Foundation

/// Monitors running applications and terminates blocked ones.
@MainActor
final class AppMonitorService {
    private var blockedBundleIDs: Set<String> = []
    private var isMonitoring = false

    /// Updates the set of bundle IDs to block.
    func updateBlockedApps(_ bundleIDs: Set<String>) {
        blockedBundleIDs = bundleIDs

        if !bundleIDs.isEmpty && !isMonitoring {
            startMonitoring()
        } else if bundleIDs.isEmpty && isMonitoring {
            stopMonitoring()
        }

        // Terminate any currently running blocked apps
        terminateBlockedApps()
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
        NSWorkspace.shared.notificationCenter.addObserver(
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
    }

    private func stopMonitoring() {
        isMonitoring = false
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    private func terminateBlockedApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  blockedBundleIDs.contains(bundleID) else { continue }
            app.terminate()
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
