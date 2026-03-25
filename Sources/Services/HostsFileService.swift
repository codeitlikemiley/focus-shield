import Foundation

/// Manages website blocking using a quad-layer approach:
///
/// 1. **`/etc/hosts`** — DNS-level blocking (Chrome, curl, native apps)
/// 2. **`pf` firewall** — Network-level blocking (IP-based)
/// 3. **PAC proxy file** — Proxy-level blocking (Chrome, Firefox)
/// 4. **Local DNS proxy** — Intercepts ALL DNS including Safari's (THE FIX)
///
/// Safari ignores /etc/hosts, pf, AND system proxy settings.
/// The only reliable way to block Safari is to intercept DNS queries directly
/// via a local DNS server on port 53.
///
/// Authentication: uses a privileged helper installed once (no repeated passwords).
enum HostsFileService {
    private static let startMarker = "# FocusShield START"
    private static let endMarker = "# FocusShield END"
    private static let hostsPath = "/etc/hosts"
    private static let pfAnchor = "com.focusshield"
    private static let pfRulesPath = "/etc/pf.anchors/com.focusshield"
    private static let helperPath = "/usr/local/bin/focusshield-helper"
    private static let sudoersPath = "/etc/sudoers.d/focusshield"
    private static let dnsProxyPath = "/usr/local/bin/focusshield-dns"
    private static let dnsPidPath = "/tmp/focusshield-dns.pid"
    private static let dnsSudoersPath = "/etc/sudoers.d/focusshield-dns"

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

    // MARK: - Public API

    /// Primary enforcement entry-point: applies a full ProfileNetworkPolicy across all layers.
    static func applyNetworkPolicy(_ policy: ProfileNetworkPolicy) async throws {
        // 1. Compute the flat global domain list
        let globalDomains = policy.globalDomains

        // 2. Build pf rules: global + per-CLI
        let pfRules = buildCombinedPfRules(
            globalDomains: globalDomains,
            globalMode: policy.globalMode,
            cliRules: policy.cliRules
        )

        // 3. Build PAC with per-app overrides
        let pacContent: String
        if policy.globalMode == .whitelist {
            // Whitelist PAC: block everything except allowed domains (+ per-app exceptions)
            pacContent = buildWhitelistPacFile(
                globalAllowed: globalDomains,
                appOverrides: policy.appDomainOverrides
            )
        } else {
            // Blacklist PAC: block listed domains, allow everything else
            pacContent = buildPacFile(for: globalDomains)
        }

        // 4. Hosts file (blacklist only — whitelist is handled by DNS proxy)
        let currentContent = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
        var newHostsContent = removeExistingEntries(from: currentContent)
        if !newHostsContent.hasSuffix("\n") { newHostsContent += "\n" }

        if policy.globalMode == .blacklist && !globalDomains.isEmpty {
            newHostsContent += "\(startMarker)\n"
            for domain in globalDomains {
                newHostsContent += "127.0.0.1 \(domain)\n"
            }
            newHostsContent += "\(endMarker)\n"
        }

        // 5. Write domains file for DNS proxy
        let domainsListContent = globalDomains.joined(separator: "\n")
        try domainsListContent.write(toFile: domainsFilePath, atomically: true, encoding: .utf8)

        // 6. Write + start PAC
        try pacContent.write(toFile: pacFilePath, atomically: true, encoding: .utf8)
        PACServer.shared.start(with: pacContent)

        // 7. Apply privileged operations
        try await applyBlocking(hostsContent: newHostsContent, pfRules: pfRules,
                                domains: globalDomains)

        // 8. Start DNS proxy
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
            for domain in domains {
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
        try await applyBlocking(hostsContent: newHostsContent, pfRules: pfRules, domains: domains)

        // 6. Start DNS proxy (after helper sets system DNS)
        if !domains.isEmpty {
            try await startDNSProxy(mode: mode)
        }
    }

    /// Removes all FocusShield entries, stops DNS proxy, restores DNS.
    static func removeAllEntries() async throws {
        let currentContent = try String(contentsOfFile: hostsPath, encoding: .utf8)
        let cleanedContent = removeExistingEntries(from: currentContent)

        // Update PAC to allow everything
        let emptyPac = "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n"
        try emptyPac.write(toFile: pacFilePath, atomically: true, encoding: .utf8)
        PACServer.shared.updateContent(emptyPac)

        // Stop DNS proxy first (restores original DNS)
        try await stopDNSProxy()

        // Clear domains file
        try "".write(toFile: domainsFilePath, atomically: true, encoding: .utf8)

        try await applyBlocking(hostsContent: cleanedContent, pfRules: "# FocusShield - no rules active\n", domains: [])
    }

    // MARK: - Helper Installation

    static var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: helperPath) &&
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    // MARK: - PAC File Generation (public for startup)

