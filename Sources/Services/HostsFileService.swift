import Foundation

/// Manages the legacy host/proxy/firewall enforcement stack:
///
/// 1. **`/etc/hosts`** — DNS-level blocking (Chrome, curl, native apps)
/// 2. **`pf` firewall** — Network-level blocking (IP-based)
/// 3. **PAC proxy file** — Proxy-level blocking (Chrome, Firefox)
/// 4. **Local DNS proxy** — Additional DNS enforcement for the legacy path
///
/// Safari / WebKit traffic should now be handled by the Network Extension path.
/// This service remains responsible for Chrome/Firefox managed policy, CLI
/// wrappers, hosts/pf, and the rest of the non-extension runtime.
///
/// Authentication: uses a privileged helper installed once (no repeated passwords).
enum HostsFileService {
    private static let startMarker = "# FocusShield START"
    private static let endMarker = "# FocusShield END"
    private static let privateRelayBlockList = [
        "mask.icloud.com",
        "mask-h2.icloud.com",
        "doh.dns.apple.com",
        "mask.apple-dns.net",
    ]
    private static let hostsPath = "/etc/hosts"
    private static let pfRulesPath = "/etc/pf.anchors/com.focusshield"
    private static let helperPath = "/usr/local/bin/focusshield-helper"
    private static let sudoersPath = "/etc/sudoers.d/focusshield"
    private static let dnsProxyPath = "/usr/local/bin/focusshield-dns"
    private static let dnsPidPath = "/tmp/focusshield-dns.pid"
    private static let supportScriptsDir = "/usr/local/lib/focusshield"
    private static let aliasManagerPath = "\(supportScriptsDir)/update_aliases.sh"
    private static let payloadGuardPath = "\(supportScriptsDir)/focusshield-cli-guard"
    private static let managedPreferencesDir = "/Library/Managed Preferences"
    private static let firefoxManagedPolicyPath = "/Library/Application Support/Mozilla/managed-policies.json"

