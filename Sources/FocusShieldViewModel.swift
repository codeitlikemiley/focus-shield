import Foundation
import SwiftUI
import KeyboardShortcuts
import os.log

#if os(macOS)
import AppKit
#endif

private let neLogger = Logger(subsystem: "com.focusshield.macos", category: "NetworkExtension")

// MARK: - Keyboard Shortcut Name

extension KeyboardShortcuts.Name {
    static let toggleFocusShield = Self("toggleFocusShield")
}

extension Notification.Name {
    static let focusShieldBrowserRestartRequired = Notification.Name("focusShieldBrowserRestartRequired")
}

/// Central state manager for FocusShield.
@MainActor
@Observable
final class FocusShieldViewModel {
    // Persisted state
    var settings: AppSettings
    var profiles: [BlockProfile]
    var activeProfile: ProfileWithRules?
    var siteLists: [SiteListWithDomains]
    var payloadPatterns: [PayloadPattern]
    var dataVersion: Int = 0

    // Transient UI state
    var errorMessage: String?
    var isProcessing = false
    var hasPendingBrowserRestart = false
    var runningBrowserNames: [String] = []
    private var runningBrowserBundleIDs: [String] = []
    #if os(macOS)
    var networkFilterState: NetworkFilterRuntimeState = .inactive
    var enforcementHealth: EnforcementHealth = EnforcementHealth()
    #endif

    private let store = DataStore.shared

    #if os(macOS)
    private let appMonitor = AppMonitorService()
    /// Periodic timer to re-enforce pf rules (they can be cleared by network events / sleep-wake).
    private var enforcementTimer: Timer?
    private var networkFilterStatusTimer: Timer?
    private var networkFilterRefreshTask: Task<Void, Never>?
    #endif

