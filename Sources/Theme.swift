import SwiftUI

// MARK: - Theme Color Scheme Extension

extension AppThemeMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Semantic Colors

enum StatusColor {
    static let blocked = Color.red
    static let allowed = Color.green
    static let inactive = Color.secondary
    static let warning = Color.orange
    static let accent = Color.accentColor
}

// MARK: - Status Badge

struct StatusBadge: View {
    let isBlocked: Bool
    let isActive: Bool

    var body: some View {
        if isActive {
            Text(isBlocked ? "Blocked" : "Allowed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isBlocked ? .white : StatusColor.allowed)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isBlocked
                        ? AnyShapeStyle(StatusColor.blocked.opacity(0.85))
                        : AnyShapeStyle(StatusColor.allowed.opacity(0.12)),
                    in: Capsule()
                )
        }
    }
}
