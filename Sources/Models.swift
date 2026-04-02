import Foundation
import GRDB

// MARK: - Filter Mode (per-app and per-CLI)

enum FilterMode: String, Codable, CaseIterable, DatabaseValueConvertible {
    case blacklist
    case whitelist
    case inheritGlobal  // legacy compatibility for migrated rows

    var label: String {
        switch self {
        case .blacklist:     "Blacklist"
        case .whitelist:     "Whitelist"
        case .inheritGlobal: "Legacy Default"
        }
    }

    var description: String {
        switch self {
        case .blacklist:     "Block listed domains, allow everything else"
        case .whitelist:     "Allow listed domains only, block everything else"
        case .inheritGlobal: "Legacy mode retained for existing installs"
        }
    }

    static let directModes: [FilterMode] = [.blacklist, .whitelist]

    var databaseValue: DatabaseValue { rawValue.databaseValue }
    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> FilterMode? {
        guard let rawValue = String.fromDatabaseValue(dbValue) else { return nil }
        return FilterMode(rawValue: rawValue) ?? .blacklist
    }
}

// MARK: - App Rule Type

enum AppRuleType: String, Codable, CaseIterable {
    case guiApp  = "guiApp"
    case cliTool = "cliTool"

    var label: String {
        switch self {
        case .guiApp:  "Application"
        case .cliTool: "CLI Tool"
        }
    }

    var systemImage: String {
        switch self {
        case .guiApp:  "app.badge"
        case .cliTool: "terminal.fill"
        }
    }
}

// MARK: - Filesystem Policy

enum FilesystemAccessType: String, Codable, CaseIterable, DatabaseValueConvertible {
    case read
    case write

    var label: String {
        switch self {
        case .read:  "Read"
        case .write: "Write"
        }
    }

    var databaseValue: DatabaseValue { rawValue.databaseValue }
    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> FilesystemAccessType? {
        guard let rawValue = String.fromDatabaseValue(dbValue) else { return nil }
        return FilesystemAccessType(rawValue: rawValue)
    }
}

enum FilesystemMode: String, Codable, CaseIterable, DatabaseValueConvertible {
    case disabled
    case blacklist
    case whitelist

    var label: String {
        switch self {
        case .disabled:  "Off"
        case .blacklist: "Blacklist"
        case .whitelist: "Whitelist"
        }
    }

    var description: String {
        switch self {
        case .disabled:
            return "Use baseline FocusShield protections only"
        case .blacklist:
            return "Block listed filesystem paths"
        case .whitelist:
            return "Allow listed filesystem paths only"
        }
    }

    var databaseValue: DatabaseValue { rawValue.databaseValue }
    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> FilesystemMode? {
        guard let rawValue = String.fromDatabaseValue(dbValue) else { return nil }
        return FilesystemMode(rawValue: rawValue)
    }
}

// MARK: - Domain Rule

