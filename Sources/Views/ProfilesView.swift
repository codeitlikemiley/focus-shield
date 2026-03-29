import SwiftUI

// MARK: - Profile Editor Sheet (create or edit)

struct ProfileEditorSheet: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    let profile: BlockProfile?   // nil = create new

    @State private var name: String = ""
    @State private var icon: String = "shield.fill"
    @State private var color: Color = .blue

    private var isNew: Bool { profile == nil }

    private let icons = [
        "shield.fill", "briefcase.fill", "book.fill", "cup.and.saucer.fill",
        "moon.fill", "house.fill", "graduationcap.fill", "dumbbell.fill",
        "gamecontroller.fill", "heart.fill", "star.fill", "lock.fill",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Profile name", text: $name)
                }

                Section("Appearance") {
                    // Icon picker
                    Text("Icon").font(.system(size: 13)).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 6), spacing: 8) {
                        ForEach(icons, id: \.self) { iconName in
                            Button {
                                icon = iconName
                            } label: {
                                Image(systemName: iconName)
                                    .font(.system(size: 18))
                                    .frame(width: 40, height: 40)
                                    .background(icon == iconName ? color.opacity(0.2) : Color.secondary.opacity(0.1),
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(icon == iconName ? color : .secondary)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(icon == iconName ? color : .clear, lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)

                    ColorPicker("Accent Color", selection: $color, supportsOpacity: false)
                }
                Section("Rules") {
                    Text("Website filtering is configured on each app or CLI rule. Reusable site lists live in the Lists section in the sidebar and can be imported into any rule as a copy.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Profile" : "Edit Profile")
            .onAppear {
                if let p = profile {
                    name = p.name
                    icon = p.icon
                    color = Color(hex: p.color) ?? .blue
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") {
                        saveProfile()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 500)
        .onDisappear {
            // Close the system color picker if it was opened via ColorPicker
            NSColorPanel.shared.close()
        }
    }

    private func saveProfile() {
        let hexColor = color.toHex() ?? "#007AFF"
        if var existing = profile {
            existing.name = name.trimmingCharacters(in: .whitespaces)
            existing.icon = icon
            existing.color = hexColor
            vm.updateProfile(&existing)
        } else {
            var newProfile = BlockProfile(
                name: name.trimmingCharacters(in: .whitespaces),
                icon: icon,
                color: hexColor,
                sortOrder: vm.profiles.count
            )
            vm.createProfile(&newProfile)
        }
    }
}

// MARK: - Legacy ProfilesView wrapper (kept for navigation compatibility)

struct ProfilesView: View {
    var body: some View {
        ProfileSidebarView(selectedProfileID: .constant(nil))
    }
}

// MARK: - Color to Hex

extension Color {
    func toHex() -> String? {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components,
              components.count >= 3 else { return nil }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
