import SwiftUI

// MARK: - App Rules Tab (GUI apps only)

struct AppRulesTab: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profileID: Int64

    @State private var searchText = ""
    @State private var expandedRuleID: Int64? = nil
    @State private var showAddApp = false
    @State private var showBrowseApps = false
    @State private var importSiteListRule: AppRuleImportTarget?

    @State private var profileWithRules: ProfileWithRules?

    var appRules: [AppRuleWithDomains] {
        let rules = profileWithRules?.guiAppRules ?? []
        guard !searchText.isEmpty else { return rules }
        return rules.filter { $0.rule.appName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(profileWithRules?.guiAppRules.count ?? 0) apps · \(profileWithRules?.blockedAppBundleIDs.count ?? 0) fully blocked")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                        .font(.system(size: 12))
                    Text("Chrome and Firefox use managed browser policies and PAC proxy for per-site blocking. Safari per-site blocking requires an approved Network Extension. All browsers support full-app blocking.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if vm.enforcementHealth.safariNeedsNetworkExtension && !vm.enforcementHealth.networkExtensionActive {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 12))
                            Text("Safari has domain rules, but the Network Extension is not active. Enable it in **System Settings → General → Login Items & Extensions → Network Extensions**.")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Open Network Extensions Settings", systemImage: "gear")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.leading, 20)
                    }
                }
                if vm.networkFilterState == .awaitingApproval || vm.networkFilterState == .rebootRequired {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 12))
                            Text(vm.networkFilterState.summary)
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Allow in System Settings", systemImage: "arrow.up.forward.app.fill")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                        .padding(.leading, 20)
                    }
                }
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
                        vm.scanInstalledApps(excludingProfile: profileID)
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
        let activeMode = appRule.effectiveFilterMode(globalMode: .blacklist)
        let activeGroups = DomainGroup.build(
            rules: appRule.domainRules(for: activeMode),
            groups: profileWithRules?.customDomainGroups ?? []
        )
        Section {
            if isExpanded {
                if appRule.supportsPerAppDomainFiltering {
                    RuleDomainEditorView(
                        currentMode: activeMode,
                        displayedGroups: activeGroups,
                        whitelistCount: appRule.domainCount(for: .whitelist),
                        blacklistCount: appRule.domainCount(for: .blacklist),
                        addPlaceholder: "Add facebook.com, m.facebook.com, or *.facebook.com",
                        onModeChange: { mode in
                            guard let id = ruleID else { return }
                            vm.setAppFilterMode(profileID: profileID, id: id, filterMode: mode)
                        },
                        onImport: {
                            guard let ruleID else { return }
                            importSiteListRule = AppRuleImportTarget(
                                ruleID: ruleID,
                                title: appRule.rule.appName,
                                filterMode: activeMode
                            )
                        },
                        onToggleRule: { id, isEnabled in
                            vm.toggleDomainRule(profileID: profileID, id: id, enabled: isEnabled)
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
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(width: 16)
                        Text("Per-domain filtering for this app is not available in the current runtime.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 16)
                }
            }
        } header: {
            AppRuleHeaderRow(
                profileID: profileID,
                appRule: appRule,
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
                vm.scanInstalledApps(excludingProfile: profileID)
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
    let profileID: Int64
    let appRule: AppRuleWithDomains
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    private var isLinked: Bool { appRule.rule.isEnabled }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: "app.fill")
                .foregroundStyle(isLinked ? (appRule.rule.isBlocked ? .red : .blue) : .gray)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(appRule.rule.appName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isLinked ? .primary : .secondary)
                HStack(spacing: 4) {
                    if !isLinked {
                        Label("Disabled", systemImage: "link.badge.plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                    } else if appRule.rule.isBlocked {
                        Label("Blocked", systemImage: "stop.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                    } else if !appRule.supportsPerAppDomainFiltering {
                        Label("Full block only", systemImage: "bolt.horizontal.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else if !appRule.domainRules.isEmpty {
                        let mode = appRule.effectiveFilterMode(globalMode: .blacklist)
                        let activeCount = appRule.domainCount(for: mode)
                        let otherMode: FilterMode = mode == .whitelist ? .blacklist : .whitelist
                        let otherCount = appRule.domainCount(for: otherMode)
                        Label("\(activeCount) \(mode.label.lowercased()) · \(otherCount) \(otherMode.label.lowercased())", systemImage: "list.bullet")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No site restrictions")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Block toggle — disabled when rule is unlinked
            Toggle("Block", isOn: Binding(
                get: { appRule.rule.isBlocked },
                set: { blocked in
                    if let id = appRule.rule.id {
                        vm.toggleAppBlocked(profileID: profileID, id: id, blocked: blocked)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(appRule.rule.isBlocked ? "Unblock app" : "Block app entirely")
            .disabled(!isLinked)
            .opacity(isLinked ? 1 : 0.4)

            // Unlink / Link button
            Button {
                if let id = appRule.rule.id {
                    vm.toggleAppEnabled(profileID: profileID, id: id, enabled: !isLinked)
                }
            } label: {
                Image(systemName: isLinked ? "link" : "link.badge.plus")
                    .foregroundStyle(isLinked ? Color.secondary : Color.orange)
            }
            .buttonStyle(.plain)
            .help(isLinked ? "Disable rule (keep domain lists)" : "Re-enable rule")

            Button(role: .destructive) {
                if let id = appRule.rule.id { vm.removeAppRule(profileID: profileID, id: id) }
            } label: {
                Image(systemName: "trash").foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .opacity(isLinked ? 1 : 0.7)
    }
}

struct AppRuleImportTarget: Identifiable {
    let ruleID: Int64
    let title: String
    let filterMode: FilterMode

    var id: Int64 { ruleID }
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
                        vm.addAppRule(profileID: profileID, name: app.name, bundleID: app.bundleIdentifier)
                        vm.scanInstalledApps(excludingProfile: profileID)
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
                    vm.addAppRule(profileID: profileID, name: appName, bundleID: bundleID, blocked: isBlocked)
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