    init() {
        let settings = DataStore.shared.loadSettings()
        self.settings = settings
        self.profiles = DataStore.shared.fetchAllProfiles()
        self.siteLists = DataStore.shared.fetchSiteListsWithDomains()
        self.payloadPatterns = DataStore.shared.fetchPayloadPatterns()
        self.activeProfile = settings.activeProfileID.flatMap { DataStore.shared.fetchProfileWithRules(id: $0) }

        #if os(macOS)
        KeyboardShortcuts.onKeyUp(for: .toggleFocusShield) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
        if settings.masterEnabled {
            applyNetworkPolicy()
            applyAppBlocking()
        }
        refreshNetworkFilterStatus(force: true)
        startEnforcementTimer()
        startNetworkFilterStatusTimer()
        #endif
        syncPayloadProtectionConfiguration()
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
                noteBrowserPolicyChange()
                #endif
            } else {
                removeAllBlocking()
                #if os(macOS)
                noteBrowserPolicyChange()
                #endif
            }
        }
    }

    func toggle() { masterEnabled.toggle() }

    #if os(macOS)
    /// Re-applies pf rules and flushes DNS every 3 minutes to survive network resets / sleep-wake.
    private func startEnforcementTimer() {
        enforcementTimer?.invalidate()
        enforcementTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.settings.masterEnabled else { return }
                // Re-apply only the lightweight pf+DNS portion (no UI prompt)
                self.applyNetworkPolicy()
                self.refreshEnforcementHealth()
            }
        }
    }

    private func startNetworkFilterStatusTimer() {
        networkFilterStatusTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshNetworkFilterStatus()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        networkFilterStatusTimer = timer
    }

    func refreshNetworkFilterStatus(force: Bool = false) {
        guard force || shouldMonitorNetworkFilterStatus else { return }

        networkFilterRefreshTask?.cancel()
        networkFilterRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await NetworkFilterManagerService.shared.refreshStatus()
            guard !Task.isCancelled else { return }
            self.updateNetworkFilterState(state)
        }
    }

    private var shouldMonitorNetworkFilterStatus: Bool {
        if settings.masterEnabled {
            return true
        }

        switch networkFilterState {
        case .awaitingApproval, .rebootRequired, .error:
            return true
        default:
            return false
        }
    }

    private func updateNetworkFilterState(_ state: NetworkFilterRuntimeState) {
        networkFilterState = state
        neLogger.info("Network filter runtime state updated: \(String(describing: state), privacy: .public)")

        switch state {
        case .error(let message):
            if errorMessage == nil || errorMessage?.hasPrefix("Network Extension:") == true {
                errorMessage = "Network Extension: \(message)"
            }
        default:
            if errorMessage?.hasPrefix("Network Extension:") == true {
                errorMessage = nil
            }
        }

        refreshEnforcementHealth()
    }
    #endif

    var currentFilterMode: FilterMode {
        activeProfile?.profile.globalMode ?? .blacklist
    }

    #if os(macOS)
    func restartBrowsers() {
        let ids = runningBrowserBundleIDs
        hasPendingBrowserRestart = false
        runningBrowserNames = []
        runningBrowserBundleIDs = []
        Task { await BrowserService.restartBrowsers(bundleIDs: ids) }
    }
    #endif

    // MARK: - Profile Management

    func reloadProfiles() {
        profiles = store.fetchAllProfiles()
        activeProfile = settings.activeProfileID.flatMap { store.fetchProfileWithRules(id: $0) }
        siteLists = store.fetchSiteListsWithDomains()
    }

    func fetchProfileWithRules(id: Int64) -> ProfileWithRules? {
        store.fetchProfileWithRules(id: id)
    }

    func notifyDataChanged() {
        dataVersion += 1
    }

    func activateProfile(_ id: Int64) {
        settings.activeProfileID = id
        store.saveSettings(settings)
        activeProfile = store.fetchProfileWithRules(id: id)
        if settings.masterEnabled {
            applyNetworkPolicy()
            #if os(macOS)
            applyAppBlocking()
            noteBrowserPolicyChange()
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
        notifyDataChanged()
        if settings.activeProfileID == profile.id && settings.masterEnabled {
            applyNetworkPolicy()
            #if os(macOS)
            applyAppBlocking()
            noteBrowserPolicyChange()
            #endif
        }
    }

    // MARK: - Custom Domain Group Actions

    func addCustomGroup(profileID: Int64, name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        var group = CustomDomainGroup(profileID: profileID, name: cleanName)
        store.saveCustomGroup(&group)
        reloadAndApply(profileID: profileID)
    }

    func removeCustomGroup(profileID: Int64, id: Int64) {
        store.deleteCustomGroup(id: id)
        reloadAndApply(profileID: profileID)
    }

    // MARK: - Site Lists

    func addSiteList(name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let nextSortOrder = (siteLists.map { $0.list.sortOrder }.max() ?? -1) + 1
        var list = SiteList(name: cleanName, isBuiltIn: false, sortOrder: nextSortOrder)
        store.saveSiteList(&list)
        reloadSiteLists()
    }

    func removeSiteList(id: Int64) {
        store.deleteSiteList(id: id)
        reloadSiteLists()
    }

    func addDomainToSiteList(siteListID: Int64, domain: String) {
        let clean = cleanDomain(domain)
        guard !clean.isEmpty else { return }
        store.addSiteListDomains(siteListID: siteListID, domains: [clean])
        reloadSiteLists()
    }

    func removeDomainFromSiteList(id: Int64) {
        store.deleteSiteListDomain(id: id)
        reloadSiteLists()
    }

    func importSiteDomains(profileID: Int64, appRuleID: Int64, domains: [String]) {
        let clean = domains.map(cleanDomain).filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        store.addDomainRules(profileID: profileID, appRuleID: appRuleID, domains: clean)
        reloadAndApply(profileID: profileID)
        if shouldPromptForBrowserRestart(appRuleID: appRuleID) { noteBrowserPolicyChange() }
    }

    // MARK: - Global Domain Rule Actions (profileID-scoped)

    func addDomainRule(profileID: Int64, domain: String, appRuleID: Int64? = nil, groupID: Int64? = nil) {
        let clean = cleanDomain(domain)
        guard !clean.isEmpty else { return }
        store.addDomainRules(profileID: profileID, appRuleID: appRuleID, groupID: groupID, domains: [clean])
        reloadAndApply(profileID: profileID)
        if shouldPromptForBrowserRestart(appRuleID: appRuleID) { noteBrowserPolicyChange() }
    }

    func addDomainRulesBulk(profileID: Int64, domains: [String], appRuleID: Int64? = nil, groupID: Int64? = nil) {
        store.addDomainRules(profileID: profileID, appRuleID: appRuleID, groupID: groupID, domains: domains)
        reloadAndApply(profileID: profileID)
        if shouldPromptForBrowserRestart(appRuleID: appRuleID) { noteBrowserPolicyChange() }
    }

    func removeDomainRule(profileID: Int64, id: Int64) {
        let domainRule = store.fetchDomainRule(id: id)
        store.deleteDomainRule(id: id)
        reloadAndApply(profileID: profileID)
        if shouldPromptForBrowserRestart(domainRule: domainRule) { noteBrowserPolicyChange() }
    }

    func toggleDomainRule(profileID: Int64, id: Int64, enabled: Bool) {
        let domainRule = store.fetchDomainRule(id: id)
        store.toggleDomainRule(id: id, enabled: enabled)
        reloadAndApply(profileID: profileID)
        if shouldPromptForBrowserRestart(domainRule: domainRule) { noteBrowserPolicyChange() }
    }

    func changeDomainGroup(profileID: Int64, ruleID: Int64, newGroupID: Int64?) {
        store.updateDomainRuleGroup(id: ruleID, groupID: newGroupID)
        reloadAndApply(profileID: profileID)
    }

    // MARK: - App Rule Actions (profileID-scoped)

    func addAppRule(profileID: Int64, name: String, bundleID: String, blocked: Bool = false,
                    filterMode: FilterMode = .blacklist) {
        var rule = AppRule(profileID: profileID, appName: name, bundleIdentifier: bundleID,
                           executablePath: nil, ruleType: .guiApp,
                           isBlocked: blocked, filterMode: filterMode)
        store.saveAppRule(&rule)
        reloadAndApplyApp(profileID: profileID)
        if AppNetworkSupport.isBrowser(bundleID: bundleID) { noteBrowserPolicyChange() }
    }

    func removeAppRule(profileID: Int64, id: Int64) {
        let appRule = store.fetchAppRule(id: id)
        store.deleteAppRule(id: id)
        reloadAndApplyApp(profileID: profileID)
        if shouldPromptForBrowserRestart(appRule: appRule) { noteBrowserPolicyChange() }
    }

    func toggleAppBlocked(profileID: Int64, id: Int64, blocked: Bool) {
        let appRule = store.fetchAppRule(id: id)
        store.toggleAppBlocked(id: id, blocked: blocked)
        reloadAndApplyApp(profileID: profileID)
        if shouldPromptForBrowserRestart(appRule: appRule) { noteBrowserPolicyChange() }
    }

    func setAppFilterMode(profileID: Int64, id: Int64, filterMode: FilterMode) {
        let appRule = store.fetchAppRule(id: id)
        store.updateAppFilterMode(id: id, filterMode: filterMode)
        reloadAndApply(profileID: profileID)
        if shouldPromptForBrowserRestart(appRule: appRule) { noteBrowserPolicyChange() }
    }

    /// Toggle a rule's enabled state (link / unlink). Works for both GUI apps and CLI tools.
    /// When disabled ("unlinked"), the rule and its domain lists stay in the database but
    /// are excluded from all enforcement artifacts on the next apply cycle.
    func toggleAppEnabled(profileID: Int64, id: Int64, enabled: Bool) {
        let appRule = store.fetchAppRule(id: id)
        store.toggleAppEnabled(id: id, enabled: enabled)
        reloadAndApply(profileID: profileID)
        if shouldPromptForBrowserRestart(appRule: appRule) { noteBrowserPolicyChange() }
    }

    // MARK: - CLI Rule Actions (profileID-scoped)

    func addCLIRule(profileID: Int64, name: String, executablePath: String, blocked: Bool = false,
                    filterMode: FilterMode = .blacklist) {
        let bundleID = "cli.\(name.lowercased())"
        var rule = AppRule(profileID: profileID, appName: name, bundleIdentifier: bundleID,
                           executablePath: executablePath, ruleType: .cliTool,
                           isBlocked: blocked, filterMode: filterMode)
        store.saveAppRule(&rule)
        reloadAndApply(profileID: profileID)
    }

    func toggleCLIBlocked(profileID: Int64, id: Int64, blocked: Bool) {
        store.toggleAppBlocked(id: id, blocked: blocked)
        reloadAndApply(profileID: profileID)
    }

    func setCLIFilterMode(profileID: Int64, id: Int64, filterMode: FilterMode) {
        store.updateAppFilterMode(id: id, filterMode: filterMode)
        reloadAndApply(profileID: profileID)
    }

    // MARK: - Payload Protection

    func setPayloadProtectionEnabled(_ enabled: Bool) {
        settings.payloadProtectionEnabled = enabled
        store.saveSettings(settings)
        syncPayloadProtectionConfiguration()
    }

    func addPayloadPattern(name: String, regex: String) -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRegex = regex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanRegex.isEmpty, PayloadProtectionService.isValidRegex(cleanRegex) else {
            return false
        }

        let nextSortOrder = (payloadPatterns.map(\.sortOrder).max() ?? -1) + 1
        var pattern = PayloadPattern(
            name: cleanName,
            regex: cleanRegex,
            isEnabled: true,
            isRecommended: false,
            sortOrder: nextSortOrder
        )
        store.savePayloadPattern(&pattern)
        reloadPayloadPatterns()
        return true
    }

    func updatePayloadPattern(_ pattern: inout PayloadPattern) -> Bool {
        let cleanName = pattern.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRegex = pattern.regex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanRegex.isEmpty, PayloadProtectionService.isValidRegex(cleanRegex) else {
            return false
        }

        pattern.name = cleanName
        pattern.regex = cleanRegex
        store.savePayloadPattern(&pattern)
        reloadPayloadPatterns()
        return true
    }

    func togglePayloadPattern(id: Int64, enabled: Bool) {
        store.togglePayloadPattern(id: id, enabled: enabled)
        reloadPayloadPatterns()
    }

    func removePayloadPattern(id: Int64) {
        store.deletePayloadPattern(id: id)
        reloadPayloadPatterns()
    }

    // MARK: - Blocking Enforcement

    func applyNetworkPolicy() {
        guard settings.masterEnabled, let profile = activeProfile else { return }
        isProcessing = true
        errorMessage = nil

        let policy = profile.computeNetworkPolicy()

        #if os(macOS)
        Task {
            // STEP 1: Always apply legacy enforcement FIRST (PAC, managed policy, hosts, pf, DNS proxy).
            // This is the guaranteed baseline that works for Chrome/Firefox/Chromium without any
            // Network Extension dependency.
            do {
                try await HostsFileService.applyNetworkPolicy(policy)
            } catch let error as HostsFileError where error == .userCancelled {
                isProcessing = false
                return
            } catch {
                errorMessage = error.localizedDescription
                isProcessing = false
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    if self.errorMessage == error.localizedDescription { self.errorMessage = nil }
                }
                // Even if legacy apply failed, still attempt NE sync below.
            }

            // STEP 2: Attempt Network Extension sync as an ADDITIVE enhancement.
            // NE failures are surfaced as persistent warnings.
            do {
                let state = try await NetworkFilterManagerService.shared.sync(profilePolicy: policy)
                updateNetworkFilterState(state)
                neLogger.info("NE sync succeeded: state=\(String(describing: self.networkFilterState))")
            } catch {
                updateNetworkFilterState(.error(error.localizedDescription))
                neLogger.error("NE sync failed: \(error.localizedDescription, privacy: .public)")
            }

            isProcessing = false

            // STEP 3: Verify enforcement artifacts are actually in place.
            refreshEnforcementHealth()
        }
        #else
        isProcessing = false
        #endif
    }

    #if os(macOS)
    private func applyAppBlocking() {
        guard settings.masterEnabled, let profile = activeProfile else {
            appMonitor.updateBlockedApps([])
            appMonitor.updateBlockedCLIs([])
            return
        }
        let blockedIDs = profile.blockedAppBundleIDs
        appMonitor.updateBlockedApps(blockedIDs)
        
        let blockedCLIs = profile.blockedCLIPaths
        appMonitor.updateBlockedCLIs(blockedCLIs)
    }
    #endif

    private func removeAllBlocking() {
        #if os(macOS)
        appMonitor.updateBlockedApps([])
        appMonitor.updateBlockedCLIs([])
        Task {
            do {
                try await NetworkFilterManagerService.shared.disable()
                updateNetworkFilterState(.inactive)
            } catch {
                updateNetworkFilterState(.error(error.localizedDescription))
            }

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
        appMonitor.updateBlockedCLIs([])
        let semaphore = DispatchSemaphore(value: 0)
        updateNetworkFilterState(.inactive)
        Task {
            try? await NetworkFilterManagerService.shared.disable()
            try? await HostsFileService.removeAllEntries()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        #endif
    }

    // MARK: - Installed App Scanning

    struct InstalledApp: Identifiable {
        let id = UUID()
        let name: String
        let bundleIdentifier: String
    }

    var installedApps: [InstalledApp] = []

    func scanInstalledApps(excludingProfile profileID: Int64) {
        #if os(macOS)
        let existing = store.fetchProfileWithRules(id: profileID)
        let existingBundleIDs = Set(existing?.guiAppRules.map { $0.rule.bundleIdentifier } ?? [])
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

    #if os(macOS)
    private func noteBrowserPolicyChange() {
        let names = BrowserService.runningBrowserNames()
        guard !names.isEmpty else { return }
        runningBrowserNames = names
        runningBrowserBundleIDs = BrowserService.runningBrowserBundleIDs()
        hasPendingBrowserRestart = true
        NotificationCenter.default.post(name: .focusShieldBrowserRestartRequired, object: nil)
    }
    #endif

    private func shouldPromptForBrowserRestart(appRuleID: Int64?) -> Bool {
        guard settings.masterEnabled, settings.activeProfileID != nil else { return false }
        guard let appRuleID else { return true }
        guard let appRule = store.fetchAppRule(id: appRuleID) else { return false }
        return AppNetworkSupport.isBrowser(bundleID: appRule.bundleIdentifier)
    }

    private func shouldPromptForBrowserRestart(domainRule: DomainRule?) -> Bool {
        guard settings.masterEnabled, settings.activeProfileID != nil else { return false }
        guard let domainRule else { return false }
        return shouldPromptForBrowserRestart(appRuleID: domainRule.appRuleID)
    }

    private func shouldPromptForBrowserRestart(appRule: AppRule?) -> Bool {
        guard settings.masterEnabled, settings.activeProfileID != nil else { return false }
        guard let appRule else { return false }
        return AppNetworkSupport.isBrowser(bundleID: appRule.bundleIdentifier)
    }

    private func reloadPayloadPatterns() {
        payloadPatterns = store.fetchPayloadPatterns()
        syncPayloadProtectionConfiguration()
    }

    private func reloadSiteLists() {
        siteLists = store.fetchSiteListsWithDomains()
    }

    private func syncPayloadProtectionConfiguration() {
        PayloadProtectionService.syncRuntimeConfiguration(
            enabled: settings.payloadProtectionEnabled,
            patterns: payloadPatterns
        )
    }

    private func reloadAndApply(profileID: Int64) {
        notifyDataChanged()
        reloadProfiles()
        if settings.masterEnabled && settings.activeProfileID == profileID {
            applyNetworkPolicy()
        }
    }

    private func reloadAndApplyApp(profileID: Int64) {
        notifyDataChanged()
        reloadProfiles()
        #if os(macOS)
        if settings.masterEnabled && settings.activeProfileID == profileID {
            applyAppBlocking()
        }
        #endif
        if settings.masterEnabled && settings.activeProfileID == profileID {
            applyNetworkPolicy()
        }
    }

    // MARK: - Enforcement Health Checks

    #if os(macOS)
    func refreshEnforcementHealth() {
        guard settings.masterEnabled, let profile = activeProfile else {
            enforcementHealth = EnforcementHealth()
            return
        }

        let hasBrowserDomains = profile.appRules.contains { appRule in
            AppNetworkSupport.isBrowser(bundleID: appRule.rule.bundleIdentifier)
                && !appRule.domainRules.filter({ $0.isEnabled }).isEmpty
        }

        let hasChromeRule = profile.appRules.contains {
            $0.rule.bundleIdentifier == "com.google.Chrome"
                && !$0.domainRules.filter({ $0.isEnabled }).isEmpty
        }

        let hasFirefoxRule = profile.appRules.contains {
            $0.rule.bundleIdentifier == "org.mozilla.firefox"
                && !$0.domainRules.filter({ $0.isEnabled }).isEmpty
        }

        let hasSafariDomains = profile.appRules.contains {
            $0.rule.bundleIdentifier == "com.apple.Safari"
                && !$0.domainRules.filter({ $0.isEnabled }).isEmpty
        }

        var health = EnforcementHealth()
        health.helperInstalled = HostsFileService.isHelperInstalled
        health.sudoersPresent = FileManager.default.fileExists(atPath: "/etc/sudoers.d/focusshield")

        if hasBrowserDomains {
            health.pacFileHealthy = HostsFileService.checkPACFileHealth()
            health.systemProxyEnabled = HostsFileService.checkSystemProxyEnabled()
        } else {
            health.pacFileHealthy = true
            health.systemProxyEnabled = true
        }

        health.chromePolicy = hasChromeRule
            ? HostsFileService.checkManagedPolicyPresent(bundleID: "com.google.Chrome")
            : nil

        health.firefoxPolicy = hasFirefoxRule
            ? FileManager.default.fileExists(atPath: "/Library/Application Support/Mozilla/managed-policies.json")
            : nil

        health.safariNeedsNetworkExtension = hasSafariDomains
        health.networkExtensionActive = networkFilterState.isActive

        enforcementHealth = health

        // Surface health warnings as a persistent error if unhealthy.
        let warnings = health.warnings
        if !warnings.isEmpty && errorMessage == nil {
            errorMessage = warnings.first
        }
    }
    #endif
}

// MARK: - Enforcement Health

#if os(macOS)
struct EnforcementHealth: Equatable {
    var helperInstalled: Bool = true
    var sudoersPresent: Bool = true
    var pacFileHealthy: Bool = true
    var systemProxyEnabled: Bool = true
    var chromePolicy: Bool? = nil      // nil = no Chrome rule configured
    var firefoxPolicy: Bool? = nil     // nil = no Firefox rule configured
    var safariNeedsNetworkExtension: Bool = false
    var networkExtensionActive: Bool = false

    var isHealthy: Bool {
        helperInstalled
            && sudoersPresent
            && pacFileHealthy
            && systemProxyEnabled
            && (chromePolicy ?? true)
            && (firefoxPolicy ?? true)
            && (!safariNeedsNetworkExtension || networkExtensionActive)
    }

    var warnings: [String] {
        var msgs: [String] = []
        if !helperInstalled { msgs.append("Privileged helper is not installed. Run the installer or reinstall.") }
        if !sudoersPresent { msgs.append("Sudoers file missing — helper cannot run without password. Reinstall required.") }
        if !pacFileHealthy { msgs.append("PAC proxy file is empty or DIRECT — browser blocking may not work.") }
        if !systemProxyEnabled { msgs.append("System proxy is not enabled — Safari/browser filtering may be inactive.") }
        if chromePolicy == false { msgs.append("Chrome managed policy file is missing — Chrome blocking may not work.") }
        if firefoxPolicy == false { msgs.append("Firefox managed policy file is missing — Firefox blocking may not work.") }
        if safariNeedsNetworkExtension && !networkExtensionActive {
            msgs.append("Safari per-site blocking requires an approved Network Extension. Safari domain rules will not be enforced until the extension is enabled in System Settings.")
        }
        return msgs
    }
}
#endif

// MARK: - Equatable for HostsFileError

extension HostsFileError: Equatable {
    static func == (lhs: HostsFileError, rhs: HostsFileError) -> Bool {
        switch (lhs, rhs) {
        case (.userCancelled, .userCancelled): return true
        case (.writeFailed, .writeFailed): return true
        case (.adminAuthFailed(let a), .adminAuthFailed(let b)): return a == b
        case (.helperInstallFailed(let a), .helperInstallFailed(let b)): return a == b
        case (.helperVerificationFailed, .helperVerificationFailed): return true
        default: return false
        }
    }
}
