import Foundation
import GRDB

// MARK: - Filter Mode (per scope: global, per-app, per-CLI)

enum FilterMode: String, Codable, CaseIterable, DatabaseValueConvertible {
    case blacklist
    case whitelist
    case inheritGlobal  // for app/CLI rules: defer to profile global mode

    var label: String {
        switch self {
        case .blacklist:     "Blacklist"
        case .whitelist:     "Whitelist"
        case .inheritGlobal: "Inherit Global"
        }
    }

    var description: String {
        switch self {
        case .blacklist:     "Block listed domains, allow everything else"
        case .whitelist:     "Allow listed domains only, block everything else"
        case .inheritGlobal: "Apply the profile's global filter mode"
        }
    }

    /// Available modes for the global profile scope (no 'inherit')
    static let globalModes: [FilterMode] = [.blacklist, .whitelist]
    /// Available modes for per-app/per-CLI scope
    static let appModes: [FilterMode] = [.blacklist, .whitelist, .inheritGlobal]

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

// MARK: - Domain Rule

struct DomainRule: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var profileID: Int64
    var appRuleID: Int64?   // nil = global rule
    var domain: String
    var isEnabled: Bool

    static let databaseTableName = "domain_rules"

    init(id: Int64? = nil, profileID: Int64, appRuleID: Int64? = nil,
         domain: String, isEnabled: Bool = true) {
        self.id = id
        self.profileID = profileID
        self.appRuleID = appRuleID
        self.domain = domain
        self.isEnabled = isEnabled
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - App Rule (GUI app OR CLI tool)

struct AppRule: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var profileID: Int64
    var appName: String
    var bundleIdentifier: String    // bundle ID for GUI apps; executable name for CLI (e.g. "curl")
    var executablePath: String?     // full path for CLI pf rules e.g. "/usr/bin/curl"
    var ruleType: AppRuleType       // .guiApp or .cliTool
    var isBlocked: Bool             // block entire app / all CLI access?
    var filterMode: FilterMode      // .blacklist / .whitelist / .inheritGlobal

    static let databaseTableName = "app_rules"

    init(id: Int64? = nil, profileID: Int64, appName: String, bundleIdentifier: String,
         executablePath: String? = nil, ruleType: AppRuleType = .guiApp,
         isBlocked: Bool = false, filterMode: FilterMode = .inheritGlobal) {
        self.id = id
        self.profileID = profileID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.ruleType = ruleType
        self.isBlocked = isBlocked
        self.filterMode = filterMode
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var isCLI: Bool { ruleType == .cliTool }
}

// MARK: - Block Profile

struct BlockProfile: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String
    var icon: String
    var color: String
    var globalMode: FilterMode   // only .blacklist or .whitelist (not .inheritGlobal)
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

    static let databaseTableName = "settings"

    init(masterEnabled: Bool = false, activeProfileID: Int64? = nil, themeMode: AppThemeMode = .system) {
        self.id = 1
        self.masterEnabled = masterEnabled
        self.activeProfileID = activeProfileID
        self.themeMode = themeMode
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

// MARK: - Domain Grouping (view helper, not persisted)

struct DomainGroup: Identifiable {
    let id: String      // root domain e.g. "facebook.com"
    let label: String   // display name e.g. "Facebook"
    var rules: [DomainRule]

    var allEnabled: Bool  { rules.allSatisfy { $0.isEnabled } }
    var enabledCount: Int { rules.filter { $0.isEnabled }.count }

    static func displayName(for rootDomain: String) -> String {
        var name = rootDomain
        for suffix in [".com", ".org", ".net", ".io", ".co", ".app", ".tv", ".ai"] {
            name = name.replacingOccurrences(of: suffix, with: "")
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static func group(_ rules: [DomainRule]) -> [DomainGroup] {
        var groups: [String: [DomainRule]] = [:]
        for rule in rules {
            let root = rootDomain(of: rule.domain)
            groups[root, default: []].append(rule)
        }
        return groups.map { root, rules in
            DomainGroup(id: root, label: displayName(for: root),
                        rules: rules.sorted { $0.domain < $1.domain })
        }.sorted { $0.label < $1.label }
    }

    static func rootDomain(of domain: String) -> String {
        let parts = domain.split(separator: ".")
        guard parts.count >= 2 else { return domain }
        return parts.suffix(2).joined(separator: ".")
    }
}

// MARK: - App Rule with Domains (composite)

struct AppRuleWithDomains: Identifiable {
    var id: Int64? { rule.id }
    var rule: AppRule
    var domainRules: [DomainRule]

    /// Effective filter mode: resolve inheritGlobal against profile's globalMode
    func effectiveFilterMode(globalMode: FilterMode) -> FilterMode {
        rule.filterMode == .inheritGlobal ? globalMode : rule.filterMode
    }
}

// MARK: - Profile Network Policy (computed, passed to HostsFileService)

struct ProfileNetworkPolicy {
    let globalMode: FilterMode
    let globalDomains: [String]         // global allow/block list (enabled only)
    let appDomainOverrides: [AppDomainOverride]   // per-app (GUI) overrides
    let cliRules: [CLINetworkRule]       // per-CLI pf rules
    let blockedAppBundleIDs: Set<String> // fully-blocked GUI apps
    let blockedCLIPaths: Set<String>     // fully-blocked CLI executables

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
    }
}

// MARK: - Profile with Relations (full view model)

struct ProfileWithRules {
    var profile: BlockProfile
    var globalDomainRules: [DomainRule]
    var appRules: [AppRuleWithDomains]

    var guiAppRules: [AppRuleWithDomains] { appRules.filter { !$0.rule.isCLI } }
    var cliRules: [AppRuleWithDomains]    { appRules.filter {  $0.rule.isCLI } }

    var blockedAppBundleIDs: Set<String> {
        Set(guiAppRules.filter { $0.rule.isBlocked }.map { $0.rule.bundleIdentifier })
    }

    var totalEnabledDomains: Int {
        let global = globalDomainRules.filter { $0.isEnabled }.count
        let perApp = appRules.flatMap { $0.domainRules }.filter { $0.isEnabled }.count
        return global + perApp
    }

    var totalAppRulesCount: Int { guiAppRules.count }
    var totalCLIRulesCount: Int { cliRules.count }

    /// Build the full network policy for enforcement layers
    func computeNetworkPolicy() -> ProfileNetworkPolicy {
        let globalDomains = globalDomainRules.filter { $0.isEnabled }.map { $0.domain }

        // Per-app overrides (GUI apps not fully blocked)
        let appOverrides: [ProfileNetworkPolicy.AppDomainOverride] = guiAppRules
            .filter { !$0.rule.isBlocked }
            .compactMap { appRule in
                let domains = appRule.domainRules.filter { $0.isEnabled }.map { $0.domain }
                guard !domains.isEmpty else { return nil }
                let mode = appRule.effectiveFilterMode(globalMode: profile.globalMode)
                return ProfileNetworkPolicy.AppDomainOverride(
                    bundleID: appRule.rule.bundleIdentifier,
                    filterMode: mode,
                    domains: domains
                )
            }

        // Per-CLI rules
        let cliNetworkRules: [ProfileNetworkPolicy.CLINetworkRule] = cliRules
            .compactMap { cliRule in
                guard let path = cliRule.rule.executablePath else { return nil }
                let domains = cliRule.domainRules.filter { $0.isEnabled }.map { $0.domain }
                let mode = cliRule.effectiveFilterMode(globalMode: profile.globalMode)
                return ProfileNetworkPolicy.CLINetworkRule(
                    executablePath: path,
                    isFullyBlocked: cliRule.rule.isBlocked,
                    filterMode: mode,
                    domains: domains
                )
            }

        let blockedCLIPaths = Set(cliRules
            .filter { $0.rule.isBlocked }
            .compactMap { $0.rule.executablePath }
        )

        return ProfileNetworkPolicy(
            globalMode: profile.globalMode,
            globalDomains: globalDomains,
            appDomainOverrides: appOverrides,
            cliRules: cliNetworkRules,
            blockedAppBundleIDs: blockedAppBundleIDs,
            blockedCLIPaths: blockedCLIPaths
        )
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

    static let socialMedia = CategoryTemplate(
        name: "Social Media", icon: "person.2.fill",
        domains: [
            "facebook.com", "www.facebook.com", "m.facebook.com",
            "web.facebook.com", "touch.facebook.com",
            "instagram.com", "www.instagram.com",
            "twitter.com", "www.twitter.com", "mobile.twitter.com",
            "x.com", "www.x.com",
            "linkedin.com", "www.linkedin.com",
            "snapchat.com", "www.snapchat.com", "web.snapchat.com",
            "pinterest.com", "www.pinterest.com",
            "threads.net", "www.threads.net",
            "tumblr.com", "www.tumblr.com",
            "mastodon.social", "mastodon.online",
            "bsky.app", "bsky.social",
            "bereal.com", "www.bereal.com",
            "nextdoor.com", "www.nextdoor.com",
            "vk.com", "www.vk.com",
            "weibo.com", "www.weibo.com",
        ]
    )

    static let messaging = CategoryTemplate(
        name: "Messaging", icon: "message.fill",
        domains: [
            "web.whatsapp.com", "www.whatsapp.com",
            "web.telegram.org", "telegram.org",
            "discord.com", "www.discord.com",
            "slack.com", "www.slack.com",
            "messenger.com", "www.messenger.com",
            "signal.org", "www.signal.org",
            "line.me", "www.line.me",
            "wechat.com", "www.wechat.com",
        ]
    )

    static let videoStreaming = CategoryTemplate(
        name: "Video & Streaming", icon: "play.rectangle.fill",
        domains: [
            "youtube.com", "www.youtube.com", "m.youtube.com",
            "netflix.com", "www.netflix.com",
            "twitch.tv", "www.twitch.tv",
            "tiktok.com", "www.tiktok.com",
            "hulu.com", "www.hulu.com",
            "disneyplus.com", "www.disneyplus.com",
            "primevideo.com", "www.primevideo.com",
            "crunchyroll.com", "www.crunchyroll.com",
            "dailymotion.com", "www.dailymotion.com",
            "vimeo.com", "www.vimeo.com",
        ]
    )

    static let forums = CategoryTemplate(
        name: "Forums & Community", icon: "bubble.left.and.bubble.right.fill",
        domains: [
            "reddit.com", "www.reddit.com", "old.reddit.com",
            "quora.com", "www.quora.com",
            "4chan.org", "www.4chan.org",
            "9gag.com", "www.9gag.com",
            "imgur.com", "www.imgur.com",
        ]
    )

    static let news = CategoryTemplate(
        name: "News & Entertainment", icon: "newspaper.fill",
        domains: [
            "buzzfeed.com", "www.buzzfeed.com",
            "tmz.com", "www.tmz.com",
            "boredpanda.com", "www.boredpanda.com",
            "news.ycombinator.com",
            "digg.com", "www.digg.com",
        ]
    )

    static let gaming = CategoryTemplate(
        name: "Gaming", icon: "gamecontroller.fill",
        domains: [
            "store.steampowered.com", "steampowered.com",
            "epicgames.com", "www.epicgames.com",
            "roblox.com", "www.roblox.com",
            "miniclip.com", "www.miniclip.com",
            "poki.com", "www.poki.com",
            "coolmathgames.com", "www.coolmathgames.com",
        ]
    )

    static let shopping = CategoryTemplate(
        name: "Shopping", icon: "cart.fill",
        domains: [
            "amazon.com", "www.amazon.com",
            "ebay.com", "www.ebay.com",
            "aliexpress.com", "www.aliexpress.com",
            "wish.com", "www.wish.com",
            "etsy.com", "www.etsy.com",
            "shopee.com", "www.shopee.com",
            "lazada.com", "www.lazada.com",
            "temu.com", "www.temu.com",
            "shein.com", "www.shein.com",
        ]
    )

    static let all: [CategoryTemplate] = [
        socialMedia, messaging, videoStreaming, forums, news, gaming, shopping,
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
