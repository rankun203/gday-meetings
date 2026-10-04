import SwiftUI

/// Capsule navigation for macOS versions whose native segmented picker uses a
/// rectangular bezel. Keep actual Buttons for keyboard and accessibility actions.
/// https://developer.apple.com/design/human-interface-guidelines/segmented-controls
struct MeetingContentTabs: View {
    @Binding var selection: Int
    @FocusState private var focusedTab: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let titles = ["Transcript", "Notes", "Summary", "Data Privacy"]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { index in
                Button {
                    selection = index
                } label: {
                    Text(titles[index])
                        .font(.callout.weight(selection == index ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .contentShape(Capsule())
                }
                .buttonStyle(ActionButtonStyle(cornerRadius: 18))
                .background {
                    if selection == index { Capsule().fill(.quaternary) }
                }
                .focused($focusedTab, equals: index)
                .focusedValue(\.directoryControlFocus, true)
                // Pointer selection should also clear focus left by keyboard navigation.
                // Keep the Button action separate so keyboard activation retains focus.
                .simultaneousGesture(TapGesture().onEnded { focusedTab = nil })
                .accessibilityAddTraits(selection == index ? .isSelected : [])
                .onKeyPress(.leftArrow) { move(from: index, by: -1) }
                .onKeyPress(.rightArrow) { move(from: index, by: 1) }
            }
        }
        .padding(4)
        .modifier(MeetingGlassSurface())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting content")
    }

    private func move(from index: Int, by step: Int) -> KeyPress.Result {
        let next = min(max(index + step, 0), titles.count - 1)
        selection = next
        focusedTab = next
        return .handled
    }
}

/// One glass surface around a group, never a glass layer for every segment.
/// https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
struct MeetingGlassSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(AppChromeSurface(shape: Capsule()))
    }
}
