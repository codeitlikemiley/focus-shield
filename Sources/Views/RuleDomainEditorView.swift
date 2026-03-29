import SwiftUI

struct RuleDomainEditorView: View {
    let currentMode: FilterMode
    let displayedGroups: [DomainGroup]
    let whitelistCount: Int
    let blacklistCount: Int
    let addPlaceholder: String
    let onModeChange: (FilterMode) -> Void
    let onImport: () -> Void
    let onToggleRule: (Int64, Bool) -> Void
    let onToggleAllRules: (Bool) -> Void
    let onDeleteRule: (Int64) -> Void
    let onAddDomain: (String, FilterMode) -> Void

    @State private var newDomain = ""

    var body: some View {
        let allRules = displayedGroups.flatMap(\.rules)
        let enabledRuleCount = allRules.filter(\.isEnabled).count
        let allRulesEnabled = !allRules.isEmpty && enabledRuleCount == allRules.count

        Group {
            HStack {
                Text("Domain Filter")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { currentMode },
                    set: onModeChange
                )) {
                    ForEach(FilterMode.directModes, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            .padding(.leading, 16)

            HStack {
                Text("\(whitelistCount) whitelist · \(blacklistCount) blacklist saved")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if allRules.isEmpty == false {
                    HStack(spacing: 8) {
                        Text("All Sites")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Toggle("", isOn: Binding(
                            get: { allRulesEnabled },
                            set: onToggleAllRules
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        Text("\(enabledRuleCount)/\(allRules.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Switching modes changes which list you edit.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 16)

            HStack {
                Text("Templates")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Import Site List…", action: onImport)
                    .buttonStyle(.plain)
            }
            .padding(.leading, 16)

            if displayedGroups.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: currentMode == .whitelist ? "checkmark.shield" : "hand.raised")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("No domains saved for this \(currentMode.label.lowercased()) yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 32)
            } else {
                let showGroupLabels = displayedGroups.count > 1 || displayedGroups.first?.id != "ungrouped"
                ForEach(displayedGroups) { group in
                    if showGroupLabels {
                        HStack {
                            Text(group.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(group.enabledCount)/\(group.rules.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.leading, 32)
                    }

                    ForEach(group.rules, id: \.id) { domainRule in
                        HStack {
                            Image(systemName: domainRule.domain.hasPrefix("*.") ? "asterisk" : "globe")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text(domainRule.domain)
                                .font(.system(size: 12))
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { domainRule.isEnabled },
                                set: { isEnabled in
                                    guard let id = domainRule.id else { return }
                                    onToggleRule(id, isEnabled)
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            Button(role: .destructive) {
                                guard let id = domainRule.id else { return }
                                onDeleteRule(id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 32)
                    }
                }
            }

            HStack {
                Image(systemName: "plus.circle")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                TextField(addPlaceholder, text: $newDomain)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit(addDomain)
            }
            .padding(.leading, 32)
        }
    }

    private func addDomain() {
        let candidate = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        onAddDomain(candidate, currentMode)
        newDomain = ""
    }
}