    /// PAC file path — stored in the app's support directory
    private static var pacFilePath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FocusShield")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("proxy.pac").path
    }

    /// Blocked domains file for the DNS proxy
    private static var domainsFilePath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FocusShield")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("blocked-domains.txt").path
    }

    /// File storing the original DNS servers before we changed them
    private static var originalDNSPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FocusShield")
        return dir.appendingPathComponent("original-dns.txt").path
    }

    private static var runtimePayloadProtectionEnabled: Bool {
        guard let content = try? String(contentsOfFile: PayloadProtectionService.patternsFilePath, encoding: .utf8) else {
            return false
        }
        return content.split(whereSeparator: \.isNewline).isEmpty == false
    }

    // MARK: - Public API

    /// Primary enforcement entry-point: applies a full ProfileNetworkPolicy across all layers.
    static func applyNetworkPolicy(_ policy: ProfileNetworkPolicy) async throws {
        let globalDomains = policy.globalDomains
        let browserOverrides = policy.appDomainOverrides.filter {
            AppNetworkSupport.supportsLegacyBrowserPolicy(bundleID: $0.bundleID)
        }
        let safariNeedsRelayBypass = browserOverrides.contains { $0.bundleID == "com.apple.Safari" }
        let relayBypassDomains = safariNeedsRelayBypass ? privateRelayBlockList : []

        let pfRules = buildCombinedPfRules(
            globalDomains: globalDomains,
            globalMode: policy.globalMode,
            cliRules: policy.cliRules,
            forcedBlockDomains: relayBypassDomains
        )

        let globalPAC: String
        if policy.globalMode == .whitelist {
            globalPAC = buildWhitelistPacFile(globalAllowed: globalDomains, appOverrides: [])
        } else {
            globalPAC = buildBlacklistPacFile(globalDomains: globalDomains, appOverrides: [])
        }

        var appPACs: [String: String] = [:]
        for override in browserOverrides {
            appPACs[override.bundleID] = buildBrowserPacFile(
                globalDomains: globalDomains,
                globalMode: policy.globalMode,
                override: override
            )
        }

        var cliPACs: [String: String] = [:]
        for cliRule in policy.cliRules where !cliRule.isFullyBlocked && !cliRule.domains.isEmpty {
            let toolName = (cliRule.executablePath as NSString).lastPathComponent
            cliPACs[toolName] = buildBrowserPacFile(
                globalDomains: globalDomains,
                globalMode: policy.globalMode,
                override: ProfileNetworkPolicy.AppDomainOverride(
                    bundleID: toolName,
                    filterMode: cliRule.filterMode,
                    domains: cliRule.domains
                )
            )
        }

        let systemPAC = appPACs["com.apple.Safari"] ?? globalPAC
        let shouldEnableSystemProxy = policy.globalMode == .whitelist
            || !globalDomains.isEmpty
            || appPACs["com.apple.Safari"] != nil

        let currentContent = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
        var newHostsContent = removeExistingEntries(from: currentContent)
        if !newHostsContent.hasSuffix("\n") { newHostsContent += "\n" }

        let staticBlockedDomains = relayBypassDomains + (
            policy.globalMode == .blacklist ? expandedDomainsForStaticResolvers(globalDomains) : []
        )
        if !staticBlockedDomains.isEmpty {
            newHostsContent += "\(startMarker)\n"
            for domain in staticBlockedDomains {
                newHostsContent += "127.0.0.1 \(domain)\n"
                newHostsContent += "::1 \(domain)\n"
            }
            newHostsContent += "\(endMarker)\n"
        }

        let domainsListContent = globalDomains.joined(separator: "\n")
        try domainsListContent.write(toFile: domainsFilePath, atomically: true, encoding: .utf8)

        try systemPAC.write(toFile: pacFilePath, atomically: true, encoding: .utf8)
        PACServer.shared.updateAll(globalPAC: systemPAC, appPACs: appPACs, cliPACs: cliPACs)

        let browserPoliciesDir = buildBrowserPolicies(appPACs: appPACs)

        let wrappersDir = buildCLIWrappers(
            cliRules: policy.cliRules,
            cliPACs: cliPACs,
            payloadProtectionEnabled: runtimePayloadProtectionEnabled,
            charScanEnv: policy.charScanEnv
        )

        try await applyBlocking(
            hostsContent: newHostsContent,
            pfRules: pfRules,
            systemProxyURL: shouldEnableSystemProxy ? PACServer.proxyURL : nil,
            wrappersDir: wrappersDir,
            browserPoliciesDir: browserPoliciesDir
        )

        if !globalDomains.isEmpty {
            try await startDNSProxy(mode: policy.globalMode)
        }
    }

    /// Legacy: Updates hosts, pf, PAC proxy, AND DNS proxy for the given domains.
    /// In blacklist mode, `domains` are blocked. In whitelist mode, `domains` are allowed.
    static func updateBlockedDomains(_ domains: [String], mode: FilterMode = .blacklist) async throws {
        // 1. Build hosts content
        let currentContent = try String(contentsOfFile: hostsPath, encoding: .utf8)
        let cleanedContent = removeExistingEntries(from: currentContent)

        var newHostsContent = cleanedContent
        if !newHostsContent.hasSuffix("\n") {
            newHostsContent += "\n"
        }

        // In blacklist mode, add domains to hosts file
        // In whitelist mode, skip hosts (DNS proxy handles it)
        if mode == .blacklist && !domains.isEmpty {
            newHostsContent += "\(startMarker)\n"
            for domain in expandedDomainsForStaticResolvers(domains) {
                newHostsContent += "127.0.0.1 \(domain)\n"
            }
            newHostsContent += "\(endMarker)\n"
        }

        // 2. Build pf rules (blacklist mode only)
        let pfRules = mode == .blacklist ? buildPfRules(for: domains) : "# FocusShield whitelist mode - no pf rules\n"

        // 3. Build PAC file and start HTTP PAC server (blacklist mode only)
        if mode == .blacklist {
            let pacContent = buildPacFile(for: domains)
            try pacContent.write(toFile: pacFilePath, atomically: true, encoding: .utf8)
            PACServer.shared.start(with: pacContent)
        } else {
            let emptyPac = "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n"
            try emptyPac.write(toFile: pacFilePath, atomically: true, encoding: .utf8)
            PACServer.shared.updateContent(emptyPac)
        }

        // 4. Write domains file for DNS proxy
        let domainsListContent = domains.joined(separator: "\n")
        try domainsListContent.write(toFile: domainsFilePath, atomically: true, encoding: .utf8)

        // 5. Apply privileged operations (hosts + pf + proxy + DNS)
        try await applyBlocking(
            hostsContent: newHostsContent,
            pfRules: pfRules,
            systemProxyURL: !domains.isEmpty ? PACServer.proxyURL : nil,
            wrappersDir: nil
        )

        // 6. Start DNS proxy (after helper sets system DNS)
        if !domains.isEmpty {
            try await startDNSProxy(mode: mode)
        }
    }

    /// Removes all FocusShield entries, stops DNS proxy, restores DNS.
    static func removeAllEntries() async throws {
        let currentContent = try String(contentsOfFile: hostsPath, encoding: .utf8)
        let cleanedContent = removeExistingEntries(from: currentContent)

        let emptyPac = "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n"
        try emptyPac.write(toFile: pacFilePath, atomically: true, encoding: .utf8)
        PACServer.shared.updateAll(globalPAC: emptyPac, appPACs: [:], cliPACs: [:])

        try await stopDNSProxy()

        try "".write(toFile: domainsFilePath, atomically: true, encoding: .utf8)

        try await applyBlocking(
            hostsContent: cleanedContent,
            pfRules: "# FocusShield - no rules active\n",
            systemProxyURL: nil,
            wrappersDir: nil,
            browserPoliciesDir: nil
        )
    }

    // MARK: - Helper Installation

    static var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: helperPath) &&
        FileManager.default.fileExists(atPath: sudoersPath) &&
        FileManager.default.fileExists(atPath: aliasManagerPath) &&
        FileManager.default.fileExists(atPath: payloadGuardPath) &&
        ((try? String(contentsOfFile: helperPath, encoding: .utf8).contains("FocusShield privileged helper v5")) ?? false)
    }

    // MARK: - Runtime Health Checks

    /// Checks that the PAC file contains actual blocking rules, not just DIRECT passthrough.
    static func checkPACFileHealth() -> Bool {
        guard let content = try? String(contentsOfFile: pacFilePath, encoding: .utf8) else {
            return false
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // A healthy PAC has blocking rules; a broken one is either empty or just returns DIRECT.
        if trimmed.isEmpty { return false }
        if trimmed == "function FindProxyForURL(url, host) { return \"DIRECT\"; }" { return false }
        return trimmed.contains("PROXY 127.0.0.1:9") || trimmed.contains("BLOCKED")
    }

    /// Checks that macOS system proxy auto-config is enabled via scutil.
    static func checkSystemProxyEnabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--proxy"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Look for ProxyAutoConfigEnable : 1
        return output.contains("ProxyAutoConfigEnable : 1")
    }

    /// Checks that a Chromium managed policy plist exists for the given browser bundle ID.
    static func checkManagedPolicyPresent(bundleID: String) -> Bool {
        let path = "\(managedPreferencesDir)/\(bundleID).plist"
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - PAC File Generation (public for startup)

    /// Generates PAC file content for the given domains. Public so the ViewModel
    /// can start the PAC server at launch without triggering the full blocking flow.
    static func buildPacFileContent(for domains: [String]) -> String {
        return buildPacFile(for: domains)
    }

    // MARK: - Per-Browser PAC generation

    /// Generates a PAC tailored for a specific browser based on its per-app domain override.
    private static func buildBrowserPacFile(
        globalDomains: [String],
        globalMode: FilterMode,
        override: ProfileNetworkPolicy.AppDomainOverride
    ) -> String {
        switch override.filterMode {
        case .inheritGlobal:
            // No per-app config — use global rules
            return globalMode == .whitelist
                ? buildWhitelistPacFile(globalAllowed: globalDomains, appOverrides: [])
                : buildBlacklistPacFile(globalDomains: globalDomains, appOverrides: [])

        case .blacklist:
            if override.domains.isEmpty {
                // Empty blacklist = this browser is unrestricted (no domains to block via PAC)
                return "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n"
            }
            // Block per-app domains + global domains additively
            let combined = Array(Set(globalDomains + override.domains))
            return buildBlacklistPacFile(globalDomains: combined, appOverrides: [])

        case .whitelist:
            // Whitelist: only allow specified domains, block everything else
            return buildWhitelistPacFile(globalAllowed: override.domains, appOverrides: [])
        }
    }

    // MARK: - CLI Wrapper Scripts

    @discardableResult
    private static func buildCLIWrappers(
        cliRules: [ProfileNetworkPolicy.CLINetworkRule],
        cliPACs: [String: String],
        payloadProtectionEnabled: Bool,
        charScanEnv: [String: String] = [:]
    ) -> String? {
        guard !cliRules.isEmpty else { return nil }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusshield_wrappers_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        // Build a sorted export block for char-scan env vars
        let charScanExports = charScanEnv.sorted(by: { $0.key < $1.key })
            .map { "export \($0.key)=\"\($0.value)\"" }
            .joined(separator: "\n")

        // Tools used internally by the CLI guard script itself. Wrapping any of these
        // would cause the guard to call its own wrapper → infinite recursion / fork bomb.
        // Also block shells, make, and other build tools that launch sub-processes.
        let neverWrapTools: Set<String> = [
            // Used directly inside focusshield-cli-guard
            "cat", "head", "grep", "awk", "perl", "shasum", "sha256sum",
            "mktemp", "sort", "sed", "wc", "rm", "mkdir", "touch", "basename",
            "printf", "echo", "base64", "sqlite3", "osascript",
            // Shells — wrapping these breaks every new terminal / sub-shell
            "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
            // Build tools whose subprocesses inherit PATH
            "make", "gmake", "ninja", "cmake", "xcodebuild",
            // Other critical system utilities
            "sudo", "su", "env", "exec", "open", "launchctl",
        ]

        var wroteAny = false
        for rule in cliRules {
            let execPath = rule.executablePath
            guard !execPath.isEmpty else { continue }

            let toolName = (execPath as NSString).lastPathComponent

            // Never wrap guard-internal tools — doing so creates a fork bomb.
            if neverWrapTools.contains(toolName) { continue }

            // Self-sandboxed agents (Claude Code, Cursor, Aider…) manage their own proxy
            // and filesystem sandbox. Skip the proxy wrapper so we don't chain two proxies.
            // NEFilter still enforces domain rules at the socket level for these processes.
            if rule.hasSelfSandbox && !rule.isFullyBlocked {
                continue
            }

            let encodedDomains = Data(rule.domains.joined(separator: "\n").utf8).base64EncodedString()
            let hasDomainRules = !rule.domains.isEmpty
            let needsGuard = payloadProtectionEnabled || hasDomainRules

            let wrapperContent: String
            if rule.isFullyBlocked {
                wrapperContent = """
#!/bin/sh
# FocusShield: \(toolName) is blocked by the active profile.
echo "focusshield: '\(toolName)' is blocked by the active FocusShield profile." >&2
exit 1
"""
            } else if needsGuard {
                let pacURL = cliPACs[toolName].map { _ in PACServer.cliPACURL(tool: toolName) } ?? ""
                wrapperContent = """
#!/bin/sh
# FocusShield: \(toolName) request preflight wrapper.
export FOCUSSHIELD_TOOL_NAME="\(toolName)"
export FOCUSSHIELD_FILTER_MODE="\(rule.filterMode.rawValue)"
export FOCUSSHIELD_DOMAIN_RULES_B64="\(encodedDomains)"
export FOCUSSHIELD_PAYLOAD_PROTECTION="\(payloadProtectionEnabled ? "1" : "0")"
export FOCUSSHIELD_PAYLOAD_PATTERNS_FILE="\(PayloadProtectionService.patternsFilePath)"
export FOCUSSHIELD_PAYLOAD_ALLOWLIST_FILE="\(PayloadProtectionService.permanentAllowlistPath)"
export FOCUSSHIELD_PAYLOAD_SESSION_ALLOWLIST_FILE="\(PayloadProtectionService.sessionAllowlistPath)"
export FOCUSSHIELD_LEGACY_PAC_URL="\(pacURL)"
\(charScanExports)

if [ -x "\(payloadGuardPath)" ]; then
    exec "\(payloadGuardPath)" "\(execPath)" "$@"
fi

exec "\(execPath)" "$@"
"""
            } else {
                continue
            }

            let wrapperFile = tmpDir.appendingPathComponent(toolName)
            if (try? wrapperContent.write(to: wrapperFile, atomically: true, encoding: .utf8)) != nil {
                wroteAny = true
            }
        }

        return wroteAny ? tmpDir.path : nil
    }

    @discardableResult
    private static func buildBrowserPolicies(appPACs: [String: String]) -> String? {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusshield_browser_policies_\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        var wroteAny = false
        let chromiumTargets = AppNetworkSupport.chromiumManagedPolicyBundleIDs
        for bundleID in chromiumTargets where appPACs[bundleID] != nil {
            let plist = managedPlistPolicyContent(pacURL: PACServer.pacURL(bundleID: bundleID))
            let target = tmpDir.appendingPathComponent("\(bundleID).plist")
            if (try? plist.write(to: target, atomically: true, encoding: .utf8)) != nil {
                wroteAny = true
            }
        }

        if appPACs["org.mozilla.firefox"] != nil {
            let json = firefoxManagedPolicyContent(pacURL: PACServer.pacURL(bundleID: "org.mozilla.firefox"))
            let target = tmpDir.appendingPathComponent("org.mozilla.firefox.json")
            if (try? json.write(to: target, atomically: true, encoding: .utf8)) != nil {
                wroteAny = true
            }
        }

        return wroteAny ? tmpDir.path : nil
    }

    private static func managedPlistPolicyContent(pacURL: String) -> String {
        """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ProxySettings</key>
    <dict>
        <key>ProxyMode</key>
        <string>pac_script</string>
        <key>ProxyPacUrl</key>
        <string>\(pacURL)</string>
    </dict>
</dict>
</plist>
"""
    }

    private static func firefoxManagedPolicyContent(pacURL: String) -> String {
        """
{
  "policies": {
    "ProxySettings": {
      "ConnectionType": "autoConfig",
      "AutoConfigURL": "\(pacURL)"
    }
  }
}
"""
    }

    // MARK: - Private: PAC file

    /// Called by buildPacFileContent (public interface)
    private static func buildPacFile(for domains: [String]) -> String {
        buildBlacklistPacFile(globalDomains: domains, appOverrides: [])
    }

    /// Generates a blacklist PAC where per-app overrides can exempt apps from global rules.
    /// Per-app Blacklist+empty = that app context bypasses the global deny list (all DIRECT via PAC).
    /// Per-app Blacklist+domains = those domains are ALSO blocked (additive to global).
    private static func buildBlacklistPacFile(
        globalDomains: [String],
        appOverrides: [ProfileNetworkPolicy.AppDomainOverride]
    ) -> String {
        // Check if any app override has Blacklist mode with EMPTY domain list.
        // This means "that app (e.g. Safari) overrides the global list with nothing" → all DIRECT via PAC.
        // Since PAC is global (can't target per-browser), the most permissive app override wins:
        // any app demanding unrestricted access means the PAC won't block anything.
        // (/etc/hosts and pf still block at network layer for non-browser apps.)
        let hasUnrestrictedAppOverride = appOverrides.contains {
            $0.filterMode == .blacklist && $0.domains.isEmpty
        }
        if hasUnrestrictedAppOverride {
            return "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n"
        }

        // Compute the effective block list:
        // Start with global, add any per-app blacklist domains, skip per-app whitelist domains.
        var effectiveDomains = Set(globalDomains)
        for override in appOverrides {
            switch override.filterMode {
            case .blacklist:
                effectiveDomains.formUnion(override.domains) // additive
            case .whitelist:
                effectiveDomains.subtract(override.domains)  // exempted
            case .inheritGlobal:
                break
            }
        }

        if effectiveDomains.isEmpty {
            return "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n"
        }

        let domainList = pacDomainMapLiteral(Array(effectiveDomains))

        return """
        // FocusShield PAC — Auto-generated
        // Routes blocked domains through a dead proxy (127.0.0.1:9)
        var BLOCKED = \(domainList);

        function FindProxyForURL(url, host) {
            host = host.toLowerCase();
            for (var domain in BLOCKED) {
                if (host === domain ||
                    (host.length > domain.length &&
                     host.substring(host.length - domain.length - 1) === "." + domain)) {
                    return "PROXY 127.0.0.1:9";
                }
            }
            return "DIRECT";
        }

        """
    }

    /// Generates a whitelist PAC: allows only listed domains, blocks everything else.
    /// Supports per-app overrides (e.g. Safari allowed extra domains).
    private static func buildWhitelistPacFile(
        globalAllowed: [String],
        appOverrides: [ProfileNetworkPolicy.AppDomainOverride]
    ) -> String {
        let allowedDomains = Array(Set(globalAllowed + Array(SystemSafelist.domains)))
        let lines = pacDomainMapLiteral(allowedDomains)

        return """
        // FocusShield PAC — Whitelist mode
        var ALLOWED = \(lines);

        function FindProxyForURL(url, host) {
            host = host.toLowerCase();
            for (var domain in ALLOWED) {
                if (host === domain ||
                    (host.length > domain.length &&
                     host.substring(host.length - domain.length - 1) === "." + domain)) {
                    return "DIRECT";
                }
            }
            // Block everything else
            return "PROXY 127.0.0.1:9";
        }

        """
    }

    private static func pacDomainMapLiteral(_ domains: [String]) -> String {
        let normalized = normalizedMatchableDomains(domains)
        guard !normalized.isEmpty else { return "{}" }
        let map = Dictionary(uniqueKeysWithValues: normalized.map { ($0, true) })
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func normalizedMatchableDomains(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains
            .map { domain in
                let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return trimmed.hasPrefix("*.") ? String(trimmed.dropFirst(2)) : trimmed
            }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func expandedDomainsForStaticResolvers(_ domains: [String]) -> [String] {
        let commonPrefixes = [
            "www", "m", "mobile", "web", "app", "api", "cdn", "static",
            "touch", "connect", "graph", "video", "media", "edge",
            "gateway", "images", "lookaside", "help", "support", "mail"
        ]

        var seen = Set<String>()
        var expanded: [String] = []

        for domain in normalizedMatchableDomains(domains) {
            if seen.insert(domain).inserted {
                expanded.append(domain)
            }
            for prefix in commonPrefixes {
                let candidate = "\(prefix).\(domain)"
                if seen.insert(candidate).inserted {
                    expanded.append(candidate)
                }
            }
        }

        return expanded
    }

    /// Builds combined pf rules: global domain blocks/allows + per-CLI process rules.
    /// Builds IP-resolved pf rules that block TCP, UDP (QUIC/HTTP3), AND ICMP for all blocked domains.
    /// Resolves hostnames to IPs in Swift before pf loads them (pf can't do DNS reliably on macOS).
    private static func buildCombinedPfRules(
        globalDomains: [String],
        globalMode: FilterMode,
        cliRules: [ProfileNetworkPolicy.CLINetworkRule],
        forcedBlockDomains: [String] = []
    ) -> String {
        // pf on macOS does NOT support per-process rules.
        // CLI blocking is enforced via wrapper scripts (domain filter) and AppMonitorService (full block).
        // pf handles IP-level blocking for all protocols for globally blocked domains and Safari relay bypass hosts.
        let effectiveDomains = Array(Set(forcedBlockDomains + (globalMode == .blacklist ? globalDomains : [])))
        guard !effectiveDomains.isEmpty else {
            return "# FocusShield pf rules — no blacklist active\n"
        }
        return buildPfRules(for: effectiveDomains)
    }


    private static func removeExistingEntries(from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var result: [String] = []
        var insideBlock = false

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == startMarker {
                insideBlock = true
                continue
            }
            if line.trimmingCharacters(in: .whitespaces) == endMarker {
                insideBlock = false
                continue
            }
            if !insideBlock {
                result.append(line)
            }
        }

        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true && result.count > 1 {
            result.removeLast()
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Private: pf rules

    /// Resolve a hostname to all its IPv4 addresses
    private static func resolveHostToIPs(_ host: String) -> [String] {
        var results: [String] = []
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let res = res else { return [] }
        defer { freeaddrinfo(res) }
        var ptr: UnsafeMutablePointer<addrinfo>? = res
        while let cur = ptr {
            if cur.pointee.ai_family == AF_INET,
               let sockaddr = cur.pointee.ai_addr {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let sa = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
                var addr = sa.pointee.sin_addr
                inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                if !ip.isEmpty && !results.contains(ip) { results.append(ip) }
            }
            ptr = cur.pointee.ai_next
        }
        return results
    }

    private static func buildPfRules(for domains: [String]) -> String {
        var rules = "# FocusShield pf rules - auto-generated\n"
        if domains.isEmpty {
            rules += "# No domains to block\n"
            return rules
        }
        // Resolve hostnames to IPs. pf cannot do DNS and we need real IPs for blocking
        // even when Safari uses Private Relay (which uses the real dest IPs through the relay).
        var resolvedIPs = Set<String>()

        // Also resolve Apple Private Relay ingress endpoints so pf blocks them directly.
        // This forces Safari to fall back to direct mode where /etc/hosts and PAC take effect.
        for relayHost in privateRelayBlockList {
            resolvedIPs.formUnion(resolveHostToIPs(relayHost))
        }

        for domain in expandedDomainsForStaticResolvers(domains) {
            resolvedIPs.formUnion(resolveHostToIPs(domain))
        }

        if resolvedIPs.isEmpty {
            rules += "# No IPs resolved (DNS may be unavailable)\n"
            return rules
        }

        rules += "# Block all outbound traffic to blocked IPs: TCP, UDP (QUIC/H3), ICMP (ping)\n"
        rules += "# Private Relay ingress IPs also blocked to force Safari into direct mode.\n"
        let interfaces = ["en0", "en1", "en2", "utun0", "utun1", "utun2"]
        for ip in resolvedIPs.sorted() {
            for iface in interfaces {
                // Full TCP/UDP block covers HTTP/1, HTTP/2, HTTP/3 (QUIC), WebSocket, gRPC
                rules += "block drop out quick on \(iface) proto { tcp udp } to \(ip) port { 80 443 }\n"
                // ICMP block prevents ping/traceroute to blocked IPs
                rules += "block drop out quick on \(iface) proto icmp to \(ip)\n"
            }
        }
        return rules
    }

    // MARK: - Private: Apply blocking

    private static func applyBlocking(
        hostsContent: String,
        pfRules: String,
        systemProxyURL: String?,
        wrappersDir: String? = nil,
        browserPoliciesDir: String? = nil
    ) async throws {
        let tmpHosts = FileManager.default.temporaryDirectory.appendingPathComponent("focusshield_hosts_\(UUID().uuidString)")
        let tmpPf = FileManager.default.temporaryDirectory.appendingPathComponent("focusshield_pf_\(UUID().uuidString)")

        try hostsContent.write(to: tmpHosts, atomically: true, encoding: .utf8)
        try pfRules.write(to: tmpPf, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tmpHosts)
            try? FileManager.default.removeItem(at: tmpPf)
        }

        if isHelperInstalled {
            try await runHelperDirectly(
                tmpHostsPath: tmpHosts.path, tmpPfPath: tmpPf.path,
                systemProxyURL: systemProxyURL, wrappersDir: wrappersDir, browserPoliciesDir: browserPoliciesDir
            )
        } else {
            try await installHelperAndApply(
                tmpHostsPath: tmpHosts.path, tmpPfPath: tmpPf.path,
                systemProxyURL: systemProxyURL, wrappersDir: wrappersDir, browserPoliciesDir: browserPoliciesDir
            )
        }
    }

    /// Runs the helper via sudo (no password needed after initial install).
    private static func runHelperDirectly(
        tmpHostsPath: String,
        tmpPfPath: String,
        systemProxyURL: String?,
        wrappersDir: String? = nil,
        browserPoliciesDir: String? = nil
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        let proxyArg = systemProxyURL ?? "disable"
        let modeArg = systemProxyURL == nil ? "disable" : "enable"
        var args: [String] = [helperPath, tmpHostsPath, tmpPfPath, proxyArg, modeArg]
        if let wd = wrappersDir { args.append(wd) }
        if let policyDir = browserPoliciesDir {
            if wrappersDir == nil { args.append("") }
            args.append(policyDir)
        }
        process.arguments = args

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? ""

            if errorMsg.contains("password") || errorMsg.contains("sudo") {
                try await installHelperAndApply(
                    tmpHostsPath: tmpHostsPath,
                    tmpPfPath: tmpPfPath,
                    systemProxyURL: systemProxyURL,
                    wrappersDir: wrappersDir,
                    browserPoliciesDir: browserPoliciesDir
                )
                return
            }
            throw HostsFileError.adminAuthFailed(errorMsg)
        }
    }

    /// One-time installation: creates the helper script and sudoers entry.
    /// Uses a temporary shell script with explicit error handling per step,
    /// followed by post-install verification.
    private static func installHelperAndApply(
        tmpHostsPath: String,
        tmpPfPath: String,
        systemProxyURL: String?,
        wrappersDir: String? = nil,
        browserPoliciesDir: String? = nil
    ) async throws {
        let helperScript = helperScriptContent()
        let aliasScript = aliasManagerScriptContent()
        let payloadGuardScript = payloadGuardScriptContent()

        let tmpHelper = FileManager.default.temporaryDirectory.appendingPathComponent("focusshield_helper_install")
        let tmpAlias = FileManager.default.temporaryDirectory.appendingPathComponent("focusshield_update_aliases_install")
        let tmpPayloadGuard = FileManager.default.temporaryDirectory.appendingPathComponent("focusshield_cli_guard_install")
        try helperScript.write(to: tmpHelper, atomically: true, encoding: .utf8)
        try aliasScript.write(to: tmpAlias, atomically: true, encoding: .utf8)
        try payloadGuardScript.write(to: tmpPayloadGuard, atomically: true, encoding: .utf8)

        let currentUser = NSUserName()
        let sudoersEntry = """
\(currentUser) ALL=(root) NOPASSWD: \(helperPath)
\(currentUser) ALL=(root) NOPASSWD: \(dnsProxyPath) *
\(currentUser) ALL=(root) NOPASSWD: /bin/kill *
\(currentUser) ALL=(root) NOPASSWD: /usr/bin/pkill -f focusshield-dns
\(currentUser) ALL=(root) NOPASSWD: /usr/bin/killall -HUP mDNSResponder
\(currentUser) ALL=(root) NOPASSWD: /usr/sbin/networksetup -setdnsservers *
"""
        let tmpSudoers = FileManager.default.temporaryDirectory.appendingPathComponent("focusshield_sudoers_install")
        try sudoersEntry.write(to: tmpSudoers, atomically: true, encoding: .utf8)

        let proxyArg = systemProxyURL ?? "disable"
        let modeArg = systemProxyURL == nil ? "disable" : "enable"

        var helperInvocation = "'\(helperPath)' '\(tmpHostsPath)' '\(tmpPfPath)' '\(proxyArg)' '\(modeArg)'"
        if let wrappersDir {
            helperInvocation += " '\(wrappersDir)'"
        }
        if let browserPoliciesDir {
            if wrappersDir == nil {
                helperInvocation += " ''"
            }
            helperInvocation += " '\(browserPoliciesDir)'"
        }

        // Build a temporary install script with strict error handling.
        // This replaces the fragile && chain that could silently drop the sudoers file.
        let installScript = """
#!/bin/bash
set -e

# Step 1: Install helper binary and support scripts
mkdir -p '\(supportScriptsDir)'
cp '\(tmpHelper.path)' '\(helperPath)'
chmod 755 '\(helperPath)'
chown root:wheel '\(helperPath)'
cp '\(tmpAlias.path)' '\(aliasManagerPath)'
chmod 755 '\(aliasManagerPath)'
chown root:wheel '\(aliasManagerPath)'
cp '\(tmpPayloadGuard.path)' '\(payloadGuardPath)'
chmod 755 '\(payloadGuardPath)'
chown root:wheel '\(payloadGuardPath)'

# Step 2: Install sudoers file with validation.
cp '\(tmpSudoers.path)' '\(sudoersPath)'
chmod 440 '\(sudoersPath)'
chown root:wheel '\(sudoersPath)'

# Step 3: Validate sudoers syntax. On failure, remove it and abort.
if ! /usr/sbin/visudo -c -f '\(sudoersPath)' 2>/dev/null; then
    rm -f '\(sudoersPath)'
    echo 'FOCUSSHIELD_ERROR: sudoers validation failed' >&2
    exit 10
fi

# Step 4: Invoke the helper to apply the current policy.
\(helperInvocation)

# Step 5: Final verification — sudoers must still exist.
if [ ! -f '\(sudoersPath)' ]; then
    echo 'FOCUSSHIELD_ERROR: sudoers file missing after install' >&2
    exit 11
fi
"""
        let tmpInstallScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("focusshield_install_\(UUID().uuidString).sh")
        try installScript.write(to: tmpInstallScript, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tmpHelper)
            try? FileManager.default.removeItem(at: tmpAlias)
            try? FileManager.default.removeItem(at: tmpPayloadGuard)
            try? FileManager.default.removeItem(at: tmpSudoers)
            try? FileManager.default.removeItem(at: tmpInstallScript)
        }

        let shellCommand = "/bin/bash '\(tmpInstallScript.path)'"
        let appleScript = "do shell script \"\(shellCommand)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"

            if errorMessage.contains("User canceled") || errorMessage.contains("-128") {
                throw HostsFileError.userCancelled
            }
            if errorMessage.contains("FOCUSSHIELD_ERROR: sudoers") {
                throw HostsFileError.helperInstallFailed(
                    "Sudoers validation failed. The helper cannot run without a valid sudoers entry."
                )
            }
            throw HostsFileError.adminAuthFailed(errorMessage)
        }

        // Post-install verification: confirm critical artifacts actually exist.
        guard FileManager.default.fileExists(atPath: helperPath),
              FileManager.default.fileExists(atPath: sudoersPath) else {
            throw HostsFileError.helperVerificationFailed
        }
    }

    private static func helperScriptContent() -> String {
        """
#!/bin/bash
# FocusShield privileged helper v5
# Usage: focusshield-helper <hosts_tmp> <pf_tmp> <pac_url|disable> <enable|disable> [wrappers_tmp_dir] [browser_policies_tmp_dir]
set -e
HOSTS_TMP="$1"
PF_TMP="$2"
PAC_URL="$3"
PROXY_MODE="$4"
WRAPPERS_TMP="$5"
BROWSER_POLICIES_TMP="$6"

if [ -f "$HOSTS_TMP" ]; then
    cp "$HOSTS_TMP" /etc/hosts
    chmod 644 /etc/hosts
fi

if [ -f "$PF_TMP" ]; then
    mkdir -p /etc/pf.anchors
    cp "$PF_TMP" "\(pfRulesPath)"
    chmod 644 "\(pfRulesPath)"
fi
if ! grep -q 'com.focusshield' /etc/pf.conf 2>/dev/null; then
    echo 'anchor "com.focusshield"' >> /etc/pf.conf
    echo 'load anchor "com.focusshield" from "\(pfRulesPath)"' >> /etc/pf.conf
fi
pfctl -a com.focusshield -f "\(pfRulesPath)" 2>/dev/null || true
pfctl -e 2>/dev/null || true

dscacheutil -flushcache 2>/dev/null || true
killall -HUP mDNSResponder 2>/dev/null || true

SERVICES=$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2)
if [ "$PROXY_MODE" = "enable" ] && [ "$PAC_URL" != "disable" ]; then
    while IFS= read -r SERVICE; do
        networksetup -setautoproxyurl "$SERVICE" "$PAC_URL" 2>/dev/null || true
        networksetup -setautoproxystate "$SERVICE" on 2>/dev/null || true
    done <<< "$SERVICES"
else
    while IFS= read -r SERVICE; do
        networksetup -setautoproxystate "$SERVICE" off 2>/dev/null || true
    done <<< "$SERVICES"
fi

WRAPPER_STORE="\(supportScriptsDir)/wrappers"
SAVED_DIR="\(supportScriptsDir)/saved"
if [ -n "$WRAPPERS_TMP" ] && [ -d "$WRAPPERS_TMP" ]; then
    mkdir -p "$WRAPPER_STORE" "$SAVED_DIR"
    ACTIVE_TOOLS=""
    for wrapper in "$WRAPPERS_TMP"/*; do
        [ -f "$wrapper" ] || continue
        TOOL=$(basename "$wrapper")
        ACTIVE_TOOLS="$ACTIVE_TOOLS $TOOL"
        DEST="$WRAPPER_STORE/$TOOL"
        LINK="/usr/local/bin/$TOOL"
        cp "$wrapper" "$DEST"
        chmod 755 "$DEST"
        if [ -e "$LINK" ] && [ ! -L "$LINK" ]; then
            cp "$LINK" "$SAVED_DIR/$TOOL"
        fi
        ln -sf "$DEST" "$LINK"
    done

    if [ -n "$SUDO_USER" ] && [ -x "\(aliasManagerPath)" ]; then
        sudo -u "$SUDO_USER" "\(aliasManagerPath)" || true
    fi

    if [ -d "$WRAPPER_STORE" ]; then
        for existing in "$WRAPPER_STORE"/*; do
            [ -f "$existing" ] || continue
            TOOL=$(basename "$existing")
            case " $ACTIVE_TOOLS " in
                *" $TOOL "*) ;;
                *)
                    rm -f "$existing" "/usr/local/bin/$TOOL"
                    [ -f "$SAVED_DIR/$TOOL" ] && mv "$SAVED_DIR/$TOOL" "/usr/local/bin/$TOOL"
                    ;;
            esac
        done
    fi
elif [ "$PROXY_MODE" = "disable" ]; then
    if [ -x "\(aliasManagerPath)" ] && [ -n "$SUDO_USER" ]; then
        sudo -u "$SUDO_USER" "\(aliasManagerPath)" --remove || true
    fi

    if [ -d "$WRAPPER_STORE" ]; then
        for wrapper in "$WRAPPER_STORE"/*; do
            [ -f "$wrapper" ] || continue
            TOOL=$(basename "$wrapper")
            rm -f "$wrapper" "/usr/local/bin/$TOOL"
            [ -f "$SAVED_DIR/$TOOL" ] && mv "$SAVED_DIR/$TOOL" "/usr/local/bin/$TOOL"
        done
    fi
fi

MANAGED_PREFS_DIR="\(managedPreferencesDir)"
FIREFOX_POLICY_DEST="\(firefoxManagedPolicyPath)"
if [ -n "$BROWSER_POLICIES_TMP" ] && [ -d "$BROWSER_POLICIES_TMP" ]; then
    mkdir -p "$MANAGED_PREFS_DIR" "$(dirname "$FIREFOX_POLICY_DEST")"

    ACTIVE_POLICY_IDS=""
    for policy in "$BROWSER_POLICIES_TMP"/*; do
        [ -f "$policy" ] || continue
        base=$(basename "$policy")
        case "$base" in
            *.plist)
                bundle_id="${base%.plist}"
                ACTIVE_POLICY_IDS="$ACTIVE_POLICY_IDS $bundle_id"
                cp "$policy" "$MANAGED_PREFS_DIR/$base"
                chmod 644 "$MANAGED_PREFS_DIR/$base"
                ;;
            org.mozilla.firefox.json)
                ACTIVE_POLICY_IDS="$ACTIVE_POLICY_IDS org.mozilla.firefox"
                cp "$policy" "$FIREFOX_POLICY_DEST"
                chmod 644 "$FIREFOX_POLICY_DEST"
                ;;
        esac
    done

    for existing in "$MANAGED_PREFS_DIR"/*.plist; do
        [ -f "$existing" ] || continue
        bundle_id=$(basename "$existing" .plist)
        case " $ACTIVE_POLICY_IDS " in
            *" $bundle_id "*) ;;
            *) rm -f "$existing" ;;
        esac
    done

    case " $ACTIVE_POLICY_IDS " in
        *" org.mozilla.firefox "*) ;;
        *) rm -f "$FIREFOX_POLICY_DEST" ;;
    esac
else
    rm -f "$MANAGED_PREFS_DIR"/com.google.Chrome.plist \
          "$MANAGED_PREFS_DIR"/company.thebrowser.Browser.plist \
          "$MANAGED_PREFS_DIR"/com.brave.Browser.plist \
          "$MANAGED_PREFS_DIR"/com.microsoft.edgemac.plist \
          "$MANAGED_PREFS_DIR"/com.operasoftware.Opera.plist \
          "$MANAGED_PREFS_DIR"/com.vivaldi.Vivaldi.plist \
          "$MANAGED_PREFS_DIR"/org.chromium.Chromium.plist \
          "$FIREFOX_POLICY_DEST"
fi
"""
    }

    private static func aliasManagerScriptContent() -> String {
        """
#!/bin/bash
set -euo pipefail

TARGETS=("$HOME/.zshrc" "$HOME/.bashrc")
ALIAS_START="# --- FocusShield Aliases START ---"
ALIAS_END="# --- FocusShield Aliases END ---"
WRAPPER_DIR="\(supportScriptsDir)/wrappers"

remove_block() {
    local target="$1"
    [ -f "$target" ] || return 0
    sed -i.bak '/# --- FocusShield Aliases START ---/,/# --- FocusShield Aliases END ---/d' "$target"
    rm -f "${target}.bak"
}

if [ "${1:-}" = "--remove" ]; then
    for target in "${TARGETS[@]}"; do
        remove_block "$target"
    done
    exit 0
fi

ALIAS_BLOCK="$ALIAS_START\n"
if [ -d "$WRAPPER_DIR" ]; then
    for wrapper in "$WRAPPER_DIR"/*; do
        [ -f "$wrapper" ] || continue
        [ -x "$wrapper" ] || continue
        tool=$(basename "$wrapper")
        ALIAS_BLOCK+="alias $tool=\"$wrapper\"\n"
    done
fi
ALIAS_BLOCK+="$ALIAS_END\n"

for target in "${TARGETS[@]}"; do
    [ -f "$target" ] || continue
    remove_block "$target"
    if [ -d "$WRAPPER_DIR" ] && [ "$(ls -A "$WRAPPER_DIR" 2>/dev/null)" ]; then
        printf "%b" "$ALIAS_BLOCK" >> "$target"
    fi
done
"""
    }

    private static func payloadGuardScriptContent() -> String {
        // IMPORTANT: This script is installed to /usr/local/lib/focusshield/focusshield-cli-guard.
        // It MUST match focusshield-cli-guard.sh in the project root.
        // Key invariant: strip PATH to safe system paths BEFORE calling ANY utility,
        // so that wrapped tools (cat, grep, etc.) in /usr/local/bin never resolve here.
        #"""
#!/bin/sh
set -eu

REAL_EXEC="$1"
shift

# ── Guard against recursive invocation ──
# Strip wrapper dirs from PATH for the duration of this script.
# All utilities below MUST use full /usr/bin/ or /bin/ prefixes.
_FS_SAVED_PATH="$PATH"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

TOOL_NAME="${FOCUSSHIELD_TOOL_NAME:-$(/usr/bin/basename "$REAL_EXEC")}"
FILTER_MODE="${FOCUSSHIELD_FILTER_MODE:-blacklist}"
DOMAIN_RULES_B64="${FOCUSSHIELD_DOMAIN_RULES_B64:-}"
PAYLOAD_PROTECTION="${FOCUSSHIELD_PAYLOAD_PROTECTION:-0}"
PATTERNS_FILE="${FOCUSSHIELD_PAYLOAD_PATTERNS_FILE:-}"
ALLOWLIST_FILE="${FOCUSSHIELD_PAYLOAD_ALLOWLIST_FILE:-}"
SESSION_ALLOWLIST_FILE="${FOCUSSHIELD_PAYLOAD_SESSION_ALLOWLIST_FILE:-}"

# ── On-demand domain-add via env vars ──
FS_ONDEMAND_MODE=""
FS_LIST_VAL="${l:-${list:-}}"
case "$FS_LIST_VAL" in
    w|white|whitelist) FS_ONDEMAND_MODE="whitelist" ;;
    b|black|blacklist) FS_ONDEMAND_MODE="blacklist" ;;
    "") ;;
    *) /bin/echo "focusshield: unknown list mode '$FS_LIST_VAL'. Use l=w or l=b." >&2 ;;
