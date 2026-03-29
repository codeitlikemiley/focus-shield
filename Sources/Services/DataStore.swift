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
                t.column("filterMode", .text).notNull().defaults(to: "blacklist")
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
            }
            try db.create(table: "settings", ifNotExists: true) { t in
                t.primaryKey("id", .integer)
                t.column("masterEnabled", .boolean).notNull().defaults(to: false)
                t.column("activeProfileID", .integer)
                t.column("themeMode", .text).notNull().defaults(to: "System")
                t.column("payloadProtectionEnabled", .boolean).notNull().defaults(to: true)
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
        migrator.registerMigration("v3_add_custom_groups") { db in
            try db.create(table: "custom_groups", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileID", .integer).notNull().references("profiles", onDelete: .cascade)
                t.column("name", .text).notNull()
            }
            let cols = try db.columns(in: "domain_rules").map { $0.name }
            if !cols.contains("groupID") {
                try db.alter(table: "domain_rules") { t in
                    t.add(column: "groupID", .integer).references("custom_groups", onDelete: .cascade)
                }
            }
        }
        migrator.registerMigration("v4_add_payload_patterns") { db in
            try db.create(table: "payload_patterns", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("regex", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("isRecommended", .boolean).notNull().defaults(to: true)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            try seedDefaultPayloadPatterns(in: db)
        }
        migrator.registerMigration("v5_add_payload_settings") { db in
            let cols = try db.columns(in: "settings").map { $0.name }
            if !cols.contains("payloadProtectionEnabled") {
                try db.alter(table: "settings") { t in
                    t.add(column: "payloadProtectionEnabled", .boolean).defaults(to: true)
                }
            }
        }
        migrator.registerMigration("v6_add_site_lists") { db in
            try db.create(table: "site_lists", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "site_list_domains", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("siteListID", .integer).notNull().references("site_lists", onDelete: .cascade)
                t.column("domain", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            try seedDefaultSiteLists(in: db)
        }
        migrator.registerMigration("v7_disable_global_website_mode") { db in
            try db.execute(sql: "UPDATE profiles SET globalMode = 'blacklist'")
        }
        migrator.registerMigration("v8_make_per_app_modes_explicit") { db in
            try db.execute(sql: "UPDATE app_rules SET filterMode = 'blacklist' WHERE filterMode = 'inheritGlobal'")
        }
        migrator.registerMigration("v9_add_app_rule_enabled") { db in
            let cols = try db.columns(in: "app_rules").map { $0.name }
            if !cols.contains("isEnabled") {
                try db.alter(table: "app_rules") { t in t.add(column: "isEnabled", .boolean).defaults(to: true) }
            }
        }
        migrator.registerMigration("v10_add_domain_rule_modes") { db in
            let cols = try db.columns(in: "domain_rules").map { $0.name }
            if !cols.contains("filterMode") {
                try db.alter(table: "domain_rules") { t in
                    t.add(column: "filterMode", .text).defaults(to: "blacklist")
                }
            }

            try db.execute(
                sql: """
                UPDATE domain_rules
                SET filterMode = 'blacklist'
                WHERE filterMode IS NULL OR filterMode NOT IN ('blacklist', 'whitelist')
                """
            )

            try db.execute(
                sql: """
                UPDATE domain_rules
                SET filterMode = COALESCE(
                    (
                        SELECT CASE
                            WHEN app_rules.filterMode = 'whitelist' THEN 'whitelist'
                            ELSE 'blacklist'
                        END
                        FROM app_rules
                        WHERE app_rules.id = domain_rules.appRuleID
                    ),
                    filterMode
                )
                WHERE appRuleID IS NOT NULL
                """
            )
        }
        try migrator.migrate(q)
        return q
    }

    private static func seedDefaultPayloadPatterns(in db: Database) throws {
        let count = try PayloadPattern.fetchCount(db)
        if count > 0 { return }

        for (index, item) in PayloadProtectionDefaults.recommendedPatterns.enumerated() {
            var pattern = PayloadPattern(
                name: item.name,
                regex: item.regex,
                isEnabled: true,
                isRecommended: true,
                sortOrder: index
            )
            try pattern.insert(db)
        }
    }

    private static func seedDefaultSiteLists(in db: Database) throws {
        let count = try SiteList.fetchCount(db)
        if count > 0 { return }

        for (index, template) in DefaultCategories.all.enumerated() {
            var list = SiteList(name: template.name, isBuiltIn: true, sortOrder: index)
            try list.insert(db)

            for (domainIndex, domain) in template.domains.enumerated() {
                var listDomain = SiteListDomain(
                    siteListID: list.id!,
                    domain: domain,
                    sortOrder: domainIndex
                )
                try listDomain.insert(db)
            }
        }
    }

    private static func seedDefaultProfileState(in db: Database) throws {
        let profileCount = try BlockProfile.fetchCount(db)

        if profileCount == 0 {
            var defaultProfile = BlockProfile(
                name: "Default Profile",
                icon: "shield.fill",
                color: "#007AFF",
                globalMode: .blacklist,
                sortOrder: 0
            )
            try defaultProfile.insert(db)

            let settings = AppSettings(masterEnabled: false, activeProfileID: defaultProfile.id)
            try settings.insert(db)
            return
        }

        guard try AppSettings.fetchOne(db) == nil else { return }
        let firstProfile = try BlockProfile.order(Column("sortOrder"), Column("id")).fetchOne(db)
        let settings = AppSettings(masterEnabled: false, activeProfileID: firstProfile?.id)
        try settings.insert(db)
    }

    // MARK: - Seed Default Data

    private func seedIfEmpty() throws {
        try dbQueue.write { db in
            try Self.seedDefaultProfileState(in: db)
        }
    }

    func resetAllData() {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM domain_rules")
            try db.execute(sql: "DELETE FROM app_rules")
            try db.execute(sql: "DELETE FROM custom_groups")
            try db.execute(sql: "DELETE FROM profiles")
            try db.execute(sql: "DELETE FROM settings")
            try db.execute(sql: "DELETE FROM site_list_domains")
            try db.execute(sql: "DELETE FROM site_lists")
            try db.execute(sql: "DELETE FROM payload_patterns")
            try db.execute(sql: "DELETE FROM sqlite_sequence")

            try Self.seedDefaultPayloadPatterns(in: db)
            try Self.seedDefaultSiteLists(in: db)
            try Self.seedDefaultProfileState(in: db)
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

    // MARK: - Site Lists

    func fetchSiteLists() -> [SiteList] {
        (try? dbQueue.read { db in
            try SiteList.order(Column("sortOrder"), Column("name")).fetchAll(db)
        }) ?? []
    }

    func fetchSiteListDomains(siteListID: Int64) -> [SiteListDomain] {
        (try? dbQueue.read { db in
            try SiteListDomain
                .filter(Column("siteListID") == siteListID)
                .order(Column("sortOrder"), Column("domain"))
                .fetchAll(db)
        }) ?? []
    }

    func fetchSiteListsWithDomains() -> [SiteListWithDomains] {
        fetchSiteLists().map { list in
            SiteListWithDomains(list: list, domains: list.id.map(fetchSiteListDomains(siteListID:)) ?? [])
        }
    }

    @discardableResult
    func saveSiteList(_ list: inout SiteList) -> Int64 {
        (try? dbQueue.write { db in
            try list.save(db)
            return list.id!
        }) ?? 0
    }

    func deleteSiteList(id: Int64) {
        _ = try? dbQueue.write { db in try SiteList.deleteOne(db, key: id) }
    }

    @discardableResult
    func saveSiteListDomain(_ domain: inout SiteListDomain) -> Int64 {
        (try? dbQueue.write { db in
            try domain.save(db)
            return domain.id!
        }) ?? 0
    }

    func deleteSiteListDomain(id: Int64) {
        _ = try? dbQueue.write { db in try SiteListDomain.deleteOne(db, key: id) }
    }

    func updateSiteListDomain(id: Int64, domain: String) {
        _ = try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE site_list_domains SET domain = ? WHERE id = ?",
                arguments: [domain, id]
            )
        }
    }

    func addSiteListDomains(siteListID: Int64, domains: [String]) {
        _ = try? dbQueue.write { db in
            var existingDomains = Set(
                try SiteListDomain
                    .filter(Column("siteListID") == siteListID)
                    .fetchAll(db)
                    .map { $0.domain.lowercased() }
            )
            let existingCount = try SiteListDomain
                .filter(Column("siteListID") == siteListID)
                .fetchCount(db)
            var insertedCount = 0

            for domain in domains {
                let normalized = domain.lowercased()
                guard existingDomains.insert(normalized).inserted else { continue }
                var item = SiteListDomain(siteListID: siteListID, domain: domain, sortOrder: existingCount + insertedCount)
                try item.insert(db)
                insertedCount += 1
            }
        }
    }

    // MARK: - Payload Patterns

    func fetchPayloadPatterns() -> [PayloadPattern] {
        (try? dbQueue.read { db in
            try PayloadPattern
                .order(Column("sortOrder"), Column("name"))
                .fetchAll(db)
        }) ?? []
    }

    @discardableResult
    func savePayloadPattern(_ pattern: inout PayloadPattern) -> Int64 {
        (try? dbQueue.write { db in
            try pattern.save(db)
            return pattern.id!
        }) ?? 0
    }

    func deletePayloadPattern(id: Int64) {
        _ = try? dbQueue.write { db in try PayloadPattern.deleteOne(db, key: id) }
    }

    func togglePayloadPattern(id: Int64, enabled: Bool) {
        _ = try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE payload_patterns SET isEnabled = ? WHERE id = ?",
                arguments: [enabled, id]
            )
        }
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

    // MARK: - Custom Domain Groups

    func fetchCustomGroups(profileID: Int64) -> [CustomDomainGroup] {
        (try? dbQueue.read { db in
            try CustomDomainGroup.filter(Column("profileID") == profileID).fetchAll(db)
        }) ?? []
    }

    @discardableResult
    func saveCustomGroup(_ group: inout CustomDomainGroup) -> Int64 {
        (try? dbQueue.write { db in
            try group.save(db)
            return group.id!
        }) ?? 0
    }

    func findCustomGroup(profileID: Int64, name: String) -> CustomDomainGroup? {
        try? dbQueue.read { db in
            try CustomDomainGroup
                .filter(Column("profileID") == profileID)
                .filter(sql: "LOWER(name) = LOWER(?)", arguments: [name])
                .fetchOne(db)
        }
    }

    @discardableResult
    func ensureCustomGroup(profileID: Int64, name: String) -> Int64 {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return 0 }
        if let existing = findCustomGroup(profileID: profileID, name: cleanName),
           let id = existing.id {
            return id
        }

        var group = CustomDomainGroup(profileID: profileID, name: cleanName)
        return saveCustomGroup(&group)
    }

    func deleteCustomGroup(id: Int64) {
        _ = try? dbQueue.write { db in try CustomDomainGroup.deleteOne(db, key: id) }
    }

    // MARK: - Domain Rules

    func fetchGlobalDomainRules(profileID: Int64) -> [DomainRule] {
        (try? dbQueue.read { db in
            try DomainRule
                .filter(Column("profileID") == profileID && Column("appRuleID") == nil)
                .order(Column("filterMode"), Column("domain"))
                .fetchAll(db)
        }) ?? []
    }

    func fetchDomainRules(appRuleID: Int64) -> [DomainRule] {
        (try? dbQueue.read { db in
            try DomainRule
                .filter(Column("appRuleID") == appRuleID)
                .order(Column("filterMode"), Column("domain"))
                .fetchAll(db)
        }) ?? []
    }

    func fetchDomainRule(id: Int64) -> DomainRule? {
        try? dbQueue.read { db in try DomainRule.fetchOne(db, key: id) }
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

    func updateDomainRuleValue(id: Int64, domain: String) {
        _ = try? dbQueue.write { db in
            try db.execute(
                sql: "UPDATE domain_rules SET domain = ? WHERE id = ?",
                arguments: [domain, id]
            )
        }
    }
    
    func updateDomainRuleGroup(id: Int64, groupID: Int64?) {
        _ = try? dbQueue.write { db in
            try db.execute(sql: "UPDATE domain_rules SET groupID = ? WHERE id = ?",
                           arguments: [groupID, id])
        }
    }

    func addDomainRules(
        profileID: Int64,
        appRuleID: Int64? = nil,
        groupID: Int64? = nil,
        filterMode: FilterMode = .blacklist,
        domains: [String]
    ) {
        _ = try? dbQueue.write { db in
            var existingDomains = Set(
                try DomainRule
                    .filter(Column("profileID") == profileID)
                    .filter(Column("appRuleID") == appRuleID)
                    .filter(Column("filterMode") == filterMode.rawValue)
                    .fetchAll(db)
                    .map { $0.domain.lowercased() }
            )

            for domain in domains {
                let normalized = domain.lowercased()
                guard existingDomains.insert(normalized).inserted else { continue }
                var rule = DomainRule(
                    profileID: profileID,
                    appRuleID: appRuleID,
                    groupID: groupID,
                    domain: domain,
                    filterMode: filterMode
                )
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

    func fetchAppRule(id: Int64) -> AppRule? {
        try? dbQueue.read { db in try AppRule.fetchOne(db, key: id) }
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

    func toggleAppEnabled(id: Int64, enabled: Bool) {
        _ = try? dbQueue.write { db in
            try db.execute(sql: "UPDATE app_rules SET isEnabled = ? WHERE id = ?",
                           arguments: [enabled, id])
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
        let customGroups = fetchCustomGroups(profileID: id)
        let appRules = fetchAppRules(profileID: id)
        let appRulesWithDomains = appRules.map { rule in
            AppRuleWithDomains(
                rule: rule,
                domainRules: rule.id.map { fetchDomainRules(appRuleID: $0) } ?? []
            )
        }
        return ProfileWithRules(profile: profile, customDomainGroups: customGroups, globalDomainRules: globalRules,
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
