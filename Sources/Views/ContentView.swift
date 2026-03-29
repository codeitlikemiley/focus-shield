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

    var body: some View {
        NavigationSplitView {
            SidebarView(destination: $destination)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            switch destination {
            case .profile(let id):
                if let profile = vm.profiles.first(where: { $0.id == id }) {
                    ProfileRulesDetailView(
                        profile: profile,
                        selectedTab: $selectedTab,
                        openLists: { destination = .lists }
                    )
                    .id(id)
                } else {
                    noSelection
                }
            case .lists:
                GlobalRulesTab()
                    .navigationTitle("Lists")
            case .settings:
                SettingsView()
            case nil:
                noSelection
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

    private var noSelection: some View {
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

    var isShieldOn: Bool { vm.settings.masterEnabled }

    var body: some View {
        VStack(spacing: 0) {
            // ── Shield on/off banner ─────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: isShieldOn ? "shield.fill" : "shield.slash.fill")
                    .foregroundStyle(isShieldOn ? .green : .secondary)
                    .font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(isShieldOn ? "Shield Active" : "Shield Off")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isShieldOn ? .primary : .secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isShieldOn },
                    set: { vm.masterEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(.green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // ── Profiles list (scrollable) ───────────────────────────────
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
        }
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

// MARK: - Profile Rules Detail (full-width, tabbed with inline profile header)

struct ProfileRulesDetailView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profile: BlockProfile
    @Binding var selectedTab: ContentView.RuleTab
    let openLists: () -> Void

    @State private var showEditor = false

    var isActive: Bool {
        vm.settings.activeProfileID == profile.id && vm.settings.masterEnabled
    }
    var color: Color { Color(hex: profile.color) ?? .accentColor }

    var profileWithRules: ProfileWithRules? {
        _ = vm.dataVersion
        guard let id = profile.id else { return nil }
        return vm.fetchProfileWithRules(id: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Tab bar ───────────────────────────────────────────────────
            HStack(spacing: 0) {
                ForEach(ContentView.RuleTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                            .padding(.vertical, 10)
                            .padding(.horizontal, 18)
                            .background(
                                selectedTab == tab
                                    ? color.opacity(0.12)
                                    : Color.clear
                            )
                            .foregroundStyle(selectedTab == tab ? color : .secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 80, minHeight: 40)
                    .contentShape(Rectangle())

                    if tab != ContentView.RuleTab.allCases.last {
                        Divider().frame(height: 20)
                    }
                }
                Spacer()
            }
            .background(.bar)
            Divider()

            // ── Tab content ───────────────────────────────────────────────
            switch selectedTab {
            case .apps: AppRulesTab(profileID: profile.id!)
            case .cli:  CLIRulesTab(profileID: profile.id!)
            }
        }
        .navigationTitle(profile.name)
        .toolbar {

            // ── Trailing: stat chips + activate/deactivate + edit ──────
            ToolbarItemGroup(placement: .primaryAction) {

                if isActive {
                    Button("Deactivate") { vm.deactivateProfile() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                } else {
                    Button("Activate") {
                        if let id = profile.id { vm.activateProfile(id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(color)
                }

                Button("Edit") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) {
            ProfileEditorSheet(profile: profile)
        }
    }



    @ViewBuilder
    private func statChip(icon: String, value: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(value)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}
