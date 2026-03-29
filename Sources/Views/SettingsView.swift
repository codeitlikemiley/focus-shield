import SwiftUI

struct SettingsView: View {
    @Environment(FocusShieldViewModel.self) private var vm
    @State private var accessibilityGranted = false
    @State private var accessibilityTimer: Timer?
    @State private var themeMode: AppThemeMode = .system
    @State private var newPatternName = ""
    @State private var newPatternRegex = ""
    @State private var payloadValidationError: String?

    var body: some View {
        Form {
            // Accessibility
            Section("Permissions") {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility Access")
                                .font(.system(size: 13, weight: .medium))
                            Text("Updates automatically after macOS confirms the grant.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(accessibilityGranted ? .green : .orange)
                    }
                    Spacer()
                    if !accessibilityGranted {
                        VStack(alignment: .trailing, spacing: 4) {
                            Button("Grant Access") {
                                requestAccessibilityAccess()
                            }
                            .controlSize(.small)
                        }
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
                // Network Extension — interactive with "Open Settings" action
                networkExtensionRow
                enforcementRow(
                    icon: "doc.text.fill",
                    title: "Hosts File",
                    description: "/etc/hosts — blocks DNS resolution system-wide",
                    isActive: vm.masterEnabled && vm.enforcementHealth.helperInstalled
                )
                enforcementRow(
                    icon: "network",
                    title: "PAC Proxy",
                    description: "Browser proxy auto-config — blacklist/whitelist enforcement for browsers",
                    isActive: vm.masterEnabled && vm.enforcementHealth.pacFileHealthy && vm.enforcementHealth.systemProxyEnabled
                )
                enforcementRow(
                    icon: "shield.lefthalf.filled",
                    title: "DNS Proxy",
                    description: "Local DNS proxy for additional resolution blocking",
                    isActive: vm.masterEnabled
                )
                enforcementRow(
                    icon: "terminal.fill",
                    title: "CLI Preflight Guard",
                    description: "Wrapper-based host and payload inspection for configured CLI tools",
                    isActive: vm.settings.payloadProtectionEnabled && vm.payloadPatterns.contains(where: \.isEnabled)
                )
                enforcementRow(
                    icon: "shield.lefthalf.filled",
                    title: "pf Firewall",
                    description: "Global IP blocking for blacklist rules, including TCP and UDP/QUIC",
                    isActive: vm.masterEnabled && !(vm.activeProfile?.cliRules.isEmpty ?? true)
                )
                enforcementRow(
                    icon: "app.badge.fill",
                    title: "App Monitor",
                    description: "Terminates fully-blocked GUI apps on launch",
                    isActive: vm.masterEnabled && !(vm.activeProfile?.blockedAppBundleIDs.isEmpty ?? true)
                )

                // Health warnings banner
                if vm.masterEnabled && !vm.enforcementHealth.isHealthy {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text("Enforcement Warnings")
                                .font(.system(size: 13, weight: .semibold))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        ForEach(vm.enforcementHealth.warnings, id: \.self) { warning in
                            Text("• \(warning)")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Payload Protection") {
                Toggle(
                    "Enable CLI payload detection",
                    isOn: Binding(
                        get: { vm.settings.payloadProtectionEnabled },
                        set: { vm.setPayloadProtectionEnabled($0) }
                    )
                )

                Text("Configured CLI wrappers inspect command arguments, piped stdin, and referenced files for sensitive patterns before the request is sent. Safari and transport-aware app filtering now come from the Network Extension path; deep HTTPS payload interception remains a separate future engine.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("\(vm.payloadPatterns.filter(\.isEnabled).count) active patterns")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                ForEach(vm.payloadPatterns) { pattern in
                    PayloadPatternRow(pattern: pattern)
                }

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Pattern name", text: $newPatternName)
                    TextField("Regex", text: $newPatternRegex, axis: .vertical)
                        .lineLimit(2...4)

                    if let payloadValidationError {
                        Text(payloadValidationError)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }

                    HStack {
                        Spacer()
                        Button("Add Pattern") {
                            if vm.addPayloadPattern(name: newPatternName, regex: newPatternRegex) {
                                newPatternName = ""
                                newPatternRegex = ""
                                payloadValidationError = nil
                            } else {
                                payloadValidationError = "Enter a name and a valid regular expression."
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newPatternName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newPatternRegex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
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
            vm.refreshNetworkFilterStatus(force: true)
        }
        .onAppear {
            themeMode = vm.settings.themeMode
            checkPermissions()
            vm.refreshNetworkFilterStatus(force: true)
            let timer = Timer(timeInterval: 2, repeats: true) { _ in
                checkPermissions()
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            accessibilityTimer = timer
        }
        .onDisappear {
            accessibilityTimer?.invalidate()
            accessibilityTimer = nil
        }
    }

    private func checkPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    private func requestAccessibilityAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: [String: AnyObject] = [key: true as AnyObject]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var networkExtensionRow: some View {
        let state = vm.networkFilterState
        let isActive = state.isActive
        let isError = {
            if case .error = state { return true }
            return false
        }()
        let accentColor: Color = isActive ? .green : (state == .awaitingApproval || state == .rebootRequired ? .orange : .secondary)

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shield.checkered")
                .foregroundStyle(isActive ? .green : accentColor)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Network Extension")
                    .font(.system(size: 13, weight: .medium))

                if isActive {
                    Text(state.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if isDebugBuild && isError {
                    Text("Debug builds cannot activate system extensions unless SIP is disabled and developer mode is on (`systemextensionsctl developer on`).")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("Build a **Release** build to activate the extension normally.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if state == .awaitingApproval {
                    Text("macOS needs your approval to enable the content filter.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Button {
                        openNetworkExtensionSettings()
                    } label: {
                        Label("Allow in System Settings", systemImage: "arrow.up.forward.app.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                } else if isError {
                    Text(state.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(3)
                } else {
                    Text(state.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if !isActive && !isDebugBuild {
                    Button {
                        openNetworkExtensionSettings()
                    } label: {
                        Label("Open Network Extensions Settings", systemImage: "gear")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer()
            Circle()
                .fill(isActive ? Color.green : accentColor.opacity(0.35))
                .frame(width: 8, height: 8)
                .padding(.top, 4)
        }
    }

    private func openNetworkExtensionSettings() {
        // Deep-link to System Settings → General → Login Items & Extensions
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func enforcementRow(
        icon: String,
        title: String,
        description: String,
        isActive: Bool,
        accent: Color = .green,
        inactiveAccent: Color = .secondary
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(isActive ? accent : inactiveAccent)
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
                .fill(isActive ? accent : inactiveAccent.opacity(0.35))
                .frame(width: 8, height: 8)
                .padding(.top, 4)
        }
    }
}

private struct PayloadPatternRow: View {
    @Environment(FocusShieldViewModel.self) private var vm
    let pattern: PayloadPattern

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pattern.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(pattern.regex)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { pattern.isEnabled },
                        set: { enabled in
                            if let id = pattern.id {
                                vm.togglePayloadPattern(id: id, enabled: enabled)
                            }
                        }
                    )
                )
                .labelsHidden()
                .controlSize(.small)
                Button(role: .destructive) {
                    if let id = pattern.id {
                        vm.removePayloadPattern(id: id)
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .disabled(pattern.isRecommended)
            }

            if pattern.isRecommended {
                Text("Recommended")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
