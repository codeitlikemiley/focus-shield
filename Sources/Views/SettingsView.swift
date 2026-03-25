import SwiftUI

struct SettingsView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @State private var accessibilityGranted = false
    @State private var themeMode: AppThemeMode = .system

    var body: some View {
        Form {
            // Accessibility
            Section("Permissions") {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility Access")
                                .font(.system(size: 13, weight: .medium))
                            Text("Required to terminate blocked apps.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(accessibilityGranted ? .green : .orange)
                    }
                    Spacer()
                    if !accessibilityGranted {
                        Button("Grant Access") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                        .controlSize(.small)
                    } else {
                        Text("Granted")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.green)
                    }
                }
            }
            .onAppear { checkPermissions() }

            // Appearance
            Section("Appearance") {
                Picker("Theme", selection: $themeMode) {
                    ForEach(AppThemeMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: themeMode) { _, newValue in
                    vm.settings.themeMode = newValue
                    DataStore.shared.saveSettings(vm.settings)
                }
            }

            // Enforcement Status
            Section("Enforcement Layers") {
                enforcementRow(
                    icon: "doc.text.fill",
                    title: "Hosts File",
                    description: "/etc/hosts — blocks DNS resolution system-wide",
                    isActive: vm.masterEnabled
                )
                enforcementRow(
                    icon: "network",
                    title: "PAC Proxy",
                    description: "Browser proxy auto-config — blacklist/whitelist enforcement for browsers",
                    isActive: vm.masterEnabled
                )
                enforcementRow(
                    icon: "shield.lefthalf.filled",
                    title: "DNS Proxy",
                    description: "Local DNS proxy for additional resolution blocking",
                    isActive: vm.masterEnabled
                )
                enforcementRow(
                    icon: "terminal.fill",
                    title: "pf Firewall (CLI)",
                    description: "Process-level blocking for CLI tools — macOS 14.4+",
                    isActive: vm.masterEnabled && !(vm.activeProfile?.cliRules.isEmpty ?? true)
                )
                enforcementRow(
                    icon: "app.badge.fill",
                    title: "App Monitor",
                    description: "Terminates fully-blocked GUI apps on launch",
                    isActive: vm.masterEnabled && !(vm.activeProfile?.blockedAppBundleIDs.isEmpty ?? true)
                )
            }

            // About
            Section("About") {
                LabeledContent("Version", value: "2.0")
                LabeledContent("Database", value: "SQLite (GRDB.swift)")
                LabeledContent("Build", value: "Focus Shield v2 — Granular Blocking Edition")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkPermissions()
        }
        .onAppear {
            themeMode = vm.settings.themeMode
            checkPermissions()
        }
    }

    private func checkPermissions() {
        let options: [String: AnyObject] = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false as AnyObject]
        accessibilityGranted = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private func enforcementRow(icon: String, title: String, description: String, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(isActive ? .green : .secondary)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)
                .padding(.top, 4)
        }
    }
}
