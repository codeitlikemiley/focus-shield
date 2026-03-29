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
                    Image(systemName: "plus")
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
                    currentMode: activeMode,
                    displayedGroups: activeGroups,
                    whitelistCount: cliRule.domainCount(for: .whitelist),
                    blacklistCount: cliRule.domainCount(for: .blacklist),
                    addPlaceholder: "Add api.example.com or *.example.com",
                    onModeChange: { mode in
                        guard let id = ruleID else { return }
                        vm.setCLIFilterMode(profileID: profileID, id: id, filterMode: mode)
                    },
                    onImport: {
                        guard let ruleID else { return }
                        importSiteListRule = AppRuleImportTarget(
                            ruleID: ruleID,
                            title: cliRule.rule.appName,
                            filterMode: activeMode
                        )
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

    private var isLinked: Bool { cliRule.rule.isEnabled }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
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

            // Unlink / Link button
            Button {
                if let id = cliRule.rule.id {
                    vm.toggleAppEnabled(profileID: profileID, id: id, enabled: !isLinked)
                }
            } label: {
                Image(systemName: isLinked ? "link" : "link.badge.plus")
                    .foregroundStyle(isLinked ? Color.secondary : Color.orange)
            }
            .buttonStyle(.plain)
            .help(isLinked ? "Disable rule (keep domain lists)" : "Re-enable rule")

            Button(role: .destructive) {
                if let id = cliRule.rule.id { vm.removeAppRule(profileID: profileID, id: id) }
            } label: {
                Image(systemName: "trash").foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .opacity(isLinked ? 1 : 0.7)
    }
}

// MARK: - Add CLI Rule Sheet

struct AddCLIRuleSheet: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let profileID: Int64

    @State private var selectedPreset: DefaultApps.AppTemplate? = nil
    @State private var customName = ""
    @State private var customPath = ""
    @State private var isBlocked = false
    @State private var filterMode: FilterMode = .blacklist
    @State private var mode: SheetMode = .presets

    enum SheetMode { case presets, custom }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Mode", selection: $mode) {
                    Text("From Presets").tag(SheetMode.presets)
                    Text("Custom").tag(SheetMode.custom)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if mode == .presets {
                    Section("Common CLI Tools") {
                        ForEach(DefaultApps.cli, id: \.bundleID) { preset in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .font(.system(.body, design: .monospaced))
                                    Text(preset.executablePath ?? "")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedPreset?.bundleID == preset.bundleID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedPreset = preset }
                        }
                    }
                } else {
                    Section("Custom CLI Tool") {
                        TextField("Name (e.g. mycli)", text: $customName)
                        TextField("Executable path (e.g. /usr/local/bin/mycli)", text: $customPath)
                    }
                }

                Section("Settings") {
                    Toggle("Block all outbound traffic", isOn: $isBlocked)
                    if !isBlocked {
                        Picker("Filter Mode", selection: $filterMode) {
                            ForEach(FilterMode.directModes, id: \.self) { mode in
                                Text(mode.label).tag(mode)
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
                        if mode == .presets, let preset = selectedPreset {
                            vm.addCLIRule(
                                profileID: profileID,
                                name: preset.name,
                                executablePath: preset.executablePath ?? customPath,
                                blocked: isBlocked,
                                filterMode: filterMode
                            )
                        } else {
                            vm.addCLIRule(
                                profileID: profileID,
                                name: customName,
                                executablePath: customPath,
                                blocked: isBlocked,
                                filterMode: filterMode
                            )
                        }
                        dismiss()
                    }
                    .disabled(isAddDisabled)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 500)
    }

    private var isAddDisabled: Bool {
        if mode == .presets { return selectedPreset == nil }
        return customName.isEmpty || customPath.isEmpty
    }
}
