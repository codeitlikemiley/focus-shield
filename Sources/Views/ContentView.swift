import SwiftUI

// MARK: - Navigation Destination

enum NavigationDestination: Hashable {
    case profile(Int64)
    case lists
    case settings
}

// MARK: - Content View

struct ContentView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @State private var destination: NavigationDestination? = nil
    @State private var selectedTab: RuleTab = .apps

    enum RuleTab: String, CaseIterable {
        case apps = "Apps"
        case cli  = "CLI"

        var systemImage: String {
            switch self {
            case .apps: "app.badge"
            case .cli:  "terminal.fill"
            }
        }
    }

    var selectedProfileID: Int64? {
        if case .profile(let id) = destination { return id }
        return nil
    }

    var body: some View {
        Group {
            if case .settings = destination {
                NavigationSplitView {
                    SidebarView(destination: $destination)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                } detail: {
                    SettingsView()
                }
            } else if case .lists = destination {
                NavigationSplitView {
                    SidebarView(destination: $destination)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                } detail: {
                    GlobalRulesTab()
                        .navigationTitle("Lists")
                }
            } else {
                NavigationSplitView {
                    SidebarView(destination: $destination)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                } content: {
                    switch destination {
                    case .profile(let id):
                        if let profile = vm.profiles.first(where: { $0.id == id }) {
                            ProfileDetailView(
                                profile: profile,
                                selectedTab: $selectedTab,
                                openLists: { destination = .lists }
                            )
                                .id(id)
                        } else {
                            noProfileSelected
                        }
                    case .lists, .settings, nil:
                        noProfileSelected
                    }
                } detail: {
                    switch destination {
                    case .profile(let id):
                        if let profile = vm.profiles.first(where: { $0.id == id }) {
                            ProfileRulesDetailView(
                                profile: profile,
                                selectedTab: $selectedTab
                            )
                            .id("\(id)-\(selectedTab.rawValue)")
                        } else {
                            noProfileSelected
                        }
                    case .lists, .settings, nil:
                        noProfileSelected
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .onAppear {
            if destination == nil {
                let id = vm.settings.activeProfileID ?? vm.profiles.first?.id
                if let id { destination = .profile(id) }
            }
        }
        .onChange(of: vm.profiles) { _, _ in
            if destination == nil {
                let id = vm.settings.activeProfileID ?? vm.profiles.first?.id
                if let id { destination = .profile(id) }
            }
        }
    }

    private var noProfileSelected: some View {
        ContentUnavailableView {
            Label("No Profile Selected", systemImage: "shield.slash")
        } description: {
            Text("Select a profile from the sidebar to view its rules.")
        }
    }
}

// MARK: - Sidebar View

struct SidebarView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @Binding var destination: NavigationDestination?
    @State private var showAddProfile = false

    var selectedProfileID: Int64? {
        if case .profile(let id) = destination { return id }
        return nil
    }

    var body: some View {
        List(selection: Binding(
            get: { selectedProfileID },
            set: { newID in
                if let id = newID { destination = .profile(id) }
            }
        )) {
            Section("PROFILES") {
                ForEach(vm.profiles) { profile in
                    ProfileRowView(profile: profile, isSelected: selectedProfileID == profile.id)
                        .tag(profile.id!)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                VStack(spacing: 8) {
                    Button {
                        destination = .lists
                    } label: {
                        Label("Lists", systemImage: "square.stack.3d.up.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(destination == .lists ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Button {
                            destination = .settings
                        } label: {
                            Label("Settings", systemImage: "gearshape.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(destination == .settings ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            showAddProfile = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("New Profile")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
        .sheet(isPresented: $showAddProfile) {
            ProfileEditorSheet(profile: nil)
        }
    }
}

// MARK: - Profile Rules Detail (tabbed wrapper)

struct ProfileRulesDetailView: View {
    let profile: BlockProfile
    @Binding var selectedTab: ContentView.RuleTab

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar at top
            HStack(spacing: 0) {
                ForEach(ContentView.RuleTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                            .background(
                                selectedTab == tab
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                            .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    if tab != ContentView.RuleTab.allCases.last {
                        Divider().frame(height: 20)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .background(.bar)
            Divider()

            // Tab content
            switch selectedTab {
            case .apps: AppRulesTab(profileID: profile.id!)
            case .cli:  CLIRulesTab(profileID: profile.id!)
            }
        }
        .navigationTitle(profile.name)
        .navigationSubtitle("Rules")
    }
}
