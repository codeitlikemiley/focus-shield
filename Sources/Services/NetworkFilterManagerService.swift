#if os(macOS)
import Foundation
import NetworkExtension
import SystemExtensions
import os.log

private let neServiceLogger = Logger(subsystem: "com.focusshield.macos", category: "NEService")

enum NetworkFilterRuntimeState: Equatable {
    case inactive
    case awaitingApproval
    case rebootRequired
    case active
    case error(String)

    var title: String {
        switch self {
        case .inactive:
            return "Inactive"
        case .awaitingApproval:
            return "Needs Approval"
        case .rebootRequired:
            return "Needs Reboot"
        case .active:
            return "Active"
        case .error:
            return "Error"
        }
    }

    var summary: String {
        switch self {
        case .inactive:
            return "The transport-aware content filter is not enabled."
        case .awaitingApproval:
            return "Approve the Focus Shield network filter in System Settings so Safari and other apps move off the legacy workaround path."
        case .rebootRequired:
            return "The system extension was updated, but macOS needs a reboot before the new filter becomes active."
        case .active:
            return "The Network Extension content filter is active for per-app socket flows, including Safari/WebKit traffic."
        case .error(let message):
            return message
        }
    }

    var isActive: Bool {
        switch self {
        case .active:
            return true
        default:
            return false
        }
    }
}

enum NetworkFilterServiceError: LocalizedError {
    case activationFailed(String)
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .activationFailed(let message):
            return "Network filter activation failed: \(message)"
        case .configurationFailed(let message):
            return "Network filter configuration failed: \(message)"
        }
    }
}

@MainActor
final class NetworkFilterManagerService {
    static let shared = NetworkFilterManagerService()
    static let extensionBundleIdentifier = "com.focusshield.macos.filter-data"

    private let manager = NEFilterManager.shared()
    private var pendingRequestDelegate: SystemExtensionRequestDelegate?
    private var pendingPropertiesRequestDelegate: SystemExtensionPropertiesRequestDelegate?

    private init() {}

    func refreshStatus() async -> NetworkFilterRuntimeState {
        let managerEnabled: Bool
        do {
            try await manager.focusshieldLoadFromPreferences()
            managerEnabled = manager.isEnabled
        } catch {
            if Self.isRecoverableConfigurationError(error) {
                neServiceLogger.warning("Ignoring recoverable NEFilterManager status error: \(Self.describeNSError(error), privacy: .public)")
                return .inactive
            }
            return .error(Self.userFacingErrorDescription(for: error))
        }

        do {
            if let properties = try await systemExtensionProperties() {
                if properties.isAwaitingUserApproval {
                    return .awaitingApproval
                }
                if properties.isEnabled {
                    return managerEnabled ? .active : .inactive
                }
            }
        } catch {
            neServiceLogger.warning("Unable to read system extension properties: \(Self.describeNSError(error), privacy: .public)")
        }

        return managerEnabled ? .active : .inactive
    }

    func sync(profilePolicy: ProfileNetworkPolicy) async throws -> NetworkFilterRuntimeState {
        let filterPolicy = Self.makeFilterPolicy(from: profilePolicy)
        guard !filterPolicy.isEmpty else {
            neServiceLogger.info("Filter policy is empty — disabling NE.")
            try await disable()
            return .inactive
        }

        neServiceLogger.info("Filter policy has \(filterPolicy.blockedApplications.count) blocked apps, \(filterPolicy.applicationRules.count) app rules. Activating sysext...")
        let activationState = try await activateSystemExtensionIfNeeded()
        neServiceLogger.info("Sysext activation result: \(String(describing: activationState))")
        try await configureManager(with: filterPolicy)
        neServiceLogger.info("NEFilterManager configured and saved.")

        switch activationState {
        case .completed:
            return .active
        case .awaitingApproval:
            return .awaitingApproval
        case .rebootRequired:
            return .rebootRequired
        }
    }

