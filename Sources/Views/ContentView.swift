import SwiftUI

struct ContentView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @State private var selectedProfileID: Int64?
    @State private var selectedTab: RuleTab = .websites

    enum RuleTab: String, CaseIterable {
        case websites = "Websites"
        case apps     = "Apps"
        case cli      = "CLI"

        var systemImage: String {
            switch self {
            case .websites: "globe"
            case .apps:     "app.badge"
            case .cli:      "terminal.fill"
            }
        }
    }

    var selectedProfile: ProfileWithRules? {
        guard let id = selectedProfileID else { return nil }
        return vm.profiles.first(where: { $0.id == id }
        ).flatMap { _ in vm.activeProfile?.profile.id == id ? vm.activeProfile : nil }
        ?? (vm.profiles.first(where: { $0.id == id }).map { p in
            ProfileWithRules(profile: p, globalDomainRules: [], appRules: [])
        })
    }

    var body: some View {
        NavigationSplitView {
            // Column 1: Profile list + Settings
            ProfileSidebarView(selectedProfileID: $selectedProfileID)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            // Column 2: Profile detail (summary + activate/edit)
            if let id = selectedProfileID,
               let profile = vm.profiles.first(where: { $0.id == id }) {
                ProfileDetailView(profile: profile, selectedTab: $selectedTab)
                    .id(id)
            } else {
                ContentUnavailableView {
                    Label("No Profile Selected", systemImage: "shield.slash")
                } description: {
                    Text("Select a profile from the sidebar to view its rules.")
                }
            }
        } detail: {
            // Column 3: Rule tabs (Websites / Apps / CLI)
            if let id = selectedProfileID,
               let profile = vm.profiles.first(where: { $0.id == id }) {
                ProfileRulesDetailView(
                    profile: profile,
                    selectedTab: $selectedTab
                )
                .id("\(id)-\(selectedTab.rawValue)")
            } else {
                ContentUnavailableView {
                    Label("Select a Profile", systemImage: "shield.fill")
                } description: {
                    Text("Choose a profile to manage its blocking rules.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            // Auto-select active profile
            if selectedProfileID == nil {
                selectedProfileID = vm.settings.activeProfileID ?? vm.profiles.first?.id
            }
        }
        .onChange(of: vm.profiles) { _, _ in
            if selectedProfileID == nil {
                selectedProfileID = vm.settings.activeProfileID ?? vm.profiles.first?.id
            }
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
            case .websites: GlobalRulesTab(profileID: profile.id!)
            case .apps:     AppRulesTab(profileID: profile.id!)
            case .cli:      CLIRulesTab(profileID: profile.id!)
            }
        }
        .navigationTitle(profile.name)
        .navigationSubtitle("Rules")
    }
}
