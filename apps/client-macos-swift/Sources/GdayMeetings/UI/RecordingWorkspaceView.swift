import SwiftUI

/// HIG Sheets: keep a modal sheet focused on one scoped task with explicit actions.
/// Merely displaying this form never opens either protected audio resource.
/// https://developer.apple.com/design/human-interface-guidelines/sheets
struct RecordingSetupView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    var onStarted: (UUID) -> Void = { _ in }
    @ViewState private var title = ""
    @ViewState private var language = "en"
    @ViewState private var microphone = true
    @ViewState private var systemAudio = true
    @ViewState private var format = RecordingFormat.opus
    @ViewState private var showOptions = false
    @ViewState private var startupError: String?
    @StateObject private var microphoneDevices = MicrophoneDeviceObserver()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 26).padding(.top, 26).padding(.bottom, 20)
            // HIG Scroll views: make content beyond the available area reachable.
            // Keep the sheet's title and completion actions outside the scrolling
            // region so expanding options or showing an error can't hide them.
            // https://developer.apple.com/design/human-interface-guidelines/scroll-views
            ScrollViewReader { scroll in
                ScrollView {
                    form.padding(.horizontal, 26).padding(.bottom, 22)
                }
                .scrollIndicators(.visible)
                .onChange(of: startupError) { _, error in
                    if error != nil {
                        // Reveal a new failure even when it appears below the fold.
                        scroll.scrollTo("recording-startup-error", anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            actions.padding(.horizontal, 26).padding(.vertical, 16)
        }
        // A bounded ideal height keeps the sheet stable when options expand.
        // The scroll region yields space when the presenting window is shorter.
        .frame(width: 510)
        .frame(minHeight: 400, idealHeight: 540, maxHeight: 620)
        .interactiveDismissDisabled(store.isStartingRecording)
        .onAppear {
            microphone = store.settings.captureMicrophone
            systemAudio = store.settings.captureSystemAudio
            microphoneDevices.start()
            format = store.settings.recordingFormat
            language = store.settings.defaultLanguage
        }
        .onDisappear { microphoneDevices.stop() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 42)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("New Recording").font(.title2.weight(.semibold))
                Text("Choose audio sources to record.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Meeting Title").font(.subheadline.weight(.medium))
                TextField("Untitled Meeting", text: $title)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Meeting Title").disabled(
                        store.isStartingRecording)
            }
            MeetingLanguagePicker(selection: $language)
                .disabled(store.isStartingRecording)
            VStack(spacing: 0) {
                RecordingSourceRow(
                    name: "Microphone", subtitle: "Record your voice and nearby sounds.", symbol: "mic.fill",
                    isOn: $microphone
                ) {
                    microphoneDevicePicker
                }
                Divider().padding(.leading, 44)
                RecordingSourceRow(
                    name: "System Audio", subtitle: "Record sound from other apps.", symbol: "speaker.wave.2.fill",
                    isOn: $systemAudio)
            }
            .padding(.horizontal, 14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .disabled(store.isStartingRecording)
            if !microphone && !systemAudio {
                Label("Choose at least one audio source.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("Recording Options", isExpanded: $showOptions) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Audio Format", selection: $format) {
                        Text("Opus (Recommended)").tag(RecordingFormat.opus)
                        Text("M4A (AAC)").tag(RecordingFormat.m4a)
                        Text("WAV").tag(RecordingFormat.wav)
                    }
                }
                .padding(.top, 12)
                // Keep the native pop-up bezel and keyboard focus ring inside
                // the disclosure's clipping boundary (HIG: retain system controls).
                // https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons
                .padding(.bottom, 4)
            }
            .disclosureGroupStyle(RecordingDisclosureStyle())
            .disabled(store.isStartingRecording)
            if let startupError {
                // HIG Feedback: keep recoverable failure beside the action it affects,
                // rather than attempting to present an alert behind this modal sheet.
                Label {
                    Text(startupError).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.callout).foregroundStyle(.secondary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .id("recording-startup-error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio sources are saved as separate tracks.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if store.isStartingRecording {
                    ProgressView().controlSize(.small)
                    Text("Preparing…").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(store.isStartingRecording)
                Button(startupError == nil ? "Start Recording" : "Try Again") {
                    startupError = nil
                    let previousError = store.errorMessage
                    Task {
                        await store.startRecording(
                            title: title, language: language, microphoneEnabled: microphone, systemEnabled: systemAudio,
                            format: format)
                        if let id = store.recordingID {
                            onStarted(id)
                            dismiss()
                        }
                        else if let permission = store.recordingPermissionNeeded {
                            startupError = permission.explanation
                            store.recordingPermissionNeeded = nil
                        }
                        else if let error = store.errorMessage, error != previousError {
                            startupError = error
                            store.errorMessage = nil
                        }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled((!microphone && !systemAudio) || !store.canStartRecording)
            }
        }
    }
    /// HIG Pop-up buttons: a menu of mutually exclusive choices, showing the current one.
    /// The saved microphone stays listed while disconnected so the choice isn't lost.
    /// https://developer.apple.com/design/human-interface-guidelines/pop-up-buttons
    private var microphoneDevicePicker: some View {
        Picker(
            "Microphone Device",
            selection: Binding(
                get: { store.settings.microphoneDevice?.uid },
                set: { uid in
                    let saved = store.settings.microphoneDevice
                    store.settings.microphoneDevice =
                        uid == saved?.uid
                        ? saved
                        : microphoneDevices.devices.first { $0.uid == uid }.map {
                            MicrophoneDeviceChoice(uid: $0.uid, name: $0.name)
                        }
                    store.saveSettings()
                })
        ) {
            ForEach(
                Self.microphoneMenu(
                    devices: microphoneDevices.devices, defaultName: microphoneDevices.defaultName,
                    saved: store.settings.microphoneDevice), id: \.uid
            ) { item in
                Text(item.title).tag(item.uid)
            }
        }
        .recordingSourceDetailMenu()
        .disabled(!microphone)
    }

    struct MicrophoneMenuItem: Equatable {
        /// `nil` is System Default.
        var uid: String?
        var title: String
    }

    static func microphoneMenu(devices: [AudioInputDevice], defaultName: String?, saved: MicrophoneDeviceChoice?)
        -> [MicrophoneMenuItem]
    {
        var items = [
            MicrophoneMenuItem(uid: nil, title: defaultName.map { "System Default (\($0))" } ?? "System Default")
        ]
        items += devices.map { MicrophoneMenuItem(uid: $0.uid, title: $0.name) }
        // Capture uses the system default until the saved microphone reconnects.
        if let saved, !devices.contains(where: { $0.uid == saved.uid }) {
            items.append(MicrophoneMenuItem(uid: saved.uid, title: "\(saved.name) (Unavailable)"))
        }
        return items
    }
}

/// One audio source in New Recording: symbol, name, explanation, optional detail
/// control (such as the microphone menu), and an on/off switch.
struct RecordingSourceRow<Detail: View>: View {
    var name: String
    var subtitle: String
    var symbol: String
    @Binding var isOn: Bool
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.title3).foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(width: 24)
            // The text column takes all width left of the switch. With a Spacer
            // beside it, the stack split that width and wrapped the explanation.
            VStack(alignment: .leading, spacing: 3) {
                Text(name).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(name, isOn: $isOn).labelsHidden().toggleStyle(.switch)
        }.padding(.vertical, 14)
    }
}