esac

if [ -n "$FS_ONDEMAND_MODE" ]; then
    DB_PATH="$HOME/Library/Application Support/FocusShield/focusshield.sqlite"
    if [ -f "$DB_PATH" ]; then
        FS_HOSTS=$(/bin/printf '%s\n' "$@" | /usr/bin/perl -ne 'while (/(?:https?:\/\/)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?::\d+)?(?:[\/\s"<>]|$)/g) { print lc($1), "\n"; }' | /usr/bin/sort -u)
        if [ -n "$FS_HOSTS" ]; then
            APP_RULE_ID=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT id FROM app_rules WHERE executablePath = '$REAL_EXEC' AND ruleType = 'cliTool' LIMIT 1" 2>/dev/null || true)
            PROFILE_ID=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT profileID FROM app_rules WHERE id = '$APP_RULE_ID' LIMIT 1" 2>/dev/null || true)
            if [ -n "$APP_RULE_ID" ] && [ -n "$PROFILE_ID" ]; then
                CURRENT_MODE=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT filterMode FROM app_rules WHERE id = $APP_RULE_ID" 2>/dev/null || true)
                if [ "$CURRENT_MODE" != "$FS_ONDEMAND_MODE" ]; then
                    /usr/bin/sqlite3 "$DB_PATH" "UPDATE app_rules SET filterMode = '$FS_ONDEMAND_MODE' WHERE id = $APP_RULE_ID" 2>/dev/null || true
                    FILTER_MODE="$FS_ONDEMAND_MODE"
                fi
                /bin/printf '%s\n' "$FS_HOSTS" | while IFS= read -r fs_host; do
                    [ -n "$fs_host" ] || continue
                    EXISTS=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM domain_rules WHERE appRuleID = $APP_RULE_ID AND domain = '$fs_host'" 2>/dev/null || /bin/echo "0")
                    if [ "$EXISTS" = "0" ]; then
                        /usr/bin/sqlite3 "$DB_PATH" "INSERT INTO domain_rules (profileID, appRuleID, domain, isEnabled) VALUES ($PROFILE_ID, $APP_RULE_ID, '$fs_host', 1)" 2>/dev/null || true
                    fi
                done
                UPDATED_DOMAINS=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT domain FROM domain_rules WHERE appRuleID = $APP_RULE_ID AND isEnabled = 1" 2>/dev/null || true)
                if [ -n "$UPDATED_DOMAINS" ]; then
                    DOMAIN_RULES_B64=$(/bin/printf '%s' "$UPDATED_DOMAINS" | /usr/bin/base64)
                fi
                FILTER_MODE=$(/usr/bin/sqlite3 "$DB_PATH" "SELECT filterMode FROM app_rules WHERE id = $APP_RULE_ID" 2>/dev/null || /bin/echo "$FILTER_MODE")
            fi
        fi
    fi
