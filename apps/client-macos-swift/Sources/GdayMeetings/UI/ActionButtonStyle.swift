import SwiftUI

/// Keep feedback above the glass so its material cannot wash out the hover tint.
struct MeetingPlaybackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(MeetingGlassSurface())
            .modifier(MeetingPlaybackHover(pressed: configuration.isPressed))
    }
}

private struct MeetingPlaybackHover: ViewModifier {
    let pressed: Bool
    @ViewState private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .contentShape(Circle())
            .overlay {
                Circle()
                    .fill(Color.accentColor.opacity(enabled ? (pressed ? 0.28 : hovered ? 0.16 : 0) : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                if enabled && (hovered || pressed) {
                    Circle()
                        .strokeBorder(
                            Color.accentColor.opacity(contrast == .increased ? 1 : 0.55), lineWidth: 1
                        )
                        .allowsHitTesting(false)
                }
            }
            .onHover {
                hovered = $0
                if enabled { ($0 ? NSCursor.pointingHand : NSCursor.arrow).set() }
            }
    }
}

/// Interaction feedback within the existing label bounds: no padding, frames,
/// scaling, or animation that could alter layout or move adjacent controls.
/// https://developer.apple.com/design/human-interface-guidelines/buttons
struct ActionButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .modifier(ActionHover(pressed: configuration.isPressed, cornerRadius: cornerRadius))
    }
}

/// Also supplements native borderless controls and custom seeking surfaces.
/// Native controls retain their own pressed and keyboard-focus treatment.
struct ActionHover: ViewModifier {
    var pressed = false
    var cornerRadius: CGFloat = 8
    @ViewState private var hovered = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.primary.opacity(enabled ? (pressed ? 0.16 : hovered ? 0.08 : 0) : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                if enabled && (hovered || pressed) && contrast == .increased {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.primary, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovered = $0 }
    }
}
