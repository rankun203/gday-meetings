import AVFoundation
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Uses a temporary library, silent playback, and no Keychain access.
enum UIPreview {
    static let enabled =
        ProcessInfo.processInfo.arguments.contains("--ui-preview")
        || Bundle.main.object(forInfoDictionaryKey: "GdayUIPreview") as? Bool == true

    @MainActor static func startSyntheticRecording(_ store: MeetingStore) async {
        guard enabled, store.recordingID == nil else { return }
        do {
            var meeting = Meeting(title: "Synthetic recording")
            let folder = store.directory(for: meeting.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            meeting.audioFiles = ["microphone.wav", "system.wav"]
            for (index, name) in meeting.audioFiles.enumerated() {
                try writeFixture(to: folder.appendingPathComponent(name), source: index)
            }
            try await store.insertImportedMeeting(meeting)
            store.recordingID = meeting.id
            store.recordingStartedAt = Date()
            store.recordingMeter.deliver(
                RecordingLevels(
                    microphone: RecordingSourceLevel(enabled: true, hasSamples: true),
                    system: RecordingSourceLevel(enabled: true, hasSamples: true)))
            store.liveTranscript.seedPreview(meetingID: meeting.id, directory: folder)
        }
        catch { store.errorMessage = "Couldn’t create the synthetic recording. \(error.localizedDescription)" }
    }

    @MainActor static func makeStore() -> MeetingStore {
        guard enabled else {
            let store = MeetingStore()
            LocalModelManager.configureShared(
                dataDirectory: store.dataDirectory, available: store.libraryWritable,
                migrateLegacy: ProcessInfo.processInfo.environment["GDAY_SWIFT_DATA_DIR"] == nil)
            return store
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Gday-UI-Preview-\(UUID())")
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        store.previewPreparation = Task { await prepare(store, directory: directory) }
        return store
    }

    @MainActor private static func prepare(_ store: MeetingStore, directory: URL) async {
        LocalModelManager.configureShared(
            dataDirectory: directory, available: store.libraryWritable, migrateLegacy: false)
        do {
            for title in ["Synthetic single track", "Synthetic conversation"] {
                var meeting = Meeting(title: title)
                let folder = store.directory(for: meeting.id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                meeting.audioFiles = title.contains("single") ? ["microphone.wav"] : ["microphone.wav", "system.wav"]
                meeting.duration = 60
                for (index, name) in meeting.audioFiles.enumerated() {
                    try writeFixture(to: folder.appendingPathComponent(name), source: index)
                }
                if title == "Synthetic conversation",
                    ProcessInfo.processInfo.arguments.contains("--preview-unavailable-track")
                        || Bundle.main.object(forInfoDictionaryKey: "GdayUnavailableTrackPreview") as? Bool == true
                {
                    meeting.audioFiles[0] = "microphone.opus"
                    try Data("Invalid synthetic audio".utf8).write(to: folder.appendingPathComponent("microphone.opus"))
                }
                try await store.insertImportedMeeting(meeting)
                try writeArchiveFixture(store: store, id: meeting.id, verified: title.contains("single"))
                try writeDataEventFixtures(directory: folder)
            }
            let person = await store.addPerson(name: "Alex Morgan")
            let matched = await store.addPerson(name: "Sam Chen")
            let previewTag = await store.addTag(name: "Preview")
            let projectTag = await store.addTag(name: "Planning")
            if var conversation = store.meetings.first(where: { $0.title == "Synthetic conversation" }) {
                let first = MeetingSpeaker(
                    label: "sys_SPEAKER_00", track: "system", providerName: "RunPod",
                    voiceScope: "preview:synthetic", embedding: [1, 0], personID: person, confirmed: true)
                let second = MeetingSpeaker(
                    label: "sys_SPEAKER_01", track: "system", providerName: "RunPod",
                    voiceScope: "preview:synthetic", embedding: [0, 1], personID: matched, confidence: 0.91)
                let third = MeetingSpeaker(
                    label: "mic_SPEAKER_00", track: "microphone", providerName: "RunPod",
                    voiceScope: "preview:synthetic", embedding: [0.5, 0.5])
                conversation.replaceSpeakers([first, second, third])
                conversation.tagIDs = [previewTag, projectTag]
                conversation.summary = """
                    ### Key points

                    - Review the **release plan** with the team. [00:06][00:11]
                    - Keep the meeting notes up to date.

                    ### Decisions

                    | Topic | Decision |
                    | --- | --- |
                    | Release | Start with the Mac app |
                    | Review | Meet on Friday |

                    ### Action items

                    **结论：**检查示例格式。[00:06]

                    - [ ] Alex: Update the schedule.
                    - [x] Sam: Check the meeting notes.
                    """
                conversation.notes = """
                    # Release plan <!-- gday:t=0:05 -->

                    - Review **meeting notes** <!-- gday:t=0:12 -->
                    - [ ] Update the schedule <!-- gday:t=0:24 -->

                    This line has no recording time.
                    """
                let image = try writeNotesImage(directory: store.directory(for: conversation.id))
                conversation.summary +=
                    "\n\nSee the [planning diagram](\(NotesAssets.encodedPath(image.originalPath))). [00:32]"
                let resizedImage = try NotesImageStore.resized(
                    image, width: 180, directory: store.directory(for: conversation.id))
                conversation.notes +=
                    "\n\n" + image.markdown + " <!-- gday:t=0:32 -->\n\n" + resizedImage.markdown
                    + " <!-- gday:t=0:42 -->\n\nEnd of image notes."
                conversation.transcript = [
                    TranscriptSegment(
                        start: 1, end: 5, speaker: first.label,
                        text: "Let’s review the release plan.", speakerID: first.id),
                    TranscriptSegment(
                        start: 6, end: 10, speaker: second.label,
                        text: "The next step is to check the meeting notes.", speakerID: second.id),
                    TranscriptSegment(
                        start: 8, end: 15, speaker: third.label,
                        text: "I’ll update the schedule after this call.", speakerID: third.id),
                ]
                if ProcessInfo.processInfo.arguments.contains("--synthetic-grouped-search")
                    || Bundle.main.object(forInfoDictionaryKey: "GdayGroupedSearchPreview") as? Bool == true
                {
                    conversation.transcript.append(contentsOf: [
                        TranscriptSegment(
                            start: 24, end: 34, speaker: first.label,
                            text: "The schedule includes a review before the next milestone.", speakerID: first.id),
                        TranscriptSegment(
                            start: 32, end: 40, speaker: second.label,
                            text: "Check the schedule again after the review is complete.", speakerID: second.id),
                        TranscriptSegment(
                            start: 52, end: 53, speaker: third.label,
                            text: "The schedule is ready.", speakerID: third.id),
                    ])
                }
                if ProcessInfo.processInfo.arguments.contains("--transcript-layout")
                    || Bundle.main.object(forInfoDictionaryKey: "GdayTranscriptLayoutPreview") as? Bool == true
                {
                    conversation.transcript.append(contentsOf: [
                        TranscriptSegment(
                            start: 3599, end: 3600, speaker: first.label,
                            text:
                                "This longer paragraph checks wrapping across several lines while the timestamp and speaker stay aligned at the top. Editing should preserve the complete text and its recording time.",
                            speakerID: first.id),
                        TranscriptSegment(
                            start: 3600, end: 3605, speaker: "A speaker with a long display name",
                            text:
                                "The hour digits extend to the left, leaving the text column aligned with earlier rows."
                        ),
                    ])
                }
                conversation.transcriptSource = TranscriptSource(
                    id: UUID(), providerName: "Preview Transcription", generatedAt: conversation.createdAt)
                await store.updateMeeting(conversation)
                try seedVoiceExamples(store: store, meeting: conversation, firstPerson: person, secondPerson: matched)
                var live = LiveTranscriptDraft(meetingID: conversation.id, locale: "en-AU")
                // The checkpoint shares the canonical segment store with the
                // saved transcript, so retain the conversation's timed rows.
                live.savedSegments = conversation.transcript
                live.complete = true
                try live.save(at: store.directory(for: conversation.id))
                try await seedTranscriptLabelingHistory(store: store, meeting: conversation, live: live)
                try await seedSpeakerConsolidation(store: store, meeting: conversation)
                if ProcessInfo.processInfo.arguments.contains("--synthetic-live-recording")
                    || ProcessInfo.processInfo.arguments.contains("--synthetic-live-speakers")
                    || Bundle.main.object(forInfoDictionaryKey: "GdaySyntheticLiveRecording") as? Bool == true
                {
                    // Simulate a new recording, not a live stream on top of the
                    // saved batch fixture. Stop can then exercise live adoption.
                    if var recording = store.meetings.first(where: { $0.id == conversation.id }) {
                        recording.transcript = []
                        if ProcessInfo.processInfo.arguments.contains("--synthetic-live-speakers") {
                            recording.language = "zh-Hans"
                        }
                        recording.replaceSpeakers([])
                        await store.updateMeeting(recording)
                    }
                    store.recordingID = conversation.id
                    store.recordingStartedAt = Date()
                    let previewTime = ProcessInfo.processInfo.systemUptime
                    for tick in 0...50 {
                        store.recordingMeter.deliver(
                            RecordingLevels(
                                microphone: RecordingSourceLevel(
                                    enabled: true, hasSamples: true, rmsDB: -32 + Double(tick % 8)),
                                system: RecordingSourceLevel(
                                    enabled: true, hasSamples: true, rmsDB: -24 + Double(tick % 6)),
                                microphoneStatus: RecordingMicrophoneStatus(voiceProcessing: true, canSwitch: true)),
                            at: previewTime - 10 + Double(tick) / 5)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--synthetic-live-speakers") {
                        LiveTranscriptPreviewReplay.start(
                            store: store, meetingID: conversation.id, directory: store.directory(for: conversation.id))
                    }
                    else {
                        store.liveTranscript.seedPreview(
                            meetingID: conversation.id, directory: store.directory(for: conversation.id),
                            previouslyAssignedPersonID: person)
                    }
                }
            }
            if UIPreviewPerformanceFixtures.flag("--synthetic-providers", infoKey: "GdaySyntheticProviders") {
                store.settings = syntheticProviderSettings(store.settings)
            }
            if UIPreviewPerformanceFixtures.flag("--synthetic-local-speakers", infoKey: "GdaySyntheticLocalSpeakers") {
                let provider = ServiceProvider(kind: .speakerLabeling)
                store.settings.serviceProviders.append(provider)
                store.settings.liveDiarizationProviderID = provider.id
                store.settings.diarizationProviderID = provider.id
            }
            if ProcessInfo.processInfo.arguments.contains("--synthetic-multiple-transcription-providers") {
                store.settings = syntheticProviderSettings(store.settings)
                var second = ServiceProvider(kind: .runpod)
                second.name = "Second Preview Provider"
                second.endpoint = "https://second.example.invalid/v2/preview"
                second.apiKey = "synthetic-preview-key"
                second.enabledCapabilities = [.transcription]
                second.uploadProviderID = store.settings.serviceProviders.first { $0.kind == .filedrop }?.id
                store.settings.serviceProviders.append(second)
            }
            if UIPreviewPerformanceFixtures.flag("--synthetic-long-transcript", infoKey: "GdaySyntheticLongTranscript"),
                var meeting = store.meetings.first(where: { $0.title == "Synthetic conversation" })
            {
                meeting.transcript = (0..<10_000).map { index in
                    let label = index.isMultiple(of: 2) ? "sys_SPEAKER_00" : "mic_SPEAKER_00"
                    return TranscriptSegment(
                        start: Double(index * 6), end: Double(index * 6 + 5),
                        speaker: label,
                        text: "Segment \(index + 1). "
                            + (index.isMultiple(of: 3)
                                ? "Review the release plan, delivery dates, and decisions. This longer paragraph exercises wrapped transcript rows while scrolling."
                                : "Keep the meeting notes up to date."),
                        speakerID: meeting.speakers.first(where: { $0.label == label })?.id)
                }
                await store.updateMeeting(meeting)
            }
            if ProcessInfo.processInfo.arguments.contains("--synthetic-tasks")
                || Bundle.main.object(forInfoDictionaryKey: "GdaySyntheticTasks") as? Bool == true
            {
                await seedTasks(store)
            }
            if UIPreviewPerformanceFixtures.librarySize == nil,
                UIPreviewPerformanceFixtures.flag("--synthetic-pagination", infoKey: "GdaySyntheticPagination")
            {
                for index in 1...45 {
                    var meeting = Meeting(title: String(format: "Pagination meeting %02d", index))
                    meeting.createdAt = Date().addingTimeInterval(-Double(index) * 3_600)
                    meeting.notes = index == 45 ? "Unique last-page search phrase" : "Synthetic notes for pagination."
                    meeting.transcript = [.init(text: "Synthetic transcript \(index)")]
                    try await store.insertImportedMeeting(meeting)
                }
                store.resetMeetingPages(evictLoaded: true)
            }
            if ProcessInfo.processInfo.arguments.contains("--synthetic-summary-stream") {
                seedSummaryStream(store)
            }
            if UIPreviewPerformanceFixtures.flag("--synthetic-directories", infoKey: "GdaySyntheticDirectories") {
                DirectoryPreview.populate(store: store)
            }
            try await seedPagedTasks(store)
            if UIPreviewPerformanceFixtures.flag(
                "--synthetic-pending-transcription", infoKey: "GdaySyntheticPendingTranscription"),
                var meeting = store.meetings.first(where: { $0.title == "Synthetic single track" })
            {
                meeting.transcript = [.init(start: 0, end: 2, text: "Original synthetic passage")]
                guard await store.updateMeeting(meeting) else {
                    throw ServiceError(store.errorMessage ?? "Couldn’t save the preview transcript.")
                }
                var attempt = ProviderTranscriptionAttempt(provider: ServiceProvider(kind: .runpod), meeting: meeting)
                attempt.result = [.init(start: 0, end: 2, text: "Replacement synthetic passage")]
                try await store.saveTranscriptionAttempt(attempt, meetingID: meeting.id)
            }
            if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--provider-test-env") {
                let arguments = ProcessInfo.processInfo.arguments
                guard arguments.indices.contains(flag + 1), !arguments[flag + 1].hasPrefix("--") else {
                    throw ServiceError("Add the configuration file path after --provider-test-env.")
                }
                let contents: String
                do { contents = try String(contentsOfFile: arguments[flag + 1], encoding: .utf8) }
                catch { throw ServiceError("Couldn’t read the provider test configuration file.") }
                let providers = try testProviders(configuration: contents)
                store.settings.serviceProviders = providers
                store.settings.transcriptionProviderID = providers.first { $0.kind == .runpod }?.id
            }
            if let meeting = store.meetings.first(where: { $0.title == "Synthetic conversation" }) {
                let folder = store.directory(for: meeting.id)
                let now = Date()
                for index in 0..<12 {
                    let time = now.addingTimeInterval(Double(index) / 100)
                    try DataEventJournal.append(
                        MeetingDataEvent(
                            action: .modified,
                            dataFlow: DataFlow(
                                location: .local, targetID: ThisMacProvider.id, targetName: "This Mac",
                                responseBytes: 1024 + index * 128, startedAt: time, endedAt: time,
                                bodies: ["transcript.jsonl"], filePaths: ["transcript.jsonl"],
                                purpose: "Saved file"
                            )), directory: folder)
                }
            }
        }
        catch { store.errorMessage = "Could not prepare UI Preview: \(error.localizedDescription)" }
        configureGeneralScenario(store)
        UIPreviewPerformanceFixtures.schedule(store)
    }

    @MainActor private static func seedVoiceExamples(
        store: MeetingStore, meeting: Meeting, firstPerson: UUID, secondPerson: UUID
    ) throws {
        guard meeting.speakers.count >= 3 else { return }
        let reviewGroup = UUID()
        let unnamedGroup = UUID()
        let typedPreview = TypedVoiceEmbedding(
            type: .community1, values: [1] + Array(repeating: 0, count: 255), provenance: "Synthetic Local Provider")
        let legacyPreview = TypedVoiceEmbedding(
            type: .unknownLegacy(dimension: 2), values: [1, 0], provenance: "Synthetic Previous Provider")
        var examples = [
            VoiceExample(
                meetingID: meeting.id, speakerID: meeting.speakers[0].id, source: "system",
                audioFile: "system.wav", start: 1, end: 5, suggestedPersonID: firstPerson,
                review: .suggested, groupID: reviewGroup),
            VoiceExample(
                meetingID: meeting.id, speakerID: meeting.speakers[0].id, source: "system",
                audioFile: "system.wav", start: 16, end: 21, suggestedPersonID: firstPerson,
                review: .suggested, groupID: reviewGroup),
            VoiceExample(
                meetingID: meeting.id, speakerID: meeting.speakers[1].id, source: "system",
                audioFile: "system.wav", start: 6, end: 10, personID: secondPerson, review: .confirmed),
            VoiceExample(
                meetingID: meeting.id, speakerID: meeting.speakers[2].id, source: "microphone",
                audioFile: "microphone.wav", start: 8, end: 15, groupID: unnamedGroup),
            VoiceExample(
                meetingID: meeting.id, speakerID: meeting.speakers[2].id, source: "microphone",
                audioFile: "microphone.wav", start: 24, end: 30, groupID: unnamedGroup),
            VoiceExample(
                meetingID: meeting.id, speakerID: UUID(), source: "unknown",
                suggestedPersonID: firstPerson, review: .suggested, excluded: true, createdAt: .distantPast),
        ]
        examples[0].embeddings = [typedPreview]
        examples[0].origin = .savedSpeaker
        var legacy = VoiceExample(
            meetingID: meeting.id, speakerID: meeting.speakers[1].id, source: "unknown",
            createdAt: meeting.createdAt.addingTimeInterval(1))
        legacy.origin = .legacyProfile
        legacy.suggestedPersonID = secondPerson
        legacy.review = .suggested
        legacy.embeddings = [legacyPreview, typedPreview]
        examples.append(legacy)
        examples.append(
            VoiceExample(
                meetingID: meeting.id, speakerID: UUID(), source: "unknown",
                suggestedPersonID: firstPerson, review: .suggested, embeddings: [typedPreview],
                createdAt: meeting.createdAt.addingTimeInterval(2)))
        for index in examples.indices {
            if let file = examples[index].audioFile {
                examples[index].audioRevision = VoiceLibraryStore.revision(
                    url: store.directory(for: meeting.id).appendingPathComponent(file))
            }
        }
        store.voiceLibrary.upsert(examples)
        let previousLabels = LocalDiarizationResult(
            generatedAt: meeting.createdAt.addingTimeInterval(-600), modelRevision: "synthetic-community1-revision",
            ranges: [], speakers: [])
        try PrivateTranscriptFile.write(
            try JSONEncoder().encode(previousLabels), name: "speaker-labels-\(previousLabels.id).json",
            at: store.directory(for: meeting.id))
    }

    /// A visible draft fixture uses no provider, credentials, or network request.
    @MainActor private static func seedSummaryStream(_ store: MeetingStore) {
        guard let meeting = store.meetings.first(where: { $0.title == "Synthetic conversation" }) else { return }
        let fragments =
            ["# Release review\n\n", "## Key points\n\n"]
            + (1...30).map {
                "- Streaming preview point \($0) arrives without waiting for the full summary.\n"
            }
        Task { @MainActor [weak store] in
            guard let store else { return }
            guard store.beginJob(.summary, .meeting(meeting.id), progress: "Writing summary…") else { return }
            defer { store.endJob(.summary, .meeting(meeting.id)) }
            store.summaryDrafts.values[meeting.id] = ""
            for fragment in fragments {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                store.summaryDrafts.values[meeting.id, default: ""] += fragment
            }
        }
    }

    /// Explicit fixtures exercise queue controls without starting provider work.
    @MainActor private static func seedTasks(_ store: MeetingStore) async {
        guard let conversation = store.meetings.first(where: { $0.title == "Synthetic conversation" }),
            let single = store.meetings.first(where: { $0.title == "Synthetic single track" })
        else { return }
        let queuedID = await store.createMeeting(title: "Synthetic queued recording")
        let failedID = await store.createMeeting(title: "Synthetic summary retry")
        let expiredID = await store.createMeeting(title: "Synthetic expired transcription")
        let now = Date()
        store.managedTasks = [
            ManagedTaskRecord(
                kind: .diarization, meetingID: conversation.id, meetingTitle: conversation.title,
                providerName: "Synthetic Community-1", state: .completed,
                progress: "Speaker labeling completed.", createdAt: now.addingTimeInterval(-500),
                finishedAt: now.addingTimeInterval(-450), isPreview: true),
            ManagedTaskRecord(
                kind: .diarization, meetingID: conversation.id, meetingTitle: conversation.title,
                providerName: "Synthetic Community-1", state: .failed,
                progress: "Failed", errorMessage: "The audio file was unavailable. The transcript was kept.",
                createdAt: now.addingTimeInterval(-400), isPreview: true, recovery: .manual),
            ManagedTaskRecord(
                kind: .diarization, meetingID: conversation.id, meetingTitle: conversation.title,
                providerName: "Synthetic Community-1", state: .running,
                progress: "Labeling speakers in system audio…", createdAt: now.addingTimeInterval(-330),
                isPreview: true),
            ManagedTaskRecord(
                kind: .transcription, meetingID: conversation.id, meetingTitle: conversation.title,
                providerName: "Preview RunPod", state: .running,
                progress: "Waiting for RunPod to finish processing…", createdAt: now.addingTimeInterval(-300),
                isPreview: true),
            ManagedTaskRecord(
                kind: .summary, meetingID: single.id, meetingTitle: single.title,
                providerName: "Preview Language Model", state: .running,
                progress: "Writing summary…", createdAt: now.addingTimeInterval(-240), isPreview: true),
            ManagedTaskRecord(
                kind: .transcription, meetingID: queuedID, meetingTitle: "Synthetic queued recording",
                providerName: "Preview RunPod", state: .queued,
                progress: "Waiting for a transcription slot", createdAt: now.addingTimeInterval(-180), isPreview: true),
            ManagedTaskRecord(
                kind: .summary, meetingID: failedID, meetingTitle: "Synthetic summary retry",
                providerName: "Preview Language Model", state: .failed, progress: "Failed",
                errorMessage: "The provider connection was interrupted. Retry to generate the summary.",
                createdAt: now.addingTimeInterval(-120), isPreview: true, recovery: .manual
            ),
            ManagedTaskRecord(
                kind: .summary, meetingID: conversation.id, meetingTitle: conversation.title,
                providerName: "Preview Language Model", state: .completed, progress: "Completed",
                createdAt: now.addingTimeInterval(-360), finishedAt: now, isPreview: true),
            ManagedTaskRecord(
                kind: .transcription, meetingID: expiredID, meetingTitle: "Synthetic expired transcription",
                providerName: "Preview RunPod", state: .failed, progress: "Failed",
                errorMessage: MissingTranscriptionJob().localizedDescription,
                createdAt: now.addingTimeInterval(-60), isPreview: true, recovery: .restartRequired,
                attemptKey: "preview-expired-request", remoteJobID: "preview-expired-job"),
            ManagedTaskRecord(
                kind: .searchIndex, meetingID: single.id, meetingTitle: single.title,
                providerName: "This Mac", state: .queued, progress: "Waiting for local processing",
                createdAt: now.addingTimeInterval(-40), isPreview: true, isAutomatic: true),
            ManagedTaskRecord(
                kind: .searchIndex, meetingID: conversation.id, meetingTitle: conversation.title,
                providerName: "This Mac", state: .completed, progress: "Completed",
                createdAt: now.addingTimeInterval(-600), finishedAt: now.addingTimeInterval(-550),
                isPreview: true, isAutomatic: true),
        ]
        for index in store.managedTasks.indices {
            var task = store.managedTasks[index]
            task.timeline = [
                .init(kind: .queued, date: task.createdAt, reason: nil),
                .init(kind: .started, date: task.createdAt.addingTimeInterval(5), reason: nil),
            ]
            if [.transcription, .summary].contains(task.kind), task.state != .queued {
                task.timeline?.append(
                    .init(kind: .waitingForProvider, date: task.createdAt.addingTimeInterval(5), reason: nil))
            }
            if task.state == .failed || task.state == .completed {
                task.timeline?.append(.init(kind: .ended, date: task.finishedAt ?? now, reason: task.errorMessage))
            }
            if task.state == .queued { task.timeline = [.init(kind: .queued, date: task.createdAt, reason: nil)] }
            store.managedTasks[index] = task
        }
        for task in store.managedTasks where task.state.isActive {
            store.backgroundJobs.append(BackgroundJob(key: task.key, progress: task.progress))
        }
        let providerID = UUID()
        let preparedIDs = store.voiceLibrary.examples.compactMap { example in
            store.voiceLibrary.hydratedExample(id: example.id)?.embeddings.isEmpty == false ? example.id : nil
        }
        let unavailableIDs = store.voiceLibrary.examples.filter { !$0.isPlayable }.map(\.id)
        let pagedFailures = UIPreviewPerformanceFixtures.flag(
            "--synthetic-task-failures", infoKey: "GdaySyntheticTaskFailures")
        let failureIDs = pagedFailures ? (0..<41).map { _ in UUID() } : unavailableIDs
        let failures = Dictionary(
            uniqueKeysWithValues: failureIDs.enumerated().map { index, id in
                (
                    id.uuidString,
                    pagedFailures
                        ? "Couldn’t prepare synthetic voice example \(index + 1)."
                        : "The saved example has no audio range. Find a playable example in its recording."
                )
            })
        store.voiceLibrary.setJobs([
            VoicePreparationJob(
                providerID: providerID, providerName: "Synthetic Community-1", type: .community1,
                discover: false, exampleIDs: preparedIDs, state: .paused, createdAt: now.addingTimeInterval(-150)),
            VoicePreparationJob(
                providerID: providerID, providerName: "Synthetic Community-1", type: .community1,
                discover: false, exampleIDs: failureIDs, failures: failures,
                state: .failed, createdAt: now.addingTimeInterval(-120)),
            VoicePreparationJob(
                providerID: providerID, providerName: "Synthetic Community-1", type: .community1,
                discover: false, exampleIDs: preparedIDs, completedExampleIDs: preparedIDs,
                state: .completed, createdAt: now.addingTimeInterval(-90)),
        ])
    }

    /// Parses only the explicitly supplied test file. Values are never logged or
    /// passed through a shell, and provider API keys stay in memory in Preview.
    static func testProviders(configuration: String) throws -> [ServiceProvider] {
        var values: [String: String] = [:]
        for line in configuration.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first,
                first == "\"" || first == "'", value.last == first
            {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        func required(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else {
                throw ServiceError("Add \(key) to the provider test configuration file.")
            }
            return value
        }
        var filedrop = ServiceProvider(kind: .filedrop)
        filedrop.endpoint = try required("FILE_DROP_URL")
        filedrop.apiKey = try required("FILE_DROP_API_KEY")
        filedrop.enabledCapabilities = [.fileTransfer]
        var runpod = ServiceProvider(kind: .runpod)
        runpod.endpoint = try required("RUNPOD_ENDPOINT_URL")
        runpod.apiKey = try required("RUNPOD_API_KEY")
        runpod.enabledCapabilities = [.transcription, .diarization]
        runpod.uploadProviderID = filedrop.id
        return [runpod, filedrop]
    }

    /// Fills Settings → Data Privacy and provider panels without real services.
    /// `.invalid` hosts never resolve (RFC 6761), so a connection check started by
    /// opening a provider panel fails locally and no content can be uploaded.
    static func syntheticProviderSettings(_ base: AppSettings) -> AppSettings {
        var settings = base
        var filedrop = ServiceProvider(kind: .filedrop)
        filedrop.endpoint = "https://files.example.invalid"
        filedrop.apiKey = "synthetic-preview-key"
        filedrop.enabledCapabilities = [.fileTransfer]
        var runpod = ServiceProvider(kind: .runpod)
        runpod.endpoint = "https://api.runpod.example.invalid/v2/preview"
        runpod.apiKey = "synthetic-preview-key"
        runpod.enabledCapabilities = [.transcription, .diarization]
        runpod.uploadProviderID = filedrop.id
        var llm = ServiceProvider(kind: .openAICompatible)
        llm.name = "Preview LLM"
        llm.endpoint = "https://llm.example.invalid/v1"
        llm.model = "preview-model"
        llm.enabledCapabilities = [.summarization]
        settings.serviceProviders = [runpod, filedrop, llm]
        settings.transcriptionProviderID = runpod.id
        settings.summaryProviderID = llm.id
        settings.autoTranscribe = true
        return settings
    }

    /// Shows the archived and incomplete states. The `.invalid` origin never
    /// resolves, and Preview cannot sign in, so Archive to Server stays disabled.
    @MainActor static func writeArchiveFixture(store: MeetingStore, id: UUID, verified: Bool) throws {
        let checkpoint = ArchiveCheckpoint(
            origin: "https://meetings.example.invalid", externalID: id.uuidString, importKey: "preview",
            snapshot: Data("{}".utf8),
            audio: [ArchiveAudio(filename: "microphone.wav", path: "microphone.wav", sha256: "", size: 0)],
            verifiedAt: verified ? Date() : nil)
        try JSONEncoder().encode(checkpoint).write(to: store.archiveCheckpointURL(for: id), options: .atomic)
        store.refreshArchiveStatus(id: id)
    }

    static func writeNotesImage(directory: URL) throws -> NotesImageReference {
        guard
            let context = CGContext(
                data: nil, width: 800, height: 400, bitsPerComponent: 8,
                bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw MeetingError.message("Couldn’t create the preview image.")
        }
        context.setFillColor(CGColor(red: 0.12, green: 0.4, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        context.setFillColor(CGColor(red: 0.8, green: 0.93, blue: 1, alpha: 1))
        for x in [60, 310, 560] { context.fill(CGRect(x: x, y: 100, width: 180, height: 200)) }
        let data = NSMutableData()
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else {
            throw MeetingError.message("Couldn’t create the preview image.")
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MeetingError.message("Couldn’t save the preview image.")
        }
        let path = try NotesImageStore.write(data as Data, filename: "preview-diagram.png", directory: directory)
        return NotesImageReference(
            range: .init(location: 0, length: 0), originalPath: path, displayPath: path,
            alt: "Three steps in the release plan")
    }

    static func writeFixture(to url: URL, source: Int) throws {
        let rate = 8000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        buffer.frameLength = 8000
        for second in 0..<60 {
            let samples = buffer.floatChannelData![0]
            for frame in 0..<8000 {
                let time = Double(second) + Double(frame) / rate
                let phase = (time + Double(source) * 4).truncatingRemainder(dividingBy: 12)
                let envelope = phase > 1 && phase < 7 ? pow(sin((phase - 1) / 6 * .pi), 2) : 0
                samples[frame] = Float(0.65 * envelope * sin(2 * .pi * 230 * time) * (0.65 + 0.35 * sin(time * 13)))
            }
            try file.write(from: buffer)
        }
    }
}

struct PreviewContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var appearance: AppearanceSettings
    @ViewState private var previewVoiceProcessing = false
    @ViewState private var showsComponents = false
    private static func recordingLevel(at time: Double, offset: Double, reconnects: Bool = false)
        -> RecordingSourceLevel
    {
        let phase = (time + offset).truncatingRemainder(dividingBy: 7)
        let value = phase < 4 ? abs(sin(time * 5 + offset)) * 0.65 + 0.12 : 0
        // Simulate a 4-second device switch every 20 seconds to show that state:
        // 2 seconds without a replacement device, then 2 seconds switching to one.
        let cycle = time.truncatingRemainder(dividingBy: 20)
        let reconnecting = reconnects && cycle >= 16
        return RecordingSourceLevel(
            enabled: true, hasSamples: true, reconnecting: reconnecting,
            switchingTo: reconnecting && cycle >= 18 ? "Preview Headphones" : nil, rmsDB: value * 60 - 60)
    }
    private static func recordingHistory(at time: Double) -> RecordingActivityHistory {
        var history = RecordingActivityHistory()
        let tick = floor(time * 10)
        for index in 0..<102 {
            let sampleTime = (tick - Double(101 - index)) / 10
            history.append(
                RecordingLevels(
                    microphone: recordingLevel(at: sampleTime, offset: 0),
                    system: recordingLevel(at: sampleTime, offset: 3, reconnects: true)), at: sampleTime)
        }
        return history
    }
    var body: some View {
        if UIPreview.enabled
            && !UIPreviewPerformanceFixtures.flag("--preview-chrome-only", infoKey: "GdayPreviewChromeOnly")
        {
            previewContent
        }
        else {
            content()
        }
    }
    private var previewContent: some View {
        VStack(spacing: 0) {
            if UIPreview.enabled {
                HStack {
                    Label("UI Preview · Synthetic audio · Silent playback", systemImage: "eye")
                    if let revision = Bundle.main.object(forInfoDictionaryKey: "GdayPreviewRevision") as? String {
                        Text(revision).foregroundStyle(.secondary)
                            .help(
                                Bundle.main.object(forInfoDictionaryKey: "GdayPreviewBuiltAt") as? String
                                    ?? "Local build")
                    }
                    Spacer()
                    Button("Components…") { showsComponents = true }
                        .popover(isPresented: $showsComponents) { PreviewComponents() }
                    if ProcessInfo.processInfo.arguments.contains("--synthetic-recording-start") {
                        Button("Start Synthetic Recording") { Task { await UIPreview.startSyntheticRecording(store) } }
                            .disabled(store.recordingID != nil)
                    }
                    Picker("Appearance", selection: $appearance.selection) {
                        ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.fixedSize()
                }.font(.caption).padding(8).background(.quaternary)
            }
            if UIPreview.enabled {
                DisclosureGroup("Recording visualization preview · synthetic levels") {
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        let now = ProcessInfo.processInfo.systemUptime
                        let history = Self.recordingHistory(at: now)
                        let status = RecordingWorkspaceView.reconnectingStatus(
                            RecordingLevels(
                                microphone: Self.recordingLevel(at: now, offset: 0),
                                system: Self.recordingLevel(at: now, offset: 3, reconnects: true)))
                        VStack(alignment: .leading, spacing: 10) {
                            // Reserve the line so the simulated reconnect does not shift the meters.
                            Label(status ?? "Reconnecting system audio…", systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline).foregroundStyle(.secondary).opacity(status == nil ? 0 : 1)
                                .accessibilityHidden(status == nil)
                            HStack(alignment: .top, spacing: 26) {
                                VStack(alignment: .leading, spacing: 10) {
                                    RecordingSourceMeter(
                                        title: "Microphone", symbol: "mic.fill",
                                        source: Self.recordingLevel(
                                            at: now, offset: 0),
                                        saving: false, activity: history.bars(microphone: true),
                                        activityTime: history.bucketStart, tint: .accentColor)
                                    // Off shows the echo hint; On shows the automatic-change notice.
                                    RecordingVoiceProcessingControl(
                                        status: RecordingMicrophoneStatus(
                                            voiceProcessing: previewVoiceProcessing, canSwitch: true,
                                            echoDetected: !previewVoiceProcessing,
                                            notices: previewVoiceProcessing
                                                ? ["Echo detected · Voice Processing turned on"] : [])
                                    ) { previewVoiceProcessing = $0 }
                                }
                                RecordingSourceMeter(
                                    title: "System Audio", symbol: "speaker.wave.2.fill",
                                    source: Self.recordingLevel(
                                        at: now, offset: 3, reconnects: true),
                                    saving: false, activity: history.bars(microphone: false),
                                    activityTime: history.bucketStart, tint: .teal)
                            }
                        }.padding(18).frame(maxWidth: 500)
                    }
                }.disclosureGroupStyle(AppDisclosureStyle())
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            content()
        }
    }
}

extension UIPreview {
    private static func writeDataEventFixtures(directory: URL) throws {
        let now = Date()
        try DataEventJournal.append(
            MeetingDataEvent(
                action: .sent,
                dataFlow: DataFlow(
                    location: .local, targetID: ThisMacProvider.id, targetName: "This Mac",
                    startedAt: now.addingTimeInterval(-35),
                    endedAt: now.addingTimeInterval(-5), bodies: ["System Audio"],
                    purpose: "Live transcription (synthetic)")), directory: directory)
        try DataEventJournal.append(
            MeetingDataEvent(
                action: .sent,
                dataFlow: DataFlow(
                    location: .remote, targetID: UUID(uuidString: "58935856-61B2-4C1F-8A7F-BBD81B7B6743")!,
                    targetName: "Example Provider", domain: "processing.example.invalid",
                    requestBytes: 12288, responseBytes: 4096, startedAt: now.addingTimeInterval(-4), endedAt: now,
                    bodies: ["notes.md", "transcript.jsonl"], filePaths: ["notes.md", "transcript.jsonl"],
                    purpose: "Summary (synthetic)")), directory: directory)
    }
}
