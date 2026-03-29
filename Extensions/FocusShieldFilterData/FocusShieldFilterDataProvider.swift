import Foundation
import NetworkExtension
import Darwin

final class FocusShieldFilterDataProvider: NEFilterDataProvider {
    private var cachedPolicy = NetworkFilterPolicy(blockedApplications: [], applicationRules: [])

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        cachedPolicy = currentPolicy()
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        cachedPolicy = NetworkFilterPolicy(blockedApplications: [], applicationRules: [])
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        cachedPolicy = currentPolicy()

        let sourceBundleID = Self.bundleIdentifier(from: flow.sourceAppAuditToken)
        let destinationHost = Self.host(from: flow)

        switch cachedPolicy.decision(bundleIdentifier: sourceBundleID, host: destinationHost) {
        case .allow:
            return .allow()
        case .block:
            return .drop()
        }
    }

    private func currentPolicy() -> NetworkFilterPolicy {
        NetworkFilterPolicy.fromVendorConfiguration(filterConfiguration.vendorConfiguration) ?? cachedPolicy
    }

    private static func host(from flow: NEFilterFlow) -> String? {
        if let urlHost = flow.url?.host, !urlHost.isEmpty {
            return NetworkFilterPolicy.normalizeHost(urlHost)
        }

        guard let socketFlow = flow as? NEFilterSocketFlow else { return nil }

        if let remoteHostname = socketFlow.remoteHostname, !remoteHostname.isEmpty {
            return NetworkFilterPolicy.normalizeHost(remoteHostname)
        }

        if let endpoint = socketFlow.remoteEndpoint as? NWHostEndpoint {
            return NetworkFilterPolicy.normalizeHost(endpoint.hostname)
        }

        return nil
    }

    private static func bundleIdentifier(from tokenData: Data?) -> String? {
        guard let executablePath = executablePath(from: tokenData) else { return nil }
        return bundleIdentifier(forExecutablePath: executablePath)
    }

    private static func executablePath(from tokenData: Data?) -> String? {
        guard let tokenData, tokenData.count == MemoryLayout<audit_token_t>.size else { return nil }

        let token = tokenData.withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: audit_token_t.self)
        }
        var mutableToken = token
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))

        let result = proc_pidpath_audittoken(&mutableToken, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }

        return String(cString: buffer)
    }

    private static func bundleIdentifier(forExecutablePath executablePath: String) -> String? {
        var currentURL = URL(fileURLWithPath: executablePath).deletingLastPathComponent()

        while currentURL.path != "/" {
            let pathExtension = currentURL.pathExtension.lowercased()
            if ["app", "appex", "systemextension"].contains(pathExtension) {
                return Bundle(url: currentURL)?.bundleIdentifier
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                break
            }
            currentURL = parentURL
        }

        return nil
    }
}
