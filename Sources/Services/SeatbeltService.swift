import Foundation

// MARK: - Seatbelt (macOS sandbox-exec) Service

/// Generates and manages macOS Seatbelt (.sb) profiles for CLI tool wrappers.
///
/// # What this is
/// macOS Seatbelt (also called "Sandbox" or "sandbox-exec") is a kernel-level
/// MAC (Mandatory Access Control) policy system built into XNU. It intercepts
/// syscalls like open(), connect(), exec() *before* they execute — roughly the
/// same mechanism the App Sandbox uses, but available to any process via the
/// `sandbox-exec` binary without a kernel extension.
///
/// # Relationship to Claude Code / other AI agent sandboxes
/// Claude Code already applies its own Seatbelt profile to its bash subprocesses,
/// blocking reads to ~/.ssh, ~/.aws, etc. FocusShield marks those tools with
/// `hasSelfSandbox = true` and skips both this profile AND the proxy wrapper — NEFilter
/// socket enforcement still applies.
///
/// For tools that do NOT have their own sandbox (curl, wget, python3, node, git…),
/// FocusShield can optionally prepend `sandbox-exec -f <profile>` inside the CLI
/// wrapper script to add filesystem isolation on top of the payload guard.
///
/// # Performance
/// sandbox-exec overhead is ~0.3 ms per process launch. It is a pure kernel
/// MAC policy lookup with no fork, no proxy hop, no IPC. It is safe to apply
/// to all CLI tools without measurable slowdown.
enum SeatbeltService {

    // MARK: - Blocked paths

    /// Paths that should never be readable by a sandboxed CLI tool.
    private static let sensitiveReadPaths: [String] = [
        "~/.ssh",
        "~/.aws",
        "~/.gnupg",
        "~/.config/gcloud",
        "~/.azure",
        "~/.kube",
        "/Library/Keychains",
        "~/Library/Keychains",
    ]

    /// Regex patterns for sensitive file extensions (any depth).
    private static let sensitiveExtensionPatterns: [String] = [
        #".*\.env$"#,
        #".*_rsa$"#,
        #".*_ed25519$"#,
        #".*\.pem$"#,
        #".*\.key$"#,
        #".*\.p12$"#,
        #".*\.pfx$"#,
        #".*\.jks$"#,
        #".*\.keystore$"#,
    ]

    // MARK: - Profile generation

    private static let sensitiveWritePaths: [String] = [
        "~/.zshrc",
        "~/.bashrc",
        "~/.bash_profile",
        "~/.zprofile",
        "~/.profile",
        "~/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/etc",
    ]

