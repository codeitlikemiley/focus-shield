import SwiftUI

// MARK: - Profile Sidebar

struct ProfileSidebarView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @Binding var selectedProfileID: Int64?
    @State private var showAddProfile = false

    var body: some View {
        List(selection: $selectedProfileID) {
            Section("PROFILES") {
                ForEach(vm.profiles) { profile in
                    ProfileRowView(profile: profile)
                        .tag(profile.id!)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape.fill")
                            .font(.system(size: 13))
                    }
                    Spacer()
                    Button {
                        showAddProfile = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("New Profile")
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

// MARK: - Profile Row

struct ProfileRowView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let profile: BlockProfile

    var isActive: Bool { vm.settings.activeProfileID == profile.id }

    var color: Color {
        Color(hex: profile.color) ?? .accentColor
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: profile.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    modeChip(profile.globalMode)
                    if isActive {
                        activeChip
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func modeChip(_ mode: FilterMode) -> some View {
        Text(mode.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(mode == .whitelist ? Color.green : Color.red)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(mode == .whitelist ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
            )
    }

    private var activeChip: some View {
        Text("ACTIVE")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
    }
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8 ) & 0xFF) / 255,
            blue:  Double( value        & 0xFF) / 255
        )
    }
}
