import SwiftUI

// MARK: - Global Rules Tab (Websites)

struct GlobalRulesTab: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profileID: Int64

    @State private var expandedGroups: Set<String> = []
    @State private var searchText = ""
    @State private var showAddDomain = false
    @State private var newDomain = ""
    @State private var showCategoryPicker = false

    var profileWithRules: ProfileWithRules? { vm.activeProfile?.profile.id == profileID ? vm.activeProfile : nil }
    var globalMode: FilterMode { profileWithRules?.profile.globalMode ?? .blacklist }
    var allRules: [DomainRule] { profileWithRules?.globalDomainRules ?? [] }

    var filteredGroups: [DomainGroup] {
        let groups = DomainGroup.group(allRules)
        guard !searchText.isEmpty else { return groups }
        return groups.compactMap { group in
            let filtered = group.rules.filter { $0.domain.localizedCaseInsensitiveContains(searchText) }
            guard !filtered.isEmpty else { return nil }
            return DomainGroup(id: group.id, label: group.label, rules: filtered)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mode picker + search bar
            HStack(spacing: 12) {
                modePicker
                Spacer()
                Text("\(allRules.filter { $0.isEnabled }.count) active")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if allRules.isEmpty {
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
                    Button("Add Domain…") { showAddDomain = true }
                    Button("Add Category…") { showCategoryPicker = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddDomain) {
            addDomainSheet
        }
        .sheet(isPresented: $showCategoryPicker) {
            CategoryPickerSheet(profileID: profileID)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(FilterMode.globalModes, id: \.self) { mode in
                Button {
                    if var p = profileWithRules?.profile {
                        p.globalMode = mode
                        vm.updateProfile(&p)
                    }
                } label: {
                    Text(mode.label)
                        .font(.system(size: 12, weight: globalMode == mode ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            globalMode == mode
                                ? (mode == .whitelist ? Color.green : Color.red)
                                : Color.clear
                        )
                        .foregroundStyle(globalMode == mode ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.secondary.opacity(0.12), in: Capsule())
        .clipShape(Capsule())
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search domains…", text: $searchText)
                .textFieldStyle(.plain)
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
        List {
            ForEach(filteredGroups) { group in
                let isExpanded = expandedGroups.contains(group.id)
                Section {
                    if isExpanded {
                        ForEach(group.rules) { rule in
                            DomainRuleRow(rule: rule)
                        }
                    }
                } header: {
                    GroupHeaderRow(
                        group: group,
                        isExpanded: isExpanded,
                        onToggleExpand: {
                            if isExpanded { expandedGroups.remove(group.id) }
                            else { expandedGroups.insert(group.id) }
                        },
                        onToggleAll: { enabled in
                            for rule in group.rules {
                                if let id = rule.id { vm.toggleDomainRule(id: id, enabled: enabled) }
                            }
                        }
                    )
                }
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(globalMode == .whitelist ? "No Allowed Domains" : "No Blocked Domains",
                  systemImage: "globe.slash")
        } description: {
            Text(globalMode == .whitelist
                 ? "Add domains to allow. All others will be blocked."
                 : "Add domains to block. All others will be allowed.")
        } actions: {
            Button("Add Domain…") { showAddDomain = true }
                .buttonStyle(.borderedProminent)
            Button("Add Category…") { showCategoryPicker = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addDomainSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Domain").font(.title2.weight(.bold))

            TextField("e.g. facebook.com", text: $newDomain)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { showAddDomain = false; newDomain = "" }
                Button("Add") {
                    vm.addDomainRule(domain: newDomain)
                    showAddDomain = false
                    newDomain = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 320)
    }
}

// MARK: - Group Header Row

struct GroupHeaderRow: View {
    let group: DomainGroup
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onToggleAll: (Bool) -> Void

    var body: some View {
        HStack {
            Button(action: onToggleExpand) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(group.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("(\(group.rules.count))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Toggle("", isOn: Binding(
                get: { group.allEnabled },
                set: { onToggleAll($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
    }
}

// MARK: - Individual Domain Rule Row

struct DomainRuleRow: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let rule: DomainRule

    var body: some View {
        HStack {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(rule.domain)
                .font(.system(size: 13))
                .foregroundStyle(rule.isEnabled ? .primary : .secondary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { enabled in
                    if let id = rule.id { vm.toggleDomainRule(id: id, enabled: enabled) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Button(role: .destructive) {
                if let id = rule.id { vm.removeDomainRule(id: id) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 28)
    }
}

// MARK: - Category Picker Sheet

struct CategoryPickerSheet: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let profileID: Int64
    @State private var selected: Set<String> = []

    var body: some View {
        let categories: [DefaultCategories.CategoryTemplate] = DefaultCategories.all
        return NavigationStack {
            List(categories, id: \.name) { cat in
                categoryRow(cat)
            }
            .navigationTitle("Add Category")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add Selected") {
                        let domains = DefaultCategories.all
                            .filter { selected.contains($0.name) }
                            .flatMap { $0.domains }
                        vm.addDomainRulesBulk(domains: domains)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .frame(minWidth: 340, minHeight: 400)
    }

    @ViewBuilder
    private func categoryRow(_ cat: DefaultCategories.CategoryTemplate) -> some View {
        let isSelected = selected.contains(cat.name)
        HStack {
            Image(systemName: cat.icon).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.name).font(.system(size: 13, weight: .medium))
                Text("\(cat.domains.count) domains")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selected.remove(cat.name) }
            else { selected.insert(cat.name) }
        }
    }
}