fi

SCAN_FILE=$(/usr/bin/mktemp -t focusshield_scan.XXXXXX)
STDIN_FILE=""

cleanup() {
    /bin/rm -f "$SCAN_FILE"
    if [ -n "$STDIN_FILE" ] && [ -f "$STDIN_FILE" ]; then
        /bin/rm -f "$STDIN_FILE"
    fi
}
trap cleanup EXIT INT TERM HUP

/bin/printf 'tool=%s\n' "$TOOL_NAME" > "$SCAN_FILE"
/bin/printf 'argv=' >> "$SCAN_FILE"
/bin/printf '%s ' "$@" >> "$SCAN_FILE"
/bin/printf '\n' >> "$SCAN_FILE"

if [ ! -t 0 ]; then
    STDIN_FILE=$(/usr/bin/mktemp -t focusshield_stdin.XXXXXX)
    /bin/cat > "$STDIN_FILE"
    /bin/printf '\nstdin:\n' >> "$SCAN_FILE"
    /usr/bin/head -c 262144 "$STDIN_FILE" >> "$SCAN_FILE" 2>/dev/null || true
    /bin/printf '\n' >> "$SCAN_FILE"
fi

for arg in "$@"; do
    candidate="$arg"
    case "$candidate" in
        @*) candidate="${candidate#@}" ;;
    esac
    if [ -f "$candidate" ]; then
        /bin/printf '\nfile:%s\n' "$candidate" >> "$SCAN_FILE"
        /usr/bin/head -c 131072 "$candidate" >> "$SCAN_FILE" 2>/dev/null || true
        /bin/printf '\n' >> "$SCAN_FILE"
    fi
