import Foundation
import GRDB

/// SQLite-backed persistence for FocusShield.
final class DataStore: @unchecked Sendable {
    static let shared = DataStore()

    let dbQueue: DatabaseQueue

    private init() {
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FocusShield", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        let dbURL = appSupportDir.appendingPathComponent("focusshield.sqlite")
        // Assign dbQueue exactly once; openDatabase never throws
        self.dbQueue = DataStore.openDatabase(at: dbURL)
        // Run instance-level post-init setup
        try? self.seedIfEmpty()
        try? self.importLegacyJSONIfNeeded(appSupportDir: appSupportDir)
    }

    // Opens the database and runs migrations. On any error, wipes and retries fresh.
    // Returns a migrated DatabaseQueue — never throws.
    private static func openDatabase(at dbURL: URL) -> DatabaseQueue {
        if let q = try? DataStore.tryOpen(at: dbURL) { return q }
        print("DataStore: migration failed — resetting to fresh DB")
        try? FileManager.default.removeItem(at: dbURL)
        guard let q = try? DataStore.tryOpen(at: dbURL) else {
            fatalError("DataStore: cannot open fresh database at \(dbURL.path)")
        }
        return q
    }

    private static func tryOpen(at dbURL: URL) throws -> DatabaseQueue {
        var migrator = DatabaseMigrator()
        let q = try DatabaseQueue(path: dbURL.path)
        // Run migrations inline
        migrator.registerMigration("v1_create_tables") { db in
            try db.create(table: "profiles", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull().defaults(to: "shield.fill")
                t.column("color", .text).notNull().defaults(to: "#007AFF")
                t.column("globalMode", .text).notNull().defaults(to: "blacklist")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            // app_rules MUST be before domain_rules (FK dependency)
            try db.create(table: "app_rules", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileID", .integer).notNull().references("profiles", onDelete: .cascade)
                t.column("appName", .text).notNull()
                t.column("bundleIdentifier", .text).notNull()
                t.column("isBlocked", .boolean).notNull().defaults(to: false)
                t.column("domainMode", .text).notNull().defaults(to: "blacklist")
            }
            try db.create(table: "domain_rules", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileID", .integer).notNull().references("profiles", onDelete: .cascade)
                t.column("appRuleID", .integer).references("app_rules", onDelete: .cascade)
                t.column("domain", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "settings", ifNotExists: true) { t in
                t.primaryKey("id", .integer)
                t.column("masterEnabled", .boolean).notNull().defaults(to: false)
                t.column("activeProfileID", .integer)
                t.column("themeMode", .text).notNull().defaults(to: "System")
            }
        }
        migrator.registerMigration("v2_add_cli_fields") { db in
            let cols = try db.columns(in: "app_rules").map { $0.name }
            if !cols.contains("executablePath") {
                try db.alter(table: "app_rules") { t in t.add(column: "executablePath", .text) }
            }
            if !cols.contains("ruleType") {
                try db.alter(table: "app_rules") { t in t.add(column: "ruleType", .text).defaults(to: "guiApp") }
            }
            if !cols.contains("filterMode") {
                try db.alter(table: "app_rules") { t in t.add(column: "filterMode", .text).defaults(to: "inheritGlobal") }
                try db.execute(sql: "UPDATE app_rules SET filterMode = domainMode WHERE domainMode IS NOT NULL")
            }
        }
        try migrator.migrate(q)
        return q
    }


    // MARK: - Seed Default Data

    private func seedIfEmpty() throws {
        try dbQueue.write { db in
            let count = try BlockProfile.fetchCount(db)
            if count > 0 { return }

            // --- Work Mode (whitelist: only allow work-related sites) ---
            var workProfile = BlockProfile(name: "Work Mode", icon: "briefcase.fill",
                                           color: "#34C759", globalMode: .whitelist, sortOrder: 0)
            try workProfile.insert(db)
            let workID = workProfile.id!

            let workDomains = [
                "google.com", "www.google.com", "docs.google.com",
                "drive.google.com", "mail.google.com", "calendar.google.com",
                "github.com", "www.github.com", "api.github.com",
                "stackoverflow.com", "www.stackoverflow.com",
                "notion.so", "www.notion.so",
                "linear.app", "figma.com", "www.figma.com",
                "vercel.com", "www.vercel.com",
                "npmjs.com", "www.npmjs.com", "registry.npmjs.org",
                "crates.io", "pub.dev",
            ]
            for domain in workDomains {
                var rule = DomainRule(profileID: workID, domain: domain)
                try rule.insert(db)
            }

            // Work Mode — CLI rules: curl can only reach work domains
            var curlRule = AppRule(profileID: workID, appName: "curl",
                                   bundleIdentifier: "com.apple.curl",
                                   executablePath: "/usr/bin/curl",
                                   ruleType: .cliTool, isBlocked: false, filterMode: .whitelist)
            try curlRule.insert(db)
            let curlID = curlRule.id!
            let curlAllowedDomains = ["api.github.com", "registry.npmjs.org", "crates.io"]
            for domain in curlAllowedDomains {
                var r = DomainRule(profileID: workID, appRuleID: curlID, domain: domain)
                try r.insert(db)
            }

            // Work Mode — Safari: inherit global (already whitelisted to work domains)
            var safariRule = AppRule(profileID: workID, appName: "Safari",
                                     bundleIdentifier: "com.apple.Safari",
                                     ruleType: .guiApp, isBlocked: false, filterMode: .inheritGlobal)
            try safariRule.insert(db)

            // --- Study Mode (blacklist: block distractions) ---
            var studyProfile = BlockProfile(name: "Study Mode", icon: "book.fill",
                                             color: "#FF9500", globalMode: .blacklist, sortOrder: 1)
            try studyProfile.insert(db)
            let studyID = studyProfile.id!

            for cat in DefaultCategories.all {
                for domain in cat.domains {
                    var rule = DomainRule(profileID: studyID, domain: domain)
                    try rule.insert(db)
                }
            }
            for app in DefaultApps.games + DefaultApps.messaging + DefaultApps.media {
                var appRule = AppRule(profileID: studyID, appName: app.name,
                                      bundleIdentifier: app.bundleID,
                                      executablePath: app.executablePath,
                                      ruleType: app.ruleType, isBlocked: true, filterMode: .inheritGlobal)
                try appRule.insert(db)
            }

            // --- Break (nothing blocked) ---
            var breakProfile = BlockProfile(name: "Break", icon: "cup.and.saucer.fill",
                                             color: "#5856D6", globalMode: .blacklist, sortOrder: 2)
            try breakProfile.insert(db)

            // Default settings
            var settings = AppSettings(masterEnabled: false, activeProfileID: nil)
            try settings.insert(db)
        }
    }

    // MARK: - Legacy JSON Import

    private func importLegacyJSONIfNeeded(appSupportDir: URL) throws {
        let jsonFile = appSupportDir.appendingPathComponent("data.json")
        guard FileManager.default.fileExists(atPath: jsonFile.path) else { return }

        let profileCount = try dbQueue.read { db in try BlockProfile.fetchCount(db) }
        if profileCount > 3 { return }

        guard let data = try? Data(contentsOf: jsonFile),
              let legacy = try? JSONDecoder().decode(LegacyData.self, from: data) else { return }

        try dbQueue.write { db in
            var imported = BlockProfile(name: "Imported", icon: "square.and.arrow.down.fill",
                                         color: "#FF3B30", globalMode: .blacklist, sortOrder: 3)
            try imported.insert(db)
            let profileID = imported.id!

            for cat in legacy.websiteCategories where cat.isEnabled {
                for domain in cat.domains where domain.isEnabled {
                    var rule = DomainRule(profileID: profileID, domain: domain.domain)
                    try rule.insert(db)
                }
            }
            for app in legacy.blockedApps where app.isEnabled {
                var appRule = AppRule(profileID: profileID, appName: app.name,
                                      bundleIdentifier: app.bundleIdentifier,
                                      ruleType: .guiApp, isBlocked: true, filterMode: .inheritGlobal)
                try appRule.insert(db)
            }
            if let settings = try AppSettings.fetchOne(db) {
                var updated = settings
                updated.masterEnabled = legacy.masterEnabled
                updated.themeMode = legacy.themeMode
                try updated.update(db)
            }
        }

        let backupPath = appSupportDir.appendingPathComponent("data.json.imported")
        try? FileManager.default.moveItem(at: jsonFile, to: backupPath)
        print("[DataStore] Imported legacy JSON data")
    }

    // MARK: - Settings

    func loadSettings() -> AppSettings {
        (try? dbQueue.read { db in try AppSettings.fetchOne(db) }) ?? AppSettings()
    }

    func saveSettings(_ settings: AppSettings) {
        try? dbQueue.write { db in try settings.save(db) }
    }

    // MARK: - Profiles

    func fetchAllProfiles() -> [BlockProfile] {
        (try? dbQueue.read { db in
            try BlockProfile.order(Column("sortOrder")).fetchAll(db)
        }) ?? []
    }

    func fetchProfile(id: Int64) -> BlockProfile? {
        try? dbQueue.read { db in try BlockProfile.fetchOne(db, key: id) }
    }

    @discardableResult
    func saveProfile(_ profile: inout BlockProfile) -> Int64 {
        (try? dbQueue.write { db in
            try profile.save(db)
            return profile.id!
        }) ?? 0
    }

    func deleteProfile(id: Int64) {
        _ = try? dbQueue.write { db in try BlockProfile.deleteOne(db, key: id) }
    }

    // MARK: - Domain Rules

    func fetchGlobalDomainRules(profileID: Int64) -> [DomainRule] {
        (try? dbQueue.read { db in
            try DomainRule
                .filter(Column("profileID") == profileID && Column("appRuleID") == nil)
                .fetchAll(db)
        }) ?? []
    }

    func fetchDomainRules(appRuleID: Int64) -> [DomainRule] {
        (try? dbQueue.read { db in
            try DomainRule.filter(Column("appRuleID") == appRuleID).fetchAll(db)
        }) ?? []
    }

    @discardableResult
    func saveDomainRule(_ rule: inout DomainRule) -> Int64 {
        (try? dbQueue.write { db in
            try rule.save(db)
            return rule.id!
        }) ?? 0
    }

    func deleteDomainRule(id: Int64) {
        _ = try? dbQueue.write { db in try DomainRule.deleteOne(db, key: id) }
    }

    func toggleDomainRule(id: Int64, enabled: Bool) {
        _ = try? dbQueue.write { db in
            try db.execute(sql: "UPDATE domain_rules SET isEnabled = ? WHERE id = ?",
                           arguments: [enabled, id])
        }
    }

    func addDomainRules(profileID: Int64, appRuleID: Int64? = nil, domains: [String]) {
        _ = try? dbQueue.write { db in
            for domain in domains {
                var rule = DomainRule(profileID: profileID, appRuleID: appRuleID, domain: domain)
                try rule.insert(db)
            }
        }
    }

    // MARK: - App Rules

    func fetchAppRules(profileID: Int64) -> [AppRule] {
        (try? dbQueue.read { db in
            try AppRule.filter(Column("profileID") == profileID).fetchAll(db)
        }) ?? []
    }

    @discardableResult
    func saveAppRule(_ rule: inout AppRule) -> Int64 {
        (try? dbQueue.write { db in
            try rule.save(db)
            return rule.id!
        }) ?? 0
    }

    func deleteAppRule(id: Int64) {
        _ = try? dbQueue.write { db in try AppRule.deleteOne(db, key: id) }
    }

    func toggleAppBlocked(id: Int64, blocked: Bool) {
        _ = try? dbQueue.write { db in
            try db.execute(sql: "UPDATE app_rules SET isBlocked = ? WHERE id = ?",
                           arguments: [blocked, id])
        }
    }

    func updateAppFilterMode(id: Int64, filterMode: FilterMode) {
        _ = try? dbQueue.write { db in
            try db.execute(sql: "UPDATE app_rules SET filterMode = ? WHERE id = ?",
                           arguments: [filterMode.rawValue, id])
        }
    }

    // MARK: - Full Profile with Relations

    func fetchProfileWithRules(id: Int64) -> ProfileWithRules? {
        guard let profile = fetchProfile(id: id) else { return nil }
        let globalRules = fetchGlobalDomainRules(profileID: id)
        let appRules = fetchAppRules(profileID: id)
        let appRulesWithDomains = appRules.map { rule in
            AppRuleWithDomains(
                rule: rule,
                domainRules: rule.id.map { fetchDomainRules(appRuleID: $0) } ?? []
            )
        }
        return ProfileWithRules(profile: profile, globalDomainRules: globalRules,
                                appRules: appRulesWithDomains)
    }
}

// MARK: - Legacy Data (JSON import)

private struct LegacyData: Codable {
    struct LegacyDomain: Codable { let domain: String; let isEnabled: Bool }
    struct LegacyCategory: Codable { let name: String; let domains: [LegacyDomain]; let isEnabled: Bool }
    struct LegacyApp: Codable { let name: String; let bundleIdentifier: String; let isEnabled: Bool }
    let websiteCategories: [LegacyCategory]
    let blockedApps: [LegacyApp]
    let masterEnabled: Bool
    let themeMode: AppThemeMode
}
