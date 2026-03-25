import SwiftUI

// MARK: - CLI Rules Tab

struct CLIRulesTab: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profileID: Int64

    @State private var expandedRuleID: Int64? = nil
    @State private var showAddCLI = false
    @State private var searchText = ""
    @State private var newDomain = ""
    @State private var addDomainForRuleID: Int64? = nil

    var profileWithRules: ProfileWithRules? { vm.activeProfile?.profile.id == profileID ? vm.activeProfile : nil }
    var globalMode: FilterMode { profileWithRules?.profile.globalMode ?? .blacklist }

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
                Text("CLI rules use pf firewall (process-level). Requires macOS 14.4+.")
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
                Menu {
                    Button("Add from Presets…") { showAddCLI = true }
                    Button("Add Custom CLI Tool…") { showAddCLI = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddCLI) {
            AddCLIRuleSheet(profileID: profileID)
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

                // Filter mode picker
                HStack {
                    Text("Domain Filter")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { cliRule.rule.filterMode },
                        set: { mode in
                            if let id = ruleID { vm.setCLIFilterMode(id: id, filterMode: mode) }
                        }
                    )) {
                        SwiftUI.ForEach(FilterMode.appModes, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
                .padding(.leading, 16)

                // Domain rules
                SwiftUI.ForEach(cliRule.domainRules, id: \.id) { domainRule in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 16)
                        Text(domainRule.domain).font(.system(size: 12))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { domainRule.isEnabled },
                            set: { on in
                                if let id = domainRule.id { vm.toggleDomainRule(id: id, enabled: on) }
                            }
                        ))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        Button(role: .destructive) {
                            if let id = domainRule.id { vm.removeDomainRule(id: id) }
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 32)
                }

                // Add domain
                HStack {
                    Image(systemName: "plus.circle").foregroundStyle(Color.accentColor).frame(width: 16)
                    TextField("Add allowed/blocked domain…", text: Binding(
                        get: { addDomainForRuleID == ruleID ? newDomain : "" },
                        set: { newDomain = $0; addDomainForRuleID = ruleID }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit {
                        if !newDomain.isEmpty, let rID = ruleID {
                            vm.addDomainRule(domain: newDomain, appRuleID: rID)
                            newDomain = ""
                            addDomainForRuleID = nil
                        }
                    }
                }
                .padding(.leading, 32)
            }
        } header: {
            CLIRuleHeaderRow(
                cliRule: cliRule,
                globalMode: globalMode,
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
    let cliRule: AppRuleWithDomains
    let globalMode: FilterMode
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: "terminal.fill")
                .foregroundStyle(cliRule.rule.isBlocked ? .red : .purple)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(cliRule.rule.appName)
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                HStack(spacing: 4) {
                    if cliRule.rule.isBlocked {
                        Label("All traffic blocked", systemImage: "stop.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                    } else if !cliRule.domainRules.isEmpty {
                        let mode = cliRule.effectiveFilterMode(globalMode: globalMode)
                        Label("\(cliRule.domainRules.count) domains · \(mode.label)", systemImage: "list.bullet")
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

            Toggle("Block", isOn: Binding(
                get: { cliRule.rule.isBlocked },
                set: { blocked in
                    if let id = cliRule.rule.id { vm.toggleCLIBlocked(id: id, blocked: blocked) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(cliRule.rule.isBlocked ? "Unblock all traffic" : "Block all network traffic")

            Button(role: .destructive) {
                if let id = cliRule.rule.id { vm.removeAppRule(id: id) }
            } label: {
                Image(systemName: "trash").foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
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
    @State private var filterMode: FilterMode = .inheritGlobal
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
                            ForEach(FilterMode.appModes, id: \.self) { mode in
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
                                name: preset.name,
                                executablePath: preset.executablePath ?? customPath,
                                blocked: isBlocked,
                                filterMode: filterMode
                            )
                        } else {
                            vm.addCLIRule(
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
