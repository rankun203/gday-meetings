import AVFoundation
import Combine
import Foundation

/// One app-owned transport survives navigation and is shared by every window.
/// HIG Playing Audio / Accessibility: sound starts only through explicit playback
/// controls, respects system output volume, and remains independently pausable.
/// https://developer.apple.com/design/human-interface-guidelines/playing-audio
/// https://developer.apple.com/design/human-interface-guidelines/accessibility
@MainActor
final class MeetingPlayback: ObservableObject {
    @Published private(set) var meetingID: UUID? {
        didSet { progress.setMeeting(meetingID) }
    }
    @Published private(set) var title = ""
    @Published private(set) var trackNames: [String] = []
    @Published private(set) var selectedTrack = -1
    @Published private(set) var isPlaying = false {
        didSet { progress.isPlaying = isPlaying }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var hasEnded = false
    // Only timeline views observe the clock; a tick must not invalidate menus,
    // the meeting editor, or the navigation hierarchy.
    let progress = PlaybackProgress()
    private(set) var currentTime: Double {
        get { progress.time }
        set { progress.update(newValue) }
    }
    @Published private(set) var duration: Double = 0
    @Published private(set) var playbackRate: Double = 1 {
        didSet { progress.rate = playbackRate }
    }
    @Published private(set) var isPlaybackBlocked = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var trackErrors: [Int: String] = [:]
    @Published private(set) var waveforms: [AudioWaveform?] = []
    @Published private(set) var isLoadingWaveforms = false
    @Published private(set) var mutedTracks: Set<Int> = []
    @Published private(set) var excerptRange: Range<Double>?
    @Published private(set) var excerptRanges: [Range<Double>] = []
    private var excerptIndex = 0
    var hasSelection: Bool { meetingID != nil }

    /// Original library file, independent of the currently browsed meeting or decoder temporaries.
    func audioURL(forTrack index: Int) -> URL? {
        sourceFiles.indices.contains(index) ? sourceFiles[index] : nil
    }

    typealias AudioPreparer = @Sendable (URL) async throws -> PreparedPlaybackAudio
    typealias WaveformLoader = @Sendable (URL, URL) async throws -> AudioWaveform
    private let prepareAudio: AudioPreparer
    private let readWaveform: WaveformLoader
    private var transport: StreamingPlayback?
    private var transportNeedsReload = false
    private var playTask: Task<Void, Never>?
    private var sourceMeeting: Meeting?
    private var sourceFiles: [URL] = []
    private var temporaryURLs: [URL] = []
    private var preparationTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var generation = UUID()
    private var seekGeneration = UUID()
    private var wantsPlayback = false
    private var playbackIntent = UUID()
    private var pendingPosition: Double = 0
    private var isSeeking = false
    init(
        readWaveform: @escaping WaveformLoader = { source, readable in
            try await WaveformCache.shared.waveform(source: source, readable: readable)
        }, prepareAudio: @escaping AudioPreparer = { url in PreparedPlaybackAudio(url: url, temporary: false) }
    ) {
        self.prepareAudio = prepareAudio
        self.readWaveform = readWaveform
    }

    deinit {
        preparationTask?.cancel()
        seekTask?.cancel()
        playTask?.cancel()
        waveformTask?.cancel()
        cacheTask?.cancel()
        transport?.close(removing: temporaryURLs)
    }

    /// Resolve a cold meeting without allowing a late load to undo a newer transport action.
    @discardableResult
    func requestPlayback(
        load: @escaping @MainActor () async -> Meeting?,
        play: @escaping @MainActor (Meeting) -> Void
    ) -> Task<Void, Never> {
        let intent = UUID()
        playbackIntent = intent
        return Task { @MainActor [weak self] in
            guard let meeting = await load(), let self, !Task.isCancelled,
                self.playbackIntent == intent, !self.isPlaybackBlocked
            else { return }
            play(meeting)
        }
    }

    /// Selection prepares a paused item. Browsing elsewhere never needs to call this.
    func select(meeting: Meeting, files: [URL], track: Int = -1) {
        playbackIntent = UUID()
        guard !isPlaybackBlocked else { return }
        let track = Self.validTrack(track, count: files.count)
        if meetingID == meeting.id, sourceFiles == files, selectedTrack == track, errorMessage == nil,
            !transportNeedsReload
        {
            title = meeting.title
            sourceMeeting = meeting
            return
        }
        let sameMeeting = meetingID == meeting.id
        load(meeting: meeting, files: files, track: track, position: sameMeeting ? currentTime : 0, autoplay: false)
    }

    func play(meeting: Meeting, files: [URL], at position: Double = 0) {
        playbackIntent = UUID()
        guard !isPlaybackBlocked else { return }
        excerptRange = nil
        excerptRanges = []
        excerptIndex = 0
        if meetingID == meeting.id, sourceFiles == files, errorMessage == nil, !transportNeedsReload {
            title = meeting.title
            sourceMeeting = meeting
            wantsPlayback = true
            seek(to: position)
            return
        }
        load(meeting: meeting, files: files, track: -1, position: position, autoplay: true)
        progress.seek(to: currentTime)
    }

    /// Review an exact source excerpt through the shared player. The transport
    /// bounds decoding so speech beyond the excerpt never enters its audio ring.
    func playExcerpt(meeting: Meeting, directory: URL, audioFile: String, start: Double, end: Double) {
        playExcerpts(
            meeting: meeting, directory: directory, audioFile: audioFile,
            spans: [.init(start: start, end: end)])
    }

    /// Each fragment has its own decoder bound. Intervening speech is never played.
    func playExcerpts(meeting: Meeting, directory: URL, audioFile: String, spans: [SpeakerEvidenceSpan]) {
        guard !spans.isEmpty, spans.allSatisfy(\.isValid),
            zip(spans, spans.dropFirst()).allSatisfy({ $0.end <= $1.start })
        else { return }
        let start = spans[0].start
        let end = spans[0].end
        playbackIntent = UUID()
        guard !isPlaybackBlocked else { return }
        guard start.isFinite, end.isFinite, start >= 0, end > start,
            meeting.audioFiles.contains(audioFile), URL(fileURLWithPath: audioFile).lastPathComponent == audioFile,
            audioFile != ".", audioFile != ".."
        else {
            errorMessage = "This voice example has no playable audio range."
            return
        }
        let files = meeting.audioFiles.filter {
            URL(fileURLWithPath: $0).lastPathComponent == $0 && $0 != "." && $0 != ".."
        }.map { directory.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let track = files.firstIndex(where: { $0.lastPathComponent == audioFile }) else {
            errorMessage = "The audio for this voice example is unavailable."
            return
        }
        load(meeting: meeting, files: files, track: track, position: start, autoplay: true)
        excerptRanges = spans.map { $0.start..<$0.end }
        excerptIndex = 0
        excerptRange = start..<end
        progress.seek(to: start)
    }

    func play() {
        playbackIntent = UUID()
        guard hasSelection, !isPlaybackBlocked else { return }
        if errorMessage != nil || transportNeedsReload {
            guard let meeting = sourceMeeting else { return }
            let range = excerptRange
            let ranges = excerptRanges
            let index = excerptIndex
            load(meeting: meeting, files: sourceFiles, track: selectedTrack, position: currentTime, autoplay: true)
            excerptRange = range
            excerptRanges = ranges
            excerptIndex = index
            return
        }
        wantsPlayback = true
        if isLoading { return }
        guard transport != nil else { return }
        if hasEnded || (duration > 0 && currentTime >= duration) {
            if let first = excerptRanges.first {
                excerptIndex = 0
                excerptRange = first
            }
            seek(to: excerptRange?.lowerBound ?? 0)
        }
        else {
            startPlayback()
        }
    }

    func pause() {
        playbackIntent = UUID()
        wantsPlayback = false
        playTask?.cancel()
        transport?.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        if wantsPlayback || isPlaying {
            pause()
        }
        else {
            play()
        }
    }

    func seek(to seconds: Double) {
        playbackIntent = UUID()
        guard hasSelection, seconds.isFinite else { return }
        if let range = excerptRange, seconds < range.lowerBound || seconds > range.upperBound {
            excerptRange = nil
            excerptRanges = []
            excerptIndex = 0
        }
        let target = duration > 0 ? Self.clampedTime(seconds, duration: duration) : max(0, seconds)
        pendingPosition = target
        progress.seek(to: target)
        hasEnded = duration > 0 && target >= duration
        if isLoading { return }
        guard let transport else { return }
        seekTask?.cancel()
        playTask?.cancel()
        let operation = UUID()
        seekGeneration = operation
        let currentGeneration = generation
        let end = excerptRange?.upperBound
        isSeeking = true
        isPlaying = false
        seekTask = Task { [weak self] in
            do {
                try await transport.seek(to: target, revision: operation, end: end)
                guard let self, !Task.isCancelled, self.generation == currentGeneration,
                    self.seekGeneration == operation
                else { return }
                self.isSeeking = false
                if self.wantsPlayback, !self.isPlaybackBlocked, !self.hasEnded {
                    self.startPlayback()
                }
                else if self.hasEnded {
                    self.pause()
                }
            }
            catch is CancellationError {}
            catch {
                guard let self, self.generation == currentGeneration, self.seekGeneration == operation else { return }
                self.isSeeking = false
                self.pause()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func startPlayback() {
        if transportNeedsReload {
            play()
            return
        }
        guard let transport, !isSeeking else { return }
        let operation = generation
        playTask?.cancel()
        playTask = Task { [weak self] in
            guard let self, self.wantsPlayback, !self.isPlaybackBlocked else { return }
            do { try await transport.play(rate: self.playbackRate) }
            catch is CancellationError {}
            catch {
                guard self.generation == operation else { return }
                self.pause()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func skip(by seconds: Double) { seek(to: currentTime + seconds) }

    func setRate(_ rate: Double) {
        guard rate.isFinite else { return }
        playbackRate = min(2, max(0.5, rate))
        transport?.setRate(playbackRate)
    }

    func selectTrack(_ track: Int) {
        guard hasSelection, !isPlaybackBlocked, !isLoading else { return }
        guard trackErrors[track] == nil else { return }
        selectedTrack = Self.validTrack(track, count: sourceFiles.count)
        mutedTracks = selectedTrack < 0 ? [] : Set(sourceFiles.indices.filter { $0 != selectedTrack })
        applyMix()
    }

    func toggleMute(_ index: Int) {
        guard sourceFiles.indices.contains(index), trackErrors[index] == nil, !isPlaybackBlocked, !isLoading else {
            return
        }
        if mutedTracks.contains(index) {
            mutedTracks.remove(index)
        }
        else {
            mutedTracks.insert(index)
        }
        let audible = sourceFiles.indices.filter { trackErrors[$0] == nil && !mutedTracks.contains($0) }
        selectedTrack = audible.count == 1 ? audible[0] : -1
        applyMix()
    }

    private func applyMix() {
        transport?.setMuted(mutedTracks)
    }

    /// Recording prevents the app's own audio from feeding back into the new meeting.
    /// Ending recording does not surprise the person by resuming audio automatically.
    func setRecordingActive(_ active: Bool) {
        isPlaybackBlocked = active
        if active { pause() }
    }

    func reconcile(meetings: [Meeting]) {
        guard let id = meetingID else { return }
        guard let meeting = meetings.first(where: { $0.id == id }) else {
            clear()
            return
        }
        title = meeting.title
        if sourceMeeting?.audioFiles != meeting.audioFiles {
            // The owner resolves URLs when starting the new recording revision.
            // Release old assets now so removed/replaced files cannot keep playing.
            clear()
        }
        else {
            sourceMeeting = meeting
        }
    }

    func clear() {
        playbackIntent = UUID()
        excerptRange = nil
        excerptRanges = []
        excerptIndex = 0
        progress.scrub(to: nil)
        generation = UUID()
        seekGeneration = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        waveformTask?.cancel()
        waveformTask = nil
        cacheTask?.cancel()
        cacheTask = nil
        seekTask?.cancel()
        seekTask = nil
        releaseCurrentItem()
        sourceMeeting = nil
        sourceFiles = []
        meetingID = nil
        title = ""
        trackNames = []
        selectedTrack = -1
        waveforms = []
        mutedTracks = []
        isLoadingWaveforms = false
        currentTime = 0
        duration = 0
        pendingPosition = 0
        isLoading = false
        isSeeking = false
        hasEnded = false
        errorMessage = nil
        trackErrors = [:]
    }

    /// Lets lifecycle/fixture checks await owned work without depending on UI sleeps.
    func waitForPreparation() async { await preparationTask?.value }
    func waitForWaveforms() async { await waveformTask?.value }
    func waitForCachedWaveforms() async { await cacheTask?.value }

    static func clampedTime(_ seconds: Double, duration: Double) -> Double {
        guard seconds.isFinite, duration.isFinite else { return 0 }
        return min(max(0, seconds), max(0, duration))
    }

    private static func validTrack(_ track: Int, count: Int) -> Int { track >= 0 && track < count ? track : -1 }

    private func load(meeting: Meeting, files: [URL], track: Int, position: Double, autoplay: Bool) {
        excerptRange = nil
        excerptRanges = []
        excerptIndex = 0
        progress.scrub(to: nil)
        generation = UUID()
        let operation = generation
        preparationTask?.cancel()
        seekTask?.cancel()
        waveformTask?.cancel()
        cacheTask?.cancel()
        releaseCurrentItem()
        sourceMeeting = meeting
        sourceFiles = files
        meetingID = meeting.id
        title = meeting.title
        selectedTrack = track
        waveforms = Array(repeating: nil, count: files.count)
        mutedTracks = track < 0 ? [] : Set(files.indices.filter { $0 != track })
        isLoadingWaveforms = !files.isEmpty
        trackNames = files.map { file in
            let name = file.deletingPathExtension().lastPathComponent
            return name == "microphone" ? "Microphone" : name == "system" ? "System Audio" : name
        }
        errorMessage = nil
        trackErrors = [:]
        hasEnded = false
        isSeeking = false
        duration = 0
        currentTime = max(0, position.isFinite ? position : 0)
        pendingPosition = currentTime
        wantsPlayback = autoplay && !isPlaybackBlocked
        guard !files.isEmpty else {
            errorMessage = "This meeting has no audio files to play."
            isLoading = false
            return
        }
        isLoading = true
        // Read small cached envelopes independently, even while an Opus source is
        // still being prepared. Never wait for waveform work to begin playback.
        cacheTask = Task { [weak self] in
            for (index, file) in files.enumerated() {
                guard !Task.isCancelled else { return }
                let cached = await WaveformCache.shared.cached(file)
                guard let self, self.generation == operation, !Task.isCancelled else { return }
                if let cached, self.waveforms[index] == nil {
                    self.waveforms[index] = cached
                    if self.isLoading, self.trackErrors[index] == nil {
                        self.duration = max(self.duration, cached.duration)
                    }
                }
            }
        }
        let prepare = prepareAudio
        let readWaveform = readWaveform
        preparationTask = Task { [weak self] in
            var temporary: [URL] = []
            var transferred = false
            let transport = StreamingPlayback(silent: UIPreview.enabled)
            do {
                var readableFiles: [URL] = []
                var preparationErrors: [Int: String] = [:]
                for (index, file) in files.enumerated() {
                    try Task.checkCancellation()
                    do {
                        let prepared = try await prepare(file)
                        if prepared.temporary { temporary.append(prepared.url) }
                        readableFiles.append(prepared.url)
                    }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        preparationErrors[index] = error.localizedDescription
                        readableFiles.append(file)
                    }
                }
                try Task.checkCancellation()
                transport.onUpdate = { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self, self.generation == operation else { return }
                        let errors = self.trackErrors.merging(snapshot.trackErrors) { _, new in new }
                        if self.trackErrors != errors { self.trackErrors = errors }
                        if snapshot.requiresReload { self.transportNeedsReload = true }
                        guard self.seekGeneration == snapshot.revision,
                            !self.isSeeking
                        else { return }
                        self.currentTime = snapshot.time
                        let playing = snapshot.playing && self.wantsPlayback && !self.isPlaybackBlocked
                        if self.isPlaying != playing { self.isPlaying = playing }
                        if snapshot.ended {
                            if snapshot.error == nil, self.wantsPlayback, !self.isPlaybackBlocked,
                                self.excerptIndex + 1 < self.excerptRanges.count
                            {
                                self.excerptIndex += 1
                                self.excerptRange = self.excerptRanges[self.excerptIndex]
                                self.seek(to: self.excerptRanges[self.excerptIndex].lowerBound)
                            }
                            else {
                                self.hasEnded = true
                                self.wantsPlayback = false
                            }
                        }
                        if let error = snapshot.error {
                            self.pause()
                            self.errorMessage = error
                        }
                    }
                }
                let length = try await transport.prepare(files: readableFiles, unavailableTracks: preparationErrors)
                try Task.checkCancellation()
                guard let self, self.generation == operation else { throw CancellationError() }
                self.transport = transport
                self.temporaryURLs = temporary
                transferred = true
                self.duration = length
                self.applyMix()
                self.isLoading = false
                self.seek(to: self.pendingPosition)
                self.waveformTask = Task { [weak self] in
                    for (index, readable) in readableFiles.enumerated() {
                        guard !Task.isCancelled else { return }
                        guard self?.trackErrors[index] == nil else { continue }
                        let envelope = try? await readWaveform(files[index], readable)
                        guard let self, self.generation == operation, !Task.isCancelled else { return }
                        if let envelope { self.waveforms[index] = envelope }
                    }
                    guard let self, self.generation == operation else { return }
                    self.isLoadingWaveforms = false
                }
            }
            catch is CancellationError {
                // Replacing/clearing selection owns the published state; stale work only cleans up.
            }
            catch {
                if let self, self.generation == operation, !Task.isCancelled {
                    self.pause()
                    self.isLoading = false
                    self.isLoadingWaveforms = false
                    self.errorMessage = "Unable to load meeting audio: " + error.localizedDescription
                }
            }
            if !transferred { await transport.shutdown(removing: temporary) }
        }
    }

    private func releaseCurrentItem() {
        pause()
        transport?.close(removing: temporaryURLs)
        transport = nil
        transportNeedsReload = false
        temporaryURLs = []
    }

}

@MainActor
final class PlaybackProgress: ObservableObject {
    struct Snapshot: Equatable {
        var meetingID: UUID?
        var time: Double = 0
        var scrubTime: Double?
        var isPlaying = false
        var rate: Double = 1
        var seekRevision: UInt64 = 0
        var displayedTime: Double { scrubTime ?? time }
    }
    @Published private(set) var snapshot = Snapshot()
    var time: Double { snapshot.time }
    var scrubTime: Double? { snapshot.scrubTime }
    var isPlaying: Bool {
        get { snapshot.isPlaying }
        set {
            guard newValue != snapshot.isPlaying else { return }
            snapshot.isPlaying = newValue
        }
    }
    var rate: Double {
        get { snapshot.rate }
        set {
            guard newValue != snapshot.rate else { return }
            snapshot.rate = newValue
        }
    }
    private var sampledAt = ProcessInfo.processInfo.systemUptime

    func setMeeting(_ id: UUID?) {
        guard id != snapshot.meetingID else { return }
        var next = snapshot
        next.meetingID = id
        next.time = 0
        next.scrubTime = nil
        next.isPlaying = false
        sampledAt = ProcessInfo.processInfo.systemUptime
        snapshot = next
    }

    /// Seek intent and its position arrive atomically through the shared clock.
    /// Subscribers decide whether to reveal the position; controls never address them.
    func seek(to value: Double) {
        guard value.isFinite else { return }
        var next = snapshot
        next.time = value
        next.scrubTime = nil
        next.seekRevision &+= 1
        sampledAt = ProcessInfo.processInfo.systemUptime
        snapshot = next
    }

    /// Briefly interpolate between audio samples, but never run away on stalls.
    func animatedTime(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        guard scrubTime == nil, isPlaying else { return displayedTime }
        return time + min(0.05, max(0, uptime - sampledAt)) * rate
    }
    var displayedTime: Double { snapshot.displayedTime }
    func scrub(to value: Double?) {
        guard value == nil || value!.isFinite, scrubTime != value else { return }
        snapshot.scrubTime = value
    }
    func update(_ value: Double, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard value.isFinite, value != time else { return }
        sampledAt = uptime
        snapshot.time = value
    }
}
