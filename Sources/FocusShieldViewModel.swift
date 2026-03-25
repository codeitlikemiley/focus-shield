import Foundation
import SwiftUI
import KeyboardShortcuts

#if os(macOS)
import AppKit
#endif

// MARK: - Keyboard Shortcut Name

extension KeyboardShortcuts.Name {
    static let toggleFocusShield = Self("toggleFocusShield")
}

/// Central state manager for FocusShield.
@MainActor
@Observable
final class FocusShieldViewModel {
    // Persisted state
    var settings: AppSettings
    var profiles: [BlockProfile]
    var activeProfile: ProfileWithRules?

    // Transient UI state
    var errorMessage: String?
    var isProcessing = false
    var showBrowserRestartAlert = false
    var runningBrowserNames: [String] = []
    private var runningBrowserBundleIDs: [String] = []

    private let store = DataStore.shared

    #if os(macOS)
    private let appMonitor = AppMonitorService()
    #endif

    init() {
        self.settings = DataStore.shared.loadSettings()
        self.profiles = DataStore.shared.fetchAllProfiles()
        self.activeProfile = settings.activeProfileID.flatMap { DataStore.shared.fetchProfileWithRules(id: $0) }

        #if os(macOS)
        KeyboardShortcuts.onKeyUp(for: .toggleFocusShield) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
        if settings.masterEnabled {
            applyNetworkPolicy()
            applyAppBlocking()
        }
        #endif
    }

    // MARK: - Master Toggle

    var masterEnabled: Bool {
        get { settings.masterEnabled }
        set {
            settings.masterEnabled = newValue
            store.saveSettings(settings)
            if newValue {
                applyNetworkPolicy()
                #if os(macOS)
                applyAppBlocking()
                let names = BrowserService.runningBrowserNames()
                if !names.isEmpty {
                    runningBrowserNames = names
                    runningBrowserBundleIDs = BrowserService.runningBrowserBundleIDs()
                    showBrowserRestartAlert = true
                }
                #endif
            } else {
                removeAllBlocking()
            }
        }
    }

    func toggle() { masterEnabled.toggle() }

    var currentFilterMode: FilterMode {
        activeProfile?.profile.globalMode ?? .blacklist
    }

    #if os(macOS)
    func restartBrowsers() {
        let ids = runningBrowserBundleIDs
        Task { await BrowserService.restartBrowsers(bundleIDs: ids) }
    }
    #endif

    // MARK: - Profile Management

    func reloadProfiles() {
        profiles = store.fetchAllProfiles()
        activeProfile = settings.activeProfileID.flatMap { store.fetchProfileWithRules(id: $0) }
    }

    func activateProfile(_ id: Int64) {
        settings.activeProfileID = id
        store.saveSettings(settings)
        activeProfile = store.fetchProfileWithRules(id: id)
        if settings.masterEnabled {
            applyNetworkPolicy()
            #if os(macOS)
            applyAppBlocking()
            #endif
        }
    }

    func deactivateProfile() {
        settings.activeProfileID = nil
        store.saveSettings(settings)
        activeProfile = nil
        if settings.masterEnabled { removeAllBlocking() }
    }

    func createProfile(_ profile: inout BlockProfile) {
        store.saveProfile(&profile)
        reloadProfiles()
    }

    func deleteProfile(id: Int64) {
        if settings.activeProfileID == id { deactivateProfile() }
        store.deleteProfile(id: id)
        reloadProfiles()
    }

    func updateProfile(_ profile: inout BlockProfile) {
        store.saveProfile(&profile)
        reloadProfiles()
        if settings.activeProfileID == profile.id && settings.masterEnabled {
            applyNetworkPolicy()
            #if os(macOS)
            applyAppBlocking()
            #endif
        }
    }

    // MARK: - Global Domain Rule Actions

    func addDomainRule(domain: String, appRuleID: Int64? = nil) {
        guard let profileID = activeProfile?.profile.id else { return }
        let clean = cleanDomain(domain)
        guard !clean.isEmpty else { return }
        store.addDomainRules(profileID: profileID, appRuleID: appRuleID, domains: [clean])
        reloadAndApply()
    }

    func addDomainRulesBulk(domains: [String], appRuleID: Int64? = nil) {
        guard let profileID = activeProfile?.profile.id else { return }
        store.addDomainRules(profileID: profileID, appRuleID: appRuleID, domains: domains)
        reloadAndApply()
    }

    func removeDomainRule(id: Int64) {
        store.deleteDomainRule(id: id)
        reloadAndApply()
    }

    func toggleDomainRule(id: Int64, enabled: Bool) {
        store.toggleDomainRule(id: id, enabled: enabled)
        reloadAndApply()
    }

    // MARK: - App Rule Actions (GUI apps)

