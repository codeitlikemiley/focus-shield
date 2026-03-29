import Foundation

/// Shared policy payload consumed by the macOS Network Extension content filter.
/// Keep this file independent from app-only models so it can compile in both the
/// host app and the system extension target.
struct NetworkFilterPolicy: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let vendorConfigurationPolicyKey = "FocusShieldNetworkFilterPolicyJSON"

    let schemaVersion: Int
    let generatedAt: Date
    let blockedApplications: [String]
    let applicationRules: [ApplicationRule]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAt: Date = .now,
        blockedApplications: [String],
        applicationRules: [ApplicationRule]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.blockedApplications = Self.normalizedBundleIdentifiers(blockedApplications)
        self.applicationRules = applicationRules.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
    }

    var isEmpty: Bool {
        blockedApplications.isEmpty && applicationRules.isEmpty
    }

    func decision(bundleIdentifier: String?, host: String?) -> Decision {
        guard let bundleIdentifier else { return .allow }
        let normalizedBundleID = Self.normalizeBundleIdentifier(bundleIdentifier)

        if blockedApplications.contains(normalizedBundleID) {
            return .block
        }

        guard let rule = applicationRules.first(where: { $0.bundleIdentifier == normalizedBundleID }) else {
            return .allow
        }

        return rule.decision(forHost: host)
    }

    var vendorConfiguration: [String: Any] {
        [
            Self.vendorConfigurationPolicyKey: encodedJSONString
        ]
    }

    var encodedJSONString: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func fromVendorConfiguration(_ vendorConfiguration: [String: Any]?) -> NetworkFilterPolicy? {
        guard
            let vendorConfiguration,
            let encoded = vendorConfiguration[vendorConfigurationPolicyKey] as? String
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: Data(encoded.utf8))
    }

    static func normalizeHost(_ rawHost: String) -> String {
        rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func normalizeBundleIdentifier(_ bundleIdentifier: String) -> String {
        bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedBundleIdentifiers(_ bundleIdentifiers: [String]) -> [String] {
        var seen = Set<String>()
        return bundleIdentifiers
            .map(normalizeBundleIdentifier)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
            .sorted()
    }
}

extension NetworkFilterPolicy {
    enum Decision {
        case allow
        case block
    }

    struct ApplicationRule: Codable, Equatable, Hashable {
        enum Mode: String, Codable {
            case blacklist
            case whitelist
        }

        let bundleIdentifier: String
        let mode: Mode
        let domains: [String]

        init(bundleIdentifier: String, mode: Mode, domains: [String]) {
            self.bundleIdentifier = NetworkFilterPolicy.normalizeBundleIdentifier(bundleIdentifier)
            self.mode = mode
            self.domains = Self.normalizedDomains(domains)
        }

        func decision(forHost rawHost: String?) -> Decision {
            guard let rawHost else {
                return mode == .whitelist ? .block : .allow
            }

            let host = NetworkFilterPolicy.normalizeHost(rawHost)
            guard !host.isEmpty else {
                return mode == .whitelist ? .block : .allow
            }

            let matched = domains.contains { Self.matches(host: host, rule: $0) }
            switch mode {
            case .blacklist:
                return matched ? .block : .allow
            case .whitelist:
                return matched ? .allow : .block
            }
        }

        private static func normalizedDomains(_ domains: [String]) -> [String] {
            var seen = Set<String>()
            return domains
                .map(NetworkFilterPolicy.normalizeHost)
                .filter { !$0.isEmpty }
                .filter { seen.insert($0).inserted }
                .sorted()
        }

        private static func matches(host: String, rule rawRule: String) -> Bool {
            let rule = NetworkFilterPolicy.normalizeHost(rawRule)
            guard !rule.isEmpty else { return false }

            if let wildcardBase = rule.stripWildcardPrefix {
                return host == wildcardBase || host.hasSuffix(".\(wildcardBase)")
            }

            return host == rule
        }
    }
}

private extension String {
    var stripWildcardPrefix: String? {
        guard hasPrefix("*.") else { return nil }
        return String(dropFirst(2))
    }
}
