import SwiftUI

/// Production controls with local synthetic state. No capture or provider work.
struct PreviewComponents: View {
    @ViewState private var selectedTab = 0
    @ViewState private var expanded = true
    @ViewState private var sourceEnabled = true
    @ViewState private var playing = false
    @ViewState private var controlsEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                Text("Component Preview").font(.title2.weight(.semibold))
                Text("Inspect pointer, keyboard, and appearance states using production controls.")
                    .foregroundStyle(.secondary)
                Toggle("Enable Controls", isOn: $controlsEnabled)
                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    MeetingContentTabs(selection: $selectedTab)
                    HStack(spacing: AppTheme.contentSpacing) {
                        Button {
                            playing.toggle()
                        } label: {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(MeetingPlaybackButtonStyle())
                        .accessibilityLabel(playing ? "Pause" : "Play")
                        .help(playing ? "Pause" : "Play")
                        Button("Action") {}.buttonStyle(.bordered)
                        Button("Primary Action") {}.buttonStyle(.borderedProminent)
                        Button("Remove", role: .destructive) {}.buttonStyle(.bordered)
                    }
                    DisclosureGroup("Recording Options", isExpanded: $expanded) {
                        RecordingSourceRow(
                            name: "Microphone", subtitle: "Record your voice and nearby sounds.",
                            symbol: "mic.fill", isOn: $sourceEnabled)
                    }
                    .disclosureGroupStyle(AppDisclosureStyle())
                    VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
                        AppInlineMessage(text: "Choose an audio source to continue.")
                        AppInlineMessage(
                            text: "The selected source is unavailable.", systemImage: "exclamationmark.triangle",
                            tint: .orange)
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Preparing audio…")
                        }
                    }
                    .padding(AppTheme.contentSpacing)
                    .modifier(AppContentSurface())
                }
                .disabled(!controlsEnabled)
            }
            .padding(AppTheme.sectionSpacing)
        }
        .frame(width: 620, height: 500)
    }
}