done

decode_domain_rules() {
    [ -z "$DOMAIN_RULES_B64" ] && return 0
    /bin/printf '%s' "$DOMAIN_RULES_B64" | /usr/bin/base64 -D 2>/dev/null || true
}

extract_hosts() {
    /usr/bin/perl -ne 'while (/(?:https?:\/\/)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})(?::\d+)?(?:[\/\s"<>]|$)/g) { print lc($1), "\n"; }' "$SCAN_FILE" | /usr/bin/sort -u
}

host_matches_rule() {
    local host="$1" rule="$2"
    case "$rule" in [*].*) rule="${rule#*.}" ;; esac
    case "$host" in "$rule"|*."$rule") return 0 ;; esac
    return 1
}

check_domain_policy() {
    local rules hosts violation matched
    violation=0
    rules="$(decode_domain_rules)"
    [ -n "$rules" ] || return 0
    hosts="$(extract_hosts)"
    [ -n "$hosts" ] || return 0

    FS_HOSTS_TMP=$(/usr/bin/mktemp -t fs_hosts.XXXXXX)
    FS_RULES_TMP=$(/usr/bin/mktemp -t fs_rules.XXXXXX)
    /bin/printf '%s\n' "$hosts" > "$FS_HOSTS_TMP"
    /bin/printf '%s\n' "$rules" > "$FS_RULES_TMP"

    while IFS= read -r host; do
        [ -n "$host" ] || continue
        matched=1
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            if host_matches_rule "$host" "$rule"; then matched=0; break; fi
        done < "$FS_RULES_TMP"
        if [ "$FILTER_MODE" = "whitelist" ] && [ "$matched" -ne 0 ]; then
            /bin/echo "focusshield: blocked '$TOOL_NAME' because '$host' is outside the allowed domain list." >&2
            violation=1
        fi
        if [ "$FILTER_MODE" = "blacklist" ] && [ "$matched" -eq 0 ]; then
            /bin/echo "focusshield: blocked '$TOOL_NAME' because '$host' matches a blocked domain rule." >&2
            violation=1
        fi
    done < "$FS_HOSTS_TMP"
    /bin/rm -f "$FS_HOSTS_TMP" "$FS_RULES_TMP"
    return "$violation"
}

