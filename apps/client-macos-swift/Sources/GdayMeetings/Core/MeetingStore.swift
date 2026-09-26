import AVFoundation
import Combine
import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    @Published var contextualChats: [String: [ChatMessage]] = [:]
    @Published var meetings: [Meeting] = []
    @Published var people: [Person] = []
    @Published var tags: [MeetingTag] = []
    @Published var settings = AppSettings()
    @Published var providerLanguageStates: [ProviderLanguageIdentity: ProviderLanguageState] = [:]
    /// Saved language and model lists. providerLanguageStates holds only loading and failure.
    lazy var providerLanguageCache = ProviderMetadataCache<ProviderLanguageCatalog>(
        directory: dataDirectory, fileName: "provider-languages.json",
        canWrite: { [unowned self] in self.canSave })
    lazy var providerModelCache = ProviderMetadataCache<[ProviderModel]>(
        directory: dataDirectory, fileName: "provider-models.json",
        canWrite: { [unowned self] in self.canSave })
    var providerLanguageTasks: [ProviderLanguageIdentity: Task<ProviderLanguageCatalog, Error>] = [:]
    var providerLanguageLoader: @MainActor (ServiceProvider) async throws -> ProviderLanguageCatalog = {
        try await ProviderLanguageService.catalog(for: $0)
    }
    @Published var recordingID: UUID?
    @Published var presentsRecordingSetup = false
    /// Transcription, summaries, chat, archiving, and imports in progress; see
    /// BackgroundJobs.swift. Change only through beginJob and endJob. Jobs never
    /// block recording. Progress is transient: outcomes appear in the content
    /// itself, and failures use errorMessage.
    @Published var backgroundJobs: [BackgroundJob] = []
    @Published var errorMessage: String?
    @Published var recordingPermissionNeeded: RecordingPermission?
    /// Capture diagnostics text. Not shown in the interface, so it is not published:
    /// a change must not re-render every view observing the store.
    var captureHealth = ""
    @Published var recordingStartedAt: Date?
    @Published var isFinalizingRecording = false
    @Published private(set) var isStartingRecording = false
    /// 10 Hz meter state lives outside the store's publisher; only the meters observe it.
    let recordingMeter = RecordingMeterState()
    let liveTranscript = LiveTranscriptController()
    var recordingLevels: RecordingLevels { recordingMeter.levels }
    let dataDirectory: URL
    lazy var notesStorage = NotesStorage(directory: dataDirectory)
    private var recorder: AudioCapture?
    private var captureTransition = false
    private var activeRecordingFormat: RecordingFormat = .opus
    private var canSave = true
    private var lastSavedLibrary = MeetingLibrary()
    var libraryWritable: Bool { canSave }
    /// Set when library.json has a newer format version; the library is then read-only.
    @Published private(set) var newerLibraryVersion: Int?
    /// Derived from each meeting's server-archive.json; see ServerArchive.swift.
    @Published var archiveStatuses: [UUID: MeetingArchiveStatus] = [:]
    private let usesKeychain: Bool
    private var savedProviderKeys: [String: String] = [:]
    private var unreadableProviderKeys = Set<String>()
    var recordingDuration: TimeInterval { recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    /// Only the recording lifecycle and a read-only library prevent a new
    /// recording; background jobs for other meetings never do.
    var canStartRecording: Bool {
        recordingID == nil && !isStartingRecording && !isFinalizingRecording && !captureTransition && canSave
    }

    init(dataDirectory: URL? = nil) {
        let dataDirectory =
            dataDirectory
            ?? ProcessInfo.processInfo.environment["GDAY_SWIFT_DATA_DIR"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
        usesKeychain = dataDirectory == nil
        self.dataDirectory = dataDirectory ?? LibraryLocation.directory()
        do {
            if dataDirectory == nil { try LibraryLocation.migrateLegacyLibrary() }
            try FileManager.default.createDirectory(
                at: self.dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let libraryURL = self.dataDirectory.appendingPathComponent("library.json")
            var migrated = false
            if FileManager.default.fileExists(atPath: libraryURL.path) {
                let loaded = try MeetingLibrary.load(from: libraryURL)
                let library = loaded.library
                migrated = loaded.migrated
                meetings = library.meetings
                people = library.people
                tags = library.tags
                contextualChats = library.contextualChats
            }
            let settingsURL = self.dataDirectory.appendingPathComponent("settings.json")
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                settings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsURL))
            }
            for index in meetings.indices {
                meetings[index].notes = try notesStorage.load(meetings[index].id, fallback: meetings[index].notes)
            }
            notesStorage.onError = { [weak self] error in
                self?.errorMessage = "Couldn’t save meeting notes. \(error.localizedDescription)"
            }
            lastSavedLibrary = MeetingLibrary(
                contextualChats: contextualChats, meetings: meetings, people: people, tags: tags)
            if migrated { save() }
            refreshArchiveStatuses()
            if usesKeychain {
                for index in settings.serviceProviders.indices {
                    let account = ProviderCredentialPersistence.account(for: settings.serviceProviders[index])
                    do {
                        let key = try KeychainStore.get(account) ?? ""
                        settings.serviceProviders[index].apiKey = key
                        savedProviderKeys[account] = key
                    }
                    catch {
                        unreadableProviderKeys.insert(account)
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        catch let error as NewerLibraryVersionError {
            // Every write path checks canSave, so the newer library stays untouched.
            canSave = false
            newerLibraryVersion = error.version
            errorMessage = error.localizedDescription
        }
        catch {
            canSave = false
            errorMessage =
                "Could not open the local library. Existing files have been preserved. \(error.localizedDescription)"
        }
    }
    @discardableResult private func save() -> Bool {
        guard canSave else {
            errorMessage =
                newerLibraryVersion != nil
                ? NewerLibraryVersionError.message
                : "Library is read-only because loading failed. Restore library.json before saving changes."
            return false
        }
        do {
            try notesStorage.flushAll()
            for meeting in meetings where notesStorage.saved[meeting.id] != meeting.notes {
                try notesStorage.write(meeting.id, text: meeting.notes)
            }
            let encoder = JSONEncoder()
            encoder.userInfo[.notesInSidecars] = true
            let data = try encoder.encode(
                MeetingLibrary(contextualChats: contextualChats, meetings: meetings, people: people, tags: tags))
            try data.write(to: dataDirectory.appendingPathComponent("library.json"), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: dataDirectory.appendingPathComponent("library.json").path)
            lastSavedLibrary = MeetingLibrary(
                contextualChats: contextualChats, meetings: meetings, people: people, tags: tags)
            return true
        }
        catch {
            meetings = lastSavedLibrary.meetings.map { old in
                var recovered = old
                recovered.notes = notesStorage.pending[old.id] ?? notesStorage.saved[old.id] ?? old.notes
                return recovered
            }
            people = lastSavedLibrary.people
            tags = lastSavedLibrary.tags
            contextualChats = lastSavedLibrary.contextualChats
            errorMessage = "Could not save changes: \(error.localizedDescription)"
            return false
        }
    }
    func saveContextChat(key: String, messages: [ChatMessage]) {
        guard canSave else { return }
        contextualChats[key] = messages
        save()
    }
    @discardableResult func saveSettings() -> Bool {
        guard canSave else {
            errorMessage =
                newerLibraryVersion != nil
                ? NewerLibraryVersionError.message
                : "Restore the local library before changing settings."
            return false
        }
        do {
            let settingsData = try JSONEncoder().encode(settings)
            let persist = {
                try ProviderCredentialPersistence.writeSettings(
                    settingsData, to: self.dataDirectory.appendingPathComponent("settings.json"))
            }
            if usesKeychain {
                // Read failed credentials before changing any item, including keys
                // belonging to providers removed from the draft settings.
                var previous = savedProviderKeys
                for account in unreadableProviderKeys {
                    previous[account] = try KeychainStore.get(account) ?? ""
                }
                var next: [String: String] = [:]
                for provider in settings.serviceProviders {
                    let account = ProviderCredentialPersistence.account(for: provider)
                    if unreadableProviderKeys.contains(account), provider.apiKey.isEmpty {
                        next[account] = previous[account]
                    }
                    else {
                        next[account] = provider.apiKey
                    }
                }
                try ProviderCredentialPersistence.save(
                    previous: previous, next: next,
                    write: { try KeychainStore.set($1, for: $0) },
                    remove: { try KeychainStore.delete($0) }, persistSettings: persist)
                savedProviderKeys = next
                unreadableProviderKeys.removeAll()
                for index in settings.serviceProviders.indices {
                    let account = ProviderCredentialPersistence.account(for: settings.serviceProviders[index])
                    settings.serviceProviders[index].apiKey = next[account] ?? ""
                }
            }
            else {
                try persist()
            }
        }
        catch {
            errorMessage = error.localizedDescription
            return false
        }
        return true
    }
    func insertImportedMeeting(_ meeting: Meeting) throws {
        guard canSave else { throw MeetingError.message("The library is read-only because loading failed.") }
        meetings.insert(meeting, at: 0)
        guard save() else { throw MeetingError.message(errorMessage ?? "Could not save imported meeting.") }
    }
    @discardableResult func createMeeting(title: String = "Untitled Meeting", language: String? = nil) -> UUID {
        guard canSave else { return UUID() }
        let meeting = Meeting(title: title, language: language ?? settings.defaultLanguage)
        meetings.insert(meeting, at: 0)
        save()
        return meeting.id
    }
    func updateMeeting(_ meeting: Meeting) {
        guard canSave else { return }
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[i] = meeting
            save()
        }
    }
    func deleteMeeting(id: UUID) {
        guard canSave else { return }
        guard recordingID != id else {
            errorMessage = "Stop recording before deleting this meeting."
            return
        }
        guard !backgroundJobs.contains(where: { $0.meetingID == id }) else {
            errorMessage = "Wait for this meeting’s background tasks to finish before deleting it."
            return
        }
        do {
            try notesStorage.flush(id)
            let original = meetings
            meetings.removeAll { $0.id == id }
            guard save() else { return }
            let folder = directory(for: id)
            do {
                if FileManager.default.fileExists(atPath: folder.path) {
                    _ = try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                }
                notesStorage.discard(id)
            }
            catch {
                meetings = original
                save()
                throw error
            }
        }
        catch { errorMessage = error.localizedDescription }
    }
    @discardableResult func addPerson(name: String) -> UUID {
        guard canSave else { return UUID() }
        let person = Person(name: name)
        people.append(person)
        save()
        return person.id
    }
    func updatePerson(_ person: Person) {
        guard canSave else { return }
        if let i = people.firstIndex(where: { $0.id == person.id }) {
            people[i] = person
            save()
        }
    }
    func deletePerson(id: UUID) {
        guard canSave else { return }
        people.removeAll { $0.id == id }
        contextualChats.removeValue(forKey: Self.contextChatKey(personID: id))
        for i in meetings.indices {
            meetings[i].personIDs.removeAll { $0 == id }
            for speaker in meetings[i].speakers.indices where meetings[i].speakers[speaker].personID == id {
                meetings[i].speakers[speaker].personID = nil
                meetings[i].speakers[speaker].confidence = nil
                meetings[i].speakers[speaker].confirmed = false
            }
        }
        save()
    }
    @discardableResult func addTag(name: String, color: String = "blue") -> UUID {
        guard canSave else { return UUID() }
        let tag = MeetingTag(name: name, color: color)
        tags.append(tag)
        save()
        return tag.id
    }
    func updateTag(_ tag: MeetingTag) {
        guard canSave else { return }
        if let i = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[i] = tag
            save()
        }
    }
    func deleteTag(id: UUID) {
        guard canSave else { return }
        tags.removeAll { $0.id == id }
        contextualChats.removeValue(forKey: Self.contextChatKey(tagID: id))
        for i in meetings.indices { meetings[i].tagIDs.removeAll { $0 == id } }
        save()
    }
    func directory(for id: UUID) -> URL { dataDirectory.appendingPathComponent(id.uuidString, isDirectory: true) }
    func audioURLs(for meeting: Meeting) -> [URL] {
        meeting.audioFiles.filter { URL(fileURLWithPath: $0).lastPathComponent == $0 && !$0.contains("..") }.map {
            directory(for: meeting.id).appendingPathComponent($0)
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    func audioURL(for meeting: Meeting) -> URL? { audioURLs(for: meeting).first }

    func startRecording(
        title: String? = nil, language: String? = nil, microphoneEnabled: Bool? = nil, systemEnabled: Bool? = nil,
        format: RecordingFormat? = nil
    ) async {
        guard !UIPreview.enabled else {
            errorMessage = "Recording is disabled in UI Preview."
            return
        }
        guard canStartRecording else { return }
        let microphone = microphoneEnabled ?? settings.captureMicrophone
        let systemAudio = systemEnabled ?? settings.captureSystemAudio
        isStartingRecording = true
        defer { isStartingRecording = false }
        recordingMeter.reset(
            RecordingLevels(
                microphone: RecordingSourceLevel(enabled: microphone),
                system: RecordingSourceLevel(enabled: systemAudio)))
        recordingPermissionNeeded = nil
        captureTransition = true
        activeRecordingFormat = format ?? settings.recordingFormat
        let suppliedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let meeting = Meeting(
            title: suppliedTitle.isEmpty ? Date().formatted(date: .abbreviated, time: .shortened) : suppliedTitle,
            language: language ?? settings.defaultLanguage)
        do {
            try FileManager.default.createDirectory(at: directory(for: meeting.id), withIntermediateDirectories: true)
            let capture = AudioCapture()
            let liveSink = LiveAudioSink()
            capture.liveAudioSink = liveSink
            capture.onLevels = { [weak self] levels, delivered in
                Task { @MainActor in
                    defer { delivered() }
                    if self?.recordingID == meeting.id && self?.isFinalizingRecording == false {
                        self?.recordingMeter.deliver(levels)
                    }
                }
            }
            capture.onHealth = { [weak self] message in
                Task { @MainActor in if self?.recordingID == meeting.id { self?.captureHealth = message } }
            }
            capture.onFailure = { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    while self.captureTransition { try? await Task.sleep(nanoseconds: 100_000_000) }
                    guard self.recordingID == meeting.id else { return }
                    self.errorMessage = error.localizedDescription
                    await self.stopRecording(transcribeAfter: false)
                }
            }
            let files = try await capture.start(
                directory: directory(for: meeting.id), microphoneEnabled: microphone,
                systemEnabled: systemAudio,
                voiceProcessing: settings.automaticVoiceProcessing ? .automatic : .off,
                microphoneDevice: settings.microphoneDevice)
            var recorded = meeting
            recorded.audioFiles = files
            recorded.recordingProfile = capture.profile
            meetings.insert(recorded, at: 0)
            guard save() else {
                try? await capture.stop()
                throw MeetingError.message(errorMessage ?? "Could not save recording metadata.")
            }
            recorder = capture
            recordingID = meeting.id
            recordingStartedAt = Date()
            liveTranscript.begin(
                meetingID: meeting.id, language: meeting.language, directory: directory(for: meeting.id),
                sources: [microphone ? .microphone : nil, systemAudio ? .system : nil].compactMap { $0 },
                sink: liveSink, enabled: settings.showLiveTranscript)
            captureHealth = [
                microphone
                    ? (capture.profile.microphoneVoiceProcessing
                        ? "Microphone: Apple voice processing" : "Microphone: unprocessed") : nil,
                systemAudio ? "System audio: separate track" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
        }
        catch {
            if error is CancellationError {
                // Cancelling is deliberate, so it needs no notice.
            }
            else if let permission = RecordingPermissions.permission(for: error) {
                recordingPermissionNeeded = permission
            }
            else {
                errorMessage = error.localizedDescription
            }
        }
        captureTransition = false
    }
    /// The live Voice Processing switch; explicit for the rest of the recording.
    func setRecordingVoiceProcessing(_ enabled: Bool) { recorder?.setVoiceProcessing(enabled) }
    func stopRecording(transcribeAfter: Bool = true) async {
        _ = flushNotes()
        guard let id = recordingID else { return }
        guard !captureTransition else { return }
        captureTransition = true
        isFinalizingRecording = true
        let duration = recordingDuration
        var stopFailed = false
        do { try await recorder?.stop() }
        catch {
            // An empty source is not a failed recording; its message names the
            // source and says which track was saved.
            errorMessage =
                (error as? CaptureSourceError)?.isNoAudio == true
                ? error.localizedDescription
                : "Couldn’t finish the recording. Audio captured before the problem is kept in this meeting. \(error.localizedDescription)"
            stopFailed = true
        }
        await liveTranscript.finish()
        let profile = recorder?.profile
        recorder = nil
        captureHealth = ""
        if let index = meetings.firstIndex(where: { $0.id == id }) {
            meetings[index].duration = duration
            meetings[index].recordingProfile = profile
            if !save() { stopFailed = true }
        }
        if !stopFailed && activeRecordingFormat != .wav {
            do { try await finalizeRecordingAudio(id: id, format: activeRecordingFormat) }
            catch {
                errorMessage =
                    "Couldn’t convert the recording to \(activeRecordingFormat.rawValue.uppercased()). The original WAV audio is kept in this meeting. \(error.localizedDescription)"
                stopFailed = true
            }
        }
        recordingID = nil
        recordingStartedAt = nil
        recordingMeter.reset()
        captureTransition = false
        isFinalizingRecording = false
        // A separate task, so callers awaiting the stop return once audio is saved.
        if !stopFailed && transcribeAfter && settings.autoTranscribe { Task { await transcribe(id: id) } }
    }
    func finalizeRecordingAudio(id: UUID, format: RecordingFormat) async throws {
        guard canSave, format != .wav else { return }
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        let originals = audioURLs(for: meeting)
        guard !originals.isEmpty, originals.count == meeting.audioFiles.count else {
            throw MeetingError.message("A recorded audio file is missing.")
        }
        var encoded: [URL] = []
        do {
            for source in originals {
                let destination = source.deletingPathExtension().appendingPathExtension(format.rawValue)
                try await RecordingEncoder.encode(source: source, destination: destination, format: format)
                encoded.append(destination)
            }
            guard let index = meetings.firstIndex(where: { $0.id == id }) else {
                throw MeetingError.message("The recording no longer exists.")
            }
            meetings[index].audioFiles = encoded.map(\.lastPathComponent)
            if var profile = meetings[index].recordingProfile {
                for i in profile.tracks.indices {
                    if let sourceIndex = originals.firstIndex(where: {
                        $0.lastPathComponent == profile.tracks[i].filename
                    }) {
                        profile.tracks[i].filename = encoded[sourceIndex].lastPathComponent
                    }
                }
                meetings[index].recordingProfile = profile
            }
            guard save() else {
                throw MeetingError.message(errorMessage ?? "Could not save compressed recording metadata.")
            }
        }
        catch {
            for file in encoded { try? FileManager.default.removeItem(at: file) }
            throw error
        }
        // Remove only this capture's PCM spools, after durable metadata points to
        // every finalized compressed track. Failed conversion leaves WAV recoverable.
        for file in originals { try? FileManager.default.removeItem(at: file) }
    }
    @discardableResult func finalizeForQuit() async -> Bool {
        RecordingPermissions.cancelPendingStart()
        while captureTransition { try? await Task.sleep(nanoseconds: 100_000_000) }
        await stopRecording(transcribeAfter: false)
        return flushNotes()
    }
    /// A list drop creates one meeting per file; a detail drop appends aligned
    /// tracks to one meeting. Commit metadata once, or remove all new copies.
    @discardableResult func importAudioFiles(_ urls: [URL], into target: UUID? = nil) async throws -> [UUID] {
        guard canSave else { throw MeetingError.message("The library is read-only because loading failed.") }
        guard !isStartingRecording, !isFinalizingRecording, recordingID == nil else {
            throw MeetingError.message("Stop the recording before importing audio.")
        }
        guard !isImportingAudio else {
            throw MeetingError.message("Wait for the current import to finish before importing more audio.")
        }
        guard !urls.isEmpty else { return [] }
        if let target {
            guard let meeting = meetings.first(where: { $0.id == target }) else {
                throw MeetingError.message("This meeting no longer exists.")
            }
            guard meeting.transcriptionAttempt == nil, !isJobRunning(.transcription, .meeting(target)) else {
                throw MeetingError.message(
                    "Resume and finish this meeting’s pending transcription before adding tracks.")
            }
            guard !isJobRunning(.archive, .meeting(target)) else {
                throw MeetingError.message("Wait for this meeting’s archive to finish before adding tracks.")
            }
        }
        let scope: BackgroundJob.Scope = target.map { .meeting($0) } ?? .library
        guard beginJob(.importAudio, scope, progress: "Importing audio…") else { return [] }
        defer { endJob(.importAudio, scope) }
        var copied: [URL] = []
        var newFolders: [URL] = []
        var additions: [(id: UUID, title: String, file: String, duration: Double)] = []
        do {
            for source in urls {
                try Task.checkCancellation()
                let ext = source.pathExtension.lowercased()
                guard source.isFileURL,
                    ["opus", "ogg", "wav", "m4a", "mp3", "mp4", "aiff", "aif", "caf", "flac", "aac", "mov"].contains(
                        ext)
                else {
                    throw MeetingError.message("Choose a supported audio or video file: \(source.lastPathComponent).")
                }
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw MeetingError.message("Choose a file, not a folder: \(source.lastPathComponent).")
                }
                let id = target ?? UUID()
                let folder = directory(for: id)
                if !FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    newFolders.append(folder)
                }
                let base = source.deletingPathExtension().lastPathComponent
                let filenameBase = base.replacingOccurrences(of: "..", with: "_")
                var destination = folder.appendingPathComponent(filenameBase).appendingPathExtension(ext)
                var suffix = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    destination = folder.appendingPathComponent("\(filenameBase)-\(suffix)").appendingPathExtension(ext)
                    suffix += 1
                }
                let copyTo = destination
                copied.append(destination)
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: source, to: copyTo)
                }.value
                let duration: Double
                if ["opus", "ogg"].contains(ext) {
                    duration = try await AudioPlaybackPreparation.opusMetadata(destination).duration
                }
                else {
                    let asset = AVURLAsset(url: destination)
                    guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                        throw MeetingError.message("No audio track found in \(source.lastPathComponent).")
                    }
                    duration = try await asset.load(.duration).seconds
                }
                guard duration.isFinite, duration > 0 else {
                    throw MeetingError.message("No playable audio in \(source.lastPathComponent).")
                }
                additions.append((id, base, destination.lastPathComponent, duration))
            }
            try Task.checkCancellation()
            if let target {
                guard let index = meetings.firstIndex(where: { $0.id == target }) else {
                    throw MeetingError.message("This meeting was deleted during import.")
                }
                meetings[index].audioFiles += additions.map(\.file)
                meetings[index].duration = max(meetings[index].duration, additions.map(\.duration).max() ?? 0)
            }
            else {
                let imported = additions.map {
                    Meeting(
                        id: $0.id, title: $0.title, language: settings.defaultLanguage, duration: $0.duration,
                        audioFiles: [$0.file])
                }
                meetings.insert(contentsOf: imported, at: 0)
            }
            guard save() else { throw MeetingError.message(errorMessage ?? "Could not save imported audio.") }
        }
        catch {
            for file in copied { try? FileManager.default.removeItem(at: file) }
            for folder in newFolders {
                if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            throw error
        }
        return target.map { [$0] } ?? additions.map(\.id)
    }
    func importArchive(url: URL) throws {
        guard canSave else { throw MeetingError.message("The library is read-only because loading failed.") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var meeting = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: url))
        meeting.id = UUID()
        meeting.audioFiles = []
        meeting.personIDs = []
        meeting.tagIDs = []
        meeting.transcriptionAttempt = nil
        for index in meeting.speakers.indices {
            meeting.speakers[index].personID = nil
            meeting.speakers[index].confidence = nil
            meeting.speakers[index].confirmed = false
            meeting.speakers[index].embedding = nil
            meeting.speakers[index].voiceScope = nil
        }
        meeting.restoreSpeakerIdentities()
        meetings.insert(meeting, at: 0)
        guard save() else { throw MeetingError.message(errorMessage ?? "Could not save imported meeting.") }
    }
    func exportMeeting(id: UUID, to url: URL) throws {
        guard var meeting = meetings.first(where: { $0.id == id }) else {
            throw MeetingError.message("Meeting no longer exists.")
        }
        meeting.transcriptionAttempt = nil
        for index in meeting.transcript.indices {
            meeting.transcript[index].speaker = meeting.speakerName(for: meeting.transcript[index], people: people)
            meeting.transcript[index].speakerID = nil
        }
        meeting.speakers = []
        if url.pathExtension.lowercased() == "json" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(meeting).write(to: url, options: .atomic)
        }
        else {
            let transcript = meeting.transcript.map {
                "[\(Int($0.start / 60)):\(String(format: "%02d", Int($0.start) % 60))] **\($0.speaker):** \($0.text)"
            }.joined(separator: "\n\n")
            let todos = meeting.todos.map { "- [\($0.isCompleted ? "x" : " ")] \($0.title)" }.joined(separator: "\n")
            try
                "# \(meeting.title)\n\n\(meeting.createdAt.formatted())\n\n## Summary\n\n\(meeting.summary)\n\n## Notes\n\n\(NotesDocument(meeting.notes).citedText)\n\n## Action items\n\n\(todos)\n\n## Transcript\n\n\(transcript)\n"
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
