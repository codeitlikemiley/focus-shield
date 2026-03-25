import SwiftUI

// MARK: - App Rules Tab (GUI apps only)

struct AppRulesTab: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profileID: Int64

    @State private var searchText = ""
    @State private var expandedRuleID: Int64? = nil
    @State private var showAddApp = false
    @State private var showBrowseApps = false
    @State private var newDomain = ""
    @State private var addDomainForRuleID: Int64? = nil

    var profileWithRules: ProfileWithRules? { vm.activeProfile?.profile.id == profileID ? vm.activeProfile : nil }
    var globalMode: FilterMode { profileWithRules?.profile.globalMode ?? .blacklist }

    var appRules: [AppRuleWithDomains] {
        let rules = profileWithRules?.guiAppRules ?? []
        guard !searchText.isEmpty else { return rules }
        return rules.filter { $0.rule.appName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            HStack {
                Text("\(profileWithRules?.guiAppRules.count ?? 0) apps · \(profileWithRules?.blockedAppBundleIDs.count ?? 0) fully blocked")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if (profileWithRules?.guiAppRules ?? []).isEmpty {
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
                    Button("Browse Installed Apps…") {
                        vm.scanInstalledApps()
                        showBrowseApps = true
                    }
                    Button("Add Manually…") { showAddApp = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showBrowseApps) {
            BrowseAppsSheet(profileID: profileID)
        }
        .sheet(isPresented: $showAddApp) {
            AddAppSheet(profileID: profileID)
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search apps…", text: $searchText).textFieldStyle(.plain)
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
        let rules: [AppRuleWithDomains] = appRules
        return List(rules, id: \.rule.bundleIdentifier) { appRule in
            appRuleSection(appRule)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func appRuleSection(_ appRule: AppRuleWithDomains) -> some View {
        let ruleID: Int64? = appRule.rule.id
        let isExpanded: Bool = expandedRuleID != nil && expandedRuleID == ruleID
        Section {
            if isExpanded {
                // Filter mode picker
                HStack {
                    Text("Domain Filter")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { appRule.rule.filterMode },
                        set: { mode in
                            if let id = ruleID { vm.setAppFilterMode(id: id, filterMode: mode) }
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
                SwiftUI.ForEach(appRule.domainRules, id: \.id) { domainRule in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 16)
                        Text(domainRule.domain).font(.system(size: 12))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { domainRule.isEnabled },
                            set: { on in if let id = domainRule.id { vm.toggleDomainRule(id: id, enabled: on) } }
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
                    TextField("Add domain for \(appRule.rule.appName)…",
                              text: Binding(
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
            AppRuleHeaderRow(
                appRule: appRule,
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
            Label("No App Rules", systemImage: "app.badge.fill")
        } description: {
            Text("Add apps to control their network access per profile.")
        } actions: {
            Button("Browse Apps…") {
                vm.scanInstalledApps()
                showBrowseApps = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App Rule Header Row

struct AppRuleHeaderRow: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let appRule: AppRuleWithDomains
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

            Image(systemName: "app.fill")
                .foregroundStyle(appRule.rule.isBlocked ? .red : .blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(appRule.rule.appName)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    if appRule.rule.isBlocked {
                        Label("Blocked", systemImage: "stop.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                    } else if !appRule.domainRules.isEmpty {
                        let mode = appRule.effectiveFilterMode(globalMode: globalMode)
                        Label("\(appRule.domainRules.count) domain rules · \(mode.label)", systemImage: "list.bullet")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Inherit Global")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Block toggle
            Toggle("Block", isOn: Binding(
                get: { appRule.rule.isBlocked },
                set: { blocked in
                    if let id = appRule.rule.id { vm.toggleAppBlocked(id: id, blocked: blocked) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(appRule.rule.isBlocked ? "Unblock app" : "Block app entirely")

            Button(role: .destructive) {
                if let id = appRule.rule.id { vm.removeAppRule(id: id) }
            } label: {
                Image(systemName: "trash").foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Browse Apps Sheet

struct BrowseAppsSheet: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let profileID: Int64
    @State private var searchText = ""

    var filtered: [FocusShieldViewModel.InstalledApp] {
        guard !searchText.isEmpty else { return vm.installedApps }
        return vm.installedApps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { app in
                HStack {
                    Image(systemName: "app.fill").foregroundStyle(.blue).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.system(size: 13, weight: .medium))
                        Text(app.bundleIdentifier).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Add") {
                        vm.addAppRule(name: app.name, bundleID: app.bundleIdentifier)
                        vm.scanInstalledApps()
                    }
                    .controlSize(.small)
                }
            }
            .searchable(text: $searchText, prompt: "Search apps")
            .navigationTitle("Installed Apps")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 480)
    }
}

// MARK: - Add App Sheet (manual)

struct AddAppSheet: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let profileID: Int64
    @State private var appName = ""
    @State private var bundleID = ""
    @State private var isBlocked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add App Rule").font(.title2.weight(.bold))
            TextField("App name", text: $appName).textFieldStyle(.roundedBorder)
            TextField("Bundle ID (e.g. com.apple.Safari)", text: $bundleID).textFieldStyle(.roundedBorder)
            Toggle("Block entirely", isOn: $isBlocked)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    vm.addAppRule(name: appName, bundleID: bundleID, blocked: isBlocked)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appName.isEmpty || bundleID.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }
}
