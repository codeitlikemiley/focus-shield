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
                    ProfileRowView(profile: profile, isSelected: selectedProfileID == profile.id)
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
    let isSelected: Bool

    @State private var showEditor = false
    @State private var showDeleteConfirm = false

    var isActive: Bool { vm.settings.activeProfileID == profile.id && vm.settings.masterEnabled }

    var color: Color {
        Color(hex: profile.color) ?? .accentColor
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? .white.opacity(0.2) : color.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: profile.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)
                if isActive {
                    activeChip
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            // Edit
            Button {
                showEditor = true
            } label: {
                Label("Edit Profile", systemImage: "pencil")
            }

            Divider()

            // Activate / Deactivate
            if isActive {
                Button {
                    vm.deactivateProfile()
                } label: {
                    Label("Deactivate", systemImage: "stop.circle")
                }
            } else if vm.settings.activeProfileID == profile.id {
                // Active profile but master shield is off
                Button {
                    vm.masterEnabled = true
                } label: {
                    Label("Turn On Shield", systemImage: "shield.fill")
                }
            } else {
                Button {
                    if let id = profile.id { vm.activateProfile(id) }
                } label: {
                    Label("Activate", systemImage: "checkmark.circle")
                }
            }

            Divider()

            // Delete
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete Profile", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showEditor) {
            ProfileEditorSheet(profile: profile)
        }
        .alert("Delete \"\(profile.name)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let id = profile.id { vm.deleteProfile(id: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the profile and all its rules.")
        }
    }

    private var activeChip: some View {
        Text("ACTIVE")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(isSelected ? Color.accentColor : .white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(isSelected ? .white : Color.accentColor))
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