    /// Generates PAC file content for the given domains. Public so the ViewModel
    /// can start the PAC server at launch without triggering the full blocking flow.
    static func buildPacFileContent(for domains: [String]) -> String {
        return buildPacFile(for: domains)
    }

    // MARK: - Private: PAC file

    /// Generates a PAC (Proxy Auto-Config) file that routes blocked domains through a dead proxy.
    /// Safari and all browsers respect system proxy settings, making this the most reliable approach.
    private static func buildPacFile(for domains: [String]) -> String {
        if domains.isEmpty {
            return "function FindProxyForURL(url, host) { return \"DIRECT\"; }\n"
        }

        // Build a fast lookup using a JS object
        var domainList = ""
        // Also extract base domains for subdomain matching
        var baseDomains = Set<String>()
        for domain in domains {
            let escaped = domain.replacingOccurrences(of: "\"", with: "\\\"")
            domainList += "    \"\(escaped)\": true,\n"

            // Extract base domain (remove www., m., web., etc.)
            let parts = domain.split(separator: ".")
            if parts.count >= 2 {
                let base = parts.suffix(2).joined(separator: ".")
                baseDomains.insert(base)
            }
        }

        return """
        // FocusShield PAC — Auto-generated
        // Routes blocked domains through a dead proxy (127.0.0.1:9)
        var BLOCKED = {
        \(domainList)};

        function FindProxyForURL(url, host) {
            // Exact match
            if (BLOCKED[host]) return "PROXY 127.0.0.1:9";

            // Check if host ends with a blocked domain (subdomain matching)
            for (var domain in BLOCKED) {
                if (host.length > domain.length &&
                    host.substring(host.length - domain.length - 1) === "." + domain) {
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
        var lines = ""
        for domain in globalAllowed {
            let escaped = domain.replacingOccurrences(of: "\"", with: "\\\"")
            lines += "    \"\(escaped)\": true,\n"
        }
        // System safelist always allowed
        for domain in SystemSafelist.domains.sorted() {
            let escaped = domain.replacingOccurrences(of: "\"", with: "\\\"")
            lines += "    \"\(escaped)\": true,\n"
        }

        return """
        // FocusShield PAC — Whitelist mode
        var ALLOWED = {
        \(lines)};

        function FindProxyForURL(url, host) {
            if (ALLOWED[host]) return "DIRECT";
            for (var domain in ALLOWED) {
                if (host.length > domain.length &&
                    host.substring(host.length - domain.length - 1) === "." + domain) {
                    return "DIRECT";
                }
            }
            // Block everything else
            return "PROXY 127.0.0.1:9";
        }

        """
    }

    /// Builds combined pf rules: global domain blocks/allows + per-CLI process rules.
    private static func buildCombinedPfRules(
        globalDomains: [String],
        globalMode: FilterMode,
        cliRules: [ProfileNetworkPolicy.CLINetworkRule]
    ) -> String {
        var rules = "# FocusShield pf rules — auto-generated\n"

        // Global domain rules (blacklist mode only via pf)
        if globalMode == .blacklist && !globalDomains.isEmpty {
            rules += "# Global blacklist\n"
            for domain in globalDomains {
                rules += "block drop out quick on en0 proto tcp to \(domain) port { 80, 443 }\n"
                rules += "block drop out quick on en1 proto tcp to \(domain) port { 80, 443 }\n"
            }
        }

        // Per-CLI process rules (pf 'proc' keyword — macOS 14.4+)
        for cliRule in cliRules {
            let path = cliRule.executablePath
            if cliRule.isFullyBlocked {
                // Block ALL outbound for this executable
                rules += "# CLI fully blocked: \(path)\n"
                rules += "block drop out quick proto tcp proc \"\(path)\"\n"
                rules += "block drop out quick proto udp proc \"\(path)\"\n"
            } else if !cliRule.domains.isEmpty {
                if cliRule.filterMode == .whitelist {
                    // Block all except listed
                    rules += "# CLI whitelist: \(path)\n"
                    rules += "block drop out quick proto tcp proc \"\(path)\"\n"
                    for domain in cliRule.domains {
                        rules += "pass out quick proto tcp to \(domain) proc \"\(path)\"\n"
                    }
                } else {
                    // Blacklist: block only listed
                    rules += "# CLI blacklist: \(path)\n"
                    for domain in cliRule.domains {
                        rules += "block drop out quick proto tcp to \(domain) proc \"\(path)\"\n"
                    }
                }
            }
        }

        return rules
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

    private static func buildPfRules(for domains: [String]) -> String {
        var rules = "# FocusShield pf rules - auto-generated\n"
        if domains.isEmpty {
            rules += "# No domains to block\n"
        } else {
            rules += "# Block outgoing connections to blocked domains\n"
            for domain in domains {
                rules += "block drop out quick on en0 proto tcp to \(domain) port { 80, 443 }\n"
                rules += "block drop out quick on en1 proto tcp to \(domain) port { 80, 443 }\n"
            }
        }
        return rules
    }

    // MARK: - Private: Apply blocking

    private static func applyBlocking(hostsContent: String, pfRules: String, domains: [String]) async throws {
        let tmpHosts = FileManager.default.temporaryDirectory.appendingPathComponent("focusshield_hosts_\(UUID().uuidString)")
        let tmpPf = FileManager.default.temporaryDirectory.appendingPathComponent("focusshield_pf_\(UUID().uuidString)")

        try hostsContent.write(to: tmpHosts, atomically: true, encoding: .utf8)
        try pfRules.write(to: tmpPf, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tmpHosts)
            try? FileManager.default.removeItem(at: tmpPf)
        }

        if isHelperInstalled {
            try await runHelperDirectly(tmpHostsPath: tmpHosts.path, tmpPfPath: tmpPf.path, enableProxy: !domains.isEmpty)
        } else {
            try await installHelperAndApply(tmpHostsPath: tmpHosts.path, tmpPfPath: tmpPf.path, enableProxy: !domains.isEmpty)
        }
    }

    /// Runs the helper via sudo (no password needed after initial install).
    private static func runHelperDirectly(tmpHostsPath: String, tmpPfPath: String, enableProxy: Bool) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [helperPath, tmpHostsPath, tmpPfPath, enableProxy ? PACServer.proxyURL : "disable", enableProxy ? "enable" : "disable"]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMsg = String(data: errorData, encoding: .utf8) ?? ""

            if errorMsg.contains("password") || errorMsg.contains("sudo") {
                try await installHelperAndApply(tmpHostsPath: tmpHostsPath, tmpPfPath: tmpPfPath, enableProxy: enableProxy)
                return
            }
            throw HostsFileError.adminAuthFailed(errorMsg)
        }
    }

    /// One-time installation: creates the helper script and sudoers entry.
    private static func installHelperAndApply(tmpHostsPath: String, tmpPfPath: String, enableProxy: Bool) async throws {
        // The helper script handles: hosts, pf, AND proxy settings
        let helperScript = """
        #!/bin/bash
        # FocusShield privileged helper v3
        # Usage: focusshield-helper <hosts_tmp> <pf_tmp> <pac_url|disable> <enable|disable>
        set -e
        HOSTS_TMP="$1"
        PF_TMP="$2"
        PAC_URL="$3"
        PROXY_MODE="$4"

        # --- Hosts file ---
        if [ -f "$HOSTS_TMP" ]; then
            cp "$HOSTS_TMP" /etc/hosts
            chmod 644 /etc/hosts
        fi

        # --- PF firewall ---
        if [ -f "$PF_TMP" ]; then
            mkdir -p /etc/pf.anchors
            cp "$PF_TMP" /etc/pf.anchors/com.focusshield
            chmod 644 /etc/pf.anchors/com.focusshield
        fi
        if ! grep -q 'com.focusshield' /etc/pf.conf 2>/dev/null; then
            echo 'anchor "com.focusshield"' >> /etc/pf.conf
            echo 'load anchor "com.focusshield" from "/etc/pf.anchors/com.focusshield"' >> /etc/pf.conf
        fi
        pfctl -a com.focusshield -f /etc/pf.anchors/com.focusshield 2>/dev/null || true
        pfctl -e 2>/dev/null || true

        # --- DNS cache flush ---
        dscacheutil -flushcache 2>/dev/null || true
        killall -HUP mDNSResponder 2>/dev/null || true

        # --- PAC Proxy (for Safari/DoH browsers) ---
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
        """

        let tmpHelper = FileManager.default.temporaryDirectory.appendingPathComponent("focusshield_helper_install")
        try helperScript.write(to: tmpHelper, atomically: true, encoding: .utf8)

        let currentUser = NSUserName()
        let sudoersEntry = "\(currentUser) ALL=(root) NOPASSWD: \(helperPath)\n"
        let tmpSudoers = FileManager.default.temporaryDirectory.appendingPathComponent("focusshield_sudoers_install")
        try sudoersEntry.write(to: tmpSudoers, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tmpHelper)
            try? FileManager.default.removeItem(at: tmpSudoers)
        }

        let proxyArg = enableProxy ? PACServer.proxyURL : "disable"
        let modeArg = enableProxy ? "enable" : "disable"

        let installCommand = [
            "cp '\(tmpHelper.path)' '\(helperPath)'",
            "chmod 755 '\(helperPath)'",
            "chown root:wheel '\(helperPath)'",
            "cp '\(tmpSudoers.path)' '\(sudoersPath)'",
            "chmod 440 '\(sudoersPath)'",
            "chown root:wheel '\(sudoersPath)'",
            "visudo -c -f '\(sudoersPath)' || rm -f '\(sudoersPath)'",
            "'\(helperPath)' '\(tmpHostsPath)' '\(tmpPfPath)' '\(proxyArg)' '\(modeArg)'"
        ].joined(separator: " && ")

        let appleScript = "do shell script \"\(installCommand)\" with administrator privileges"

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
            throw HostsFileError.adminAuthFailed(errorMessage)
        }
    }

    // MARK: - DNS Proxy Management

    /// Starts the DNS proxy server (runs as root on port 53).
    private static func startDNSProxy(mode: FilterMode = .blacklist) async throws {
        // Kill any existing DNS proxy first
        await stopDNSProxySilent()

        // Capture original DNS before changing
        captureOriginalDNS()

        // Set system DNS to 127.0.0.1
        try await setSystemDNS(to: "127.0.0.1")

        // Flush DNS cache so system starts using our DNS proxy immediately
        try await flushDNSCache()

        // Start the DNS proxy as root (needs port 53)
        // Get the original upstream DNS for forwarding
        let upstreamDNS = getOriginalDNS() ?? "8.8.8.8"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = [dnsProxyPath, domainsFilePath, upstreamDNS, mode.rawValue]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        // Run in background (don't wait for exit — it's a long-running daemon)
        try process.run()
        print("[DNS] Started DNS proxy (mode: \(mode.rawValue))")
    }

    /// Stops the DNS proxy and restores original DNS.
    private static func stopDNSProxy() async throws {
        await stopDNSProxySilent()
        // Restore original DNS
        if let originalDNS = getOriginalDNS() {
            try await setSystemDNS(to: originalDNS)
        } else {
            try await setSystemDNS(to: "empty") // Reset to DHCP
        }
        try await flushDNSCache()
    }

    /// Stops the DNS proxy without restoring DNS (internal use).
    private static func stopDNSProxySilent() async {
        // Read PID file and kill
        if let pidString = try? String(contentsOfFile: dnsPidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidString) {
            // Kill via sudo (it runs as root)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["kill", String(pid)]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
        // Also try pkill as fallback
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["pkill", "-f", "focusshield-dns"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    /// Sends SIGHUP to the DNS proxy to reload blocked domains.
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getdnsservers", "Wi-Fi"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // If it says "no DNS servers set", the system uses DHCP DNS
        if output.contains("any DNS") || output.isEmpty {
            try? "empty".write(toFile: originalDNSPath, atomically: true, encoding: .utf8)
        } else {
            // Save the first DNS server
            let firstDNS = output.components(separatedBy: .newlines).first ?? "8.8.8.8"
            try? firstDNS.write(toFile: originalDNSPath, atomically: true, encoding: .utf8)
        }
    }

    /// Gets the saved original DNS server.
    private static func getOriginalDNS() -> String? {
        guard let dns = try? String(contentsOfFile: originalDNSPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !dns.isEmpty else { return nil }
        if dns == "empty" { return nil }
        return dns
    }

    /// Sets system DNS servers via networksetup (requires sudo).
    private static func setSystemDNS(to dns: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        if dns == "empty" {
            process.arguments = ["/usr/sbin/networksetup", "-setdnsservers", "Wi-Fi", "Empty"]
        } else {
            process.arguments = ["/usr/sbin/networksetup", "-setdnsservers", "Wi-Fi", dns]
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
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

    var errorDescription: String? {
        switch self {
        case .adminAuthFailed(let msg):
            return "Admin authentication failed: \(msg)"
        case .userCancelled:
            return "Authentication cancelled."
        case .writeFailed:
            return "Failed to write hosts file."
        }
    }
}
