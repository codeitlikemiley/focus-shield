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
                Text("CLI rules now run through a wrapper preflight that can reject visible destination hosts and sensitive payloads before the command executes. Commands that hide their network targets internally still need the future transport-aware engine for full coverage.")
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
                Button {
                    showAddCLI = true
                } label: {
                    Label("Add CLI", systemImage: "plus")
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

            Image(systemName: "terminal.fill")
                .foregroundStyle(isLinked ? (cliRule.rule.isBlocked ? .red : .purple) : .gray)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(cliRule.rule.appName)
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .foregroundStyle(isLinked ? .primary : .secondary)
                HStack(spacing: 4) {
                    if !isLinked {
                        Label("Disabled", systemImage: "link.badge.plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    } else if cliRule.rule.isBlocked {
                        Label("All traffic blocked", systemImage: "stop.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
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

