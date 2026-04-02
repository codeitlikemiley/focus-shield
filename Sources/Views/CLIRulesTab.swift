import SwiftUI

// MARK: - CLI Rules Tab

struct CLIRulesTab: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profileID: Int64

    @State private var expandedRuleID: Int64? = nil
    @State private var showAddCLI = false
    @State private var importSiteListRule: AppRuleImportTarget?
    @State private var searchText = ""

    @State private var profileWithRules: ProfileWithRules?

    var cliRules: [AppRuleWithDomains] {
        let rules = profileWithRules?.cliRules ?? []
        guard !searchText.isEmpty else { return rules }
        return rules.filter { $0.rule.appName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Info bar
            HStack {
                Image(systemName: "info.circle").foregroundStyle(.blue).font(.system(size: 12))
                Text("CLI rules run through a wrapper preflight that inspects destinations and payloads. AI agents with “Self-Sandboxed” skip the proxy wrapper — their own sandbox handles it. NEFilter socket enforcement applies to all tools.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(profileWithRules?.cliRules.count ?? 0) rules")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Reader tools auto-protection banner
            // Shown only when payload protection is ON so users see what's happening
            // even though they didn't add cat/grep/head as explicit CLI rules.
            if vm.settings.payloadProtectionEnabled {
                readerToolsBanner
                Divider()
            }

            if (profileWithRules?.cliRules ?? []).isEmpty {
                emptyState
            } else {
                searchBar
                Divider()
                rulesList
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 6) {
                    // Quick-add a known AI agent (pre-sets hasSelfSandbox = true)
                    Menu {
                        ForEach(KnownSandboxedAgent.allCases) { agent in
                            Button {
                                vm.addAgentRule(profileID: profileID, agent: agent)
                            } label: {
                                Label(agent.displayName, systemImage: agent.icon)
                            }
                        }
                    } label: {
                        Label("Add AI Agent", systemImage: "sparkle")
                    }
                    .help("Add a known AI agent with Self-Sandboxed mode pre-configured")

                    Button {
                        showAddCLI = true
                    } label: {
                        Label("Add CLI", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showAddCLI) {
            AddCLIRuleSheet(profileID: profileID)
        }
        .sheet(item: $importSiteListRule) { target in
            ImportSiteListSheet(
                profileID: profileID,
                appRuleID: target.ruleID,
                title: target.title,
                filterMode: target.filterMode
            )
        }
        .onAppear {
            profileWithRules = vm.fetchProfileWithRules(id: profileID)
        }
        .onChange(of: vm.dataVersion) { oldValue, newValue in
            profileWithRules = vm.fetchProfileWithRules(id: profileID)
        }
        .onChange(of: profileID) { oldValue, newValue in
            profileWithRules = vm.fetchProfileWithRules(id: newValue)
        }
    }

    // MARK: - Reader tools auto-protection banner

    private static let readerTools: [(name: String, path: String)] = [
        ("cat",     "/bin/cat"),
        ("head",    "/usr/bin/head"),
        ("tail",    "/usr/bin/tail"),
        ("grep",    "/usr/bin/grep"),
        ("awk",     "/usr/bin/awk"),
        ("sed",     "/usr/bin/sed"),
        ("strings", "/usr/bin/strings"),
    ]

    private var readerToolsBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.green)
                .font(.system(size: 13))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text("Auto-protected reader tools")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Payload Scanner")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.8), in: Capsule())
                }

                Text("These tools are automatically wrapped with the lightweight payload scanner while Payload Protection is on. No rule needed — credentials and invisible Unicode are scanned in every file read and pipe.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Tool pills — horizontally scrollable row
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Self.readerTools, id: \.name) { tool in
                            HStack(spacing: 3) {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.green.opacity(0.8))
                                Text(tool.name)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Text(tool.path)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.green.opacity(0.2), lineWidth: 0.5))
                        }
                    }
                }

                Text("Turn off in Settings → Payload Protection.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.04))
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search CLI tools…", text: $searchText).textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var rulesList: some View {
        let rules: [AppRuleWithDomains] = cliRules
        return List(rules, id: \.rule.bundleIdentifier) { cliRule in
            cliRuleSection(cliRule)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func cliRuleSection(_ cliRule: AppRuleWithDomains) -> some View {
        let ruleID: Int64? = cliRule.rule.id
        let isExpanded: Bool = expandedRuleID != nil && expandedRuleID == ruleID
        let activeMode = cliRule.effectiveFilterMode(globalMode: .blacklist)
        let activeGroups = DomainGroup.build(
            rules: cliRule.domainRules(for: activeMode),
            groups: profileWithRules?.customDomainGroups ?? []
        )
        Section {
            if isExpanded {
                // Executable path info
                HStack {
                    Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 16)
                    Text(cliRule.rule.executablePath ?? "Unknown path")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)

                FilesystemPolicyEditorView(
                    profileID: profileID,
                    cliRule: cliRule
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)

                RuleDomainEditorView(
                    profileID: profileID,
                    currentMode: activeMode,
                    displayedGroups: activeGroups,
                    whitelistCount: cliRule.domainCount(for: .whitelist),
                    blacklistCount: cliRule.domainCount(for: .blacklist),
                    addPlaceholder: "Add api.example.com or *.example.com",
                    onModeChange: { mode in
                        guard let id = ruleID else { return }
                        vm.setCLIFilterMode(profileID: profileID, id: id, filterMode: mode)
                    },
                    onToggleRule: { id, isEnabled in
                        vm.toggleDomainRule(profileID: profileID, id: id, enabled: isEnabled)
                    },
                    onToggleAllRules: { isEnabled in
                        let ids = activeGroups.compactMap(\.rules).flatMap { $0 }.compactMap(\.id)
                        vm.toggleDomainRules(profileID: profileID, ids: ids, enabled: isEnabled)
                    },
                    onDeleteRule: { id in
                        vm.removeDomainRule(profileID: profileID, id: id)
                    },
                    onEditRule: { id, domain in
                        vm.updateDomainRule(profileID: profileID, id: id, domain: domain)
                    },
                    onAddDomain: { domain, mode in
                        guard let ruleID else { return }
                        vm.addDomainRule(
                            profileID: profileID,
                            domain: domain,
                            appRuleID: ruleID,
                            filterMode: mode
                        )
                    }
                )
            }
        } header: {
            CLIRuleHeaderRow(
                profileID: profileID,
                cliRule: cliRule,
                isExpanded: isExpanded,
                onToggleExpand: {
                    expandedRuleID = isExpanded ? nil : ruleID
                },
                onImport: {
                    guard let ruleID else { return }
                    importSiteListRule = AppRuleImportTarget(
                        ruleID: ruleID,
                        title: cliRule.rule.appName,
                        filterMode: activeMode
                    )
                }
            )
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No CLI Rules", systemImage: "terminal.fill")
        } description: {
            Text("Add CLI tools like curl, wget, python3 to control their network access.")
        } actions: {
            Button("Add CLI Tool…") { showAddCLI = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - CLI Rule Header Row

struct CLIRuleHeaderRow: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profileID: Int64
    let cliRule: AppRuleWithDomains
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onImport: () -> Void

    private var isLinked: Bool { cliRule.rule.isEnabled }
    private var isSelfSandboxed: Bool { cliRule.rule.hasSelfSandbox }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Image(systemName: isSelfSandboxed ? "bubblefill.and.magnifyingglass" : "terminal.fill")
                .foregroundStyle(isLinked ? (cliRule.rule.isBlocked ? .red : (isSelfSandboxed ? .indigo : .purple)) : .gray)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(cliRule.rule.appName)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .foregroundStyle(isLinked ? .primary : .secondary)

                    // Self-sandboxed badge
                    if isSelfSandboxed {
                        Text("Self-Sandboxed")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.85), in: Capsule())
                            .help("This tool manages its own sandbox and proxy. FocusShield’s proxy wrapper is skipped to avoid double-proxy overhead. NEFilter socket enforcement is still fully active.")
                    }
                }
                HStack(spacing: 4) {
                    if !isLinked {
                        Label("Disabled", systemImage: "link.badge.plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    } else if cliRule.rule.isBlocked {
                        Label("All traffic blocked", systemImage: "stop.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                    } else if isSelfSandboxed {
                        Label("NEFilter enforced · no proxy wrapper", systemImage: "network.badge.shield.half.filled")
                            .font(.system(size: 10))
                            .foregroundStyle(.indigo.opacity(0.8))
                    } else if !cliRule.domainRules.isEmpty {
                        let mode = cliRule.effectiveFilterMode(globalMode: .blacklist)
                        let activeCount = cliRule.domainCount(for: mode)
                        let otherMode: FilterMode = mode == .whitelist ? .blacklist : .whitelist
                        let otherCount = cliRule.domainCount(for: otherMode)
                        Label("\(activeCount) \(mode.label.lowercased()) · \(otherCount) \(otherMode.label.lowercased())", systemImage: "list.bullet")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No domain restrictions")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Self-sandbox toggle (only for CLI tools, not blocked)
            if !cliRule.rule.isBlocked {
                Button {
                    if let id = cliRule.rule.id {
                        vm.toggleSelfSandbox(profileID: profileID, id: id,
                                             hasSelfSandbox: !isSelfSandboxed)
                    }
                } label: {
                    Image(systemName: isSelfSandboxed ? "bubblefill.and.magnifyingglass" : "bubble.and.magnifyingglass")
                        .foregroundStyle(isSelfSandboxed ? Color.indigo : Color.secondary.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isSelfSandboxed
                    ? "Self-Sandboxed: this agent’s own sandbox handles proxy and filesystem. Click to revert to standard FocusShield wrapper."
                    : "Enable Self-Sandboxed mode: skip proxy wrapper for tools that manage their own sandbox (e.g. Claude Code, Cursor).")
                .disabled(!isLinked)
                .opacity(isLinked ? 1 : 0.4)
            }

            if cliRule.rule.isBlocked {
                Button("Unblock") {
                    if let id = cliRule.rule.id {
                        vm.toggleCLIBlocked(profileID: profileID, id: id, blocked: false)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.secondary)
                .disabled(!isLinked)
                .help("Unblock all traffic")
                .opacity(isLinked ? 1 : 0.4)
            } else {
                Button("Block") {
                    if let id = cliRule.rule.id {
                        vm.toggleCLIBlocked(profileID: profileID, id: id, blocked: true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
                .disabled(!isLinked)
                .help("Block all network traffic")
                .opacity(isLinked ? 1 : 0.4)
            }

            Button("Import") {
                onImport()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isLinked)
            .help("Import domains from a site list")
            .opacity(isLinked ? 1 : 0.4)

            // Unlink / Link button
            Button {
                if let id = cliRule.rule.id {
                    vm.toggleAppEnabled(profileID: profileID, id: id, enabled: !isLinked)
                }
            } label: {
                Image(systemName: isLinked ? "link" : "link.badge.plus")
                    .foregroundStyle(isLinked ? Color.secondary : Color.orange)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isLinked ? "Disable rule (keep domain lists)" : "Re-enable rule")

            Button(role: .destructive) {
                if let id = cliRule.rule.id { vm.removeAppRule(profileID: profileID, id: id) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .opacity(isLinked ? 1 : 0.7)
    }
}

// MARK: - Filesystem Policy Editor

struct FilesystemPolicyEditorView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profileID: Int64
    let cliRule: AppRuleWithDomains

    private var ruleID: Int64? { cliRule.rule.id }
    private var readRules: [FilesystemPathRule] { cliRule.filesystemPathRules(for: .read) }
    private var writeRules: [FilesystemPathRule] { cliRule.filesystemPathRules(for: .write) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Filesystem", systemImage: "externaldrive.badge.timemachine")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if cliRule.hasFilesystemPolicy {
                    Text("Seatbelt enforced")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                } else {
                    Text("Baseline protection only")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Text("CLI-only enforcement. FocusShield applies these rules when the wrapped tool is executed; GUI app filesystem control still needs a separate enforcement plane.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                filesystemModePicker(
                    title: "Read",
                    accessType: .read,
                    selection: cliRule.rule.filesystemReadMode
                )
                filesystemModePicker(
                    title: "Write",
                    accessType: .write,
                    selection: cliRule.rule.filesystemWriteMode
                )
            }

            FilesystemPathListEditor(
                profileID: profileID,
                appRuleID: ruleID,
                accessType: .read,
                mode: cliRule.rule.filesystemReadMode,
                rules: readRules
            )

            FilesystemPathListEditor(
                profileID: profileID,
                appRuleID: ruleID,
                accessType: .write,
                mode: cliRule.rule.filesystemWriteMode,
                rules: writeRules
            )
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func filesystemModePicker(
        title: String,
        accessType: FilesystemAccessType,
        selection: FilesystemMode
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) mode")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Picker(title, selection: Binding(
                get: { selection },
                set: { newValue in
                    guard let ruleID else { return }
                    vm.setFilesystemMode(
                        profileID: profileID,
                        id: ruleID,
                        accessType: accessType,
                        mode: newValue
                    )
                }
            )) {
                ForEach(FilesystemMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(ruleID == nil)

            Text(selection.description)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

struct FilesystemPathListEditor: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profileID: Int64
    let appRuleID: Int64?
    let accessType: FilesystemAccessType
    let mode: FilesystemMode
    let rules: [FilesystemPathRule]

    @State private var newPath = ""

    private var title: String { "\(accessType.label) paths" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(modeSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if rules.isEmpty {
                Text(emptyStateText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(rules) { rule in
                        FilesystemPathRow(
                            profileID: profileID,
                            rule: rule
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                TextField(pathPlaceholder, text: $newPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .disabled(appRuleID == nil)
                Button("Add") {
                    guard let appRuleID else { return }
                    vm.addFilesystemPathRule(
                        profileID: profileID,
                        appRuleID: appRuleID,
                        accessType: accessType,
                        path: newPath
                    )
                    newPath = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appRuleID == nil || newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var modeSummary: String {
        switch mode {
        case .disabled:
            return "Stored only"
        case .blacklist:
            return "Blocked by these paths"
        case .whitelist:
            return "Allowed by these paths"
        }
    }

    private var emptyStateText: String {
        switch mode {
        case .disabled:
            return "No stored paths. Baseline FocusShield secret and persistence protections still apply."
        case .blacklist:
            return "Add paths this tool must not \(accessType == .read ? "read" : "write")."
        case .whitelist:
            return "Add paths this tool is allowed to \(accessType == .read ? "read" : "write") in addition to the current working directory and system paths."
        }
    }

    private var pathPlaceholder: String {
        switch accessType {
        case .read:
            return "~/Secrets or /Volumes/Archive"
        case .write:
            return "~/Desktop/export or /tmp/build"
        }
    }
}

struct FilesystemPathRow: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profileID: Int64
    let rule: FilesystemPathRule

    @State private var draftPath: String

    init(profileID: Int64, rule: FilesystemPathRule) {
        self.profileID = profileID
        self.rule = rule
        _draftPath = State(initialValue: rule.path)
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { isEnabled in
                    guard let id = rule.id else { return }
                    vm.toggleFilesystemPathRule(profileID: profileID, id: id, enabled: isEnabled)
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            TextField("Path", text: $draftPath)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit {
                    guard let id = rule.id else { return }
                    vm.updateFilesystemPathRule(profileID: profileID, id: id, path: draftPath)
                }

            Button("Save") {
                guard let id = rule.id else { return }
                vm.updateFilesystemPathRule(profileID: profileID, id: id, path: draftPath)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(role: .destructive) {
                guard let id = rule.id else { return }
                vm.removeFilesystemPathRule(profileID: profileID, id: id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - PATH-based CLI resolver

enum CLIPathResolver {
    /// Searches each directory in $PATH for an executable named `name`.
    /// Returns the first match, or nil if not found.
    static func resolve(_ name: String) -> String? {
        guard !name.isEmpty, !name.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        let pathDirs = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        for dir in pathDirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Scans PATH directories and returns all executables matching the prefix.
    /// Used for building the suggestion list from real installed tools.
    static func search(prefix: String, limit: Int = 12) -> [(name: String, path: String)] {
        guard !prefix.isEmpty else { return [] }
        let fm = FileManager.default
        let pathDirs = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        var seen = Set<String>()
        var results: [(String, String)] = []
        for dir in pathDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries.sorted() {
                guard entry.lowercased().hasPrefix(prefix.lowercased()) else { continue }
                guard !seen.contains(entry) else { continue }
                let full = (dir as NSString).appendingPathComponent(entry)
                guard fm.isExecutableFile(atPath: full) else { continue }
                seen.insert(entry)
                results.append((entry, full))
                if results.count >= limit { return results }
            }
        }
        return results
    }
}

// MARK: - Add CLI Rule Sheet

struct AddCLIRuleSheet: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let profileID: Int64

    @State private var query = ""
    @State private var isBlocked = false
    @State private var filterMode: FilterMode = .blacklist
    @State private var showSuggestions = false
    @FocusState private var fieldFocused: Bool

    // PATH-resolved results
    @State private var pathSuggestions: [(name: String, path: String)] = []
    @State private var resolvedPath: String? = nil   // nil = not found, "" = resolving
    @State private var isResolving = false


    // ── What will be added ────────────────────────────────────────────
    private var finalName: String {
        let t = query.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("/") { return URL(fileURLWithPath: t).lastPathComponent }
        return t
    }

    private var finalPath: String {
        let t = query.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("/") { return t }                 // user typed an absolute path
        return resolvedPath ?? t                         // PATH result, or bare name as fallback
    }

    private var isAddDisabled: Bool {
        finalName.isEmpty || isResolving
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── Combobox ──────────────────────────────────────────
                Section {
                    VStack(alignment: .leading, spacing: 0) {

                        // Input row
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "terminal")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)

                            TextField("Command", text: $query)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .focused($fieldFocused)
                                .onChange(of: query) { _, newVal in
                                    scheduleResolve(newVal)
                                }
                                .autocorrectionDisabled()

                            if isResolving {
                                ProgressView().controlSize(.small)
                                    .frame(width: 16, height: 16)
                            } else if !query.isEmpty {
                                Button { query = ""; pathSuggestions = []; resolvedPath = nil } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(minHeight: 36)
                        .padding(.horizontal, 2)

                        // Live PATH suggestions dropdown
                        if showSuggestions && !pathSuggestions.isEmpty {
                            Divider()
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(pathSuggestions, id: \.path) { suggestion in
                                        Button {
                                            query = suggestion.name
                                            resolvedPath = suggestion.path
                                            showSuggestions = false
                                            fieldFocused = false
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: "terminal.fill")
                                                    .foregroundStyle(.purple)
                                                    .frame(width: 16)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(suggestion.name)
                                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                                        .foregroundStyle(.primary)
                                                    Text(suggestion.path)
                                                        .font(.system(size: 11, design: .monospaced))
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                Image(systemName: "arrow.up.left")
                                                    .font(.system(size: 10))
                                                    .foregroundStyle(.tertiary)
                                            }
                                            .padding(.vertical, 7)
                                            .padding(.horizontal, 4)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .background(Color.secondary.opacity(0.001))

                                        if suggestion.path != pathSuggestions.last?.path {
                                            Divider().padding(.leading, 30)
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 220)
                            .background(Color(nsColor: .controlBackgroundColor))
                        }

                        // Resolution preview
                        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                            Divider()
                            HStack(spacing: 6) {
                                let path = finalPath
                                let isAbsolute = query.hasPrefix("/")
                                let found = isAbsolute
                                    ? FileManager.default.isExecutableFile(atPath: path)
                                    : (resolvedPath != nil)

                                Image(systemName: found ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(found ? .green : .orange)
                                    .font(.system(size: 11))

                                if found {
                                    Text("\(finalName)  →  \(path)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                } else if !isResolving {
                                    Text("\"\(finalName)\" not found in PATH — will save name only")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 2)
                        }
                    }
                } header: {
                    Label("CLI Tool", systemImage: "terminal")
                } footer: {
                    Text("Type a command name to search your PATH, or paste an absolute path like /usr/local/bin/mycli.")
                }

                // ── Settings ──────────────────────────────────────────
                Section("Settings") {
                    Toggle("Block all outbound traffic", isOn: $isBlocked)
                    if !isBlocked {
                        Picker("Filter Mode", selection: $filterMode) {
                            ForEach(FilterMode.directModes, id: \.self) { m in
                                Text(m.label).tag(m)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add CLI Rule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        vm.addCLIRule(
                            profileID: profileID,
                            name: finalName,
                            executablePath: finalPath,
                            blocked: isBlocked,
                            filterMode: filterMode
                        )
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAddDisabled)
                }
            }
        }
        .frame(minWidth: 420)
        .frame(maxHeight: 500)
        .onAppear { fieldFocused = true }
    }

    // ── PATH resolution ───────────────────────────────────────────────

    private func scheduleResolve(_ newVal: String) {
        let trimmed = newVal.trimmingCharacters(in: .whitespaces)

        // Absolute path typed — no lookup needed, validate existence
        if trimmed.hasPrefix("/") {
            resolvedPath = trimmed
            pathSuggestions = []
            showSuggestions = false
            return
        }

        pathSuggestions = []
        resolvedPath = nil

        guard !trimmed.isEmpty else {
            showSuggestions = false
            return
        }

        isResolving = true
        showSuggestions = true

        // Debounced async PATH scan (150 ms)
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }

            let suggestions = CLIPathResolver.search(prefix: trimmed)
            let exact = CLIPathResolver.resolve(trimmed)

            await MainActor.run {
                pathSuggestions = suggestions
                resolvedPath = exact
                isResolving = false
                showSuggestions = !suggestions.isEmpty
            }
        }
    }
}
