import AVFoundation
import Accelerate
import CoreAudio

/// HIG Privacy: request protected resources only when recording is requested.
/// https://developer.apple.com/design/human-interface-guidelines/privacy
// Start/stop are serialized by MeetingStore. Each source has a recovery
// controller that replaces its engine or tap on its own serial queue; writers,
// the epoch, and files stay fixed for the whole recording. Taps and IOProc
// consumers only call the locked writer/measure/report methods. Mutable shared
// state below the "stateLock" mark is protected by stateLock.
final class AudioCapture: NSObject, @unchecked Sendable {
    /// Stop & Save waits at most this long for native teardown before abandoning it.
    static let stopBound: TimeInterval = 3
    /// A source that delivered before and then goes quiet this long is rebuilt.
    static let deliveryWatchdog: TimeInterval = 3
    /// How long the live view explains that echo detection turned processing on.
    static let echoNoticeDuration: TimeInterval = 10

    private var microphoneWriter: TimedAudioWriter?
    private var systemWriter: TimedAudioWriter?
    private let queue = DispatchQueue(label: "com.gdaymeetings.macos.system-audio")
    private var microphoneRecovery: CaptureSourceRecovery<MicrophoneSession>?
    private var systemRecovery: CaptureSourceRecovery<SystemAudioCapture>?
    private typealias RouteListener = (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)
    /// Guards the listener lists so a notification that re-registers output
    /// listeners cannot race Stop & Save's removal and leave one behind.
    private let listenerLock = NSLock()
    private var listening = false  // listenerLock
    private var routeListeners: [RouteListener] = []  // listenerLock; system object
    private var outputListeners: [RouteListener] = []  // listenerLock; default output and its streams
    private var knownInput: AudioObjectID?  // queue only after listeners register
    private var knownOutput: AudioObjectID?  // queue only after listeners register
    /// Speaker classification of the default output; queue only, microphone recordings only.
    private var outputRoute: OutputSpeakerRoute?
    private var epoch: TimeInterval = 0
    private var initialPolicy = VoiceProcessingPolicy.automatic
    /// The microphone chosen in New Recording; `nil` follows the macOS default input.
    private var selectedMicrophone: MicrophoneDeviceChoice?
    private var initialVoiceProcessing = false
    private var initialMicrophone: MicrophoneSession?
    private var initialMicrophoneFormat: AVAudioFormat?
    private var initialSystemFormat: AVAudioFormat?
    private var healthTimer: DispatchSourceTimer?
    private var meterTimer: DispatchSourceTimer?
    private var recoveryTimer: DispatchSourceTimer?
    private var expectedMicrophone = false
    private var expectedSystem = false
    private var finished = false
    // stateLock
    private let stateLock = NSLock()
    private var failure: Error?
    private var teardownError: Error?
    private var levels = RecordingLevels()
    private var microphoneDelivery = SourceDelivery()
    private var systemDelivery = SourceDelivery()
    private var microphoneVoiceProcessing = false
    /// Changes at runtime: the live switch and echo detection make it explicit.
    private var policy = VoiceProcessingPolicy.automatic
    private var microphoneRoute = MicrophoneRoute()
    /// Whether the selected microphone may be bound; see `SelectedMicrophoneFallback`.
    private var selectedFallback = SelectedMicrophoneFallback(connected: false)
    /// A switch or echo request waiting for the rebuilt engine; blocks further switching.
    private var pendingVoiceProcessing: Bool?
    private var pendingReason: RecordingRouteChange.Reason?
    private var echo = EchoDetector()
    private var echoHint = false
    private var echoNoticeUntil: TimeInterval = 0
    private var routeChanges: [RecordingRouteChange] = []
    private var meterDeliveryPending = false
    var onLevels: ((RecordingLevels, @escaping () -> Void) -> Void)?
    var onHealth: ((String) -> Void)?
    var liveAudioSink: LiveAudioSink?
    /// Terminal failures only: a writer error, or every selected source failed permanently.
    var onFailure: ((Error) -> Void)?

    /// What the installed microphone engine is recording from.
    private struct MicrophoneRoute {
        var deviceName: String?
        var usesSelectedDevice = false
        var selectedDeviceUsed = false
        var voiceProcessingUnavailable = false
    }

    struct SourceDelivery {
        var everDelivered = false
        /// The installed session has delivered; reported once to its recovery controller.
        var sessionDelivered = false
        /// A rebuilt session has not delivered yet; the source still shows as reconnecting.
        var awaitingResume = false
        var sessionStart: TimeInterval = 0
        var last: TimeInterval = 0
        /// The installed session's device, when known.
        var device: AudioDeviceIdentity?
        /// The device of the last session that delivered audio.
        var deliveredDevice: AudioObjectID?
        /// While reconnecting: the device the next session will use, if one is available.
        var target: AudioDeviceIdentity?

        /// The device to name in "Switching … to *Name*…": the reconnect target,
        /// or a rebuilt session that has not delivered yet. `nil` keeps
        /// "Reconnecting…": no replacement is available yet, or capture is
        /// rebuilding on the device it already recorded from.
        func switchingTo(state: CaptureSourceState?) -> String? {
            let next: AudioDeviceIdentity?
            switch state {
            case .reconnecting?: next = target
            case .running? where awaitingResume: next = device
            default: return nil
            }
            guard let next, let deliveredDevice, next.id != deliveredDevice else { return nil }
            return next.name
        }
    }

    var profile: RecordingProfile {
        let systemProfile = queue.sync { systemWriter?.profile }
        var microphoneProfile = microphoneWriter?.profile
        // An automatic-policy fallback can finish on an unprocessed engine after
        // the writer was created for a processed one.
        microphoneProfile?.voiceProcessed = initialVoiceProcessing
        var profile = RecordingProfile(
            microphoneVoiceProcessing: initialVoiceProcessing,
            tracks: [microphoneProfile, systemProfile].compactMap { $0 })
        // The policy at start; live switches and echo detection appear in `routeChanges`.
        profile.voiceProcessingPolicy = expectedMicrophone ? initialPolicy : nil
        profile.routeChanges = locked { routeChanges }
        return profile
    }