contains_allow_fingerprint() {
    [ -f "$2" ] || return 1
    /usr/bin/grep -Fxq "$1" "$2"
}

record_allow_fingerprint() {
    /bin/mkdir -p "$(/usr/bin/dirname "$2")"
    /usr/bin/touch "$2"
    contains_allow_fingerprint "$1" "$2" || /bin/echo "$1" >> "$2"
}

escape_applescript() {
    local value="$1"
    value="${value//\/\\}"
    value="${value//\"/\\"}"
    value="${value//$'\n'/\n}"
    /bin/printf '%s' "$value"
}

check_payload_patterns() {
    [ "$PAYLOAD_PROTECTION" = "1" ] || return 0
    [ -n "$PATTERNS_FILE" ] && [ -f "$PATTERNS_FILE" ] || return 0

    local matched_names="" name regex
    while IFS=$'\t' read -r name regex; do
        [ -n "$name" ] && [ -n "$regex" ] || continue
        if /usr/bin/perl -0e 'use strict; use warnings; my $p=shift @ARGV; local $/; my $d=<STDIN>; exit(($d=~/$p/im)?0:1);' "$regex" < "$SCAN_FILE"; then
            matched_names="${matched_names}${name}\n"
        fi
    done < "$PATTERNS_FILE"
    [ -n "$matched_names" ] || return 0

    local fingerprint
    fingerprint=$(/usr/bin/shasum -a 256 "$SCAN_FILE" | /usr/bin/awk '{print $1}')
    [ -n "$ALLOWLIST_FILE" ] || ALLOWLIST_FILE="/tmp/focusshield-payload-allowlist.txt"
    [ -n "$SESSION_ALLOWLIST_FILE" ] || SESSION_ALLOWLIST_FILE="/tmp/focusshield-payload-session-allowlist.txt"
    /usr/bin/touch "$ALLOWLIST_FILE" "$SESSION_ALLOWLIST_FILE"
    contains_allow_fingerprint "$fingerprint" "$ALLOWLIST_FILE" && return 0
    contains_allow_fingerprint "$fingerprint" "$SESSION_ALLOWLIST_FILE" && return 0

    local clean_names message button
    clean_names=$(/bin/printf "%b" "$matched_names" | /usr/bin/sed '/^$/d')
    message=$(/bin/printf "FocusShield detected sensitive payload patterns for %s:\n\n%s\n\nAllow this request?" "$TOOL_NAME" "$clean_names")
    button=$(/usr/bin/osascript -e "button returned of (display dialog \"$(escape_applescript "$message")\" buttons {\"Deny\", \"Allow Session\", \"Always Allow\"} default button \"Deny\" with icon caution)" 2>/dev/null || true)
    case "$button" in
        "Allow Session") record_allow_fingerprint "$fingerprint" "$SESSION_ALLOWLIST_FILE" ;;
        "Always Allow")  record_allow_fingerprint "$fingerprint" "$ALLOWLIST_FILE" ;;
        *) /bin/echo "focusshield: request denied because sensitive payload patterns were detected." >&2; return 1 ;;
    esac
}

