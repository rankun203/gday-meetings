import SwiftUI

/// Native toolbar placement supplies the system's tab-navigation appearance.
/// https://developer.apple.com/videos/play/wwdc2025/310/
struct MeetingContentTabs: View {
    @Binding var selection: Int

    var body: some View {
        Picker("Meeting Content", selection: $selection) {
            Text("Transcript").tag(0)
            Text("Notes").tag(1)
            Text("Summary").tag(2)
        }
        .pickerStyle(.segmented)
        .focusedValue(\.directoryControlFocus, true)
    }
}

/// One glass surface around a group, never a glass layer for every segment.
/// https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
struct MeetingGlassSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.modifier(AppChromeSurface(shape: Capsule()))
    }
}
