import SwiftUI

/// Shared app-specific metrics. Native controls keep their system sizing.
enum AppTheme {
    static let compactSpacing: CGFloat = 8
    static let contentSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 24
    static let contentInset: CGFloat = 20
    static let chromeInset: CGFloat = 12
    static let cornerRadius: CGFloat = 16
    static let transportTarget: CGFloat = 44
    static let readingBackground = Color(nsColor: .textBackgroundColor)
}

/// A stationary heading separates list scope and actions from selected-item details.
struct WorkspaceListHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }.layoutPriority(1)
            Spacer(minLength: 4)
            actions().labelStyle(.iconOnly).controlSize(.regular)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.readingBackground)
    }
}

/// Stationary navigation and transport chrome; never apply to scrolling rows.
struct AppChromeSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay {
                    if contrast == .increased {
                        shape.stroke(.primary.opacity(0.5), lineWidth: 1).allowsHitTesting(false)
                    }
                }
        }
        else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        }
        else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// Quiet grouping for related information, without a second glass layer.
struct AppContentSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(AppTheme.readingBackground, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                        .stroke(.secondary, lineWidth: 1).allowsHitTesting(false)
                }
            }
    }
}