check_invisible_chars() {
    CHARSCAN_ENABLED="${FOCUSSHIELD_CHARSCAN_ENABLED:-0}"
    [ "$CHARSCAN_ENABLED" = "1" ] || return 0
    CHARSCAN_ZWSP="${FOCUSSHIELD_CHARSCAN_ZWSP:-0}"
    CHARSCAN_RTL="${FOCUSSHIELD_CHARSCAN_RTL:-0}"
    CHARSCAN_TAGS="${FOCUSSHIELD_CHARSCAN_TAGS:-0}"
    CHARSCAN_INVIS="${FOCUSSHIELD_CHARSCAN_INVIS:-0}"
    CHARSCAN_HOMOGLYPH="${FOCUSSHIELD_CHARSCAN_HOMOGLYPH:-0}"
    local checks=""
    [ "$CHARSCAN_ZWSP"      = "1" ] && checks="${checks}zwsp,"
    [ "$CHARSCAN_RTL"       = "1" ] && checks="${checks}rtl,"
    [ "$CHARSCAN_TAGS"      = "1" ] && checks="${checks}tags,"
    [ "$CHARSCAN_INVIS"     = "1" ] && checks="${checks}invis,"
    [ "$CHARSCAN_HOMOGLYPH" = "1" ] && checks="${checks}homoglyph,"
    [ -n "$checks" ] || return 0

    local hit_names
    hit_names=$(/usr/bin/perl -e '
use strict; use warnings;
binmode(STDIN, ":utf8");
my @checks = split(/,/, $ARGV[0] // "");
local $/; my $data = <STDIN> // "";
my %found;
for my $c (@checks) {
    if    ($c eq "zwsp")      { $found{$c}++ if $data =~ /[\x{200B}\x{200C}\x{200D}\x{FEFF}\x{2060}\x{FFFC}\x{FFF9}\x{FFFA}\x{FFFB}]/ }
    elsif ($c eq "rtl")       { $found{$c}++ if $data =~ /[\x{202A}-\x{202E}\x{2066}-\x{2069}]/ }
    elsif ($c eq "tags")      { $found{$c}++ if $data =~ /[\x{E0001}-\x{E007F}]/ }
    elsif ($c eq "invis")     { $found{$c}++ if $data =~ /[\x{00AD}\x{115F}\x{1160}\x{3164}\x{17B4}\x{17B5}\x{180B}-\x{180D}\x{FE00}-\x{FE0F}]/ }
    elsif ($c eq "homoglyph") { $found{$c}++ if $data =~ /[\x{0430}-\x{0435}\x{043E}\x{0440}\x{0441}\x{0445}\x{03BF}\x{03B1}]/ }
}
print join("\n", keys %found), "\n" if %found;
' "$checks" < "$SCAN_FILE" 2>/dev/null || true)
    [ -n "$hit_names" ] || return 0

    local fingerprint
    fingerprint=$(/bin/printf '%s%s' "$hit_names" "$(/usr/bin/wc -c < "$SCAN_FILE")" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
    [ -n "$ALLOWLIST_FILE" ]         || ALLOWLIST_FILE="/tmp/focusshield-payload-allowlist.txt"
    [ -n "$SESSION_ALLOWLIST_FILE" ] || SESSION_ALLOWLIST_FILE="/tmp/focusshield-payload-session-allowlist.txt"
    /usr/bin/touch "$ALLOWLIST_FILE" "$SESSION_ALLOWLIST_FILE"
    contains_allow_fingerprint "$fingerprint" "$ALLOWLIST_FILE" && return 0
    contains_allow_fingerprint "$fingerprint" "$SESSION_ALLOWLIST_FILE" && return 0

    local labels message button
    labels=$(/bin/printf '%s\n' "$hit_names" | /usr/bin/sed \
        -e 's/zwsp/Zero-Width Characters/g' \
        -e 's/rtl/RTL Override\/Embedding/g' \
        -e 's/tags/Invisible Tag Characters (prompt-injection risk)/g' \
        -e 's/invis/Invisible Format Characters/g' \
        -e 's/homoglyph/Unicode Homoglyphs (lookalike letters)/g')
    message=$(/bin/printf "FocusShield detected suspicious Unicode in the %s payload:\n\n%s\n\nAllow this request?" "$TOOL_NAME" "$labels")
    button=$(/usr/bin/osascript \
        -e "button returned of (display dialog \"$(escape_applescript "$message")\" \
            buttons {\"Deny\", \"Allow Session\", \"Always Allow\"} \
            default button \"Deny\" with icon caution)" 2>/dev/null || true)
    case "$button" in
        "Allow Session") record_allow_fingerprint "$fingerprint" "$SESSION_ALLOWLIST_FILE" ;;
        "Always Allow")  record_allow_fingerprint "$fingerprint" "$ALLOWLIST_FILE" ;;
        *) /bin/echo "focusshield: request denied — invisible/bad Unicode characters detected in payload." >&2; return 1 ;;
    esac
}