extension RecordingSourceRow where Detail == EmptyView {
    init(name: String, subtitle: String, symbol: String, isOn: Binding<Bool>) {
        self.init(name: name, subtitle: subtitle, symbol: symbol, isOn: isOn) { EmptyView() }
    }
}

extension View {
    /// Pop-up menu styling for a control shown under a source row's explanation.
    /// A fixed maximum width keeps the row stable when the selected title changes;
    /// long device names truncate in the button but remain complete in the menu.
    func recordingSourceDetailMenu() -> some View {
        labelsHidden().pickerStyle(.menu).controlSize(.small).frame(maxWidth: 280, alignment: .leading)
    }
}

/// HIG Feedback: actual source activity remains visible and understandable without
/// interrupting the task. Color is supplemented by text and accessible values.
/// https://developer.apple.com/design/human-interface-guidelines/feedback
struct RecordingWorkspaceView: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: UUID
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle().fill(store.isFinalizingRecording ? Color.secondary : .red)
                            .frame(width: 7, height: 7).accessibilityHidden(true)
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            let elapsed =
                                store.isFinalizingRecording
                                ? (store.meetings.first { $0.id == meetingID }?.duration ?? store.recordingDuration)
                                : (store.recordingStartedAt.map { timeline.date.timeIntervalSince($0) } ?? 0)
                            Text(Self.elapsed(elapsed)).font(.system(size: 26, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .accessibilityLabel("Recording duration").accessibilityValue(Self.elapsed(elapsed))
                        }
                        Text(store.isFinalizingRecording ? "Saving" : "Recording")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let meeting = store.meetings.first(where: { $0.id == meetingID }) {
                        Text(meeting.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // A route change is exceptional; preserve its visible explanation.
                    if !store.isFinalizingRecording {
                        RecordingReconnectStatus(status: store.recordingMeter.status)
                    }
                }
                Spacer()
                if store.isFinalizingRecording {
                    // HIG Progress: saving duration is unknown; never invent a percentage.
                    // https://developer.apple.com/design/human-interface-guidelines/progress-indicators
                    ProgressView().controlSize(.small)
                    Text("Saving audio…").foregroundStyle(.secondary)
                }
                else {
                    Button {
                        Task { await store.stopRecording() }
                    } label: {
                        Label("Stop & Save", systemImage: "stop.fill")
                    }.buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                }
            }
            RecordingLiveMeters(
                meter: store.recordingMeter, status: store.recordingMeter.status, saving: store.isFinalizingRecording
            ) {
                store.setRecordingVoiceProcessing($0)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    RecordingSettingsDisclosure(meetingID: meetingID, status: store.recordingMeter.status)
                    LiveTranscriptView(controller: store.liveTranscript)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
    }
    /// Names the new device when a source is switching to one. When both
    /// sources switch (usually one event, such as connecting AirPods), a short
    /// generic line fits the header; each meter's help and accessibility value
    /// still names its device.
    static func reconnectingStatus(_ levels: RecordingLevels) -> String? {
        let microphone = levels.microphone.enabled && levels.microphone.reconnecting
        let system = levels.system.enabled && levels.system.reconnecting
        switch (microphone, system) {
        case (true, true):
            return levels.microphone.switchingTo != nil && levels.system.switchingTo != nil
                ? "Switching audio devices…" : "Reconnecting microphone and system audio…"
        case (true, false):
            return levels.microphone.switchingTo.map { "Switching microphone to \($0)…" } ?? "Reconnecting microphone…"
        case (false, true):
            return levels.system.switchingTo.map { "Switching system audio to \($0)…" } ?? "Reconnecting system audio…"
        case (false, false): return nil
        }
    }
    static func elapsed(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// SwiftUI observes semantic status only; native surfaces receive amplitude ticks directly.
private struct RecordingReconnectStatus: View {
    @ObservedObject var status: RecordingMeterStatus
    var body: some View {
        if let status = RecordingWorkspaceView.reconnectingStatus(status.levels) {
            Label(status, systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct RecordingLiveMeters: View {
    let meter: RecordingMeterState
    @ObservedObject var status: RecordingMeterStatus
    let saving: Bool
    let setVoiceProcessing: (Bool) -> Void
    var body: some View {
        let levels = status.levels
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                RecordingSourceMeter(
                    title: "Microphone", symbol: "mic.fill", source: levels.microphone, saving: saving,
                    activity: meter.activity.bars(microphone: true), activityTime: meter.activity.bucketStart,
                    tint: .accentColor, liveMeter: meter, microphone: true)
            }
            RecordingSourceMeter(
                title: "System Audio", symbol: "speaker.wave.2.fill", source: levels.system, saving: saving,
                activity: meter.activity.bars(microphone: false), activityTime: meter.activity.bucketStart,
                tint: .teal, liveMeter: meter, microphone: false)
        }
    }
}

/// HIG Toggles: a switch for a setting that takes effect immediately. It shows
/// the running engine's state, so automatic changes move it too; it is disabled
/// while the microphone rebuilds rather than queueing another change.
/// https://developer.apple.com/design/human-interface-guidelines/toggles
struct RecordingVoiceProcessingControl: View {
    let status: RecordingMicrophoneStatus
    let onChange: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Toggle("Voice Processing", isOn: Binding(get: { status.voiceProcessing }, set: onChange))
                    .toggleStyle(.switch).controlSize(.small).font(.callout)
                    .disabled(!status.canSwitch)
                    .help("Reduces echo and background noise in the microphone track. May lower other apps’ volume.")
                if status.echoDetected {
                    Label("Echo detected", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help("The microphone is picking up system audio. Turn on Voice Processing or use headphones.")
                }
            }
            ForEach(status.notices, id: \.self) { notice in
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// HIG Disclosure controls: provide a clear, accessible way to reveal related details.
/// One native button owns the entire header so its label and empty space activate
/// the same action as its chevron, with standard keyboard and disabled behavior.
/// https://developer.apple.com/design/human-interface-guidelines/disclosure-controls
struct RecordingDisclosureStyle: DisclosureGroupStyle {
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

struct RecordingSourceMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let title: String
    let symbol: String
    let source: RecordingSourceLevel
    let saving: Bool
    let activity: [Double]
    let activityTime: TimeInterval?
    let tint: Color
    var liveMeter: RecordingMeterState? = nil
    var microphone = true
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Preserve the source name at narrow widths. The level bar remains
            // visible when there is not enough room for the activity history.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    sourceLabel.fixedSize()
                    Spacer(minLength: 0)
                    activitySurface.frame(width: 110, height: 24)
                }
                HStack(spacing: 6) {
                    sourceLabel.fixedSize()
                    Spacer(minLength: 0)
                    Image(systemName: statusSymbol).font(.caption2).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }.frame(height: 24)
            if let liveMeter {
                RecordingLiveLevelSurface(
                    meter: liveMeter, microphone: microphone, saving: saving, tint: tint, title: title
                )
                .frame(height: 7)
            }
            else {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(source.peakDB > -1 ? Color.orange : tint)
                            .frame(width: geometry.size.width * (saving ? 0 : source.level))
                    }
                }.frame(height: 7)
            }
        }
        .accessibilityElement(children: liveMeter == nil ? .ignore : .contain)
        .accessibilityLabel(title)
        .help(statusText)
        .accessibilityValue(
            receiving && liveMeter == nil ? "\(statusText), \(Int(source.rmsDB)) decibels" : statusText)
    }

    private var activitySurface: some View {
        Group {
            if let liveMeter {
                RecordingLiveActivitySurface(
                    meter: liveMeter, microphone: microphone, tint: tint,
                    animate: receiving && !reduceMotion && scenePhase == .active)
            }
            else {
                RecordingActivitySurface(
                    bars: activity, bucketStart: activityTime, tint: tint,
                    animate: receiving && !reduceMotion && scenePhase == .active)
            }
        }
        .help("Last 10 seconds · " + statusText)
        .overlay(alignment: .trailing) {
            if !receiving {
                Image(systemName: statusSymbol).font(.caption2).foregroundStyle(.secondary)
                    .padding(2).background(.background, in: Circle())
            }
        }
    }

    private var receiving: Bool {
        !saving && source.enabled && source.hasSamples && !source.stale && !source.reconnecting
    }

    private var sourceLabel: some View { Label(title, systemImage: symbol).font(.subheadline.weight(.medium)) }
    private var statusText: String {
        if saving { return source.enabled ? "Finalizing" : "Not recorded" }
        // The native child exposes current loudness; the container describes availability.
        if liveMeter != nil && receiving { return "Receiving audio" }
        return source.statusText
    }

    private var statusSymbol: String {
        if !source.enabled { return "minus.circle" }
        if saving { return "hourglass" }
        if source.reconnecting { return "arrow.triangle.2.circlepath" }
        if !source.hasSamples { return "clock" }
        if source.stale { return "exclamationmark.triangle" }
        return source.rmsDB < -60 ? "waveform" : "waveform.circle.fill"
    }
}

/// The full disclosure row is a native button; values wrap without shrinking the hit target.
struct RecordingSettingsDisclosure: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject var status: RecordingMeterStatus
    let meetingID: UUID
    @ViewState private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(meetingID: UUID, status: RecordingMeterStatus) {
        self.meetingID = meetingID
        self.status = status
    }
    var body: some View {
        if let meeting = store.meetings.first(where: { $0.id == meetingID }) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).frame(width: 12)
                        Text(summary(meeting)).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }.buttonStyle(ActionButtonStyle())
                    .accessibilityLabel("Recording Settings")
                    .accessibilityValue("\(expanded ? "Expanded" : "Collapsed"). \(summary(meeting))")
                    .help(expanded ? "Hide Recording Settings" : "Show Recording Settings")
                if expanded {
                    MeetingLanguagePicker(
                        selection: Binding(
                            get: { meeting.language },
                            set: { language in
                                guard var latest = store.meetings.first(where: { $0.id == meetingID }) else { return }
                                latest.language = language
                                store.updateMeeting(latest)
                                if store.meetings.first(where: { $0.id == meetingID })?.language == language {
                                    store.liveTranscript.changeLanguage(language)
                                }
                            }))
                    if status.levels.microphone.enabled && !store.isFinalizingRecording {
                        RecordingVoiceProcessingControl(status: status.levels.microphoneStatus) {
                            store.setRecordingVoiceProcessing($0)
                        }
                    }
                    MeetingTagsView(meetingID: meetingID)
                }
            }
        }
    }
    private func summary(_ meeting: Meeting) -> String {
        let language = Locale.current.localizedString(forIdentifier: meeting.language) ?? meeting.language
        let names = meeting.tagIDs.compactMap { id in store.tags.first(where: { $0.id == id })?.name }
        return Self.settingsSummary(
            language: language, microphoneEnabled: status.levels.microphone.enabled,
            microphone: status.levels.microphoneStatus, tags: names)
    }
    static func settingsSummary(
        language: String, microphoneEnabled: Bool,
        microphone: RecordingMicrophoneStatus, tags: [String]
    ) -> String {
        let processing =
            !microphoneEnabled
            ? "Microphone Off"
            : microphone.voiceProcessingUnavailable
                ? "Voice Processing Unavailable"
                : "Voice Processing \(microphone.voiceProcessing ? "On" : "Off")"
        return "\(language) · \(processing) · \(tags.isEmpty ? "No Tags" : tags.joined(separator: ", "))"
    }
}
