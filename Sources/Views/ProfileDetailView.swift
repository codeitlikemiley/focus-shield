import SwiftUI

// MARK: - Profile Detail (middle column)

struct ProfileDetailView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profile: BlockProfile
    @Binding var selectedTab: ContentView.RuleTab
    @State private var showEditor = false

    var isActive: Bool { vm.settings.activeProfileID == profile.id }

    var color: Color { Color(hex: profile.color) ?? .accentColor }

    var profileWithRules: ProfileWithRules? {
        vm.activeProfile?.profile.id == profile.id ? vm.activeProfile : nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header card
                profileHeader
                    .padding()

                Divider()

                // Stats grid
                statsGrid
                    .padding()

                Divider()

                // Quick-jump buttons
                quickJumpSection
                    .padding()
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

                modeLabel
            }

            // Activate / Deactivate
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

    private var modeLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: profile.globalMode == .whitelist ? "checkmark.shield.fill" : "xmark.shield.fill")
                .foregroundStyle(profile.globalMode == .whitelist ? .green : .red)
            Text("\(profile.globalMode.label) Mode")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var statsGrid: some View {
        let rules = profileWithRules
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatCard(
                title: "Websites",
                value: "\(rules?.globalDomainRules.filter { $0.isEnabled }.count ?? 0)",
                systemImage: "globe",
                color: .blue
            ) { selectedTab = .websites }

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
                title: "Blocked Apps",
                value: "\(rules?.blockedAppBundleIDs.count ?? 0)",
                systemImage: "stop.circle.fill",
                color: .red
            ) { selectedTab = .apps }
        }
    }

    private var quickJumpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUICK ACCESS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(ContentView.RuleTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
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
