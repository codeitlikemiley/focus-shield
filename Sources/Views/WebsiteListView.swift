import SwiftUI

// MARK: - Site List Bank Tab

struct GlobalRulesTab: View {
    @Environment(FocusShieldViewModel.self) private var vm

    @State private var expandedListIDs: Set<Int64> = []
    @State private var searchText = ""
    @State private var showAddList = false
    @State private var addDomainForListID: Int64?
    @State private var newDomain = ""
    @State private var editingDomainID: Int64?
    @State private var editingDomainText = ""

    var filteredLists: [SiteListWithDomains] {
        guard !searchText.isEmpty else { return vm.siteLists }

        return vm.siteLists.compactMap { list in
            let matchesList = list.list.name.localizedCaseInsensitiveContains(searchText)
            let matchingDomains = list.domains.filter { $0.domain.localizedCaseInsensitiveContains(searchText) }
            guard matchesList || !matchingDomains.isEmpty else { return nil }
            return SiteListWithDomains(list: list.list, domains: matchesList ? list.domains : matchingDomains)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(vm.siteLists.count) reusable lists")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 12))
                    Text("Site lists are templates only. Importing a list into an app or CLI rule makes a copy, so future edits to the template do not mutate the existing app rule.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if vm.siteLists.isEmpty {
                emptyState
            } else {
                searchBar
                Divider()
                siteListList
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddList = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddList) {
            AddSiteListSheet { newListID in
                expandedListIDs.insert(newListID)
                addDomainForListID = newListID
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search site lists or domains…", text: $searchText)
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

    private var siteListList: some View {
        List {
            ForEach(filteredLists, id: \.list.id) { siteList in
                let listID = siteList.list.id ?? -1
                let isExpanded = expandedListIDs.contains(listID)

                Section {
                    if isExpanded {
                        if siteList.domains.isEmpty, !siteList.list.isBuiltIn {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "square.and.pencil")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text("No domains yet. Add `facebook.com`, `m.facebook.com`, or `*.facebook.com` below.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.leading, 20)
                        }

                        ForEach(siteList.domains, id: \.id) { domain in
                            let domainID = domain.id ?? -1
                            if editingDomainID == domainID, !siteList.list.isBuiltIn {
                                HStack(spacing: 8) {
                                    Image(systemName: domain.domain.hasPrefix("*.") ? "asterisk" : "globe")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    TextField("Edit domain", text: $editingDomainText)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13))
                                        .onSubmit {
                                            guard let id = domain.id else { return }
                                            vm.updateSiteListDomain(id: id, domain: editingDomainText)
                                            editingDomainID = nil
                                            editingDomainText = ""
                                        }
                                    Button("Save") {
                                        guard let id = domain.id else { return }
                                        vm.updateSiteListDomain(id: id, domain: editingDomainText)
                                        editingDomainID = nil
                                        editingDomainText = ""
                                    }
                                    .buttonStyle(.plain)
                                    Button("Cancel") {
                                        editingDomainID = nil
                                        editingDomainText = ""
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.leading, 20)
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: domain.domain.hasPrefix("*.") ? "asterisk" : "globe")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    Text(domain.domain)
                                        .font(.system(size: 13))
                                        .textSelection(.enabled)
                                    Spacer()
                                    if !siteList.list.isBuiltIn {
                                        Button {
                                            editingDomainID = domainID
                                            editingDomainText = domain.domain
                                        } label: {
                                            Image(systemName: "pencil")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        Button(role: .destructive) {
                                            guard let id = domain.id else { return }
                                            vm.removeDomainFromSiteList(id: id)
                                        } label: {
                                            Image(systemName: "trash")
                                                .foregroundStyle(.red.opacity(0.7))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.leading, 20)
                            }
                        }

                        if !siteList.list.isBuiltIn {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 18)
                                TextField(
                                    "Add facebook.com, m.facebook.com, or *.facebook.com",
                                    text: Binding(
                                        get: { addDomainForListID == listID ? newDomain : "" },
                                        set: { newDomain = $0; addDomainForListID = listID }
                                    )
                                )
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .onSubmit {
                                    guard !newDomain.isEmpty else { return }
                                    vm.addDomainToSiteList(siteListID: listID, domain: newDomain)
                                    newDomain = ""
                                    addDomainForListID = nil
                                }
                            }
                            .padding(.leading, 20)
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        Button {
                            if isExpanded {
                                expandedListIDs.remove(listID)
                            } else {
                                expandedListIDs.insert(listID)
                            }
                        } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(siteList.list.name)
                                    .font(.system(size: 13, weight: .semibold))
                                Text("(\(siteList.domains.count))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Text(siteList.list.isBuiltIn ? "Built-in list" : "Custom list")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if !siteList.list.isBuiltIn {
                            Button(role: .destructive) {
                                vm.removeSiteList(id: listID)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Site Lists", systemImage: "square.stack.3d.up.slash")
        } description: {
            Text("Create reusable lists like Social Media, Streaming, Shopping, or AI Tools, then import a copy into any app or CLI rule.")
        } actions: {
            Button("Create List") { showAddList = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Add Site List Sheet

struct AddSiteListSheet: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let onCreated: (Int64) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Site List")
                .font(.title2.weight(.bold))

            TextField("e.g. Social Media", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    if let id = vm.addSiteList(name: name) {
                        onCreated(id)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }
}

// MARK: - Import Site List Sheet

struct ImportSiteListSheet: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    let profileID: Int64
    let appRuleID: Int64
    let title: String
    let filterMode: FilterMode

    @State private var selectedListID: Int64?
    @State private var selectedDomainIDs: Set<Int64> = []

    private var selectedList: SiteListWithDomains? {
        guard let selectedListID else { return nil }
        return vm.siteLists.first(where: { $0.list.id == selectedListID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Into \(title)")
                .font(.title2.weight(.bold))

            Text("Imported domains are added to the \(filterMode.label.lowercased()) list for this rule only, expanded with known related site-family domains, and grouped under the template name.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Picker("Template", selection: $selectedListID) {
                Text("Select a site list").tag(Int64?.none)
                ForEach(vm.siteLists, id: \.list.id) { list in
                    Text(list.list.name).tag(list.list.id)
                }
            }

            if let selectedList {
                HStack {
                    Text("\(selectedDomainIDs.count) of \(selectedList.domains.count) selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Select All") {
                        selectedDomainIDs = Set(selectedList.domains.compactMap(\.id))
                    }
                    .buttonStyle(.plain)
                    Button("Clear") {
                        selectedDomainIDs.removeAll()
                    }
                    .buttonStyle(.plain)
                }

                List(selectedList.domains, id: \.id) { domain in
                    let domainID = domain.id ?? -1
                    Button {
                        if selectedDomainIDs.contains(domainID) {
                            selectedDomainIDs.remove(domainID)
                        } else {
                            selectedDomainIDs.insert(domainID)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selectedDomainIDs.contains(domainID) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedDomainIDs.contains(domainID) ? Color.accentColor : .secondary)
                            Text(domain.domain)
                                .font(.system(size: 13))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 260)
            } else {
                ContentUnavailableView("Choose a site list", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity, minHeight: 260)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import Selected") {
                    guard let selectedList else { return }
                    let selectedDomains = selectedList.domains
                        .filter { domain in
                            guard let id = domain.id else { return false }
                            return selectedDomainIDs.contains(id)
                        }
                        .map(\.domain)
                    vm.importSiteDomains(
                        profileID: profileID,
                        appRuleID: appRuleID,
                        filterMode: filterMode,
                        domains: selectedDomains,
                        siteListName: selectedList.list.name
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedDomainIDs.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 520)
        .onAppear {
            if selectedListID == nil {
                selectedListID = vm.siteLists.first?.list.id
            }
        }
        .onChange(of: selectedListID) { _, newValue in
            guard let newValue,
                  let list = vm.siteLists.first(where: { $0.list.id == newValue }) else {
                selectedDomainIDs.removeAll()
                return
            }
            selectedDomainIDs = Set(list.domains.compactMap(\.id))
        }
    }
}
