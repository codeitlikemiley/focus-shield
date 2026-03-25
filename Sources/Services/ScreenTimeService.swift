import Foundation

/// Screen Time API service.
/// On macOS: acts as an inert stub — website/app blocking is done via
/// HostsFileService and AppMonitorService instead.
/// On iOS: the real implementation lives in Sources/iOS/ScreenTimeServiceiOS.swift.
@MainActor
final class ScreenTimeService: ObservableObject {
    @Published var isAuthorized = false
    @Published var authorizationError: String?

    func requestAuthorization() async {
        authorizationError = "Screen Time is available on iOS only. macOS uses /etc/hosts."
    }

    func checkAuthorization() {}
    func blockWebsites(_ domains: [String]) {}
    func clearWebsiteRestrictions() {}
    func removeAllRestrictions() {}
}
