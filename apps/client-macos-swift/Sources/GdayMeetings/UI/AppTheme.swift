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