    func disable() async throws {
        do {
            try await manager.focusshieldLoadFromPreferences()
        } catch {
            if Self.isRecoverableConfigurationError(error) {
                neServiceLogger.warning("Clearing invalid NEFilterManager preferences during disable: \(Self.describeNSError(error), privacy: .public)")
                try? await manager.focusshieldRemoveFromPreferences()
                return
            }
            throw NetworkFilterServiceError.configurationFailed(Self.userFacingErrorDescription(for: error))
        }

        manager.isEnabled = false
        if #available(macOS 15.0, *) {
            manager.disableEncryptedDNSSettings = false
        }
        do {
            try await manager.focusshieldSaveToPreferences()
        } catch {
            if Self.isRecoverableConfigurationError(error) {
                neServiceLogger.warning("Clearing invalid NEFilterManager preferences after disable save failure: \(Self.describeNSError(error), privacy: .public)")
                try? await manager.focusshieldRemoveFromPreferences()
                return
            }
            throw NetworkFilterServiceError.configurationFailed(Self.userFacingErrorDescription(for: error))
        }
    }

    private func configureManager(with filterPolicy: NetworkFilterPolicy) async throws {
        do {
            try await manager.focusshieldLoadFromPreferences()
        } catch {
            if Self.isRecoverableConfigurationError(error) {
                neServiceLogger.warning("Resetting invalid NEFilterManager preferences before configure: \(Self.describeNSError(error), privacy: .public)")
                try? await manager.focusshieldRemoveFromPreferences()
            } else {
                throw NetworkFilterServiceError.configurationFailed(Self.userFacingErrorDescription(for: error))
            }
        }

        let configuration = manager.providerConfiguration ?? NEFilterProviderConfiguration()
        configuration.filterSockets = true
        configuration.filterDataProviderBundleIdentifier = Self.extensionBundleIdentifier
        configuration.serverAddress = "Focus Shield Network Filter"
        configuration.vendorConfiguration = filterPolicy.vendorConfiguration

        manager.providerConfiguration = configuration
        manager.localizedDescription = "Focus Shield Network Filter"
        manager.grade = .firewall
        if #available(macOS 15.0, *) {
            manager.disableEncryptedDNSSettings = true
        }
        manager.isEnabled = true

        do {
            try await manager.focusshieldSaveToPreferences()
        } catch {
            throw NetworkFilterServiceError.configurationFailed(Self.userFacingErrorDescription(for: error))
        }
    }

    private func activateSystemExtensionIfNeeded() async throws -> ActivationResult {
        neServiceLogger.info("Submitting system extension activation request for \(Self.extensionBundleIdentifier)")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = SystemExtensionRequestDelegate { [weak self] result in
                neServiceLogger.info("System extension activation completed: \(String(describing: result))")
                self?.pendingRequestDelegate = nil
                continuation.resume(returning: result)
            } onError: { [weak self] error in
                neServiceLogger.error("System extension activation FAILED: \(error.localizedDescription, privacy: .public)")
                self?.pendingRequestDelegate = nil
                continuation.resume(
                    throwing: NetworkFilterServiceError.activationFailed(error.localizedDescription)
                )
            }

            pendingRequestDelegate = delegate
            request.delegate = delegate
            OSSystemExtensionManager.shared.submitRequest(request)
            neServiceLogger.info("System extension request submitted to OSSystemExtensionManager.")
        }
    }

    private func systemExtensionProperties() async throws -> OSSystemExtensionProperties? {
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: Self.extensionBundleIdentifier,
            queue: .main
        )

        return try await withCheckedThrowingContinuation { continuation in
            let delegate = SystemExtensionPropertiesRequestDelegate { [weak self] properties in
                self?.pendingPropertiesRequestDelegate = nil
                let matchingProperty = properties.first { $0.bundleIdentifier == Self.extensionBundleIdentifier }
                continuation.resume(returning: matchingProperty)
            } onError: { [weak self] error in
                self?.pendingPropertiesRequestDelegate = nil
                continuation.resume(throwing: error)
            }

            pendingPropertiesRequestDelegate = delegate
            request.delegate = delegate
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private static func makeFilterPolicy(from profilePolicy: ProfileNetworkPolicy) -> NetworkFilterPolicy {
        let blockedApplications = Array(profilePolicy.blockedAppBundleIDs).sorted()
        let applicationRules = profilePolicy.appDomainOverrides.map { override in
            NetworkFilterPolicy.ApplicationRule(
                bundleIdentifier: override.bundleID,
                mode: override.filterMode == .whitelist ? .whitelist : .blacklist,
                domains: override.domains
            )
        }

        return NetworkFilterPolicy(
            blockedApplications: blockedApplications,
            applicationRules: applicationRules
        )
    }

    private static func filterManagerError(from error: Error) -> NEFilterManagerError? {
        let nsError = error as NSError
        guard nsError.domain == NEFilterErrorDomain else { return nil }
        return NEFilterManagerError(rawValue: nsError.code)
    }

    private static func isRecoverableConfigurationError(_ error: Error) -> Bool {
        switch filterManagerError(from: error) {
        case .configurationInvalid, .configurationDisabled, .configurationStale:
            return true
        default:
            return false
        }
    }

    private static func userFacingErrorDescription(for error: Error) -> String {
        switch filterManagerError(from: error) {
        case .configurationInvalid:
            return "The saved network filter configuration is invalid."
        case .configurationDisabled:
            return "The network filter configuration is disabled."
        case .configurationStale:
            return "The network filter configuration is stale."
        case .configurationCannotBeRemoved:
            return "macOS refused to remove the saved network filter configuration."
        case .configurationPermissionDenied:
            return "macOS denied access to the network filter configuration."
        case .configurationInternalError:
            return "macOS returned an internal network filter configuration error."
        case nil:
            return error.localizedDescription
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func describeNSError(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }
}

private enum ActivationResult {
    case completed
    case awaitingApproval
    case rebootRequired
}

private final class SystemExtensionRequestDelegate: NSObject, OSSystemExtensionRequestDelegate {
    private var didResolve = false
    private let onResult: (ActivationResult) -> Void
    private let onError: (Error) -> Void

    init(onResult: @escaping (ActivationResult) -> Void, onError: @escaping (Error) -> Void) {
        self.onResult = onResult
        self.onError = onError
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        resolve(.awaitingApproval)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            resolve(.completed)
        case .willCompleteAfterReboot:
            resolve(.rebootRequired)
        @unknown default:
            resolve(.completed)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        guard !didResolve else { return }
        didResolve = true
        onError(error)
    }

    private func resolve(_ result: ActivationResult) {
        guard !didResolve else { return }
        didResolve = true
        onResult(result)
    }
}

private final class SystemExtensionPropertiesRequestDelegate: NSObject, OSSystemExtensionRequestDelegate {
    private var didResolve = false
    private let onResult: ([OSSystemExtensionProperties]) -> Void
    private let onError: (Error) -> Void

    init(onResult: @escaping ([OSSystemExtensionProperties]) -> Void, onError: @escaping (Error) -> Void) {
        self.onResult = onResult
        self.onError = onError
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}

    func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        resolve(with: properties)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        resolve(with: [])
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        guard !didResolve else { return }
        didResolve = true
        onError(error)
    }

    private func resolve(with properties: [OSSystemExtensionProperties]) {
        guard !didResolve else { return }
        didResolve = true
        onResult(properties)
    }
}

private extension NEFilterManager {
    func focusshieldLoadFromPreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func focusshieldSaveToPreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func focusshieldRemoveFromPreferences() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            removeFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
#endif