    func start(
        directory: URL, microphoneEnabled: Bool, systemEnabled: Bool,
        voiceProcessing: VoiceProcessingPolicy = .automatic, microphoneDevice: MicrophoneDeviceChoice? = nil
    ) async throws -> [String] {
        guard microphoneEnabled || systemEnabled else {
            throw MeetingError.message("Choose Microphone or System Audio in New Recording.")
        }
        expectedMicrophone = microphoneEnabled
        expectedSystem = systemEnabled
        initialPolicy = voiceProcessing
        policy = voiceProcessing
        selectedMicrophone = microphoneDevice
        if let microphoneDevice {
            locked {
                selectedFallback = SelectedMicrophoneFallback(
                    connected: RecordingAudioRoute.inputDevice(uid: microphoneDevice.uid) != nil)
            }
        }
        CaptureLog.capture.notice(
            "Recording start: microphone \(microphoneEnabled), system audio \(systemEnabled), voice processing policy \(voiceProcessing.rawValue, privacy: .public), selected microphone \(microphoneDevice?.name ?? "System Default", privacy: .public)"
        )
        levels.microphone.enabled = microphoneEnabled
        levels.system.enabled = systemEnabled
        var files: [String] = []
        do {
            let cancellationGeneration = await RecordingPermissions.currentCancellationGeneration
            try await RecordingPermissions.request(microphone: microphoneEnabled)
            try await RecordingPermissions.checkCancellation(since: cancellationGeneration)
            if systemEnabled {
                let recovery = makeSystemRecovery()
                systemRecovery = recovery
                // Trigger audio-only consent before starting the microphone. Frames
                // before the common recording epoch are discarded, not persisted.
                let session = try makeSystemSession(generation: 0)
                recovery.install(session)
                initialSystemFormat = session.format
                let output = AudioDeviceIdentity.current(output: true)
                locked { systemDelivery.device = output }
                CaptureLog.capture.notice(
                    "System audio tap started: \(CaptureLog.describe(session.format), privacy: .public), output \(Self.defaultDeviceName(output: true) ?? "unknown", privacy: .public)"
                )
                try await RecordingPermissions.checkCancellation(since: cancellationGeneration)
            }
            epoch = hostNow()
            if microphoneEnabled {
                let recovery = makeMicrophoneRecovery()
                microphoneRecovery = recovery
                let url = directory.appendingPathComponent("microphone.wav")
                let session = try makeMicrophoneSession(generation: 0) { [self] format, processed in
                    // A voice-processing fallback reuses the first writer; it converts formats.
                    if let microphoneWriter { return microphoneWriter }
                    epoch = hostNow()
                    try prepareSystemWriter(directory: directory)
                    let writer = try TimedAudioWriter(
                        url: url, format: format, epoch: epoch, voiceProcessed: processed,
                        alignedAudio: { [weak self] buffer, start in
                            self?.liveAudioSink?.append(buffer, start: start, source: .microphone)
                        })
                    microphoneWriter = writer
                    return writer
                }
                recovery.install(session)
                locked { microphoneDelivery.device = session.device }
                initialMicrophone = session
                initialVoiceProcessing = session.voiceProcessing
                initialMicrophoneFormat = session.format
                files.append(url.lastPathComponent)
            }
            if systemEnabled {
                if !microphoneEnabled { try prepareSystemWriter(directory: directory) }
                files.append("system.wav")
            }
            let now = ProcessInfo.processInfo.systemUptime
            locked {
                microphoneVoiceProcessing = initialVoiceProcessing
                microphoneDelivery.sessionStart = now
                systemDelivery.sessionStart = now
            }
            recordInitialRoutes()
            // On queue: route notifications run there and must see the initial state.
            try queue.sync { try observeDefaultDevices() }
            startTimers()
            if let startupFailure = currentFailure() { throw startupFailure }
            return files
        }
        catch {
            CaptureLog.capture.error("Recording start failed: \(error.localizedDescription, privacy: .public)")
            try? await stop()
            throw error
        }
    }

