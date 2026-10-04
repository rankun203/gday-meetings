import AppKit
import SwiftUI

/// HIG Playing Audio: familiar transport controls stay available while people
/// navigate and work. The app owns playback; this view only presents its state.
/// https://developer.apple.com/design/human-interface-guidelines/playing-audio
struct MeetingPlayerBar: View {
    @EnvironmentObject private var playback: MeetingPlayback
    @EnvironmentObject private var store: MeetingStore
    let showMeeting: (UUID) -> Void
    @ViewState private var tracksExpanded = false
    @ViewState private var compactOptions = false
    @ViewState private var tracksSpaceExpanded = false
    @ViewState private var tracksVisible = false
    @ViewState private var trackWaveformsMounted = false
    @ViewState private var tracksTransition = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Group {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(playback.trackNames.enumerated()), id: \.offset) { index, name in
                            HStack(spacing: 14) {
                                HStack {
                                    Text(name).font(.caption).lineLimit(1)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            if NSEvent.modifierFlags.contains(.command) { revealTrack(index) }
                                        }
                                        .help("Command-click to reveal this audio file in Finder.")
                                        .accessibilityAction(named: "Reveal in Finder") { revealTrack(index) }
                                        .contextMenu { Button("Reveal in Finder") { revealTrack(index) } }
                                    Spacer()
                                    Button {
                                        playback.toggleMute(index)
                                    } label: {
                                        Image(
                                            systemName: playback.mutedTracks.contains(index)
                                                ? "speaker.slash" : "speaker.wave.2"
                                        )
                                        .frame(width: 44, height: 44)
                                    }.buttonStyle(ActionButtonStyle())
                                        .accessibilityLabel(
                                            "\(playback.mutedTracks.contains(index) ? "Unmute" : "Mute") \(name)"
                                        )
                                        .help("\(playback.mutedTracks.contains(index) ? "Unmute" : "Mute") \(name)")
                                        .disabled(playback.isLoading || playback.isPlaybackBlocked)
                                }.frame(width: 160)
                                Group {
                                    if trackWaveformsMounted {
                                        PlaybackPosition(
                                            progress: playback.progress,
                                            waveforms: playback.waveforms.indices.contains(index)
                                                ? [playback.waveforms[index]].compactMap { $0 } : [],
                                            duration: playback.duration,
                                            label: "\(name) playback position",
                                            dimmed: playback.mutedTracks.contains(index),
                                            isLoading: playback.isLoadingWaveforms, seek: playback.seek
                                        )
                                        .disabled(
                                            playback.isLoading || playback.duration <= 0 || playback.isPlaybackBlocked)
                                    }
                                    else {
                                        Color.clear.frame(height: 24).accessibilityHidden(true)
                                    }
                                }.transition(.identity)
                            }
                        }
                    }.padding(.horizontal, AppTheme.contentInset).padding(.top, AppTheme.contentSpacing)
                }.frame(height: tracksHeight)
                    .scrollClipDisabled()
                    .opacity(tracksVisible ? 1 : 0)
                    .offset(y: tracksVisible || reduceMotion ? 0 : 8)
                    .allowsHitTesting(tracksVisible)
                    .accessibilityHidden(!tracksVisible)
            }
            .frame(height: tracksSpaceExpanded ? tracksHeight : 0, alignment: .top)
            // Focus rings extend beyond the row and scroll viewport. Reserve
            // drawing overflow only, without changing layout or hit targets.
            .clipShape(Rectangle().inset(by: tracksVisible ? -6 : 0))
            HStack(spacing: 14) {
                Button {
                    guard let id = playback.meetingID else { return }
                    if NSEvent.modifierFlags.contains(.command) {
                        revealMeeting()
                    }
                    else {
                        showMeeting(id)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .font(.title2).foregroundStyle(.tint)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(playback.title).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(
                                playback.isLoading
                                    ? "Preparing audio…"
                                    : playback.isPlaying ? "Now Playing" : playback.hasEnded ? "Finished" : "Paused"
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(ActionButtonStyle())
                .frame(minWidth: 80, idealWidth: 180, maxWidth: 220)
                .help("Show the meeting. Command-click to reveal its folder in Finder.")
                .accessibilityAction(named: "Reveal in Finder") { revealMeeting() }
                .accessibilityLabel("Show meeting: \(playback.title)")

                HStack(spacing: 9) {
                    transportButton("Back 15 Seconds", symbol: "gobackward.15") { playback.skip(by: -15) }
                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Group {
                            if playback.isLoading {
                                ProgressView().controlSize(.small)
                            }
                            else {
                                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                            }
                        }.frame(width: 44, height: 44)
                    }
                    .buttonStyle(ActionButtonStyle())
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                    .help(playback.isPlaying ? "Pause playback" : "Play recording")
                    .disabled(playback.isPlaybackBlocked || playback.isLoading)
                    transportButton("Forward 15 Seconds", symbol: "goforward.15") { playback.skip(by: 15) }
                }

                PlaybackPosition(
                    progress: playback.progress, waveforms: audibleWaveforms,
                    duration: playback.duration, dimmed: playback.mutedTracks.count == playback.trackNames.count,
                    showsTimes: true, isLoading: playback.isLoadingWaveforms, seek: playback.seek
                )
                .disabled(playback.isLoading || playback.duration <= 0 || playback.isPlaybackBlocked)
                .frame(minWidth: 130, maxWidth: .infinity)

                if !compactOptions {
                    playerOptions.fixedSize()
                }
                else {
                    Menu {
                        Button(tracksExpanded ? "Hide Audio Tracks" : "Show Audio Tracks", action: toggleTracks)
                        speedPicker
                        trackPicker
                        Divider()
                        Button("Close Player", systemImage: "xmark") { playback.clear() }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: AppTheme.transportTarget, height: AppTheme.transportTarget)
                    }
                    .menuStyle(.button).buttonStyle(ActionButtonStyle())
                    .accessibilityLabel("Playback Options")
                    .help("Playback speed, audio tracks, and player options")
                }

            }
            .padding(.horizontal, AppTheme.contentInset).padding(.vertical, AppTheme.contentSpacing)
            if let error = playback.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
        }
        .modifier(AppChromeSurface(shape: RoundedRectangle(cornerRadius: AppTheme.cornerRadius)))
        .padding(AppTheme.chromeInset)
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width < 960
        } action: {
            compactOptions = $0
        }
        .onChange(of: playback.meetingID) { _, _ in resetTracks() }
        .onDisappear { resetTracks() }
    }

    private var playerOptions: some View {
        HStack(spacing: 4) {
            Button(action: toggleTracks) {
                Image(systemName: tracksExpanded ? "chevron.down" : "chevron.up")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(ActionButtonStyle())
            .accessibilityLabel(tracksExpanded ? "Hide audio tracks" : "Show audio tracks")
            .help(tracksExpanded ? "Hide audio tracks" : "Show audio tracks")
            Menu {
                speedPicker
            } label: {
                HStack(spacing: 4) {
                    Text("\(playback.playbackRate.formatted())×").monospacedDigit()
                    Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
                }.padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(ActionButtonStyle()).fixedSize()
            .accessibilityLabel("Playback speed")
            .help("Playback speed")

            Menu {
                trackPicker
                Divider()
                Button("Close Player", systemImage: "xmark") { playback.clear() }
            } label: {
                HStack(spacing: 4) {
                    Label(selectedTrackName, systemImage: "slider.horizontal.3").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
                }.padding(.horizontal, 12).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(ActionButtonStyle()).frame(maxWidth: 140)
            .accessibilityLabel("Audio track and player options")
            .accessibilityValue(selectedTrackName)
            .help("Choose microphone, system audio, or all tracks")
        }
    }

    private var speedPicker: some View {
        Picker(
            "Playback Speed",
            selection: Binding(get: { playback.playbackRate }, set: { playback.setRate($0) })
        ) {
            ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                Text("\(rate.formatted())×").tag(rate)
            }
        }
    }

    private var trackPicker: some View {
        Picker(
            "Audio Track",
            selection: Binding(get: { playback.selectedTrack }, set: { playback.selectTrack($0) })
        ) {
            Text("All Tracks").tag(-1)
            ForEach(Array(playback.trackNames.enumerated()), id: \.offset) { index, name in
                Text(name).tag(index)
            }
        }
    }

    private func revealMeeting() {
        guard let id = playback.meetingID else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: id)])
    }

    private func revealTrack(_ index: Int) {
        guard let url = playback.audioURL(forTrack: index) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var tracksHeight: CGFloat {
        min(200, CGFloat(playback.trackNames.count) * 54 + 12)
    }

    private func resetTracks() {
        tracksTransition = UUID()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            tracksExpanded = false
            tracksSpaceExpanded = false
            tracksVisible = false
            trackWaveformsMounted = false
        }
    }

    private func toggleTracks() {
        let transition = UUID()
        tracksTransition = transition
        tracksExpanded.toggle()
        if reduceMotion {
            tracksSpaceExpanded = tracksExpanded
            tracksVisible = tracksExpanded
            trackWaveformsMounted = tracksExpanded
            return
        }
        if tracksExpanded {
            // Preserve viewport and row geometry while releasing hidden waveform
            // observers and native display links between openings.
            trackWaveformsMounted = true
            // Reveal only after the full-size viewport has made room for the rows.
            withAnimation(.easeInOut(duration: 0.25), completionCriteria: .removed) {
                tracksSpaceExpanded = true
            } completion: {
                guard tracksTransition == transition, tracksExpanded else { return }
                withAnimation(.easeInOut(duration: 0.18)) { tracksVisible = true }
            }
        }
        else {
            // Reverse the sequence, keeping row geometry stable while it fades.
            withAnimation(.easeInOut(duration: 0.18), completionCriteria: .removed) {
                tracksVisible = false
            } completion: {
                guard tracksTransition == transition, !tracksExpanded else { return }
                withAnimation(.easeInOut(duration: 0.25), completionCriteria: .removed) {
                    tracksSpaceExpanded = false
                } completion: {
                    guard tracksTransition == transition, !tracksExpanded else { return }
                    trackWaveformsMounted = false
                }
            }
        }
    }

    private var audibleWaveforms: [AudioWaveform] {
        if playback.mutedTracks.count == playback.trackNames.count { return playback.waveforms.compactMap { $0 } }
        return playback.waveforms.enumerated().compactMap {
            playback.mutedTracks.contains($0.offset) ? nil : $0.element
        }
    }

    private var selectedTrackName: String {
        if playback.mutedTracks.count == playback.trackNames.count { return "All Muted" }
        if playback.selectedTrack < 0 && !playback.mutedTracks.isEmpty { return "Custom Mix" }
        return playback.trackNames.indices.contains(playback.selectedTrack)
            ? playback.trackNames[playback.selectedTrack] : "All Tracks"
    }

    private func transportButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3).frame(width: 44, height: 44) }
            .buttonStyle(ActionButtonStyle()).accessibilityLabel(title).help(title)
            .disabled(playback.isLoading || playback.isPlaybackBlocked || playback.duration <= 0)
    }
}

func playbackTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = Int(max(0, min(seconds, Double(Int.max / 2))))
    if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
    return String(format: "%d:%02d", total / 60, total % 60)
}
