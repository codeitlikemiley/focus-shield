import SwiftUI

// MARK: - Profile Detail (middle column)

struct ProfileDetailView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profile: BlockProfile
    @Binding var selectedTab: ContentView.RuleTab
    let openLists: () -> Void
    @State private var showEditor = false

    var isSelectedProfile: Bool { vm.settings.activeProfileID == profile.id }
    var isShieldEnabled: Bool { vm.settings.masterEnabled }
    var isActive: Bool { isSelectedProfile && isShieldEnabled }
    var color: Color { Color(hex: profile.color) ?? .accentColor }
    var siteListCount: Int { vm.siteLists.count }

    /// Load fresh rules for this profile (not just the active one).
    var profileWithRules: ProfileWithRules? {
        _ = vm.dataVersion
        guard let id = profile.id else { return nil }
        return vm.fetchProfileWithRules(id: id)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                profileHeader.padding()
                Divider()
                statsGrid.padding()
            }
        }
        .navigationTitle(profile.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) {
            ProfileEditorSheet(profile: profile)
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: profile.icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(spacing: 4) {
                Text(profile.name)
                    .font(.title2.weight(.bold))
                Text("Per-app and per-CLI traffic rules")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if isActive {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Active Profile")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                }
                Button("Deactivate", role: .destructive) {
                    vm.deactivateProfile()
                }
                .controlSize(.small)
                if vm.networkFilterState == .awaitingApproval || vm.networkFilterState == .rebootRequired {
                    Text(vm.networkFilterState.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            } else if isSelectedProfile {
                HStack(spacing: 8) {
                    Image(systemName: "power.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Shield Off")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Button("Turn Shield On") {
                    vm.masterEnabled = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(color)
            } else {
                Button("Activate Profile") {
                    if let id = profile.id { vm.activateProfile(id) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(color)
            }
        }
    }

    private var statsGrid: some View {
        let rules = profileWithRules
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatCard(
                title: "Templates",
                value: "\(siteListCount)",
                systemImage: "square.stack.3d.up.fill",
                color: .blue
            ) { openLists() }

            StatCard(
                title: "App Rules",
                value: "\(rules?.totalAppRulesCount ?? 0)",
                systemImage: "app.badge",
                color: .orange
            ) { selectedTab = .apps }

            StatCard(
                title: "CLI Rules",
                value: "\(rules?.totalCLIRulesCount ?? 0)",
                systemImage: "terminal.fill",
                color: .purple
            ) { selectedTab = .cli }

            StatCard(
                title: "Attached Sites",
                value: "\(rules?.totalEnabledDomains ?? 0)",
                systemImage: "globe",
                color: .red
            ) { selectedTab = .apps }
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: systemImage)
                        .foregroundStyle(color)
                        .font(.system(size: 16))
                    Spacer()
                    Text(value)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