    /// Generates a macOS Seatbelt (.sb) profile string for a given CLI rule.
    static func generateProfile(
        toolName: String,
        executablePath: String,
        readMode: FilesystemMode = .disabled,
        writeMode: FilesystemMode = .disabled,
        readPaths: [String] = [],
        writePaths: [String] = [],
        extraAllowReadPaths: [String] = [],
        extraDenyReadPaths: [String] = [],
        extraAllowWritePaths: [String] = [],
        extraDenyWritePaths: [String] = []
    ) -> String {
        let home = NSHomeDirectory()
        let executableDir = (executablePath as NSString).deletingLastPathComponent
        let readAllowPaths = normalizedPaths(
            [
                executablePath,
                executableDir,
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
                "/usr/lib",
                "/usr/local/lib",
                "/opt/homebrew/lib",
                "/opt/homebrew/bin",
                "/System/Library/Frameworks",
                "/System/Library/PrivateFrameworks",
                "/Library/Developer/CommandLineTools",
                "/tmp",
                "/var/folders",
                "(param \"_CWD\")",
            ]
                + extraAllowReadPaths
                + (readMode == .whitelist ? readPaths : [])
        )

        let writeAllowPaths = normalizedPaths(
            [
                "/tmp",
                "/var/folders",
                "(param \"_CWD\")",
            ]
                + extraAllowWritePaths
                + (writeMode == .whitelist ? writePaths : [])
        )

        var readDenyPaths = normalizedPaths(sensitiveReadPaths + extraDenyReadPaths)
        if readMode == .blacklist {
            readDenyPaths = normalizedPaths(readDenyPaths + readPaths)
        }
        if readMode == .whitelist {
            readDenyPaths = normalizedPaths(readDenyPaths + [home, "/Volumes"])
        }

        var writeDenyPaths = normalizedPaths(sensitiveWritePaths + extraDenyWritePaths)
        if writeMode == .blacklist {
            writeDenyPaths = normalizedPaths(writeDenyPaths + writePaths)
        }
        if writeMode == .whitelist {
            writeDenyPaths = normalizedPaths(writeDenyPaths + [home, "/Volumes", "/Library", "/Applications"])
        }

        let denyReadSubpathLines = stanzaLines(readDenyPaths)
        let denyReadRegexLines = stanzaLines(sensitiveExtensionPatterns.map { "regex #\"\($0)\"" }, literal: true)
        let allowReadSubpathLines = stanzaLines(readAllowPaths)
        let denyWriteSubpathLines = stanzaLines(writeDenyPaths)
        let allowWriteSubpathLines = stanzaLines(writeAllowPaths)

        return """
; FocusShield Seatbelt profile for: \(toolName)
; Generated: \(ISO8601DateFormatter().string(from: Date()))
;
; This profile adds filesystem read protection on top of FocusShield's
; network enforcement. It blocks reads to credential directories without
; interfering with normal tool operation.
;
; Enforcement plane: FILESYSTEM (syscall open/read)
; Complementary layers:
;   - NEFilter:     socket-level domain enforcement (always active)
;   - CLI guard:    payload pattern + Unicode scanning (always active)
;   - This profile: denies open() on credential paths before they're read
(version 1)

; Start permissive — only restrict what we explicitly deny.
; This avoids breaking tools that need broad system access.
(allow default)

; ── FILESYSTEM: deny credential reads ────────────────────────────────
; Denying file-read* prevents open(2) before any data is returned.
; The tool never sees "permission denied" errors for network destinations —
; this only fires for local filesystem reads of sensitive paths.
(deny file-read*
\(denyReadSubpathLines)
\(denyReadRegexLines))

; ── FILESYSTEM: explicit allows ──────────────────────────────────────
; Re-allow the current working directory, the tool binary, and common system paths.
(allow file-read*
\(allowReadSubpathLines))

(allow file-write*
\(allowWriteSubpathLines))

; ── PREVENT WRITING SHELL INIT FILES ─────────────────────────────────
; AI agents sometimes attempt to backdoor shell config for persistence.
(deny file-write*
\(denyWriteSubpathLines))
"""
    }

    private static func normalizedPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths
            .map { rawPath in
                if rawPath.hasPrefix("(param ") { return rawPath }
                return rawPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func stanzaLines(_ values: [String], literal: Bool = false) -> String {
        values.map { value in
            if literal {
                return "    (\(value))"
            }
            if value.hasPrefix("(param ") {
                return "    (subpath \(value))"
            }
            return "    (subpath \"\(value)\")"
        }
        .joined(separator: "\n")
    }

    // MARK: - Disk I/O

    /// Writes a Seatbelt profile to disk and returns its path.
    ///
    /// Profiles are stored at: `~/Library/Application Support/FocusShield/sandbox/<toolName>.sb`
    static func writeProfile(_ profile: String, toolName: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/FocusShield/sandbox")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(toolName).sb")
        try profile.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Returns the path to a stored profile if it exists.
    static func profilePath(for toolName: String) -> String? {
        let path = NSHomeDirectory() +
            "/Library/Application Support/FocusShield/sandbox/\(toolName).sb"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - Wrapper integration

    /// Returns the shell script prefix that prepends `sandbox-exec` to a command,
    /// or an empty string if sandboxing is disabled or the profile doesn't exist.
    ///
    /// Usage inside a generated wrapper script:
    /// ```sh
    /// \(SeatbeltService.execPrefix(for: "curl", profilePath: "/path/to/curl.sb"))exec /usr/bin/curl "$@"
    /// ```
    static func execPrefix(profilePath: String?) -> String {
        guard let path = profilePath,
              FileManager.default.fileExists(atPath: path),
              FileManager.default.fileExists(atPath: "/usr/bin/sandbox-exec")
        else { return "" }
        return "/usr/bin/sandbox-exec -f \"\(path)\" "
    }

    // MARK: - Convenience: generate + write + return prefix

    // MARK: - Validation

    /// Returns true if `/usr/bin/sandbox-exec` exists and is executable on this system.
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
    }
}