struct DomainRule: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var profileID: Int64
    var appRuleID: Int64?   // nil = global rule
    var groupID: Int64?     // nil = ungrouped
    var domain: String
    var filterMode: FilterMode
    var isEnabled: Bool

    static let databaseTableName = "domain_rules"

    init(id: Int64? = nil, profileID: Int64, appRuleID: Int64? = nil, groupID: Int64? = nil,
         domain: String, filterMode: FilterMode = .blacklist, isEnabled: Bool = true) {
        self.id = id
        self.profileID = profileID
        self.appRuleID = appRuleID
        self.groupID = groupID
        self.domain = domain
        self.filterMode = filterMode
        self.isEnabled = isEnabled
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - App Rule (GUI app OR CLI tool)

struct AppRule: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var profileID: Int64
    var appName: String
    var bundleIdentifier: String    // bundle ID for GUI apps; executable name for CLI (e.g. "curl")
    var executablePath: String?     // full path for CLI pf rules e.g. "/usr/bin/curl"
    var ruleType: AppRuleType       // .guiApp or .cliTool
    var isBlocked: Bool             // block entire app / all CLI access?
    var filterMode: FilterMode      // .blacklist / .whitelist / legacy .inheritGlobal
    var isEnabled: Bool             // false = "unlinked" — rule stays in DB but enforcement skips it
    /// When true, FocusShield skips generating a CLI proxy wrapper for this tool.
    /// Use this for AI agents (Claude Code, Cursor, Aider…) that already provide their own
    /// sandbox + HTTP proxy: avoids a double-proxy chain while NEFilter socket enforcement
    /// stays fully active at zero extra overhead.
    var hasSelfSandbox: Bool
    var filesystemReadMode: FilesystemMode
    var filesystemWriteMode: FilesystemMode

    static let databaseTableName = "app_rules"

    init(id: Int64? = nil, profileID: Int64, appName: String, bundleIdentifier: String,
         executablePath: String? = nil, ruleType: AppRuleType = .guiApp,
         isBlocked: Bool = false, filterMode: FilterMode = .blacklist,
         isEnabled: Bool = true, hasSelfSandbox: Bool = false,
         filesystemReadMode: FilesystemMode = .disabled,
         filesystemWriteMode: FilesystemMode = .disabled) {
        self.id = id
        self.profileID = profileID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.ruleType = ruleType
        self.isBlocked = isBlocked
        self.filterMode = filterMode
        self.isEnabled = isEnabled
        self.hasSelfSandbox = hasSelfSandbox
        self.filesystemReadMode = filesystemReadMode
        self.filesystemWriteMode = filesystemWriteMode
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var isCLI: Bool { ruleType == .cliTool }
}

// MARK: - Known Self-Sandboxed AI Agents

/// AI agent CLI tools that manage their own sandbox + HTTP proxy.
/// Adding one of these pre-sets `hasSelfSandbox = true` so FocusShield
/// skips the proxy wrapper while keeping NEFilter socket enforcement.
enum KnownSandboxedAgent: String, CaseIterable, Identifiable {
    case claudeCode = "claude"
    case cursor     = "cursor"
    case codex      = "codex"
    case aider      = "aider"
    case copilot    = "gh"      // GitHub Copilot CLI
    case windsurf   = "windsurf"
    case cline      = "cline"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor:     return "Cursor"
        case .codex:      return "OpenAI Codex CLI"
        case .aider:      return "Aider"
        case .copilot:    return "GitHub Copilot CLI"
        case .windsurf:   return "Windsurf"
        case .cline:      return "Cline"
        }
    }

    var icon: String {
        switch self {
        case .claudeCode: return "sparkle"
        case .cursor:     return "cursorarrow.rays"
        case .codex:      return "cpu"
        case .aider:      return "brain"
        case .copilot:    return "airplane"
        case .windsurf:   return "wind"
        case .cline:      return "terminal.fill"
        }
    }

    /// Common install paths — first match wins; falls back to PATH resolution.
    var candidatePaths: [String] {
        switch self {
        case .claudeCode:
            return ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        case .cursor:
            return ["/usr/local/bin/cursor", "/Applications/Cursor.app/Contents/MacOS/Cursor"]
        case .codex:
            return ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        case .aider:
            return ["/usr/local/bin/aider", "/opt/homebrew/bin/aider"]
        case .copilot:
            return ["/usr/local/bin/gh", "/opt/homebrew/bin/gh"]
        case .windsurf:
            return ["/usr/local/bin/windsurf", "/Applications/Windsurf.app/Contents/MacOS/Windsurf"]
        case .cline:
            return ["/usr/local/bin/cline"]
        }
    }

    /// Returns the first path that exists on disk, or the bare command name as fallback.
    var resolvedPath: String {
        let fm = FileManager.default
        if let found = candidatePaths.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        // Try PATH
        if let fromPath = CLIPathResolver.resolve(rawValue) { return fromPath }
        return rawValue
    }

    /// Builds an AppRule ready to insert for a given profile.
    func makeRule(profileID: Int64, filterMode: FilterMode = .whitelist) -> AppRule {
        AppRule(
            profileID: profileID,
            appName: displayName,
            bundleIdentifier: "cli.\(rawValue)",
            executablePath: resolvedPath,
            ruleType: .cliTool,
            isBlocked: false,
            filterMode: filterMode,
            isEnabled: true,
            hasSelfSandbox: true,
            filesystemReadMode: .disabled,
            filesystemWriteMode: .disabled
        )
    }
}

// MARK: - Block Profile

