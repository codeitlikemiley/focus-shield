/// iOS-specific entry point for Focus Shield.
/// On iOS, there is no MenuBarExtra and no /etc/hosts access.
/// Website and app blocking is handled entirely via the Screen Time API
/// (FamilyControls + ManagedSettings frameworks).
///
/// NOTE: The FamilyControls entitlement (com.apple.developer.family-controls)
/// must be enabled in your Apple Developer account and provisioning profile.
/// Without it, the app will build but Screen Time authorization will fail.

#if os(iOS)
import SwiftUI

@main
struct FocusShieldiOSApp: App {
    @State private var viewModel = FocusShieldViewModel()

    var body: some Scene {
        WindowGroup {
            iOSContentView()
                .environment(viewModel)
        }
    }
}

// MARK: - iOS Root View

struct iOSContentView: View {
    @Environment(FocusShieldViewModel.self) private var vm

    var body: some View {
        TabView {
            iOSWebsiteListView()
                .tabItem {
                    Label("Websites", systemImage: "globe")
                }

            iOSAppListView()
                .tabItem {
                    Label("Apps", systemImage: "app.badge")
                }

            iOSSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .safeAreaInset(edge: .top) {
            masterToggleBanner
        }
    }

    private var masterToggleBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: vm.data.masterEnabled ? "shield.checkered" : "shield")
                .font(.title2)
                .foregroundStyle(vm.data.masterEnabled ? .green : .secondary)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text("Focus Shield")
                    .font(.headline)
                Text(vm.data.masterEnabled ? "Active — blocking enabled" : "Off — nothing is blocked")
                    .font(.caption)
                    .foregroundStyle(vm.data.masterEnabled ? .green : .secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { vm.masterEnabled },
                set: { vm.masterEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

// MARK: - iOS Website List

struct iOSWebsiteListView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @State private var searchText = ""
    @State private var showingAddDomain = false
    @State private var showingAddCategory = false
    @State private var addDomainText = ""
    @State private var addCategoryText = ""
    @State private var targetCategoryID: UUID?

    var body: some View {
        NavigationStack {
            List {
                if !vm.data.masterEnabled {
                    warningBanner
                }

                ForEach(filteredCategories) { category in
                    Section {
                        categoryHeader(category)
                        if category.isEnabled {
                            ForEach(category.domains) { domain in
                                domainRow(domain, categoryID: category.id)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search domains...")
            .navigationTitle("Blocked Websites")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            addCategoryText = ""
                            showingAddCategory = true
                        } label: {
                            Label("Add Category", systemImage: "folder.badge.plus")
                        }
                        Button {
                            toggleAllCategories()
                        } label: {
                            let allOn = vm.data.websiteCategories.allSatisfy { $0.isEnabled }
                            Label(allOn ? "Disable All" : "Enable All", systemImage: allOn ? "eye.slash" : "eye")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingAddDomain) { addDomainSheet }
            .sheet(isPresented: $showingAddCategory) { addCategorySheet }
        }
    }

    private var filteredCategories: [WebsiteCategory] {
        if searchText.isEmpty { return vm.data.websiteCategories }
        return vm.data.websiteCategories.filter { cat in
            cat.name.localizedCaseInsensitiveContains(searchText)
            || cat.domains.contains { $0.domain.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private func categoryHeader(_ category: WebsiteCategory) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading) {
                    Text(category.name).font(.headline)
                    let active = category.domains.filter { $0.isEnabled }.count
                    Text("\(active)/\(category.domains.count) domains").font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: category.icon)
                    .foregroundStyle(category.isEnabled && vm.data.masterEnabled ? .red : .secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { category.isEnabled },
                set: { _ in vm.toggleCategory(category.id) }
            ))
            .labelsHidden()

            Button {
                targetCategoryID = category.id
                addDomainText = ""
                showingAddDomain = true
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }

    private func domainRow(_ domain: BlockedDomain, categoryID: UUID) -> some View {
        HStack {
            Image(systemName: domain.isEnabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(domain.isEnabled ? .red : .secondary)
                .onTapGesture { vm.toggleDomain(domain.id, inCategory: categoryID) }

            Text(domain.domain)
                .font(.system(.body, design: .monospaced))
                .strikethrough(!domain.isEnabled, color: .secondary)

            Spacer()
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                vm.removeWebsite(domain.id, fromCategoryID: categoryID)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var warningBanner: some View {
        Label("Shield is off. Enable the master toggle.", systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
    }

    private var addDomainSheet: some View {
        NavigationStack {
            Form {
                TextField("e.g. example.com", text: $addDomainText)
            }
            .navigationTitle("Add Website")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingAddDomain = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let id = targetCategoryID { vm.addWebsite(domain: addDomainText, toCategoryID: id) }
                        showingAddDomain = false
                    }
                    .disabled(addDomainText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var addCategorySheet: some View {
        NavigationStack {
            Form {
                TextField("Category Name", text: $addCategoryText)
            }
            .navigationTitle("Add Category")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingAddCategory = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        vm.addCategory(name: addCategoryText)
                        showingAddCategory = false
                        addCategoryText = ""
                    }
                    .disabled(addCategoryText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func toggleAllCategories() {
        let allOn = vm.data.websiteCategories.allSatisfy { $0.isEnabled }
        for cat in vm.data.websiteCategories {
            if (allOn && cat.isEnabled) || (!allOn && !cat.isEnabled) { vm.toggleCategory(cat.id) }
        }
    }
}

// MARK: - iOS App List

struct iOSAppListView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if !vm.data.masterEnabled {
                    Label("Shield is off.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }

                Section(
                    header: Text("Blocked Apps"),
                    footer: Text("On iOS, app blocking uses Screen Time (FamilyControls). Apps in this list will be restricted when the shield is active.")
                ) {
                    ForEach(filteredApps) { app in
                        HStack {
                            Image(systemName: app.isEnabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(app.isEnabled ? .red : .secondary)
                                .onTapGesture { vm.toggleApp(app.id) }

                            VStack(alignment: .leading) {
                                Text(app.name).font(.body)
                                    .strikethrough(!app.isEnabled, color: .secondary)
                                Text(app.bundleIdentifier).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { vm.removeApp(app.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search apps...")
            .navigationTitle("Blocked Apps")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let allOn = vm.data.blockedApps.allSatisfy { $0.isEnabled }
                        for app in vm.data.blockedApps {
                            if (allOn && app.isEnabled) || (!allOn && !app.isEnabled) { vm.toggleApp(app.id) }
                        }
                    } label: {
                        let allOn = vm.data.blockedApps.allSatisfy { $0.isEnabled }
                        Label(allOn ? "Disable All" : "Enable All", systemImage: allOn ? "eye.slash" : "eye")
                    }
                }
            }
        }
    }

    private var filteredApps: [AppBlockItem] {
        if searchText.isEmpty { return vm.data.blockedApps }
        return vm.data.blockedApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - iOS Settings

struct iOSSettingsView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @StateObject private var screenTime = ScreenTimeService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Screen Time") {
                    HStack {
                        Label("Authorization", systemImage: "shield.checkered")
                        Spacer()
                        if screenTime.isAuthorized {
                            Label("Authorized", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Button("Authorize") {
                                Task { await screenTime.requestAuthorization() }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    if let error = screenTime.authorizationError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }

                    Text("Screen Time authorization lets Focus Shield block websites and apps natively using Apple's FamilyControls framework.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Section("About") {
                    Label("Version 1.0.0", systemImage: "info.circle")
                    Label {
                        Text("Website blocking uses Screen Time content filters")
                    } icon: {
                        Image(systemName: "globe")
                    }
                    .font(.caption)
                    Label {
                        Text("App blocking uses ManagedSettings restrictions")
                    } icon: {
                        Image(systemName: "app.badge")
                    }
                    .font(.caption)
                }

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        vm.data = FocusShieldData.defaultData
                        DataStore.save(vm.data)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { screenTime.checkAuthorization() }
        }
    }
}
#endif