    func stop() async throws {
        guard !finished else { return }
        finished = true
        meterTimer?.cancel()
        meterTimer = nil
        healthTimer?.cancel()
        healthTimer = nil
        recoveryTimer?.cancel()
        recoveryTimer = nil
        // Remove route listeners first so no notification can restart capture.
        removeRouteListeners()
        let deadline = DispatchTime.now() + Self.stopBound
        let system = systemRecovery
        let microphone = microphoneRecovery
        // Waiting blocks a thread, so keep it off Swift's cooperative pool.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Stop the tap before VoiceProcessingIO, whose aggregate removal
                // must not look like a route loss. Both share one deadline.
                system?.stop(deadline: deadline)
                microphone?.stop(deadline: deadline)
                continuation.resume()
            }
        }
        // End both tracks at the same host time, padding a source that was still
        // reconnecting. Finished writers ignore late callbacks from abandoned sessions.
        let stopHost = hostNow()
        var stopError: Error?
        queue.sync {
            do { try systemWriter?.finish(throughHostSeconds: stopHost) }
            catch { stopError = error }
        }
        do { try microphoneWriter?.finish(throughHostSeconds: stopHost) }
        catch { stopError = error }
        if let captureFailure = currentFailure() { throw captureFailure }
        if let stopError { throw stopError }
        if let teardownError = locked({ teardownError }) { throw teardownError }
        // Frames count across reconnects, so a source that delivered earlier and
        // was reconnecting at stop does not trigger this error.
        let systemFrames = queue.sync { systemWriter?.capturedFrames ?? 0 }
        let microphoneFrames = microphoneWriter?.capturedFrames ?? 0
        CaptureLog.capture.notice(
            "Recording stopped: microphone \(microphoneFrames) frames, system audio \(systemFrames) frames")
        let silentMicrophone = expectedMicrophone && microphoneFrames == 0
        let silentSystem = expectedSystem && systemFrames == 0
        if silentMicrophone || silentSystem {
            throw CaptureSourceError.noAudio(
                microphone: silentMicrophone, systemAudio: silentSystem,
                otherTrackSaved: expectedMicrophone && expectedSystem && !(silentMicrophone && silentSystem))
        }
    }

    // MARK: - Recovery wiring

    private func makeMicrophoneRecovery() -> CaptureSourceRecovery<MicrophoneSession> {
        let recovery = CaptureSourceRecovery<MicrophoneSession>(
            label: "microphone", scheduler: QueueRecoveryScheduler(queue: queue),
            attemptQueue: DispatchQueue(label: "com.gdaymeetings.macos.microphone-recovery"),
            start: { [weak self] generation in
                guard let self else { throw CancellationError() }
                return try self.rebuildMicrophone(generation: generation)
            },
            stop: { $0.teardown() },
            isPermanent: { ($0 as? CaptureSourceError) == .microphoneAccessDenied })
        recovery.onStateChange = { [weak self] state in self?.sourceStateChanged(state, source: "microphone") }
        recovery.onInstalled = { [weak self] session in
            guard let self else { return }
            let reason = self.locked {
                self.microphoneDelivery.sessionStart = ProcessInfo.processInfo.systemUptime
                self.microphoneDelivery.sessionDelivered = false
                self.microphoneDelivery.awaitingResume = self.microphoneDelivery.everDelivered
                self.microphoneDelivery.device = session.device
                self.microphoneDelivery.target = nil
                return self.adoptMicrophone(session)
            }
            if let format = session.format {
                self.recordRoute(
                    source: "microphone", format: format, voiceProcessed: session.voiceProcessing,
                    device: session.deviceName, reason: reason)
            }
        }
        recovery.onPermanentFailure = { [weak self] error in
            guard let self else { return }
            self.locked { self.pendingVoiceProcessing = nil }
            self.sourceFailedPermanently(error)
        }
        return recovery
    }

    private func makeSystemRecovery() -> CaptureSourceRecovery<SystemAudioCapture> {
        let recovery = CaptureSourceRecovery<SystemAudioCapture>(
            label: "system audio", scheduler: QueueRecoveryScheduler(queue: queue),
            attemptQueue: DispatchQueue(label: "com.gdaymeetings.macos.system-audio-recovery"),
            start: { [weak self] generation in
                guard let self else { throw CancellationError() }
                return try self.makeSystemSession(generation: generation)
            },
            stop: { [weak self] capture in
                do { try capture.stop() }
                catch { self?.rememberTeardownError(error) }
            },
            // System audio has no revocable runtime permission that Core Audio
            // reports; keep retrying while the recording is active.
            isPermanent: { _ in false })
        recovery.onStateChange = { [weak self] state in self?.sourceStateChanged(state, source: "system audio") }
        recovery.onInstalled = { [weak self] capture in
            guard let self else { return }
            // The tap follows the default output; read it as the session's device.
            let output = AudioDeviceIdentity.current(output: true)
            self.locked {
                self.systemDelivery.sessionStart = ProcessInfo.processInfo.systemUptime
                self.systemDelivery.sessionDelivered = false
                self.systemDelivery.awaitingResume = self.systemDelivery.everDelivered
                self.systemDelivery.device = output
                self.systemDelivery.target = nil
            }
            CaptureLog.capture.notice(
                "System audio tap rebuilt: \(CaptureLog.describe(capture.format), privacy: .public), output \(Self.defaultDeviceName(output: true) ?? "unknown", privacy: .public)"
            )
            if let format = capture.format {
                self.recordRoute(
                    source: "system", format: format, voiceProcessed: false,
                    device: Self.defaultDeviceName(output: true),
                    reason: .route)
            }
        }
        return recovery
    }

    private func makeSystemSession(generation: Int) throws -> SystemAudioCapture {
        let capture = SystemAudioCapture(queue: queue)
        capture.onFailure = { [weak self] error in self?.report(error) }
        capture.onInterrupted = { [weak self] in
            CaptureLog.capture.notice("System audio tap interrupted (generation \(generation))")
            self?.systemRecovery?.sessionInterrupted(generation: generation)
        }
        capture.onBuffer = { [weak self] buffer, timestamp in
            guard let self, let writer = self.systemWriter, timestamp >= self.epoch else { return }
            try writer.append(buffer, hostSeconds: timestamp)
            self.measure(buffer, microphone: false, hostSeconds: timestamp)
        }
        try capture.start()
        return capture
    }

    /// Builds a fresh engine on the current default input for an existing writer.
    private func rebuildMicrophone(generation: Int) throws -> MicrophoneSession {
        // Revoked access cannot recover by retrying; other sources keep recording.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureSourceError.microphoneAccessDenied
        }
        guard let writer = microphoneWriter else { throw CancellationError() }
        return try makeMicrophoneSession(generation: generation) { _, _ in writer }
    }

    /// Every build re-reads the policy, the output route (automatic policy), and
    /// whether the selected microphone is connected. When voice processing
    /// cannot be enabled, capture continues unprocessed and the live view says
    /// so: losing the microphone is worse than recording it without processing.
    /// When the selected microphone cannot be bound or started, capture falls
    /// back to the default input once, with the same notice as a disconnected
    /// device, rather than retrying a device that keeps failing.
    private func makeMicrophoneSession(
        generation: Int, writer: (AVAudioFormat, Bool) throws -> TimedAudioWriter
    ) throws -> MicrophoneSession {
        let policy = locked { policy }
        let processed = policy.enabled()
        CaptureLog.capture.notice(
            "Microphone build \(generation): voice processing \(processed ? "on" : "off", privacy: .public) (policy \(policy.rawValue, privacy: .public), output \(Self.defaultDeviceName(output: true) ?? "unknown", privacy: .public))"
        )
        // A missing selected microphone records from the default input until it returns.
        let connected = selectedMicrophone.flatMap { RecordingAudioRoute.inputDevice(uid: $0.uid) }
        if let connected, locked({ selectedFallback.allowsSelected(connected: true) }) {
            do {
                return try buildWithVoiceProcessingFallback(
                    generation: generation, voiceProcessing: processed, device: connected, writer: writer)
            }
            catch {
                locked { selectedFallback.selectedFailed() }
                CaptureLog.capture.error(
                    "Selected microphone \(connected.name, privacy: .public) (\(connected.id)) failed: \(error.localizedDescription, privacy: .public). Using the default input until it reconnects."
                )
            }
        }
        else if let selectedMicrophone {
            CaptureLog.capture.notice(
                "Selected microphone \(selectedMicrophone.name, privacy: .public) \(connected == nil ? "not connected" : "skipped after a failure", privacy: .public); using the default input"
            )
        }
        return try buildWithVoiceProcessingFallback(
            generation: generation, voiceProcessing: processed, device: nil, writer: writer)
    }

    private func buildWithVoiceProcessingFallback(
        generation: Int, voiceProcessing processed: Bool, device: AudioInputDevice?,
        writer: (AVAudioFormat, Bool) throws -> TimedAudioWriter
    ) throws -> MicrophoneSession {
        do {
            return try buildMicrophoneEngine(
                generation: generation, voiceProcessing: processed, device: device, writer: writer)
        }
        catch  where processed {
            CaptureLog.capture.error(
                "Voice-processed microphone failed: \(error.localizedDescription, privacy: .public). Retrying unprocessed."
            )
            let session = try buildMicrophoneEngine(
                generation: generation, voiceProcessing: false, device: device, writer: writer)
            session.voiceProcessingUnavailable = true
            return session
        }
    }

    private func buildMicrophoneEngine(
        generation: Int, voiceProcessing requested: Bool, device: AudioInputDevice?,
        writer makeWriter: (AVAudioFormat, Bool) throws -> TimedAudioWriter
    ) throws -> MicrophoneSession {
        let session = MicrophoneSession()
        session.usesSelectedDevice = device != nil
        if let device {
            session.deviceID = device.id
            session.deviceName = device.name
        }
        else {
            session.deviceID = RecordingAudioRoute.defaultDevice(output: false)
            session.deviceName = session.deviceID.flatMap(RecordingAudioRoute.deviceName)
        }
        do {
            try configure(
                session, generation: generation, voiceProcessing: requested, device: device?.id, writer: makeWriter)
            CaptureLog.capture.notice(
                "Microphone \(generation) started on \(session.deviceName ?? "unknown", privacy: .public)\(device.map { " (\($0.id))" } ?? " (default input)", privacy: .public): \(CaptureLog.describe(session.format), privacy: .public), voice processing \(session.voiceProcessing ? "on" : "off", privacy: .public)"
            )
            return session
        }
        catch {
            session.teardown()
            throw error
        }
    }

    private func configure(
        _ session: MicrophoneSession, generation: Int, voiceProcessing requested: Bool, device: AudioObjectID?,
        writer makeWriter: (AVAudioFormat, Bool) throws -> TimedAudioWriter
    ) throws {
        let engine = session.engine
        let input = engine.inputNode
        // Selecting a device leaves AVAudioEngine a pending configuration change
        // (it starts on a default-device aggregate). Started before that change is
        // processed, the engine stops itself or keeps the previous device's format
        // (24 kHz AirPods while the Mac microphone ran at 48 kHz, so the tap was
        // rejected), then posts AVAudioEngineConfigurationChange, which rebuilt the
        // microphone into the same state forever. Bind, then let the change settle
        // before reading formats or starting. Measured on macOS 26.
        if let device {
            let pending = PendingConfigurationChange(engine: engine)
            if try Self.bindInput(input, to: device) { pending.prepareAndWait(engine, step: "select device") }
        }
        // The hardware side reflects the bound device; the node's output format
        // can still describe the previous device until the engine reconfigures.
        let hardware = input.inputFormat(forBus: 0)
        let client = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, client.channelCount > 0 else {
            throw MeetingError.message("No microphone input is available.")
        }
        if client.sampleRate != hardware.sampleRate {
            CaptureLog.capture.error(
                "Microphone client format \(CaptureLog.describe(client), privacy: .public) differs from hardware \(CaptureLog.describe(hardware), privacy: .public); using the hardware rate"
            )
        }
        // Enable only while stopped. Both hardware I/O nodes participate; never feed
        // captured system audio or microphone monitoring back to the speakers.
        // https://developer.apple.com/videos/play/wwdc2019/510/
        var pendingVoiceProcessingBind: PendingConfigurationChange?
        if requested {
            // Settling prepared the engine; voice processing changes only while uninitialized.
            if device != nil { engine.stop() }
            do { try input.setVoiceProcessingEnabled(true) }
            catch {
                let cause = error as NSError
                throw CaptureSourceError.voiceProcessing(
                    "Could not enable Apple microphone voice processing (\(cause.domain) \(cause.code)): \(cause.localizedDescription)"
                )
            }
            session.voiceProcessing = input.isVoiceProcessingEnabled
            guard session.voiceProcessing else {
                throw CaptureSourceError.voiceProcessing("Apple voice processing is unavailable on this audio route.")
            }
            // Enabling voice processing resets the input to the default device.
            // Its configuration change settles after the graph is wired: preparing
            // before `connect` would make AVAudioEngine reject the connection.
            if let device {
                let pending = PendingConfigurationChange(engine: engine)
                if try Self.bindInput(input, to: device) { pendingVoiceProcessingBind = pending }
            }
            // Other applications count as other audio. Minimum reduces but does not
            // promise to eliminate ducking; do not claim external-app AEC guarantees.
            // https://developer.apple.com/videos/play/wwdc2023/10235/
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false, duckingLevel: .min)
            input.isVoiceProcessingAGCEnabled = true
        }
        let format: AVAudioFormat
        if session.voiceProcessing {
            // Request a mono processed-speech client from the Audio Unit itself.
            // installTap's explicit format configures this otherwise-unconnected
            // output bus; no application-side selection/downmix of aggregate
            // channels is performed. Raw capture keeps its device channel layout.
            // https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)
            guard
                let speechFormat = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1)
            else {
                throw CaptureSourceError.voiceProcessing("Could not configure the mono voice-processing client format.")
            }
            format = speechFormat
            // Voice I/O needs an active hardware output. Render silence, never the
            // captured meeting: this establishes I/O without monitoring or feedback.
            let silence = AVAudioSourceNode { _, _, _, buffers in
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                return noErr
            }
            engine.attach(silence)
            // VoiceProcessingIO requires its client input and output formats
            // to match. The mixer's implicit output format can differ from the
            // input client's aggregate default, causing initialization -10875.
            // Connect the silent source directly to hardware I/O with the exact
            // microphone client format; the Audio Unit handles the device format.
            // https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)
            engine.connect(silence, to: engine.outputNode, format: format)
            let outputFormat = engine.outputNode.inputFormat(forBus: 0)
            guard outputFormat == format else {
                throw CaptureSourceError.voiceProcessing(
                    "Apple voice processing requires matching client formats. Microphone: \(format); output: \(outputFormat)."
                )
            }
        }
        else {
            // A tap whose rate differs from the hardware is rejected ("Failed to
            // create tap") and delivers nothing, so take the rate from the hardware.
            guard
                let rawFormat = AVAudioFormat(
                    standardFormatWithSampleRate: hardware.sampleRate, channels: client.channelCount)
            else { throw MeetingError.message("Could not configure the microphone format.") }
            format = rawFormat
        }
        session.format = format
        let writer = try makeWriter(format, session.voiceProcessing)
        // An ordinary input tap is deliberately used rather than a realtime sink.
        // Its samples are copied into Core Audio's bounded asynchronous writer,
        // which converts a rebuilt engine's format to the track format.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            guard time.isHostTimeValid else {
                // Without host time the buffer cannot be placed; rebuild the engine.
                self.microphoneRecovery?.sessionInterrupted(generation: generation)
                return
            }
            do {
                let host = AVAudioTime.seconds(forHostTime: time.hostTime)
                try writer.append(buffer, hostSeconds: host)
                self.measure(buffer, microphone: true, hostSeconds: host)
            }
            catch { self.report(error) }
        }
        session.tapInstalled = true
        if session.voiceProcessing {
            let negotiatedInput = input.outputFormat(forBus: 0)
            let negotiatedOutput = engine.outputNode.inputFormat(forBus: 0)
            guard negotiatedInput == format, negotiatedOutput == format else {
                throw CaptureSourceError.voiceProcessing(
                    "Apple voice processing did not accept the mono client format. Input: \(negotiatedInput); output: \(negotiatedOutput)."
                )
            }
        }
        engine.prepare()
        pendingVoiceProcessingBind?.wait(step: "select device after voice processing")
        do { try engine.start() }
        catch {
            let cause = error as NSError
            let mode = session.voiceProcessing ? "voice-processed" : "unprocessed"
            let output = session.voiceProcessing ? "; output client \(engine.outputNode.inputFormat(forBus: 0))" : ""
            throw MeetingError.message(
                "Could not start \(mode) microphone capture (\(cause.domain) \(cause.code)). Input client \(format)\(output). \(cause.localizedDescription)"
            )
        }
        guard engine.isRunning else {
            throw MeetingError.message("The microphone engine could not start on this route.")
        }
        // Never record a different microphone than the one shown: confirm the
        // running engine still uses the selected device.
        let startedDevice = Self.boundInput(input)
        if let device, startedDevice != device {
            throw CaptureSourceError.selectedMicrophone(
                "The selected microphone was replaced when the engine started (bound \(startedDevice.map(String.init) ?? "none"), expected \(device))."
            )
        }
        // A device, sample-rate, or channel change stops this engine. Recovery
        // builds a fresh engine for the same track. A notification that leaves the
        // engine running on the same device and hardware format changed nothing
        // this track depends on, so it is logged and ignored rather than rebuilt.
        // https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification
        let started = MicrophoneConfigurationChange(
            running: true, device: startedDevice, sampleRate: input.inputFormat(forBus: 0).sampleRate,
            channels: input.inputFormat(forBus: 0).channelCount)
        session.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self, weak engine] _ in
            guard let self, let engine else { return }
            let input = engine.inputNode
            let hardware = input.inputFormat(forBus: 0)
            let now = MicrophoneConfigurationChange(
                running: engine.isRunning, device: Self.boundInput(input), sampleRate: hardware.sampleRate,
                channels: hardware.channelCount)
            guard now.requiresRebuild(since: started) else {
                CaptureLog.capture.notice(
                    "Microphone \(generation) configuration change ignored: still running on device \(now.device.map(String.init) ?? "none", privacy: .public), \(CaptureLog.describe(hardware), privacy: .public)"
                )
                return
            }
            CaptureLog.capture.notice(
                "Microphone \(generation) configuration changed: running \(now.running), device \(now.device.map(String.init) ?? "none", privacy: .public), \(CaptureLog.describe(hardware), privacy: .public)"
            )
            self.microphoneRecovery?.routeChanged(generation: generation)
        }
    }

    /// Selects the device on the I/O unit's input element (1) and confirms it.
    /// Returns whether the device changed, which leaves a configuration change
    /// pending. With voice processing on, `AUAudioUnit.setDeviceID` moves
    /// VoiceProcessingIO's output instead and the microphone stays on the default
    /// input (measured on macOS 26); the input element selects only the
    /// microphone for both modes.
    /// https://developer.apple.com/documentation/audiotoolbox/kaudiooutputunitproperty_currentdevice
    private static func bindInput(_ input: AVAudioInputNode, to device: AudioObjectID) throws -> Bool {
        guard let unit = input.audioUnit else {
            throw CaptureSourceError.selectedMicrophone("The microphone engine has no input unit.")
        }
        let previous = boundInput(input)
        guard previous != device else { return false }
        var value = device
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &value,
            UInt32(MemoryLayout<AudioObjectID>.size))
        let bound = boundInput(input)
        CaptureLog.capture.notice(
            "Microphone input element: device \(previous.map(String.init) ?? "none", privacy: .public) → \(device), status \(status), read back \(bound.map(String.init) ?? "none", privacy: .public)"
        )
        guard status == noErr, bound == device else {
            throw CaptureSourceError.selectedMicrophone("Could not select the microphone (Core Audio \(status)).")
        }
        return true
    }

    private static func boundInput(_ input: AVAudioInputNode) -> AudioObjectID? {
        guard let unit = input.audioUnit else { return nil }
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1, &device, &size)
        return status == noErr ? device : nil
    }

    private static func defaultDeviceName(output: Bool) -> String? {
        RecordingAudioRoute.defaultDevice(output: output).flatMap(RecordingAudioRoute.deviceName)
    }

    /// Records the installed microphone engine's route and returns why it changed.
    /// Call with stateLock held.
    private func adoptMicrophone(_ session: MicrophoneSession) -> RecordingRouteChange.Reason? {
        let previous = microphoneRoute
        var reason = pendingReason ?? .route
        if selectedMicrophone != nil, session.usesSelectedDevice != previous.usesSelectedDevice {
            reason = session.usesSelectedDevice ? .selectedMicrophoneReturned : .selectedMicrophoneUnavailable
        }
        if session.voiceProcessingUnavailable, pendingReason == nil { reason = .voiceProcessingUnavailable }
        if pendingReason == .echoDetected, session.voiceProcessing {
            echoNoticeUntil = ProcessInfo.processInfo.systemUptime + Self.echoNoticeDuration
        }
        microphoneVoiceProcessing = session.voiceProcessing
        microphoneRoute = MicrophoneRoute(
            deviceName: session.deviceName, usesSelectedDevice: session.usesSelectedDevice,
            selectedDeviceUsed: previous.selectedDeviceUsed || session.usesSelectedDevice,
            voiceProcessingUnavailable: session.voiceProcessingUnavailable)
        pendingVoiceProcessing = nil
        pendingReason = nil
        // The processed and unprocessed envelopes differ; start the comparison over.
        echo.reset()
        echoHint = false
        return reason
    }

    /// The live Voice Processing switch. The choice is explicit for the rest of
    /// the recording. Only the microphone engine is rebuilt; its brief gap is
    /// padded and saved like any reconnect. Ignored while a rebuild is pending.
    func setVoiceProcessing(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, let recovery = self.microphoneRecovery, recovery.state == .running else { return }
            let rebuild: Bool = self.locked {
                guard self.pendingVoiceProcessing == nil else { return false }
                self.policy = enabled ? .on : .off
                self.echoHint = false
                guard enabled != self.microphoneVoiceProcessing else { return false }
                self.pendingVoiceProcessing = enabled
                self.pendingReason = .voiceProcessingSwitched
                return true
            }
            CaptureLog.capture.notice(
                "Voice Processing switched \(enabled ? "on" : "off", privacy: .public)\(rebuild ? "; rebuilding microphone" : "", privacy: .public)"
            )
            if rebuild { recovery.routeChanged() }
        }
    }

    /// Runs on queue. Follows the macOS default devices. Comparing device IDs
    /// ignores notifications caused by capture's own aggregate and
    /// voice-processing changes, which do not change the user's default devices.
    private func observeDefaultDevices() throws {
        knownInput = RecordingAudioRoute.defaultDevice(output: false)
        knownOutput = RecordingAudioRoute.defaultDevice(output: true)
        listenerLock.withLock { listening = true }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listeners: [RouteListener] = []
        // Register what exists so far even if a later listener fails; stop removes them.
        defer { listenerLock.withLock { routeListeners += listeners } }
        if expectedMicrophone {
            listeners.append(
                try listen(system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
                    self?.defaultDeviceChanged(output: false)
                })
            if selectedMicrophone != nil {
                listeners.append(
                    try listen(system, kAudioHardwarePropertyDevices) { [weak self] in self?.inputDevicesChanged() })
            }
        }
        listeners.append(
            try listen(system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                self?.defaultDeviceChanged(output: true)
            })
        if expectedMicrophone {
            outputRoute = OutputSpeakerRoute(speaker: RecordingAudioRoute.defaultVoiceProcessing())
            observeOutputRoute(knownOutput)
        }
    }

    private func listen(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ handler: @escaping () -> Void
    ) throws -> RouteListener {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        guard status == noErr else {
            throw MeetingError.message("Could not observe audio device changes (Core Audio \(status)).")
        }
        return (object, address, block)
    }

    /// Runs on queue. Replaces the listeners on the default output: its data
    /// source, its output stream list, and each stream's terminal type. These
    /// change without a new default device ID, for example when headphones are
    /// plugged into a built-in jack. Properties a device lacks are skipped.
    private func observeOutputRoute(_ device: AudioObjectID?) {
        var added: [RouteListener] = []
        if let device {
            let streams =
                RecordingAudioRoute.readProperty(
                    object: device, selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) ?? []
            let properties: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] =
                [
                    (device, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput),
                    (device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
                ] + streams.map { ($0, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal) }
            for (object, selector, scope) in properties {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
                guard AudioObjectHasProperty(object, &address) else { continue }
                let streamsChanged = selector == kAudioDevicePropertyStreams
                do {
                    added.append(
                        try listen(object, selector, scope: scope) { [weak self] in
                            self?.outputRouteChanged(streamsChanged: streamsChanged)
                        })
                }
                catch {
                    CaptureLog.capture.error(
                        "Output route listener on \(object) not added: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        // After Stop & Save, remove what was just added instead of keeping it.
        let stale: [RouteListener] = listenerLock.withLock {
            guard listening else { return added }
            defer { outputListeners = added }
            return outputListeners
        }
        Self.remove(stale, queue: queue)
        CaptureLog.capture.info(
            "Observing output route on device \(device.map(String.init) ?? "none", privacy: .public): \(added.count) listeners"
        )
    }

    private func removeRouteListeners() {
        let listeners: [RouteListener] = listenerLock.withLock {
            listening = false
            defer {
                routeListeners.removeAll()
                outputListeners.removeAll()
            }
            return routeListeners + outputListeners
        }
        Self.remove(listeners, queue: queue)
    }

    private static func remove(_ listeners: [RouteListener], queue: DispatchQueue) {
        for (object, var address, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
    }

    /// Runs on queue.
    private func defaultDeviceChanged(output: Bool) {
        let device = RecordingAudioRoute.defaultDevice(output: output)
        if output {
            guard device != knownOutput else { return }
            knownOutput = device
            CaptureLog.capture.notice(
                "Default output changed to \(device.flatMap(RecordingAudioRoute.deviceName) ?? "none", privacy: .public) (\(device.map(String.init) ?? "none", privacy: .public))"
            )
            systemRecovery?.routeChanged()
            guard expectedMicrophone else { return }
            let speaker = RecordingAudioRoute.defaultVoiceProcessing()
            outputRoute = OutputSpeakerRoute(speaker: speaker)
            observeOutputRoute(device)
            let (processed, policy) = locked { (microphoneVoiceProcessing, policy) }
            if OutputSpeakerRoute.rebuildsMicrophone(policy: policy, voiceProcessing: processed, speaker: speaker) {
                microphoneRecovery?.routeChanged()
            }
        }
        else {
            guard device != knownInput else { return }
            knownInput = device
            // A connected selected microphone does not follow the default input.
            let pinned = locked({ microphoneRoute.usesSelectedDevice }) && microphoneRecovery?.state == .running
            CaptureLog.capture.notice(
                "Default input changed to \(device.flatMap(RecordingAudioRoute.deviceName) ?? "none", privacy: .public) (\(device.map(String.init) ?? "none", privacy: .public))\(pinned ? "; selected microphone keeps recording" : "", privacy: .public)"
            )
            if pinned { return }
            microphoneRecovery?.routeChanged()
        }
    }

    /// Runs on queue. The default output's data source, streams, or terminal
    /// types changed on the same device. Only a change between speaker and
    /// non-speaker matters; other notifications are ignored.
    private func outputRouteChanged(streamsChanged: Bool) {
        guard var route = outputRoute else { return }
        // New streams need their own terminal-type listeners.
        if streamsChanged { observeOutputRoute(knownOutput) }
        let (processed, policy) = locked { (microphoneVoiceProcessing, policy) }
        let change = route.refresh(policy: policy, voiceProcessing: processed)
        outputRoute = route
        guard case .changed(let rebuild) = change else {
            CaptureLog.capture.debug("Output route notification ignored: speaker classification unchanged")
            return
        }
        CaptureLog.capture.notice(
            "Output route on \(Self.defaultDeviceName(output: true) ?? "unknown", privacy: .public) is now \(route.speaker ? "a speaker" : "not a speaker", privacy: .public) (policy \(policy.rawValue, privacy: .public), voice processing \(processed ? "on" : "off", privacy: .public))\(rebuild ? "; rebuilding microphone" : "; microphone unchanged", privacy: .public)"
        )
        if rebuild { microphoneRecovery?.routeChanged() }
    }

    /// Runs on queue. Moves to the default input when the selected microphone
    /// disconnects, and back when it returns. Only a change in the selected
    /// device's connection counts: VoiceProcessingIO's own aggregate changes the
    /// device list on every rebuild and must not trigger another one.
    private func inputDevicesChanged() {
        guard let selectedMicrophone, let recovery = microphoneRecovery else { return }
        let connected = RecordingAudioRoute.inputDevice(uid: selectedMicrophone.uid) != nil
        let rebuild = locked {
            selectedFallback.connectionChanged(connected: connected, usingSelected: microphoneRoute.usesSelectedDevice)
        }
        guard rebuild else { return }
        CaptureLog.capture.notice(
            "Selected microphone \(selectedMicrophone.name, privacy: .public) \(connected ? "connected" : "disconnected", privacy: .public); rebuilding microphone"
        )
        recovery.routeChanged()
    }

    private func sourceStateChanged(_ state: CaptureSourceState, source: String) {
        CaptureLog.capture.notice("\(source, privacy: .public) state: \(String(describing: state), privacy: .public)")
        publishHealth()
        // Start padding right away so a resumed source never appends after a large backlog.
        if state == .reconnecting { queue.async { [weak self] in self?.superviseSources() } }
    }

    private func sourceFailedPermanently(_ error: Error) {
        CaptureLog.capture.error("Source stopped permanently: \(error.localizedDescription, privacy: .public)")
        publishHealth()
        let microphoneFailed = !expectedMicrophone || microphoneRecovery?.state == .failed
        let systemFailed = !expectedSystem || systemRecovery?.state == .failed
        if microphoneFailed && systemFailed { report(error) }
    }

    private func rememberTeardownError(_ error: Error) {
        // Recovery teardown errors are expected on a lost device; report only final-stop failures.
        guard finished else { return }
        locked { if teardownError == nil { teardownError = error } }
    }

    // MARK: - Timers, health, and metadata

    private func startTimers() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in self?.publishHealth() }
        healthTimer = timer
        timer.resume()
        let recoveryTimer = DispatchSource.makeTimerSource(queue: queue)
        recoveryTimer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        recoveryTimer.setEventHandler { [weak self] in self?.superviseSources() }
        self.recoveryTimer = recoveryTimer
        recoveryTimer.resume()
        let meterTimer = DispatchSource.makeTimerSource(queue: queue)
        meterTimer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        meterTimer.setEventHandler { [weak self] in
            guard let self else { return }
            let pending: Bool = self.locked {
                let pending = self.meterDeliveryPending
                if !pending { self.meterDeliveryPending = true }
                return pending
            }
            guard !pending else { return }
            let finish = { [weak self] in
                guard let self else { return }
                self.locked { self.meterDeliveryPending = false }
            }
            if let publish = self.onLevels {
                publish(self.levelSnapshot(), finish)
            }
            else {
                finish()
            }
        }
        self.meterTimer = meterTimer
        meterTimer.resume()
    }

    /// Runs on queue once per second: keeps reconnecting tracks at pace with the
    /// host clock, and rebuilds a source whose engine runs without delivering.
    private func superviseSources() {
        let host = hostNow()
        let now = ProcessInfo.processInfo.systemUptime
        updateReconnectTargets()
        let sources: [(String, CaptureSourceState?, TimedAudioWriter?, SourceDelivery, (() -> Void)?)] = [
            (
                "microphone", microphoneRecovery?.state, microphoneWriter, locked { microphoneDelivery },
                microphoneRecovery.map { recovery in { [weak self] in self?.microphoneStalled(recovery) } }
            ),
            (
                "system audio", systemRecovery?.state, systemWriter, locked { systemDelivery },
                systemRecovery.map { recovery in { recovery.sessionInterrupted() } }
            ),
        ]
        for (source, state, writer, delivery, interrupt) in sources {
            switch state {
            case .reconnecting?, .failed?:
                // Pad in one-second steps so the writer never flushes a long outage
                // at once. Stay 0.5 s behind now so a resumed buffer is not trimmed.
                do { try writer?.padSilence(throughHostSeconds: host - 0.5) }
                catch { report(error) }
            case .running?:
                // A microphone always delivers buffers, even of silence, so one that
                // never started delivering is broken too. System audio keeps the
                // earlier rule: only a tap that delivered and then stopped.
                let watched = delivery.everDelivered || source == "microphone"
                let quiet = now - max(delivery.last, delivery.sessionStart)
                if watched, quiet > Self.deliveryWatchdog {
                    CaptureLog.capture.error(
                        "\(source, privacy: .public) watchdog: no audio for \(quiet, format: .fixed(precision: 1)) s\(delivery.sessionDelivered ? "" : " since the session started", privacy: .public)"
                    )
                    interrupt?()
                }
            default: break
            }
        }
        evaluateEcho()
    }

    /// Runs on queue. Reads the device each reconnecting source will use next,
    /// following the same choice as its rebuild, so the status can name it.
    private func updateReconnectTargets() {
        if microphoneRecovery?.state == .reconnecting {
            var target = AudioDeviceIdentity.current(output: false)
            if let selectedMicrophone, let connected = RecordingAudioRoute.inputDevice(uid: selectedMicrophone.uid),
                locked({ selectedFallback.allowsSelected(connected: true) })
            {
                target = AudioDeviceIdentity(id: connected.id, name: connected.name)
            }
            locked { microphoneDelivery.target = target }
        }
        if systemRecovery?.state == .reconnecting {
            let target = AudioDeviceIdentity.current(output: true)
            locked { systemDelivery.target = target }
        }
    }

    /// Runs on queue. A selected microphone that started but never delivered is
    /// treated like one that failed to bind: the next build uses the default input.
    private func microphoneStalled(_ recovery: CaptureSourceRecovery<MicrophoneSession>) {
        let fallBack: Bool = locked {
            guard microphoneRoute.usesSelectedDevice, !microphoneDelivery.sessionDelivered else { return false }
            selectedFallback.selectedFailed()
            return true
        }
        if fallBack {
            CaptureLog.capture.error(
                "Selected microphone delivered no audio; using the default input until it reconnects")
        }
        recovery.sessionInterrupted()
    }

    /// Runs on queue once per second. Echo only matters while the microphone is
    /// unprocessed and both sources are recording. Automatic policy turns
    /// processing on and keeps it on; an explicit Off only shows a hint.
    private func evaluateEcho() {
        guard expectedMicrophone, expectedSystem, microphoneRecovery?.state == .running,
            systemRecovery?.state == .running
        else { return }
        let turnOn: Bool = locked {
            guard !microphoneVoiceProcessing, pendingVoiceProcessing == nil else { return false }
            _ = echo.evaluate()
            echoHint = echo.echoLikely && policy == .off
            guard echo.echoLikely, policy == .automatic else { return false }
            policy = .on
            pendingVoiceProcessing = true
            pendingReason = .echoDetected
            return true
        }
        if turnOn {
            CaptureLog.capture.notice("Echo detected; turning Voice Processing on")
            microphoneRecovery?.routeChanged()
        }
    }

    private func publishHealth() {
        guard let onHealth else { return }
        onHealth(healthText())
    }

    private func healthText() -> String {
        let (microphone, system) = locked { (microphoneDelivery, systemDelivery) }
        let processed = locked { microphoneVoiceProcessing }
        var statuses: [String] = []
        if expectedMicrophone, let recovery = microphoneRecovery {
            switch recovery.state {
            case .failed:
                statuses.append("Microphone stopped · Allow microphone access in System Settings")
            case .reconnecting,
                .running where microphone.awaitingResume:
                statuses.append(
                    microphone.switchingTo(state: recovery.state).map { "Switching microphone to \($0)…" }
                        ?? "Reconnecting microphone…")
            default:
                statuses.append(
                    (microphoneWriter?.capturedFrames ?? 0) > 0
                        ? (processed
                            ? "Microphone receiving · Apple voice processing" : "Microphone receiving · unprocessed")
                        : "Microphone: no audio samples received")
            }
        }
        if expectedSystem, let recovery = systemRecovery {
            if recovery.state == .reconnecting || (recovery.state == .running && system.awaitingResume) {
                statuses.append(
                    system.switchingTo(state: recovery.state).map { "Switching system audio to \($0)…" }
                        ?? "Reconnecting system audio…")
            }
            else {
                statuses.append(
                    (systemWriter?.capturedFrames ?? 0) > 0
                        ? "System audio receiving · separate track"
                        : "System audio: no samples yet; the source may be silent")
            }
        }
        return statuses.joined(separator: " · ")
    }

    private func recordInitialRoutes() {
        if let session = initialMicrophone, let format = initialMicrophoneFormat {
            locked { _ = adoptMicrophone(session) }
            // The initial route has a reason only when it already differs from the request.
            let reason: RecordingRouteChange.Reason? =
                selectedMicrophone != nil && !session.usesSelectedDevice
                ? .selectedMicrophoneUnavailable
                : session.voiceProcessingUnavailable ? .voiceProcessingUnavailable : nil
            recordRoute(
                source: "microphone", format: format, voiceProcessed: initialVoiceProcessing,
                device: session.deviceName, reason: reason)
            initialMicrophone = nil
        }
        if let format = initialSystemFormat {
            recordRoute(
                source: "system", format: format, voiceProcessed: false, device: Self.defaultDeviceName(output: true),
                reason: nil)
        }
    }

    private func recordRoute(
        source: String, format: AVAudioFormat, voiceProcessed: Bool, device: String?,
        reason: RecordingRouteChange.Reason?
    ) {
        let change = RecordingRouteChange(
            time: max(0, hostNow() - epoch), source: source, device: device, sampleRate: format.sampleRate,
            channels: format.channelCount, voiceProcessed: voiceProcessed, reason: reason?.rawValue)
        locked { routeChanges.append(change) }
    }

    private func measure(_ buffer: AVAudioPCMBuffer, microphone: Bool, hostSeconds: TimeInterval) {
        let measured = RecordingSourceLevel.measure(buffer)
        let now = ProcessInfo.processInfo.systemUptime
        // Echo detection reuses this level: one power value per buffer, no audio copies.
        let meanSquare = measured.hasSamples ? pow(10, measured.rmsDB / 10) : 0
        let duration = buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
        let tracksEcho = expectedMicrophone && expectedSystem
        var firstInSession = false
        let resumed: Bool = locked {
            if tracksEcho {
                if microphone {
                    echo.addMicrophone(meanSquare: meanSquare, hostTime: hostSeconds, duration: duration)
                }
                else {
                    echo.addSystem(meanSquare: meanSquare, hostTime: hostSeconds, duration: duration)
                }
            }
            if microphone {
                levels.microphone = measured
                defer { microphoneDelivery.awaitingResume = false }
                firstInSession = !microphoneDelivery.sessionDelivered
                if firstInSession { microphoneDelivery.deliveredDevice = microphoneDelivery.device?.id }
                microphoneDelivery.sessionDelivered = true
                microphoneDelivery.everDelivered = true
                microphoneDelivery.last = now
                return microphoneDelivery.awaitingResume
            }
            levels.system = measured
            defer { systemDelivery.awaitingResume = false }
            firstInSession = !systemDelivery.sessionDelivered
            if firstInSession { systemDelivery.deliveredDevice = systemDelivery.device?.id }
            systemDelivery.sessionDelivered = true
            systemDelivery.everDelivered = true
            systemDelivery.last = now
            return systemDelivery.awaitingResume
        }
        // Once per session: working audio clears the recovery loop guard.
        if firstInSession {
            if microphone {
                microphoneRecovery?.sessionDelivered()
            }
            else {
                systemRecovery?.sessionDelivered()
            }
        }
        // Clear the reconnecting status as soon as audio arrives again.
        if resumed { publishHealth() }
    }

    private func levelSnapshot() -> RecordingLevels {
        let now = ProcessInfo.processInfo.systemUptime
        let microphoneState = microphoneRecovery?.state
        let systemState = systemRecovery?.state
        return locked {
            var snapshot = levels
            if now - microphoneDelivery.last > 1 { snapshot.microphone.stale = true }
            if now - systemDelivery.last > 1 { snapshot.system.stale = true }
            snapshot.microphone.reconnecting =
                microphoneState == .reconnecting || (microphoneState == .running && microphoneDelivery.awaitingResume)
            snapshot.system.reconnecting =
                systemState == .reconnecting || (systemState == .running && systemDelivery.awaitingResume)
            snapshot.microphone.switchingTo = microphoneDelivery.switchingTo(state: microphoneState)
            snapshot.system.switchingTo = systemDelivery.switchingTo(state: systemState)
            snapshot.microphoneStatus = microphoneStatus(state: microphoneState, now: now)
            return snapshot
        }
    }

    /// Call with stateLock held.
    private func microphoneStatus(state: CaptureSourceState?, now: TimeInterval) -> RecordingMicrophoneStatus {
        guard expectedMicrophone else { return RecordingMicrophoneStatus() }
        var status = RecordingMicrophoneStatus(
            voiceProcessing: pendingVoiceProcessing ?? microphoneVoiceProcessing,
            canSwitch: state == .running && pendingVoiceProcessing == nil && !microphoneDelivery.awaitingResume,
            echoDetected: echoHint)
        let device = microphoneRoute.deviceName ?? "System Default"
        if let selectedMicrophone, !microphoneRoute.usesSelectedDevice {
            status.notices.append(
                microphoneRoute.selectedDeviceUsed && !selectedFallback.failed
                    ? "\(selectedMicrophone.name) disconnected · Using \(device)"
                    : "\(selectedMicrophone.name) unavailable · Using \(device)")
        }
        if microphoneRoute.voiceProcessingUnavailable {
            status.voiceProcessingUnavailable = true
            status.notices.append("Voice Processing is unavailable for \(device)")
        }
        if now < echoNoticeUntil { status.notices.append("Echo detected · Voice Processing turned on") }
        return status
    }

    private func currentFailure() -> Error? { locked { failure } }

    private func report(_ error: Error) {
        let first: Bool = locked {
            guard failure == nil else { return false }
            failure = error
            return true
        }
        if first {
            CaptureLog.capture.fault("Recording failed: \(error.localizedDescription, privacy: .public)")
            onFailure?(error)
        }
    }

    private func prepareSystemWriter(directory: URL) throws {
        guard let format = initialSystemFormat else { return }
        try queue.sync {
            systemWriter = try TimedAudioWriter(
                url: directory.appendingPathComponent("system.wav"), format: format, epoch: epoch,
                alignedAudio: { [weak self] buffer, start in
                    self?.liveAudioSink?.append(buffer, start: start, source: .system)
                })
        }
    }

    private func hostNow() -> TimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

/// One microphone engine. Recovery discards it and builds another rather than
/// restarting an engine whose device or format changed.
final class MicrophoneSession {
    let engine = AVAudioEngine()
    var format: AVAudioFormat?
    var voiceProcessing = false
    /// Voice processing was requested but could not be enabled; recording unprocessed.
    var voiceProcessingUnavailable = false
    /// Bound to the selected microphone rather than following the default input.
    var usesSelectedDevice = false
    /// The input device when the engine was built: the selected device or the default input.
    var deviceID: AudioObjectID?
    var deviceName: String?
    var device: AudioDeviceIdentity? {
        guard let deviceID, let deviceName else { return nil }
        return AudioDeviceIdentity(id: deviceID, name: deviceName)
    }
    var configurationObserver: NSObjectProtocol?
    var tapInstalled = false

    /// Remove the observer first so teardown cannot trigger another rebuild.
    func teardown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }
}

/// Waits for the AVAudioEngineConfigurationChange that selecting an input
/// device leaves pending. Create it before binding so the notification cannot
/// be missed; it stops observing when waited on or released.
final class PendingConfigurationChange {
    /// The change posted about 0.1 s after `prepare` in measurements; a device
    /// that is already current posts none, so the wait must stay short.
    static let timeout: TimeInterval = 0.5
    private let posted = DispatchSemaphore(value: 0)
    private var observer: NSObjectProtocol?

    init(engine: AVAudioEngine) {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [posted] _ in posted.signal() }
    }

    deinit { cancel() }

    func prepareAndWait(_ engine: AVAudioEngine, step: String) {
        engine.prepare()
        wait(step: step)
    }

    /// Call after `prepare`, which is when AVAudioEngine applies the change.
    func wait(step: String) {
        let began = DispatchTime.now()
        let settled = posted.wait(timeout: began + Self.timeout) == .success
        cancel()
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000
        CaptureLog.capture.notice(
            "Microphone \(step, privacy: .public): configuration \(settled ? "settled" : "change not posted", privacy: .public) after \(milliseconds, format: .fixed(precision: 0)) ms"
        )
    }

    private func cancel() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// The microphone engine state that matters to its track. A configuration
/// notification that changes none of it (the engine still runs on the same
/// device and hardware format) needs no rebuild.
struct MicrophoneConfigurationChange: Equatable {
    var running: Bool
    var device: AudioObjectID?
    var sampleRate: Double
    var channels: AVAudioChannelCount

    func requiresRebuild(since started: Self) -> Bool {
        !(running && device == started.device && sampleRate == started.sampleRate && channels == started.channels)
    }
}

/// Decides whether a microphone build may use the selected device. After it
/// fails to bind, start, or deliver audio once, builds use the default input
/// until the device disconnects and reconnects, so a failing device costs one
/// fallback instead of a rebuild loop. Only changes in the device's connection
/// trigger rebuilds; device-list noise from capture's own aggregates does not.
struct SelectedMicrophoneFallback: Equatable {
    private(set) var failed = false
    private var connected: Bool

    init(connected: Bool) { self.connected = connected }

    func allowsSelected(connected: Bool) -> Bool { connected && !failed }

    mutating func selectedFailed() { failed = true }

    /// Returns whether the microphone should be rebuilt for this device-list change.
    mutating func connectionChanged(connected now: Bool, usingSelected: Bool) -> Bool {
        guard now != connected else { return false }
        connected = now
        if now {
            // A reconnected device gets another chance.
            failed = false
            return !usingSelected
        }
        return usingSelected
    }
}

enum CaptureSourceError: LocalizedError, Equatable {
    /// Microphone access was revoked during recording; retrying cannot recover it.
    case microphoneAccessDenied
    /// Voice processing failed on the current route or device; capture falls back to unprocessed.
    case voiceProcessing(String)
    /// The selected microphone could not be bound or stayed unbound; capture falls back to the default input.
    case selectedMicrophone(String)
    /// A recorded source captured no audio at all. The other track, if any, was saved.
    case noAudio(microphone: Bool, systemAudio: Bool, otherTrackSaved: Bool)

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            return "Microphone access is off. Available audio was saved. Allow microphone access in System Settings."
        case .voiceProcessing(let message), .selectedMicrophone(let message):
            return message
        case .noAudio(let microphone, let systemAudio, let otherTrackSaved):
            // The first sentence is the alert title (LibraryView.alertParts).
            let microphoneHelp =
                "Check the microphone selected in New Recording and microphone access in System Settings → Privacy & Security."
            let systemHelp =
                "Allow Gday Meetings in System Settings → Privacy & Security → Screen & System Audio Recording."
            switch (microphone, systemAudio) {
            case (true, true):
                return "Microphone and System Audio recorded no audio. \(microphoneHelp) \(systemHelp)"
            case (true, false):
                return "Microphone recorded no audio. "
                    + (otherTrackSaved ? "The System Audio track was saved. " : "") + microphoneHelp
            default:
                return "System Audio recorded no audio. "
                    + (otherTrackSaved ? "The Microphone track was saved. " : "") + systemHelp
            }
        }
    }

    /// A finished recording with an empty source, as opposed to a capture failure.
    var isNoAudio: Bool {
        if case .noAudio = self { return true }
        return false
    }
}