struct BlockProfile: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var icon: String
    var color: String
    var globalMode: FilterMode   // legacy compatibility field; website enforcement is per app/CLI
    var sortOrder: Int

    static let databaseTableName = "profiles"

    init(id: Int64? = nil, name: String, icon: String, color: String = "#007AFF",
         globalMode: FilterMode = .blacklist, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.icon = icon
        self.color = color
        self.globalMode = globalMode
        self.sortOrder = sortOrder
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Settings

struct AppSettings: Codable, FetchableRecord, PersistableRecord {
    var id: Int64 = 1  // singleton
    var masterEnabled: Bool
    var activeProfileID: Int64?
    var themeMode: AppThemeMode
    var payloadProtectionEnabled: Bool

    static let databaseTableName = "settings"

    init(
        masterEnabled: Bool = false,
        activeProfileID: Int64? = nil,
        themeMode: AppThemeMode = .system,
        payloadProtectionEnabled: Bool = true
    ) {
        self.id = 1
        self.masterEnabled = masterEnabled
        self.activeProfileID = activeProfileID
        self.themeMode = themeMode
        self.payloadProtectionEnabled = payloadProtectionEnabled
    }
}

// MARK: - Theme

enum AppThemeMode: String, Codable, CaseIterable, DatabaseValueConvertible {
    case system = "System"
    case light  = "Light"
    case dark   = "Dark"

    var databaseValue: DatabaseValue { rawValue.databaseValue }
    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> AppThemeMode? {
        guard let rawValue = String.fromDatabaseValue(dbValue) else { return nil }
        return AppThemeMode(rawValue: rawValue)
    }
}

// MARK: - Custom Domain Group

struct CustomDomainGroup: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var profileID: Int64
    var name: String

    static let databaseTableName = "custom_groups"

    init(id: Int64? = nil, profileID: Int64, name: String) {
        self.id = id
        self.profileID = profileID
        self.name = name
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Domain Grouping (view helper)

struct DomainGroup: Identifiable {
    let id: String      // custom group ID stringified, or "ungrouped"
    let label: String   // display name e.g. "Work Sites"
    var rules: [DomainRule]

    var allEnabled: Bool  { rules.allSatisfy { $0.isEnabled } }
    var enabledCount: Int { rules.filter { $0.isEnabled }.count }

    static func build(rules: [DomainRule], groups: [CustomDomainGroup]) -> [DomainGroup] {
        var groupMap: [Int64: [DomainRule]] = [:]
        var ungrouped: [DomainRule] = []

        for rule in rules {
            if let gid = rule.groupID {
                groupMap[gid, default: []].append(rule)
            } else {
                ungrouped.append(rule)
            }
        }

        var result: [DomainGroup] = []
        for group in groups {
            let groupRules = groupMap[group.id!] ?? []
            guard !groupRules.isEmpty else { continue }
            result.append(DomainGroup(id: String(group.id!), label: group.name,
                                      rules: groupRules.sorted { $0.domain < $1.domain }))
        }
        
        if !ungrouped.isEmpty {
            result.append(DomainGroup(id: "ungrouped", label: "Ungrouped",
                                      rules: ungrouped.sorted { $0.domain < $1.domain }))
        }

        return result
    }
}

// MARK: - App Rule with Domains (composite)

struct AppRuleWithDomains: Identifiable {
    var id: Int64? { rule.id }
    var rule: AppRule
    var domainRules: [DomainRule]
    var filesystemPathRules: [FilesystemPathRule]

    /// Resolve legacy `inheritGlobal` rows to blacklist after global website enforcement removal.
    func effectiveFilterMode(globalMode: FilterMode) -> FilterMode {
        rule.filterMode == .inheritGlobal ? .blacklist : rule.filterMode
    }

    var supportsPerAppDomainFiltering: Bool {
        !rule.isCLI
    }

    var needsBrowserRestart: Bool {
        AppNetworkSupport.isBrowser(bundleID: rule.bundleIdentifier)
    }

    func domainRules(for mode: FilterMode) -> [DomainRule] {
        let resolvedMode: FilterMode = mode == .whitelist ? .whitelist : .blacklist
        return domainRules
            .filter { $0.filterMode == resolvedMode }
            .sorted { lhs, rhs in
                lhs.domain.localizedStandardCompare(rhs.domain) == .orderedAscending
            }
    }

    func domainCount(for mode: FilterMode) -> Int {
        domainRules(for: mode).count
    }

    func filesystemPathRules(for accessType: FilesystemAccessType) -> [FilesystemPathRule] {
        filesystemPathRules
            .filter { $0.accessType == accessType }
            .sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
    }

    var hasFilesystemPolicy: Bool {
        rule.filesystemReadMode != .disabled
            || rule.filesystemWriteMode != .disabled
            || filesystemPathRules.contains(where: \.isEnabled)
    }
}

// MARK: - App Network Support Matrix

enum AppNetworkSupport {
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
    ]

    static let chromiumManagedPolicyBundleIDs: Set<String> = [
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
    ]

    static func isBrowser(bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }

    static func supportsLegacyBrowserPolicy(bundleID: String) -> Bool {
        bundleID == "com.apple.Safari"
            || bundleID == "org.mozilla.firefox"
            || chromiumManagedPolicyBundleIDs.contains(bundleID)
    }

    static func usesChromiumManagedPolicy(bundleID: String) -> Bool {
        chromiumManagedPolicyBundleIDs.contains(bundleID)
    }
}

enum SiteDomainBundle {
    struct Expansion {
        let groupLabel: String?
        let domains: [String]
    }

    private static let knownFamilies: [String: [String]] = [
        "facebook.com": [
            "facebook.com", "*.facebook.com",
            "*.fbcdn.net", "*.fbsbx.com",
            "messenger.com", "*.messenger.com", "m.me"
        ],
        "instagram.com": [
            "instagram.com", "*.instagram.com",
            "*.cdninstagram.com", "*.fbcdn.net", "*.fbsbx.com"
        ],
        "youtube.com": [
            "youtube.com", "*.youtube.com", "youtu.be",
            "*.googlevideo.com", "*.ytimg.com",
            "*.youtubei.googleapis.com", "*.gstatic.com"
        ],
        "twitter.com": [
            "twitter.com", "*.twitter.com",
            "x.com", "*.x.com",
            "t.co", "*.t.co", "*.twimg.com"
        ],
        "x.com": [
            "x.com", "*.x.com",
            "twitter.com", "*.twitter.com",
            "t.co", "*.t.co", "*.twimg.com"
        ],
    ]

    static func expansion(for rawDomain: String) -> Expansion {
        let normalized = rawDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else {
            return Expansion(groupLabel: nil, domains: [])
        }

        let isWildcard = normalized.hasPrefix("*.")
        let base = isWildcard ? String(normalized.dropFirst(2)) : normalized
        let labelCount = base.split(separator: ".").count
        let shouldExpand = isWildcard || labelCount <= 2 || knownFamilies[base] != nil

        guard shouldExpand else {
            return Expansion(groupLabel: nil, domains: [normalized])
        }

        var seen = Set<String>()
        var expanded: [String] = []

        func append(_ domain: String) {
            let clean = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !clean.isEmpty, seen.insert(clean).inserted else { return }
            expanded.append(clean)
        }

        append(base)
        append("*.\(base)")
        for domain in knownFamilies[base] ?? [] {
            append(domain)
        }

        expanded.sort { lhs, rhs in
            lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return Expansion(groupLabel: base, domains: expanded)
    }
}

// MARK: - Profile Network Policy (computed, passed to HostsFileService)

struct ProfileNetworkPolicy {
    let globalMode: FilterMode
    let globalDomains: [String]
    let appDomainOverrides: [AppDomainOverride]   // per-app (GUI) overrides
    let cliRules: [CLINetworkRule]       // per-CLI pf rules
    let blockedAppBundleIDs: Set<String> // fully-blocked GUI apps
    let blockedCLIPaths: Set<String>     // fully-blocked CLI executables
    /// Char-scan env vars to inject into every CLI wrapper for this profile.
    let charScanEnv: [String: String]

    struct AppDomainOverride {
        let bundleID: String
        let filterMode: FilterMode       // actual mode (never inheritGlobal here)
        let domains: [String]
    }

    struct CLINetworkRule {
        let executablePath: String
        let isFullyBlocked: Bool
        let filterMode: FilterMode       // actual mode (never inheritGlobal here)
        let domains: [String]
        /// When true, this tool manages its own sandbox + proxy.
        /// `buildCLIWrappers` skips wrapper generation; NEFilter still enforces domain rules.
        let hasSelfSandbox: Bool
        let filesystemReadMode: FilesystemMode
        let filesystemWriteMode: FilesystemMode
        let readPaths: [String]
        let writePaths: [String]
    }
}

// MARK: - Profile with Relations (full view model)

struct ProfileWithRules {
    var profile: BlockProfile
    var customDomainGroups: [CustomDomainGroup]
    var globalDomainRules: [DomainRule]
    var appRules: [AppRuleWithDomains]

    var guiAppRules: [AppRuleWithDomains] { appRules.filter { !$0.rule.isCLI } }
    var cliRules: [AppRuleWithDomains]    { appRules.filter {  $0.rule.isCLI } }

    var blockedAppBundleIDs: Set<String> {
        Set(guiAppRules.filter { $0.rule.isEnabled && $0.rule.isBlocked }.map { $0.rule.bundleIdentifier })
    }

    var blockedCLIPaths: Set<String> {
        let paths = cliRules.filter { $0.rule.isEnabled && $0.rule.isBlocked }.compactMap { $0.rule.executablePath }
        return Set(paths)
    }

    var totalEnabledDomains: Int {
        let perApp = appRules.flatMap { $0.domainRules }.filter { $0.isEnabled }.count
        return perApp
    }

    var totalAppRulesCount: Int { guiAppRules.count }
    var totalCLIRulesCount: Int { cliRules.count }

    /// Expands `*.foo.com` wildcard entries into a small set of known common subdomains
    /// for enforcement layers (hosts file, pf) that don't support wildcard syntax natively.
    /// The DNS proxy and PAC file handle subdomain matching dynamically, so they receive the raw list.
    private func canonicalDomains(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains
            .flatMap { SiteDomainBundle.expansion(for: $0).domains }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    /// Build the full network policy for enforcement layers
    func computeNetworkPolicy(charScanEnv: [String: String] = [:]) -> ProfileNetworkPolicy {
        let globalDomains: [String] = []

        let appOverrides: [ProfileNetworkPolicy.AppDomainOverride] = guiAppRules
            .filter { $0.rule.isEnabled && !$0.rule.isBlocked }
            .compactMap { appRule in
                let mode = appRule.effectiveFilterMode(globalMode: profile.globalMode)
                let domains = canonicalDomains(appRule.domainRules(for: mode).filter { $0.isEnabled }.map { $0.domain })
                guard !domains.isEmpty || mode == .whitelist else { return nil }
                return ProfileNetworkPolicy.AppDomainOverride(
                    bundleID: appRule.rule.bundleIdentifier,
                    filterMode: mode,
                    domains: domains
                )
            }

        // Per-CLI rules (skip disabled/unlinked rules)
        let cliNetworkRules: [ProfileNetworkPolicy.CLINetworkRule] = cliRules
            .filter { $0.rule.isEnabled }
            .compactMap { cliRule in
                guard let path = cliRule.rule.executablePath else { return nil }
                let mode = cliRule.effectiveFilterMode(globalMode: profile.globalMode)
                let domains = canonicalDomains(cliRule.domainRules(for: mode).filter { $0.isEnabled }.map { $0.domain })
                return ProfileNetworkPolicy.CLINetworkRule(
                    executablePath: path,
                    isFullyBlocked: cliRule.rule.isBlocked,
                    filterMode: mode,
                    domains: domains,
                    hasSelfSandbox: cliRule.rule.hasSelfSandbox,
                    filesystemReadMode: cliRule.rule.filesystemReadMode,
                    filesystemWriteMode: cliRule.rule.filesystemWriteMode,
                    readPaths: cliRule.filesystemPathRules(for: .read).filter(\.isEnabled).map(\.path),
                    writePaths: cliRule.filesystemPathRules(for: .write).filter(\.isEnabled).map(\.path)
                )
            }

        let blockedCLIPaths = Set(cliRules
            .filter { $0.rule.isEnabled && $0.rule.isBlocked }
            .compactMap { $0.rule.executablePath }
        )

        return ProfileNetworkPolicy(
            globalMode: profile.globalMode,
            globalDomains: globalDomains,
            appDomainOverrides: appOverrides,
            cliRules: cliNetworkRules,
            blockedAppBundleIDs: blockedAppBundleIDs,
            blockedCLIPaths: blockedCLIPaths,
            charScanEnv: charScanEnv
        )
    }
}

struct FilesystemPathRule: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var appRuleID: Int64
    var accessType: FilesystemAccessType
    var path: String
    var isEnabled: Bool

    static let databaseTableName = "filesystem_path_rules"

    init(
        id: Int64? = nil,
        appRuleID: Int64,
        accessType: FilesystemAccessType,
        path: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.appRuleID = appRuleID
        self.accessType = accessType
        self.path = path
        self.isEnabled = isEnabled
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Payload Protection

struct SiteList: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var isBuiltIn: Bool
    var sortOrder: Int
    var isVisible: Bool

    static let databaseTableName = "site_lists"

    init(id: Int64? = nil, name: String, isBuiltIn: Bool = false, sortOrder: Int = 0, isVisible: Bool = true) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
        self.isVisible = isVisible
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct SiteListDomain: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var siteListID: Int64
    var domain: String
    var sortOrder: Int
    var isEnabled: Bool

    static let databaseTableName = "site_list_domains"

    init(id: Int64? = nil, siteListID: Int64, domain: String, sortOrder: Int = 0, isEnabled: Bool = true) {
        self.id = id
        self.siteListID = siteListID
        self.domain = domain
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct SiteListWithDomains: Identifiable {
    let list: SiteList
    let domains: [SiteListDomain]

    var id: Int64? { list.id }
    var enabledDomainCount: Int { domains.count }
}

struct PayloadPattern: Identifiable, Codable, Hashable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var regex: String
    var isEnabled: Bool
    var isRecommended: Bool
    var sortOrder: Int

    static let databaseTableName = "payload_patterns"

    init(
        id: Int64? = nil,
        name: String,
        regex: String,
        isEnabled: Bool = true,
        isRecommended: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.regex = regex
        self.isEnabled = isEnabled
        self.isRecommended = isRecommended
        self.sortOrder = sortOrder
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

enum PayloadProtectionDefaults {
    static let recommendedPatterns: [(name: String, regex: String)] = [
        ("OpenAI API Key", #"\bsk-[A-Za-z0-9]{20,}\b"#),
        ("Anthropic API Key", #"\bsk-ant-api[0-9]{2}-[A-Za-z0-9_-]{20,}\b"#),
        ("GitHub Classic PAT", #"\bghp_[A-Za-z0-9]{36}\b"#),
        ("GitHub Fine-Grained PAT", #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#),
        ("GitHub OAuth Token", #"\bgho_[A-Za-z0-9]{36}\b"#),
        ("GitHub App Token", #"\b(ghu|ghs)_[A-Za-z0-9]{36}\b"#),
        ("Google API Key", #"\bAIza[0-9A-Za-z\-_]{35}\b"#),
        ("Google OAuth Client ID", #"\b[0-9]+-[0-9A-Za-z_]{24,}\.apps\.googleusercontent\.com\b"#),
        ("AWS Access Key ID", #"\b(A3T|AKIA|ASIA|ABIA)[A-Z0-9]{16}\b"#),
        ("Slack App Token", #"\bxapp-[0-9A-Za-z-]{20,}\b"#),
        ("Stripe Secret Key", #"\b(?:rk|sk)_(?:live|test)_[0-9A-Za-z]{24,}\b"#),
        ("JWT", #"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9._-]{10,}\.[A-Za-z0-9._-]{10,}\b"#),
        ("Firebase Auth Domain", #"\b[a-z0-9-]{2,30}\.firebaseapp\.com\b"#),
        ("Fireworks API Key", #"\bfw_[A-Za-z0-9]{24,}\b"#),
        ("Warp API Key", #"\bwpk-[0-9]+-[A-Fa-f0-9\-]+\b"#),
        ("Phone Number", #"\b(?:\+?\d{1,2}\s*)?(?:\(?\d{3}\)?[\s.-]*)\d{3}[\s.-]*\d{4}\b"#),
        ("IPv4 Address", #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#),
        ("IPv6 Address", #"\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}\b"#),
        ("MAC Address", #"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#),
    ]
}

// MARK: - Invisible Character Scan Policy (per profile)

/// Defines which categories of dangerous/invisible Unicode characters to block
/// for CLI payloads in this profile. One row per profile in `profile_char_policies`.
struct ProfileCharPolicy: Codable, FetchableRecord, PersistableRecord, Equatable {
    /// Foreign key — also the primary key (one-to-one with BlockProfile).
    var profileID: Int64
    /// Zero-width characters: U+200B ZWSP, U+200C ZWNJ, U+200D ZWJ, U+FEFF BOM,
    /// U+2060 Word Joiner, U+FFFC Object Replacement Character, etc.
    var zeroWidthBlock: Bool
    /// RTL override / embedding: U+202A-202E, U+2066-2069 — used to spoof text direction.
    var rtlOverrideBlock: Bool
    /// Invisible tag plane: U+E0001-U+E007F — frequently used in AI prompt injection.
    var tagCharBlock: Bool
    /// Invisible format characters: U+00AD soft hyphen, U+115F/U+1160 Hangul fillers,
    /// U+3164 Hangul filler, U+17B4/17B5, variation selectors U+FE00-FE0F, etc.
    var invisibleFormatBlock: Bool
    /// Alert when Cyrillic/Greek characters that visually resemble ASCII letters are detected.
    var homoglyphAlert: Bool
    /// Master switch — when false the scanner is skipped entirely for this profile.
    var isEnabled: Bool

    static let databaseTableName = "profile_char_policies"

    init(
        profileID: Int64,
        zeroWidthBlock: Bool = false,
        rtlOverrideBlock: Bool = false,
        tagCharBlock: Bool = false,
        invisibleFormatBlock: Bool = false,
        homoglyphAlert: Bool = false,
        isEnabled: Bool = false
    ) {
        self.profileID = profileID
        self.zeroWidthBlock = zeroWidthBlock
        self.rtlOverrideBlock = rtlOverrideBlock
        self.tagCharBlock = tagCharBlock
        self.invisibleFormatBlock = invisibleFormatBlock
        self.homoglyphAlert = homoglyphAlert
        self.isEnabled = isEnabled
    }

    /// Returns a default (all-off) policy for the given profile.
    static func defaultPolicy(profileID: Int64) -> ProfileCharPolicy {
        ProfileCharPolicy(profileID: profileID)
    }

    /// Environment variables to inject into CLI wrapper processes.
    /// When `isEnabled` is false all vars are omitted / set to 0 for fast short-circuit.
    var cliEnv: [String: String] {
        guard isEnabled else {
            return ["FOCUSSHIELD_CHARSCAN_ENABLED": "0"]
        }
        return [
            "FOCUSSHIELD_CHARSCAN_ENABLED":   "1",
            "FOCUSSHIELD_CHARSCAN_ZWSP":      zeroWidthBlock       ? "1" : "0",
            "FOCUSSHIELD_CHARSCAN_RTL":       rtlOverrideBlock     ? "1" : "0",
            "FOCUSSHIELD_CHARSCAN_TAGS":      tagCharBlock         ? "1" : "0",
            "FOCUSSHIELD_CHARSCAN_INVIS":     invisibleFormatBlock ? "1" : "0",
            "FOCUSSHIELD_CHARSCAN_HOMOGLYPH": homoglyphAlert       ? "1" : "0",
        ]
    }

    /// Human-readable summary of active categories (for UI status lines).
    var activeCategoryLabels: [String] {
        guard isEnabled else { return [] }
        var labels: [String] = []
        if zeroWidthBlock       { labels.append("Zero-Width") }
        if rtlOverrideBlock     { labels.append("RTL Override") }
        if tagCharBlock         { labels.append("Tag Chars") }
        if invisibleFormatBlock { labels.append("Invisible Format") }
        if homoglyphAlert       { labels.append("Homoglyphs") }
        return labels
    }
}

// MARK: - System Safelist (always allowed in whitelist mode)

enum SystemSafelist {
    static let domains: Set<String> = [
        "apple.com", "www.apple.com",
        "icloud.com", "www.icloud.com",
        "mzstatic.com", "cdn-apple.com",
        "apple-dns.net", "push.apple.com",
        "aaplimg.com", "ocsp.apple.com",
        "gs.apple.com", "swscan.apple.com",
        "configuration.apple.com",
        "xp.apple.com", "gsa.apple.com",
        "setup.icloud.com", "p-setup.icloud.com",
        "swdist.apple.com", "swcdn.apple.com",
        "updates.cdn-apple.com",
        "apps.apple.com", "itunes.apple.com",
        "time.apple.com", "time.euro.apple.com",
        "localhost", "local",
        "broadcasthost",
        "captive.apple.com",
    ]
}

// MARK: - Default Data Templates

enum DefaultCategories {
    struct CategoryTemplate {
        let name: String
        let icon: String
        let domains: [String]
    }

    // Each service uses *.domain.com wildcards where appropriate.
    // The DNS proxy + PAC handle subdomain matching dynamically;
    // hosts/pf expand these via ProfileWithRules.expandWildcards().

    static let socialMedia = CategoryTemplate(
        name: "Social Media", icon: "person.2.fill",
        domains: [
            "*.facebook.com",
            "*.instagram.com",
            "*.twitter.com", "*.x.com",
            "*.linkedin.com",
            "*.snapchat.com",
            "*.pinterest.com",
            "*.threads.net",
            "*.tumblr.com",
            "*.tiktok.com",
            "mastodon.social", "mastodon.online",
            "bsky.app", "bsky.social",
            "*.bereal.com",
            "*.nextdoor.com",
            "*.vk.com",
            "*.weibo.com",
            "*.reddit.com",
        ]
    )

    static let messaging = CategoryTemplate(
        name: "Messaging", icon: "message.fill",
        domains: [
            "*.whatsapp.com",
            "*.telegram.org",
            "*.discord.com",
            "*.slack.com",
            "*.messenger.com",
            "*.signal.org",
            "*.line.me",
            "*.wechat.com",
            "*.viber.com",
            "*.kik.com",
        ]
    )

    static let videoStreaming = CategoryTemplate(
        name: "Video & Streaming", icon: "play.rectangle.fill",
        domains: [
            "*.youtube.com", "youtu.be",
            "*.netflix.com",
            "*.twitch.tv",
            "*.hulu.com",
            "*.disneyplus.com",
            "*.primevideo.com", "*.amazon.com",
            "*.crunchyroll.com",
            "*.dailymotion.com",
            "*.vimeo.com",
            "*.bilibili.com",
            "*.peacocktv.com",
            "*.hbomax.com",
            "*.max.com",
            "*.paramountplus.com",
            "*.appletv.apple.com",
            "*.plex.tv",
            "*.spotify.com",
            "*.soundcloud.com",
        ]
    )

    static let news = CategoryTemplate(
        name: "News & Entertainment", icon: "newspaper.fill",
        domains: [
            "*.buzzfeed.com",
            "*.tmz.com",
            "*.boredpanda.com",
            "*.9gag.com",
            "*.imgur.com",
            "*.digg.com",
            "*.vice.com",
            "*.huffpost.com",
            "*.buzzfeednews.com",
            "news.ycombinator.com",
        ]
    )

    static let gaming = CategoryTemplate(
        name: "Gaming", icon: "gamecontroller.fill",
        domains: [
            "*.steampowered.com",
            "*.epicgames.com",
            "*.roblox.com",
            "*.miniclip.com",
            "*.poki.com",
            "*.coolmathgames.com",
            "*.battle.net",
            "*.ea.com",
            "*.ubisoft.com",
            "*.gog.com",
        ]
    )

    static let shopping = CategoryTemplate(
        name: "Shopping", icon: "cart.fill",
        domains: [
            "*.ebay.com",
            "*.aliexpress.com",
            "*.wish.com",
            "*.etsy.com",
            "*.shopee.com",
            "*.lazada.com",
            "*.temu.com",
            "*.shein.com",
            "*.alibaba.com",
            "*.walmart.com",
            "*.target.com",
        ]
    )

    static let all: [CategoryTemplate] = [
        socialMedia, messaging, videoStreaming, news, gaming, shopping,
        CategoryTemplate(
            name: "Professional Networks", icon: "person.3.sequence.fill",
            domains: ["*.linkedin.com", "*.angel.co", "*.wellfound.com", "*.glassdoor.com"]
        ),
        CategoryTemplate(
            name: "AI Tools", icon: "sparkles",
            domains: ["*.openai.com", "*.chatgpt.com", "*.anthropic.com", "*.claude.ai", "*.perplexity.ai", "*.cursor.sh"]
        ),
        CategoryTemplate(
            name: "Developer Forums", icon: "chevron.left.forwardslash.chevron.right",
            domains: ["*.stackoverflow.com", "news.ycombinator.com", "*.reddit.com", "*.hashnode.dev", "*.dev.to"]
        ),
        CategoryTemplate(
            name: "Streaming Music", icon: "music.note.list",
            domains: ["*.spotify.com", "*.soundcloud.com", "*.music.apple.com", "*.bandcamp.com"]
        ),
        CategoryTemplate(
            name: "Short Video", icon: "film.stack.fill",
            domains: ["*.tiktok.com", "*.youtube.com", "*.instagram.com", "*.reels.facebook.com", "*.snapchat.com"]
        ),
        CategoryTemplate(
            name: "Shopping & Deals", icon: "bag.fill",
            domains: ["*.amazon.com", "*.ebay.com", "*.etsy.com", "*.temu.com", "*.shein.com", "*.walmart.com", "*.target.com"]
        ),
        CategoryTemplate(
            name: "Adult Content", icon: "exclamationmark.shield.fill",
            domains: ["*.pornhub.com", "*.xvideos.com", "*.xnxx.com", "*.onlyfans.com", "*.redtube.com"]
        ),
    ]
}

// MARK: - Default Apps / CLI Templates

enum DefaultApps {
    struct AppTemplate {
        let name: String
        let bundleID: String
        let executablePath: String?
        let ruleType: AppRuleType

        init(name: String, bundleID: String, executablePath: String? = nil, ruleType: AppRuleType = .guiApp) {
            self.name = name
            self.bundleID = bundleID
            self.executablePath = executablePath
            self.ruleType = ruleType
        }
    }

    static let games: [AppTemplate] = [
        AppTemplate(name: "Steam",              bundleID: "com.valvesoftware.steam"),
        AppTemplate(name: "Epic Games Launcher",bundleID: "com.epicgames.EpicGamesLauncher"),
        AppTemplate(name: "GOG Galaxy",         bundleID: "com.gog.galaxy"),
        AppTemplate(name: "Battle.net",         bundleID: "net.battle.app"),
        AppTemplate(name: "Riot Client",        bundleID: "com.riotgames.RiotClient"),
        AppTemplate(name: "Minecraft",          bundleID: "com.mojang.minecraftlauncher"),
        AppTemplate(name: "Roblox",             bundleID: "com.roblox.RobloxPlayer"),
        AppTemplate(name: "Chess",              bundleID: "com.apple.Chess"),
        AppTemplate(name: "EA App",             bundleID: "com.ea.mac.EADesktop"),
    ]

    static let messaging: [AppTemplate] = [
        AppTemplate(name: "Discord",     bundleID: "com.hnc.Discord"),
        AppTemplate(name: "Telegram",    bundleID: "ru.keepcoder.Telegram"),
        AppTemplate(name: "WhatsApp",    bundleID: "net.whatsapp.WhatsApp"),
        AppTemplate(name: "Slack",       bundleID: "com.tinyspeck.slackmacgap"),
        AppTemplate(name: "Messenger",   bundleID: "com.facebook.archon"),
        AppTemplate(name: "Microsoft Teams", bundleID: "com.microsoft.teams2"),
        AppTemplate(name: "Zoom",        bundleID: "uk.zoom.xos"),
    ]

    static let media: [AppTemplate] = [
        AppTemplate(name: "Spotify",     bundleID: "com.spotify.client"),
        AppTemplate(name: "Apple Music", bundleID: "com.apple.Music"),
        AppTemplate(name: "Apple TV",    bundleID: "com.apple.TV"),
        AppTemplate(name: "Twitch",      bundleID: "tv.twitch.client.native"),
        AppTemplate(name: "TikTok",      bundleID: "com.zhiliaoapp.musically"),
    ]

    static let browsers: [AppTemplate] = [
        AppTemplate(name: "Safari",         bundleID: "com.apple.Safari"),
        AppTemplate(name: "Google Chrome",  bundleID: "com.google.Chrome"),
        AppTemplate(name: "Firefox",        bundleID: "org.mozilla.firefox"),
        AppTemplate(name: "Arc",            bundleID: "company.thebrowser.Browser"),
        AppTemplate(name: "Brave",          bundleID: "com.brave.Browser"),
        AppTemplate(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        AppTemplate(name: "Opera",          bundleID: "com.operasoftware.Opera"),
    ]

    /// Common CLI tools with known executable paths
    static let cli: [AppTemplate] = [
        AppTemplate(name: "curl",    bundleID: "com.apple.curl",   executablePath: "/usr/bin/curl",           ruleType: .cliTool),
        AppTemplate(name: "wget",    bundleID: "org.gnu.wget",     executablePath: "/usr/local/bin/wget",      ruleType: .cliTool),
        AppTemplate(name: "python3", bundleID: "org.python.python",executablePath: "/usr/bin/python3",        ruleType: .cliTool),
        AppTemplate(name: "node",    bundleID: "org.nodejs.node",  executablePath: "/usr/local/bin/node",     ruleType: .cliTool),
        AppTemplate(name: "npm",     bundleID: "org.npmjs.npm",    executablePath: "/usr/local/bin/npm",      ruleType: .cliTool),
        AppTemplate(name: "git",     bundleID: "org.git-scm.git",  executablePath: "/usr/bin/git",            ruleType: .cliTool),
        AppTemplate(name: "ssh",     bundleID: "com.apple.ssh",    executablePath: "/usr/bin/ssh",            ruleType: .cliTool),
        AppTemplate(name: "claude",  bundleID: "com.anthropic.claude", executablePath: "/usr/local/bin/claude", ruleType: .cliTool),
    ]

    static var allGUI: [AppTemplate] { games + messaging + media + browsers }
    static var allCLI: [AppTemplate] { cli }
    static var all: [AppTemplate] { allGUI + allCLI }
}