check_domain_policy
check_payload_patterns
check_invisible_chars

# Restore full PATH so the real tool runs in the user's environment
export PATH="$_FS_SAVED_PATH"

if [ -n "$STDIN_FILE" ]; then
    exec "$REAL_EXEC" "$@" < "$STDIN_FILE"
fi

exec "$REAL_EXEC" "$@"
"""#
    }

    // MARK: - DNS Proxy Management

    /// Starts the DNS proxy server (runs as root on port 53).
    private static func startDNSProxy(mode: FilterMode = .blacklist) async throws {
        await stopDNSProxySilent()
        captureOriginalDNS()
        try await setSystemDNS(to: "127.0.0.1")
        try await flushDNSCache()
        let upstreamDNS = preferredUpstreamDNS(from: getOriginalDNSSettings()) ?? "8.8.8.8"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [dnsProxyPath, domainsFilePath, upstreamDNS, mode.rawValue]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        print("[DNS] Started DNS proxy (mode: \(mode.rawValue), upstream: \(upstreamDNS))")
    }

    /// Stops the DNS proxy and restores original DNS.
    static func stopDNSProxy() async throws {
        await stopDNSProxySilent()
        let originalSettings = getOriginalDNSSettings()
        if originalSettings.isEmpty {
            try await setSystemDNS(to: "empty")
        } else {
            for (service, dns) in originalSettings {
                try await setSystemDNS(to: dns, services: [service])
            }
        }
        try await flushDNSCache()
    }

    /// Stops the DNS proxy silently (internal use).
    private static func stopDNSProxySilent() async {
        if let pidString = try? String(contentsOfFile: dnsPidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidString) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            proc.arguments = ["kill", String(pid)]
            proc.standardOutput = Pipe(); proc.standardError = Pipe()
            try? proc.run(); proc.waitUntilExit()
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["pkill", "-f", "focusshield-dns"]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        try? proc.run(); proc.waitUntilExit()
    }

    /// Sends SIGHUP to reload blocked domains.
    static func reloadDNSProxy() {
        if let pidString = try? String(contentsOfFile: dnsPidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidString) {
            kill(pid, SIGHUP)
            print("[DNS] Sent SIGHUP to DNS proxy (PID: \(pid))")
        }
    }

    /// Captures the current DNS servers before we change them.
    private static func captureOriginalDNS() {
        // Only capture if we haven't already
        if FileManager.default.fileExists(atPath: originalDNSPath) { return }

        var snapshot: [String: String] = [:]
        for service in listNetworkServices() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            process.arguments = ["-getdnsservers", service]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()

            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if output.contains("any DNS") || output.isEmpty {
                snapshot[service] = "empty"
            } else {
                snapshot[service] = output.components(separatedBy: .newlines).first ?? "empty"
            }
        }

        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: URL(fileURLWithPath: originalDNSPath), options: .atomic)
        }
    }

    private static func getOriginalDNSSettings() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: originalDNSPath)),
              let settings = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return settings
    }

    private static func preferredUpstreamDNS(from settings: [String: String]) -> String? {
        settings.values.first { !$0.isEmpty && $0 != "empty" }
    }

    /// Sets system DNS servers via networksetup (requires sudo).
    private static func setSystemDNS(to dns: String, services: [String]? = nil) async throws {
        let targetServices = services ?? listNetworkServices()
        for service in targetServices {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            if dns == "empty" {
                process.arguments = ["/usr/sbin/networksetup", "-setdnsservers", service, "Empty"]
            } else {
                process.arguments = ["/usr/sbin/networksetup", "-setdnsservers", service, dns]
            }
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        }
    }

    private static func listNetworkServices() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallnetworkservices"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output
            .components(separatedBy: .newlines)
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    /// Flushes the macOS DNS cache.
    private static func flushDNSCache() async throws {
        let flush = Process()
        flush.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        flush.arguments = ["-flushcache"]
        flush.standardOutput = Pipe()
        flush.standardError = Pipe()
        try? flush.run()
        flush.waitUntilExit()

        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        kill.arguments = ["killall", "-HUP", "mDNSResponder"]
        kill.standardOutput = Pipe()
        kill.standardError = Pipe()
        try? kill.run()
        kill.waitUntilExit()
    }

    /// Whether the DNS proxy binary is installed.
    static var isDNSProxyInstalled: Bool {
        FileManager.default.fileExists(atPath: dnsProxyPath)
    }
}

enum HostsFileError: LocalizedError {
    case adminAuthFailed(String)
    case userCancelled
    case writeFailed
    case helperInstallFailed(String)
    case helperVerificationFailed

    var errorDescription: String? {
        switch self {
        case .adminAuthFailed(let msg):
            return "Admin authentication failed: \(msg)"
        case .userCancelled:
            return "Authentication cancelled."
        case .writeFailed:
            return "Failed to write hosts file."
        case .helperInstallFailed(let msg):
            return "Helper installation failed: \(msg)"
        case .helperVerificationFailed:
            return "Helper installation could not be verified — sudoers or helper binary missing after install."
        }
    }
}