struct RecordingLevels: Equatable {
    var microphone = RecordingSourceLevel()
    var system = RecordingSourceLevel()
    var microphoneStatus = RecordingMicrophoneStatus()
}
/// Live Voice Processing state and automatic-choice explanations for the recording view.
struct RecordingMicrophoneStatus: Equatable {
    var voiceProcessingUnavailable = false
    /// The switch position: a requested change while it applies, otherwise the running engine's state.
    var voiceProcessing = false
    /// False while the microphone rebuilds or reconnects.
    var canSwitch = false
    /// Echo is likely while Voice Processing is off by choice.
    var echoDetected = false
    /// Explanations of automatic choices, most lasting first.
    var notices: [String] = []
}
struct RecordingSourceLevel: Equatable {
    var enabled = false
    var hasSamples = false
    var stale = false
    /// The source's device is being replaced; earlier levels no longer apply.
    var reconnecting = false
    /// While reconnecting: the name of the different device the source is moving to, if known.
    var switchingTo: String?
    var rmsDB: Double = -120
    var peakDB: Double = -120
    var level: Double { enabled && hasSamples && !stale && !reconnecting ? min(1, max(0, (rmsDB + 60) / 60)) : 0 }
    var statusText: String {
        if !enabled { return "Not recording" }
        if reconnecting { return switchingTo.map { "Switching to \($0)…" } ?? "Reconnecting…" }
        if !hasSamples { return "Waiting for audio" }
        if stale { return "No recent audio" }
        return rmsDB < -60 ? "Quiet" : "Receiving audio"
    }
    static func measure(_ buffer: AVAudioPCMBuffer) -> Self {
        // Scalar snapshots only: no sample history, audio copies, or UI work here.
        guard buffer.format.commonFormat == .pcmFormatFloat32, buffer.frameLength > 0 else {
            return Self(enabled: true)
        }
        var sumSquares: Float = 0
        var maximum: Float = 0
        var sampleCount = 0
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audio.mData else { continue }
            let count = min(
                Int(audio.mDataByteSize) / MemoryLayout<Float>.size,
                frameCount * (buffer.format.isInterleaved ? channels : 1))
            guard count > 0 else { continue }
            var energy: Float = 0
            var peak: Float = 0
            vDSP_svesq(data.assumingMemoryBound(to: Float.self), 1, &energy, vDSP_Length(count))
            vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &peak, vDSP_Length(count))
            sumSquares += energy
            maximum = max(maximum, peak)
            sampleCount += count
        }
        guard sampleCount > 0, sumSquares.isFinite, maximum.isFinite else { return Self(enabled: true) }
        return Self(
            enabled: true, hasSamples: true,
            rmsDB: 20 * log10(max(1e-6, sqrt(Double(sumSquares) / Double(sampleCount)))),
            peakDB: 20 * log10(max(1e-6, Double(maximum))))
    }
}
