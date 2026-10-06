import SwiftUI

/// Activity, not speaker diarization. All sources use the same meeting timeline.
/// HIG Accessibility: seeking supports pointer, keyboard, and adjustable actions.
/// https://developer.apple.com/design/human-interface-guidelines/accessibility
struct WaveformTimeline: View {
    let waveforms: [AudioWaveform]
    let duration: Double
    let time: Double
    let progress: PlaybackProgress
    let animate: Bool
    var label = "Playback position"
    var dimmed = false
    var isLoading = false
    let seek: (Double) -> Void
    let scrub: (Double?) -> Void
    @ViewState private var isScrubbing = false
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PlaybackWaveformSurface(
                    waveforms: waveforms, duration: duration, progress: progress, time: time, animate: animate
                )
                .opacity(dimmed ? 0.55 : 1)
                .allowsHitTesting(false)
                // A SwiftUI sibling owns pointer input. Gestures attached directly
                // to NSViewRepresentable can be bypassed by native hit testing.
                Rectangle().fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // Pointer seeking never requests keyboard focus.
                                isScrubbing = true
                                scrub(min(duration, max(0, value.location.x / max(1, geometry.size.width) * duration)))
                            }
                            .onEnded { value in
                                seek(min(duration, max(0, value.location.x / max(1, geometry.size.width) * duration)))
                                scrub(nil)
                                isScrubbing = false
                            })
            }
        }
        .frame(height: 24)
        .background {
            // Panning adjusts playback without moving keyboard focus.
            WaveformScrollInput(time: time, duration: duration, seek: seek, scrub: scrub)
        }
        .modifier(ActionHover(pressed: isScrubbing, cornerRadius: 4))
        .overlay(alignment: .center) {
            if waveforms.isEmpty {
                Text(isLoading ? "Loading waveform…" : "Waveform unavailable").font(.caption2).foregroundStyle(
                    .secondary
                ).allowsHitTesting(false)
            }
        }
        // Accept keyboard navigation without SwiftUI's click-to-edit focus.
        .focusable(interactions: .activate).focused($focused)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(focused ? Color.accentColor : .clear, lineWidth: 2))
        .onKeyPress(.leftArrow) {
            seek(max(0, time - 5))
            return .handled
        }
        .onKeyPress(.rightArrow) {
            seek(min(duration, time + 5))
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(playbackTime(time)) of \(playbackTime(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(min(duration, time + 5))
            case .decrement: seek(max(0, time - 5))
            @unknown default: break
            }
        }
        .help("Click, drag, or scroll horizontally to seek. Arrow keys move five seconds.")
        .onDisappear { if isScrubbing { scrub(nil) } }
    }
}

/// The only observer of frequent progress updates. Controls outside this view
/// retain their identity while its playhead and timestamps advance.
struct PlaybackPosition: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var progress: PlaybackProgress
    let waveforms: [AudioWaveform]
    let duration: Double
    var label = "Playback position"
    var dimmed = false
    var showsTimes = false
    var isLoading = false
    let seek: (Double) -> Void

    var body: some View {
        let animate = progress.isPlaying && progress.scrubTime == nil && !reduceMotion && scenePhase == .active
        WaveformTimeline(
            waveforms: waveforms, duration: duration, time: progress.displayedTime, progress: progress,
            animate: animate,
            label: label, dimmed: dimmed, isLoading: isLoading, seek: seek, scrub: progress.scrub
        )
        .overlay(alignment: .bottom) {
            if showsTimes {
                HStack {
                    Text(playbackTime(progress.displayedTime))
                    Spacer()
                    Text("−" + playbackTime(max(0, duration - progress.displayedTime)))
                }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .offset(y: 18)
            }
        }
    }
}
