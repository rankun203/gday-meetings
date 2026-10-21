import SwiftUI

/// Shared excerpt transport keeps a compact glyph inside the standard playback hit target.
struct VoiceSamplePlaybackControl: View {
    let playing: Bool
    let available: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless).modifier(ActionHover())
        .disabled(!available)
        .help(available ? (playing ? "Pause sample" : "Play sample") : "The recording excerpt is unavailable.")
        .accessibilityLabel(playing ? "Pause sample" : "Play sample")
    }
}
