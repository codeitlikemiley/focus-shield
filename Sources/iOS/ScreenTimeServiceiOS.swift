#if os(iOS)
import FamilyControls
import Foundation
import ManagedSettings

/// iOS implementation of Screen Time blocking using FamilyControls + ManagedSettings.
/// This file is only compiled for the iOS target.
extension ScreenTimeService {
    private static let settingsStore = ManagedSettingsStore()

    func requestAuthorizationiOS() async {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            isAuthorized = true
            authorizationError = nil
        } catch {
            isAuthorized = false
            authorizationError = error.localizedDescription
        }
    }

    func checkAuthorizationiOS() {
        isAuthorized = AuthorizationCenter.shared.authorizationStatus == .approved
    }

    func blockWebsitesiOS(_ domains: [String]) {
        guard isAuthorized else { return }
        let webDomains = Set(domains.map { WebDomain(domain: $0) })
        Self.settingsStore.webContent.blockedByFilter = .auto(webDomains)
    }

    func clearWebsiteRestrictionsiOS() {
        Self.settingsStore.webContent.blockedByFilter = nil
    }

    func removeAllRestrictionsiOS() {
        Self.settingsStore.clearAllSettings()
    }
}
#endif