    func addAppRule(name: String, bundleID: String, blocked: Bool = false,
                    filterMode: FilterMode = .inheritGlobal) {
        guard let profileID = activeProfile?.profile.id else { return }
        var rule = AppRule(profileID: profileID, appName: name, bundleIdentifier: bundleID,
                           executablePath: nil, ruleType: .guiApp,
                           isBlocked: blocked, filterMode: filterMode)
        store.saveAppRule(&rule)
        reloadAndApplyApp()
    }

    func removeAppRule(id: Int64) {
        store.deleteAppRule(id: id)
        reloadAndApplyApp()
    }

    func toggleAppBlocked(id: Int64, blocked: Bool) {
        store.toggleAppBlocked(id: id, blocked: blocked)
        reloadAndApplyApp()
    }

    func setAppFilterMode(id: Int64, filterMode: FilterMode) {
        store.updateAppFilterMode(id: id, filterMode: filterMode)
        reloadAndApply()
    }

    // MARK: - CLI Rule Actions

    func addCLIRule(name: String, executablePath: String, blocked: Bool = false,
                    filterMode: FilterMode = .inheritGlobal) {
        guard let profileID = activeProfile?.profile.id else { return }
        // Use the binary name as bundleID for CLI tools
        let bundleID = "cli.\(name.lowercased())"
        var rule = AppRule(profileID: profileID, appName: name, bundleIdentifier: bundleID,
                           executablePath: executablePath, ruleType: .cliTool,
                           isBlocked: blocked, filterMode: filterMode)
        store.saveAppRule(&rule)
        reloadAndApply()
    }

    func toggleCLIBlocked(id: Int64, blocked: Bool) {
        store.toggleAppBlocked(id: id, blocked: blocked)
        reloadAndApply()
    }

    func setCLIFilterMode(id: Int64, filterMode: FilterMode) {
        store.updateAppFilterMode(id: id, filterMode: filterMode)
        reloadAndApply()
    }

    // MARK: - Blocking Enforcement

    func applyNetworkPolicy() {
        guard settings.masterEnabled, let profile = activeProfile else { return }
        isProcessing = true
        errorMessage = nil

        let policy = profile.computeNetworkPolicy()

        #if os(macOS)
        Task {
            do {
                try await HostsFileService.applyNetworkPolicy(policy)
                isProcessing = false
            } catch let error as HostsFileError where error == .userCancelled {
                isProcessing = false
            } catch {
                errorMessage = error.localizedDescription
                isProcessing = false
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    if self.errorMessage == error.localizedDescription { self.errorMessage = nil }
                }
            }
        }
        #else
        isProcessing = false
        #endif
    }

    #if os(macOS)
    private func applyAppBlocking() {
        guard settings.masterEnabled, let profile = activeProfile else {
            appMonitor.updateBlockedApps([])
            return
        }
        let blockedIDs = profile.blockedAppBundleIDs
        appMonitor.updateBlockedApps(blockedIDs)
    }
    #endif

    private func removeAllBlocking() {
        #if os(macOS)
        appMonitor.updateBlockedApps([])
        Task {
            do {
                try await HostsFileService.removeAllEntries()
            } catch {
                errorMessage = error.localizedDescription
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    if self.errorMessage == error.localizedDescription { self.errorMessage = nil }
                }
            }
        }
        #endif
    }

    /// Synchronous cleanup called on app quit (Cmd+Q).
    func cleanupOnQuit() {
        guard settings.masterEnabled else { return }
        #if os(macOS)
        appMonitor.updateBlockedApps([])
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            try? await HostsFileService.removeAllEntries()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        settings.masterEnabled = false
        store.saveSettings(settings)
        #endif
    }

    // MARK: - Installed App Scanning

    struct InstalledApp: Identifiable {
        let id = UUID()
        let name: String
        let bundleIdentifier: String
    }

    var installedApps: [InstalledApp] = []

    func scanInstalledApps() {
        #if os(macOS)
        let existingBundleIDs = Set(activeProfile?.guiAppRules.map { $0.rule.bundleIdentifier } ?? [])
        installedApps = AppMonitorService.scanInstalledApps()
            .filter { !existingBundleIDs.contains($0.bundleIdentifier) }
        #endif
    }

    // MARK: - Private Helpers

    private func cleanDomain(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: "/").first ?? ""
    }

    private func reloadAndApply() {
        reloadProfiles()
        if settings.masterEnabled { applyNetworkPolicy() }
    }

    private func reloadAndApplyApp() {
        reloadProfiles()
        #if os(macOS)
        if settings.masterEnabled { applyAppBlocking() }
        #endif
        if settings.masterEnabled { applyNetworkPolicy() }
    }
}

// MARK: - Equatable for HostsFileError

extension HostsFileError: Equatable {
    static func == (lhs: HostsFileError, rhs: HostsFileError) -> Bool {
        switch (lhs, rhs) {
        case (.userCancelled, .userCancelled): return true
        case (.writeFailed, .writeFailed): return true
        case (.adminAuthFailed(let a), .adminAuthFailed(let b)): return a == b
        default: return false
        }
    }
}
