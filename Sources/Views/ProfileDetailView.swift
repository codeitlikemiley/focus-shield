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
        let appRuleCount = rules?.totalAppRulesCount ?? 0
        let cliRuleCount = rules?.totalCLIRulesCount ?? 0
        let attachedSiteCount = rules?.totalEnabledDomains ?? 0
        let hasNoProfileData = appRuleCount == 0 && cliRuleCount == 0 && attachedSiteCount == 0

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            if hasNoProfileData {
                EmptyProfileCard(
                    templateCount: siteListCount,
                    openLists: openLists,
                    openApps: { selectedTab = .apps },
                    openCLI: { selectedTab = .cli }
                )
                .gridCellColumns(2)
            }

            StatCard(
                title: "Templates",
                value: "\(siteListCount)",
                systemImage: "square.stack.3d.up.fill",
                color: .blue
            ) { openLists() }

            StatCard(
                title: "App Rules",
                value: "\(appRuleCount)",
                systemImage: "app.badge",
                color: .orange
            ) { selectedTab = .apps }

            StatCard(
                title: "CLI Rules",
                value: "\(cliRuleCount)",
                systemImage: "terminal.fill",
                color: .purple
            ) { selectedTab = .cli }

            StatCard(
                title: "Attached Sites",
                value: "\(attachedSiteCount)",
                systemImage: "globe",
                color: .red
            ) { selectedTab = .apps }
        }
    }
}

private struct EmptyProfileCard: View {
    let templateCount: Int
    let openLists: () -> Void
    let openApps: () -> Void
    let openCLI: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No data yet.", systemImage: "sparkles.rectangle.stack")
                .font(.system(size: 14, weight: .semibold))

            Text("This default profile starts empty. Add an app rule, add a CLI tool, or import one of the \(templateCount) built-in site lists to get started.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Open Apps", action: openApps)
                    .buttonStyle(.borderedProminent)
                Button("Open CLI", action: openCLI)
                    .buttonStyle(.bordered)
                Button("Browse Lists", action: openLists)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
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
