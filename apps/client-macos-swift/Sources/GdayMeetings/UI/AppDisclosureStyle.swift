import SwiftUI

/// HIG Disclosure controls: provide a clear, accessible way to reveal related details.
/// One native button owns the entire header so its label and empty space activate
/// the same action as its chevron, with standard keyboard and disabled behavior.
/// https://developer.apple.com/design/human-interface-guidelines/disclosure-controls
struct AppDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(ActionButtonStyle())
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
