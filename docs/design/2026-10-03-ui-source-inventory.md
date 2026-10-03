---
title: UI source inventory
date: 2026-10-03
status: audit
scope: swift-app-ui
---

# UI source inventory

Snapshot taken for the October 3–4 audit from HEAD `5cf3ba3` plus then-current uncommitted voice review work. Concurrent changes after this snapshot are outside this index. This mechanical index supplements the manually reviewed component matrix in the [worklog](../worklogs/2026-10-03-liquid-glass-refresh.md). It is not proof that each state was rendered. Dynamic labels and multiline expressions require reading the linked source. Source hashes identify the reviewed snapshot; subsequent edits may change line numbers.

Families inherit the [shared theme](../../apps/client-macos-swift/docs/UI_THEME.md). Text, controls, help/accessibility wording, warnings, sheets, and compound views are indexed below. Renderer support files with no declarative labels are retained so native components are not omitted.

## ActionButtonStyle.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/ActionButtonStyle.swift) · SHA-256 `7f4aadbd91313582`

Types: `MeetingPlaybackButtonStyle`, `MeetingPlaybackHover`, `ActionButtonStyle`, `ActionHover`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## AgentsView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/AgentsView.swift) · SHA-256 `1d50857cd3c655eb`

Types: `AgentsView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 16 | `.accessibilityLabel("AGENTS.md")` |
| 19 | `Text(loadError).textSelection(.enabled)` |
| 20 | `Button("Try Again") { reloadID = UUID() }` |
| 25 | `ProgressView("Reading AGENTS.md…")` |

## AppDisclosureStyle.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/AppDisclosureStyle.swift) · SHA-256 `ff0ee49f793ec331`

Types: `AppDisclosureStyle`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 30 | `.accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")` |

## AudioFileDrop.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/AudioFileDrop.swift) · SHA-256 `66171f917db00abb`

Types: `AudioFileDrop`, `AudioDropBatch`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 18 | `Text(meetingID == nil ? "Import as meetings" : "Add audio tracks")` |

## ContextDetailView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/ContextDetailView.swift) · SHA-256 `bcb2461901a04613`

Types: `ContextDetailView`, `AssociatedMeetingPage`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 21 | `Text(title).font(.largeTitle)` |
| 25 | `TextField("Name", text: personBinding(person, \.name))` |
| 26 | `TextField("Email", text: personBinding(person, \.email))` |
| 27 | `TextField("Notes", text: personBinding(person, \.notes), axis: .vertical).lineLimit(1...4)` |
| 32 | `Text("\(page.total) associated meetings").foregroundStyle(.secondary)` |
| 35 | `Toggle(` |
| 47 | `.help("Hide meetings and people with this tag from the main lists and meeting search.")` |
| 56 | `Text(meeting.title)` |
| 58 | `Text(meeting.createdAt, style: .date).foregroundStyle(.secondary)` |
| 63 | `Button("Newer") { Task { await load(before: meetings.first) } }` |
| 65 | `Button("Older") { Task { await load(after: meetings.last) } }` |
| 68 | `if loading { ProgressView().controlSize(.small) }` |
| 69 | `Text("\(meetings.count) shown").font(.caption).foregroundStyle(.secondary)` |
| 73 | `Text(pageError).font(.caption).foregroundStyle(.secondary)` |
| 74 | `Button("Try Again") { Task { await load() } }.disabled(loading)` |
| 78 | `Text("Ask about the 20 most recent meetings").font(.headline)` |
| 83 | `Text(message.role == "user" ? "You" : "Gday").font(.headline)` |
| 84 | `Text(message.content).textSelection(.enabled)` |
| 90 | `TextField("Ask a question", text: $draft, axis: .vertical).lineLimit(1...5).onSubmit(send)` |
| 91 | `Button("Send", systemImage: "arrow.up", action: send).disabled(` |
| 100 | `.sheet(isPresented: $reviewingVoices) {` |
| 103 | `.sheet(isPresented: Binding(get: { selectedMeeting != nil }, set: { if !$0 { selectedMeeting = nil } })) {` |
| 108 | `Button("Done") { self.selectedMeeting = nil }.keyboardShortcut(.cancelAction)` |

## DataPrivacyView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/DataPrivacyView.swift) · SHA-256 `29f3ceb210044677`

Types: `DataPrivacyView`, `DataPrivacyForm`, `DataPrivacyRowView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 27 | `Text(` |
| 32 | `Section("Data") {` |
| 35 | `Section("Logs") {` |
| 36 | `Text(` |
| 40 | `Button("Export Logs", action: exportLogs)` |
| 41 | `Text("Saves this session’s logs from the last hour to ~/Library/Logs/Gday Meetings.")` |
| 60 | `Text(row.type.title).font(.body)` |
| 62 | `Text(contents).font(.caption).foregroundStyle(.secondary)` |
| 66 | `Label(row.storageStatus, systemImage: row.storageSymbol)` |
| 72 | `Text(destination.text)` |
| 79 | `Text(note).font(.caption).foregroundStyle(.secondary)` |

## DataSettingsView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/DataSettingsView.swift) · SHA-256 `353cad03d6e0032f`

Types: `DataSettingsView`, `DataSettingsContent`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 21 | `Section("Data Folder") {` |
| 23 | `Text(store.dataDirectory.path).textSelection(.enabled)` |
| 25 | `Button("Change Folder…", action: chooseFolder)` |
| 27 | `Button("Show in Finder") {` |
| 33 | `ProgressView().controlSize(.small)` |
| 34 | `Text("Copying library… \(store.copiedLibraryFiles.formatted()) files verified")` |
| 36 | `Button("Cancel") { store.cancelLibraryFolderChange() }` |
| 40 | `Text("Data folder after restart: \(pending.path)").textSelection(.enabled)` |
| 41 | `Text("Quit and reopen Gday Meetings to use this folder. The original files are kept.")` |
| 44 | `Button("Cancel Change") { store.cancelLibraryFolderChange() }` |
| 45 | `Button("Quit Gday Meetings") { NSApp.terminate(nil) }` |
| 49 | `Text(` |
| 53 | `Text("For iCloud Drive, keep the data folder downloaded and use it on one Mac at a time.")` |
| 57 | `Text(error).foregroundStyle(.red).textSelection(.enabled)` |
| 60 | `Section("Index") {` |
| 65 | `Button("Rebuild Index") { store.libraryMonitor?.rebuild() }` |
| 69 | `Text("Local index: \(store.indexDirectory.appendingPathComponent("index.db").path)")` |
| 74 | `ProgressView().controlSize(.small)` |
| 76 | `Text("Reading meeting folders… \(status.discoveredFolders.formatted()) checked")` |
| 79 | `Text("Building index… \(status.processed.formatted()) meetings processed")` |
| 82 | `Text("Counts are incomplete while the index is building.").font(.caption).foregroundStyle(` |
| 86 | `Text("Couldn’t update the index. \(error)").foregroundStyle(.red).textSelection(.enabled)` |
| 89 | `Section("Library") {` |
| 96 | `.alert(` |
| 100 | `Button("Cancel", role: .cancel) {}` |
| 101 | `Button(copyCurrent ? "Copy Library" : "Use Library") {` |
| 108 | `Text(` |

## DirectoryViews.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/DirectoryViews.swift) · SHA-256 `5a6487652bfaf788`

Types: `PeopleView`, `TagsView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 12 | `Button("Review Voices…", systemImage: "waveform") { reviewingVoices = true }` |
| 16 | `TextField("New person", text: $name).onSubmit(add)` |
| 17 | `Button("Add", systemImage: "plus", action: add).help("Add").labelStyle(.iconOnly).disabled(` |
| 23 | `Label(person.name, systemImage: "person.crop.circle")` |
| 26 | `Text("Excluded").font(.caption).foregroundStyle(.secondary)` |
| 28 | `Button("Delete Person…", systemImage: "trash", role: .destructive) { deleting = person }.help(` |
| 34 | `Toggle("Show Excluded", isOn: $showExcluded).toggleStyle(.checkbox).padding(.horizontal).padding(.bottom)` |
| 36 | `.sheet(isPresented: $reviewingVoices) {` |
| 40 | `.confirmationDialog(` |
| 45 | `Button("Delete Person", role: .destructive) {` |
| 50 | `Text("The person will be removed from your directory and meeting assignments.")` |
| 69 | `TextField("New tag", text: $name).onSubmit(add)` |
| 70 | `Button("Add", systemImage: "plus", action: add).help("Add").labelStyle(.iconOnly).disabled(` |
| 76 | `TextField(` |
| 86 | `if tag.isExcluded { Text("Excluded").font(.caption).foregroundStyle(.secondary) }` |
| 87 | `Text("\((try? store.libraryIndex?.count(tagID: tag.id)) ?? 0)").foregroundStyle(` |
| 89 | `Button("Delete Tag…", systemImage: "trash", role: .destructive) { deleting = tag }.help(` |
| 96 | `.confirmationDialog(` |
| 101 | `Button("Delete Tag", role: .destructive) {` |
| 106 | `Text("The tag will be removed from all meetings and people.")` |

## GeneralSettingsView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/GeneralSettingsView.swift) · SHA-256 `d3c7b74e9db0e6e6`

Types: `GeneralSettingsView`, `HealthIdentity`, `LocalHealthIdentity`, `GeneralProviderPicker`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 33 | `Picker("Preview Scenario", selection: $previewScenario) {` |
| 34 | `ForEach(1...10, id: \.self) { Text("Scenario \($0)").tag($0) }` |
| 46 | `Picker("Audio Format", selection: setting(\.recordingFormat)) {` |
| 47 | `Text("Opus").tag(RecordingFormat.opus)` |
| 48 | `Text("M4A (AAC)").tag(RecordingFormat.m4a)` |
| 49 | `Text("WAV").tag(RecordingFormat.wav)` |
| 53 | `Text("Reduces echo and background noise when needed. May lower other apps’ volume.")` |
| 95 | `Text("Extracts to-dos from completed summaries.").font(.caption).foregroundStyle(.secondary)` |
| 98 | `Picker("Appearance", selection: $appearance.selection) {` |
| 99 | `ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }` |
| 125 | `Button("Configure Capability Providers →") { settingsTab = "providers" }` |
| 131 | `Text(` |
| 206 | `Text(title).font(.headline).accessibilityAddTraits(.isHeader)` |
| 212 | `.accessibilityLabel(title)` |
| 226 | `Text(title).fixedSize(horizontal: false, vertical: true)` |
| 228 | `Label(` |
| 239 | `Text("Off").font(.caption).foregroundStyle(.secondary).fixedSize()` |
| 242 | `Toggle(title, isOn: enabled).labelsHidden()` |
| 243 | `.accessibilityLabel(title)` |
| 247 | `Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)` |
| 254 | `Text(title).fixedSize(horizontal: false, vertical: true)` |
| 256 | `Toggle(title, isOn: enabled).labelsHidden().accessibilityLabel(title)` |
| 301 | `Text(title).font(.callout)` |
| 306 | `Text(selectedName).lineLimit(1)` |
| 311 | `.accessibilityLabel(title).accessibilityValue(selectedName)` |
| 312 | `.popover(isPresented: $isOpen, arrowEdge: .bottom) {` |
| 326 | `Text(reason).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)` |
| 327 | `Button("Open \(selectedName) Settings →") {` |
| 343 | `Text(state.isReady ? name : "\(name) (\(state.reason ?? state.title))")` |

## LibrarySidebarControl.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/LibrarySidebarControl.swift) · SHA-256 `559ab74a2760016c`

Types: `LibrarySidebarControl`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## LibraryView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/LibraryView.swift) · SHA-256 `af23a5427d983768`

Types: `LibraryDestination`, `LibraryView`, `MeetingPanels`, `LibraryToolbarTitleForeground`, `RecordingToolbarForeground`, `LibraryIndexPlaceholder`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 55 | `Label(title, systemImage: "waveform")` |
| 57 | `Text(description)` |
| 60 | `Button("New Recording") { store.presentsRecordingSetup = true }` |
| 87 | `ProgressView("Loading meetings…")` |
| 96 | `Text(error).font(.caption)` |
| 97 | `Button("Try Again") { Task { await store.searchMeetingPages(search) } }` |
| 124 | `Label("Meetings", systemImage: "waveform").tag(LibraryDestination.meetings)` |
| 125 | `Label("People", systemImage: "person.2").tag(LibraryDestination.people)` |
| 126 | `Label("Tags", systemImage: "tag").tag(LibraryDestination.tags)` |
| 127 | `Label("Tasks", systemImage: "list.bullet.rectangle").tag(LibraryDestination.tasks)` |
| 128 | `Label("Agents", systemImage: "bubble.left.and.text.bubble.right").tag(` |
| 198 | `Button(action: toggleSidebar) {` |
| 199 | `Label(sidebarExpanded ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")` |
| 201 | `.help(sidebarExpanded ? "Hide Sidebar" : "Show Sidebar")` |
| 210 | `Text("Gday Meetings")` |
| 213 | `Text(destinationTitle)` |
| 227 | `Label("Open Meetings Folder", systemImage: "folder")` |
| 229 | `.help("Open the meetings storage folder in Finder")` |
| 238 | `Label(` |
| 245 | `.help(recordingActive ? "Show the current recording" : "Choose sources and start a recording")` |
| 252 | `Label("Import", systemImage: "square.and.arrow.down")` |
| 254 | `.help("Import an audio or video file")` |
| 258 | `Button("New Meeting Notes", systemImage: "square.and.pencil") {` |
| 262 | `Button("Import Existing Gday Library…") { MeetingPanels.importLegacy(store) }` |
| 263 | `Button("Import Meeting Archive…") { MeetingPanels.importArchive(store) }` |
| 265 | `Label("Library Actions", systemImage: "ellipsis")` |
| 267 | `.help("New notes and library imports").disabled(!store.libraryWritable)` |
| 275 | `.buttonStyle(ActionButtonStyle()).help("Search meetings and transcripts")` |
| 276 | `.accessibilityLabel("Search meetings and transcripts")` |
| 278 | `TextField("Search meetings and transcripts", text: $search)` |
| 280 | `.accessibilityLabel("Search meetings and transcripts")` |
| 287 | `.buttonStyle(ActionButtonStyle()).accessibilityLabel("Clear search").help(` |
| 328 | `.sheet(isPresented: $store.presentsRecordingSetup) {` |
| 349 | `.alert(` |
| 355 | `Button("OK") { store.errorMessage = nil }` |
| 357 | `Text(Self.alertParts(store.errorMessage).message)` |
| 359 | `.alert(` |
| 365 | `Button("Request Access Again") {` |
| 369 | `Button("Cancel", role: .cancel) { store.recordingPermissionNeeded = nil }` |
| 371 | `Text(` |
| 376 | `.alert(` |
| 381 | `Button("Move to Trash", role: .destructive) {` |
| 386 | `Button("Cancel", role: .cancel) { deleting = nil }` |
| 389 | `Text("The meeting and its saved files will be moved to the Trash. You can restore them in Finder.")` |
| 430 | `.accessibilityLabel("New Recording")` |
| 431 | `.help("New Recording")` |
| 433 | `Text("Select a meeting or start a recording.")` |
| 450 | `Text(playbackTime(elapsed)).font(.title3).monospacedDigit().accessibilityLabel(` |
| 456 | `Button("Show Recording") { showMeeting(id) }` |
| 457 | `Button("Stop & Save", systemImage: "stop.fill") { Task { await store.stopRecording() } }` |
| 587 | `ProgressView().controlSize(.large)` |
| 588 | `Text("Building Index").font(.headline)` |
| 590 | `Text("\(status.discoveredFolders.formatted()) meeting folders checked")` |
| 594 | `Text("\(status.processed.formatted()) meetings processed")` |
| 598 | `Text("Reading meeting folders…").foregroundStyle(.secondary)` |
| 602 | `Text("Meetings will appear as they are indexed.")` |

## LiveTranscriptDisplayCache.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/LiveTranscriptDisplayCache.swift) · SHA-256 `0fd235561e59fb31`

Types: `LiveTranscriptDisplayCache`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## LiveTranscriptStreamDisplayCache.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/LiveTranscriptStreamDisplayCache.swift) · SHA-256 `cb7c320f139488dc`

Types: `LiveTranscriptStreamDisplayCache`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## LiveTranscriptView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/LiveTranscriptView.swift) · SHA-256 `e89373c2038aae33`

Types: `LiveTranscriptView`, `LiveTranscriptDisplay`, `PersonDisplayIdentity`, `LiveTranscriptHeader`, `LiveTranscriptIssueDetails`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 33 | `Label(` |
| 37 | `Text(` |
| 99 | `return AnyView(Text("Speaker is unavailable."))` |
| 196 | `Toggle("Transcribe", isOn: $enabled)` |
| 198 | `Toggle("Label Speakers", isOn: $recognizesSpeakers)` |
| 209 | `.help("Show transcript issues")` |
| 210 | `.accessibilityLabel("Transcript issues")` |
| 211 | `.popover(isPresented: $showsIssues) {` |
| 221 | `Button("Follow Live", action: follow)` |
| 235 | `Text("Transcript Issues").font(.headline)` |
| 237 | `Text(issue).fixedSize(horizontal: false, vertical: true)` |
| 240 | `Button("Open Service Providers", action: openProviders)` |

## LocalSpeakerProviderView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/LocalSpeakerProviderView.swift) · SHA-256 `6c69a052537a2f8c`

Types: `LocalSpeakerProviderView`, `LocalModelDownloadView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 31 | `Label(draft.kind.title, systemImage: draft.kind.systemImage)` |
| 33 | `TextField("Name", text: $draft.name)` |
| 34 | `Toggle("Enable This Provider", isOn: $draft.isEnabled)` |
| 35 | `Text("Audio and speaker association stay on this Mac. Model downloads connect to Hugging Face.")` |
| 38 | `Section("Capabilities") {` |
| 40 | `Toggle(` |
| 53 | `Text(` |
| 60 | `Section("Readiness") {` |
| 64 | `if let reason = result.reason { Text(reason).font(.caption).foregroundStyle(.orange) }` |
| 67 | `Section("Model") {` |
| 68 | `Picker("Preset", selection: $draft.model) {` |
| 69 | `ForEach(choices) { id in Text(LocalModelRegistry.descriptor(id).title).tag(id.rawValue) }` |
| 74 | `Text(` |
| 80 | `Text(` |
| 87 | `Text("Changes apply to the next recording or labeling job.")` |
| 91 | `Section("Speaker Association Model") {` |
| 93 | `Text(` |
| 100 | `if let failure { Text(failure).foregroundStyle(.secondary).textSelection(.enabled) }` |
| 101 | `Button("Save") { save() }.disabled(` |
| 136 | `Text(state.phase == .missing ? readiness.title : state.phase.settingsTitle)` |
| 138 | `Text(` |
| 145 | `Button("Remove Download", role: .destructive) {` |
| 156 | `Button("Download") { models.download(modelID) }.disabled(state.inUse > 0)` |
| 159 | `ProgressView().controlSize(.small)` |
| 161 | `Button("Retry") { models.retry(modelID) }.disabled(state.inUse > 0)` |
| 168 | `.buttonStyle(.plain).accessibilityLabel("Cancel Download")` |
| 170 | `Button("Remove Download", role: .destructive) {` |
| 183 | `ProgressView(value: progress)` |
| 186 | `ProgressView().controlSize(.small)` |
| 188 | `Text(` |
| 195 | `if state.phase == .preparing &#124;&#124; state.phase == .verifying { ProgressView().controlSize(.small) }` |
| 197 | `Text("In use. Stop the current work before removing this model.").font(.caption).foregroundStyle(` |
| 201 | `Text(reason).font(.caption).foregroundStyle(.secondary)` |
| 204 | `Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)` |
| 207 | `Button("Open Model Folder") { openFolder() }` |
| 208 | `Button("Refresh") { Task { await models.refresh() } }` |
| 210 | `DisclosureGroup("Manual Installation") {` |
| 211 | `Text("Copy the selected revision’s files into the model folder. Place these items directly inside it:")` |
| 213 | `Text(` |
| 218 | `Text(` |

## MarkdownControlCursor.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MarkdownControlCursor.swift) · SHA-256 `05b73c0cedc1dfa9`

Types: `MarkdownActionButton`, `MarkdownControlCursor`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## MarkdownInlineCodeAppearance.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MarkdownInlineCodeAppearance.swift) · SHA-256 `a49523505af3a2ce`

Types: `MarkdownInlineCodeAppearance`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## MarkdownNotesEditor.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MarkdownNotesEditor.swift) · SHA-256 `c9527118f6840918`

Types: `MeetingNotesEditor`, `MarkdownNotesEditor`, `NotesTextView`, `Clipboard`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## MeetingArchiveStatusView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MeetingArchiveStatusView.swift) · SHA-256 `5099c2a54899ad33`

Types: `MeetingArchiveStatusView`, `MeetingArchiveListIcon`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 42 | `Label(status.title, systemImage: status.symbol)` |
| 44 | `.accessibilityLabel(status.accessibilityText)` |
| 45 | `.help(status.accessibilityText)` |
| 51 | `Button("Archive to Server") { Task { await store.archiveToServer(id: meetingID) } }` |
| 57 | `.help(` |
| 73 | `.accessibilityLabel(status.accessibilityText)` |
| 74 | `.help(status.title)` |

## MeetingAssociationsView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MeetingAssociationsView.swift) · SHA-256 `2d9d0ee4b3161a5c`

Types: `MeetingTagsView`, `MeetingSpeakersView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 12 | `Text("Tags").font(.callout).foregroundStyle(.secondary)` |
| 19 | `Label(tag.name, systemImage: "xmark.circle.fill")` |
| 25 | `.help("Remove \(tag.name) from this meeting")` |
| 26 | `.accessibilityLabel("Remove tag \(tag.name)")` |
| 30 | `Toggle(` |
| 37 | `Button("New Tag…") {` |
| 42 | `Label("Add Tag", systemImage: "plus").labelStyle(.iconOnly)` |
| 46 | `.help("Add tags to this meeting")` |
| 50 | `.sheet(isPresented: $addingTag) {` |
| 52 | `Text("New Tag").font(.headline)` |
| 53 | `TextField("Name", text: $tagName).onSubmit(addTag)` |
| 56 | `Button("Cancel", role: .cancel) { addingTag = false }.keyboardShortcut(.cancelAction)` |
| 57 | `Button("Add Tag", action: addTag).keyboardShortcut(.defaultAction)` |
| 100 | `.sheet(item: $newPersonSpeaker) { speaker in` |
| 102 | `Text("New Person").font(.headline)` |
| 103 | `TextField("Name", text: $personName).onSubmit { createPerson(speaker) }` |
| 106 | `Button("Cancel", role: .cancel) { newPersonSpeaker = nil }.keyboardShortcut(.cancelAction)` |
| 107 | `Button("Assign Person") { createPerson(speaker) }.keyboardShortcut(.defaultAction)` |
| 116 | `Text(speaker.displayLabel.isEmpty ? "Unlabeled" : speaker.displayLabel)` |
| 119 | `.help([speaker.providerName, speaker.track].filter { !$0.isEmpty }.joined(separator: " · "))` |
| 122 | `Text(personName(for: speaker) ?? "Unassigned").lineLimit(1)` |
| 135 | `Button("Remove Assignment") {` |
| 141 | `Menu(personName(for: speaker) ?? "Assign Person") {` |
| 143 | `Button(person.name) {` |
| 148 | `Button("New Person…") {` |
| 153 | `Button("Remove Assignment") {` |
| 160 | `.accessibilityLabel(` |
| 163 | `.accessibilityValue(personName(for: speaker) ?? "Unassigned")` |
| 164 | `.help(` |

## MeetingContentTabs.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MeetingContentTabs.swift) · SHA-256 `6e12a4e3bc9ce045`

Types: `MeetingContentTabs`, `MeetingGlassSurface`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 19 | `Text(titles[index])` |
| 39 | `.accessibilityLabel("Meeting content")` |

## MeetingDataPrivacyView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MeetingDataPrivacyView.swift) · SHA-256 `b7acc3f94716f6cd`

Types: `MeetingDataPrivacyView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 15 | `Text("Data Privacy").font(.headline)` |
| 17 | `Button("Reveal Meeting Folder", systemImage: "folder") {` |
| 23 | `Text("File changes and data transfers, grouped by file, action, and destination.")` |
| 25 | `if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }` |
| 27 | `Text(` |
| 33 | `ContentUnavailableView(` |
| 35 | `description: Text(` |
| 72 | `return DisclosureGroup(` |
| 87 | `Button("Reveal File", systemImage: "doc") {` |
| 100 | `Label(` |
| 108 | `Text(group.events.count == 1 ? "1 event" : "\(group.events.count) events")` |
| 111 | `Text("\(group.action.rawValue.capitalized) · \(destination(flow))")` |
| 114 | `Text("\(flow.location == .local ? "Local" : "Remote")\(flow.domain.map { " · " + $0 } ?? "")")` |
| 116 | `Text("Latest \(flow.startedAt.formatted(date: .abbreviated, time: .standard))")` |
| 148 | `Text(flow.purpose).font(.callout)` |
| 150 | `Text(flow.startedAt, format: .dateTime.hour().minute().second())` |
| 159 | `Text(title).foregroundStyle(.secondary)` |
| 160 | `Text(value)` |

## MeetingDetailView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MeetingDetailView.swift) · SHA-256 `cf1000a1fef27580`

Types: `MeetingDetailView`, `SummaryReadingView`, `MeetingActionsMenu`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 82 | `Text(meeting.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())` |
| 84 | `Text(formatTime(meeting.duration)).monospacedDigit().accessibilityLabel(` |
| 102 | `Label(` |
| 115 | `.help(` |
| 142 | `Text("Summary").font(.headline)` |
| 144 | `Button(meeting.summary.isEmpty ? "Generate Summary" : "Regenerate Summary", systemImage: "sparkles")` |
| 155 | `.accessibilityLabel("Summary")` |
| 203 | `Button("Export Meeting Text…", systemImage: "square.and.arrow.up") {` |
| 206 | `Button("Archive to Server", systemImage: "icloud.and.arrow.up") {` |
| 214 | `Label("Meeting Actions", systemImage: "ellipsis.circle")` |
| 216 | `.help("Transcribe, export, or archive this meeting")` |

## MeetingExportPanel.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MeetingExportPanel.swift) · SHA-256 `5e0732e002b4478d`

Types: `MeetingExportPanel`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## MeetingLanguagePicker.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MeetingLanguagePicker.swift) · SHA-256 `e2d29539e4822a37`

Types: `MeetingLanguagePicker`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 25 | `.accessibilityLabel("Language Information")` |
| 26 | `.help("About transcription language")` |
| 27 | `.popover(isPresented: $showInformation) {` |
| 29 | `Text("Transcription Language").font(.headline)` |
| 30 | `Text("Choose the language spoken in the recording.")` |
| 31 | `Text(` |
| 49 | `Picker(` |
| 55 | `ForEach(AppLanguages.all) { Text($0.name).tag($0.code) }` |
| 57 | `Text(AppLanguages.name(for: selection)).tag(selection).disabled(true)` |

## MeetingNotesWorkspace.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MeetingNotesWorkspace.swift) · SHA-256 `c6eb57ccb257d8a9`

Types: `MeetingNotesWorkspace`, `MeetingMarkdownReadingView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 12 | `Text("Meeting Notes").font(.headline)` |
| 16 | `Text("Saved as you type").font(.caption).foregroundStyle(.secondary)` |
| 18 | `Picker(` |
| 25 | `Image(systemName: "pencil").help("Edit notes").accessibilityLabel("Edit Notes").tag(false)` |
| 26 | `Image(systemName: "book").help("Read notes").accessibilityLabel("Read Notes").tag(true)` |
| 32 | `.accessibilityLabel("Notes View")` |

## MeetingPlayerBar.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MeetingPlayerBar.swift) · SHA-256 `2e7790d3f7cb6b3f`

Types: `MeetingPlayerBar`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 38 | `Text(playback.title).font(.callout.weight(.semibold)).lineLimit(1)` |
| 39 | `Text(` |
| 51 | `.help("Show the meeting. Command-click to reveal its folder in Finder.")` |
| 53 | `.accessibilityLabel("Show meeting: \(playback.title)")` |
| 62 | `ProgressView().controlSize(.small)` |
| 70 | `.accessibilityLabel(playback.isPlaying ? "Pause" : "Play")` |
| 71 | `.help(playback.isPlaying ? "Pause playback" : "Play recording")` |
| 85 | `Button(action: toggleTracks) {` |
| 90 | `.accessibilityLabel(tracksExpanded ? "Hide audio tracks" : "Show audio tracks")` |
| 91 | `.help(tracksExpanded ? "Hide audio tracks" : "Show audio tracks")` |
| 93 | `Picker(` |
| 98 | `Text("\(rate.formatted())×").tag(rate)` |
| 103 | `Text("\(playback.playbackRate.formatted())×").monospacedDigit()` |
| 108 | `.accessibilityLabel("Playback speed")` |
| 109 | `.help("Playback speed")` |
| 112 | `Picker(` |
| 116 | `Text("All Tracks").tag(-1)` |
| 118 | `Text(name).tag(index)` |
| 122 | `Button("Close Player", systemImage: "xmark") { playback.clear() }` |
| 125 | `Label(selectedTrackName, systemImage: "slider.horizontal.3").lineLimit(1)` |
| 130 | `.accessibilityLabel("Audio track and player options")` |
| 131 | `.accessibilityValue(selectedTrackName)` |
| 132 | `.help("Choose microphone, system audio, or all tracks")` |
| 142 | `Text(name).font(.caption).lineLimit(1)` |
| 147 | `.help("Command-click to reveal this audio file in Finder.")` |
| 149 | `.contextMenu { Button("Reveal in Finder") { revealTrack(index) } }` |
| 160 | `.accessibilityLabel(` |
| 163 | `.help("\(playback.mutedTracks.contains(index) ? "Unmute" : "Mute") \(name)")` |
| 199 | `Label(error, systemImage: "exclamationmark.triangle")` |
| 289 | `Button(action: action) { Image(systemName: symbol).font(.title3).frame(width: 44, height: 44) }` |
| 290 | `.buttonStyle(ActionButtonStyle()).accessibilityLabel(title).help(title)` |

## MeetingTitleView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MeetingTitleView.swift) · SHA-256 `9daf6d67efb4b6d0`

Types: `MeetingTitleView`, `MeetingTitleEditor`, `Coordinator`, `MeetingTitleTextField`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 17 | `Text(Self.displayTitle(title))` |
| 24 | `.accessibilityLabel(title)` |
| 28 | `Button("Edit Title", action: begin).disabled(!editable)` |
| 29 | `Button("Open Meeting Folder", action: openFolder)` |
| 31 | `.help("\(title)\nDouble-click to edit. Command-click to open the meeting folder in Finder.")` |

## MeetingTranscriptView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/MeetingTranscriptView.swift) · SHA-256 `c698ce9adb9d8d64`

Types: `MeetingTranscriptView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 48 | `Text(` |
| 54 | `if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }` |
| 59 | `ContentUnavailableView(` |
| 61 | `description: Text("Transcribe the recording to create a transcript.")` |
| 92 | `return AnyView(Text("Speaker is unavailable."))` |
| 97 | `DisclosureGroup("Speakers") {` |
| 122 | `Button("Cancel Speaker Labeling") { store.cancelLocalDiarization(id: meetingID) }` |
| 127 | `Button("Label Speakers") {` |
| 136 | `.help(` |
| 146 | `Menu("Transcript History") {` |
| 150 | `Button(` |
| 164 | `Label(` |

## ModelComboBox.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/ModelComboBox.swift) · SHA-256 `6e76b1e164aae3fa`

Types: `ModelComboBox`, `Coordinator`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## NativeMarkdownReadingView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/NativeMarkdownReadingView.swift) · SHA-256 `c73efe9df5e0e467`

Types: `NativeMarkdownReadingView`, `MarkdownReadingTextView`, `CodeRegion`, `TaskRegion`, `MarkdownReadingRenderer`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## NativeMeetingList.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/NativeMeetingList.swift) · SHA-256 `f35181559b006f92`

Types: `NativeMeetingList`, `Coordinator`, `MeetingNativeTable`, `MeetingNativeCell`, `MeetingSummaryPreview`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## NativeTranscriptView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/NativeTranscriptView.swift) · SHA-256 `0835a301c7724085`

Types: `TranscriptDisplayRow`, `NativeTranscriptView`, `Coordinator`, `TranscriptHeightCache`, `Entry`, `TranscriptNativeScroller`, `TranscriptNativeScrollView`, `TranscriptNativeTable`, `TranscriptNativeRowView`, `TranscriptSpeakerPalette`, `TranscriptSpeakerBadge`, `TranscriptNativeCell`, `TranscriptLiveWordColor`, `TranscriptRowUpdate`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## NotesEditorLineIndex.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/NotesEditorLineIndex.swift) · SHA-256 `8f932421c9f5855c`

Types: `NotesEditorLineIndex`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## NotesImagePresentation.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/NotesImagePresentation.swift) · SHA-256 `016179f2786a74f5`

Types: `NotesImagePresentation`, `NotesImageView`, `NotesImageFieldValidation`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## PersonTagsView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/PersonTagsView.swift) · SHA-256 `328fb13813515a77`

Types: `PersonTagsView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 10 | `Text("Tags").font(.callout).foregroundStyle(.secondary)` |
| 17 | `Label(tag.name, systemImage: "xmark.circle.fill")` |
| 23 | `.help("Remove \(tag.name) from this person")` |
| 24 | `.accessibilityLabel("Remove tag \(tag.name)")` |
| 28 | `Toggle(` |
| 36 | `Label("Add Tag", systemImage: "plus").labelStyle(.iconOnly)` |
| 41 | `.help("Add tags to this person")` |

## PlaybackSpaceKey.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/PlaybackSpaceKey.swift) · SHA-256 `87c78e64fb08a978`

Types: `DirectoryControlFocusKey`, `PlaybackSpaceKey`, `KeyView`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## PlaybackWaveformSurface.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/PlaybackWaveformSurface.swift) · SHA-256 `3e89fe40f67e6d96`

Types: `PlaybackWaveformSurface`, `PlaybackWaveformView`, `TickTarget`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## ProviderReadinessRow.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/ProviderReadinessRow.swift) · SHA-256 `9d999e012c644cbb`

Types: `ProviderReadinessRow`, `ProviderReadinessDetails`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 18 | `Label(` |
| 24 | `Text(provider.isEnabled ? provider.kind.title : "Disabled")` |
| 40 | `.help("Show provider readiness for \(provider.name)")` |
| 41 | `.accessibilityLabel("Provider readiness for \(provider.name)")` |
| 42 | `.popover(isPresented: $showsIssues) {` |
| 61 | `Text("Provider Readiness").font(.headline)` |
| 63 | `Text(message).fixedSize(horizontal: false, vertical: true)` |
| 65 | `Button("Open Provider Settings", action: showModels)` |

## RecordingActivitySurface.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/RecordingActivitySurface.swift) · SHA-256 `61684c23359de4f9`

Types: `RecordingActivitySurface`, `RecordingActivityView`, `Target`, `RecordingLiveActivitySurface`, `Coordinator`, `RecordingLiveLevelSurface`, `Coordinator`, `RecordingLevelView`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## RecordingStripTitle.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/RecordingStripTitle.swift) · SHA-256 `776d338b10d3a72b`

Types: `RecordingStripTitle`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 23 | `.help("Show the recording. Command-click to reveal its folder in Finder.")` |
| 24 | `.accessibilityLabel("Show Recording")` |
| 35 | `ProgressView().controlSize(.small)` |
| 42 | `Text(` |
| 48 | `Text(meeting.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)` |
| 51 | `Text("Complete the macOS audio consent prompt.").font(.caption).foregroundStyle(.secondary)` |

## RecordingWorkspaceView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/RecordingWorkspaceView.swift) · SHA-256 `fdb65b66fa1ceaa3`

Types: `RecordingSetupView`, `MicrophoneMenuItem`, `RecordingSourceRow`, `RecordingWorkspaceView`, `RecordingReconnectStatus`, `RecordingLiveMeters`, `RecordingVoiceProcessingControl`, `RecordingSourceMeter`, `RecordingSettingsDisclosure`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 63 | `Text("New Recording").font(.title2.weight(.semibold))` |
| 64 | `Text("Choose audio sources to record.")` |
| 73 | `Text("Meeting Title").font(.subheadline.weight(.medium))` |
| 74 | `TextField("Untitled Meeting", text: $title)` |
| 75 | `.textFieldStyle(.roundedBorder).accessibilityLabel("Meeting Title").disabled(` |
| 95 | `Label("Choose at least one audio source.", systemImage: "info.circle")` |
| 98 | `DisclosureGroup("Recording Options", isExpanded: $showOptions) {` |
| 100 | `Picker("Audio Format", selection: $format) {` |
| 101 | `Text("Opus (Recommended)").tag(RecordingFormat.opus)` |
| 102 | `Text("M4A (AAC)").tag(RecordingFormat.m4a)` |
| 103 | `Text("WAV").tag(RecordingFormat.wav)` |
| 118 | `Text(startupError).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)` |
| 133 | `Text("Audio sources are saved as separate tracks.")` |
| 138 | `ProgressView().controlSize(.small)` |
| 139 | `Text("Preparing…").font(.callout).foregroundStyle(.secondary)` |
| 142 | `Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)` |
| 144 | `Button(startupError == nil ? "Start Recording" : "Try Again") {` |
| 174 | `Picker(` |
| 194 | `Text(item.title).tag(item.uid)` |
| 238 | `Text(name).fontWeight(.medium)` |
| 239 | `Text(subtitle).font(.caption).foregroundStyle(.secondary)` |
| 243 | `Toggle(name, isOn: $isOn).labelsHidden().toggleStyle(.switch)` |
| 281 | `Text(Self.elapsed(elapsed)).font(.system(size: 26, weight: .medium, design: .rounded))` |
| 283 | `.accessibilityLabel("Recording duration").accessibilityValue(Self.elapsed(elapsed))` |
| 285 | `Text(store.isFinalizingRecording ? "Saving" : "Recording")` |
| 289 | `Text(meeting.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())` |
| 301 | `ProgressView().controlSize(.small)` |
| 302 | `Text("Saving audio…").foregroundStyle(.secondary)` |
| 308 | `Label("Stop & Save", systemImage: "stop.fill")` |
| 353 | `Label(status, systemImage: "arrow.triangle.2.circlepath")` |
| 391 | `Toggle("Voice Processing", isOn: Binding(get: { status.voiceProcessing }, set: onChange))` |
| 394 | `.help("Reduces echo and background noise in the microphone track. May lower other apps’ volume.")` |
| 396 | `Label("Echo detected", systemImage: "exclamationmark.triangle")` |
| 398 | `.help("The microphone is picking up system audio. Turn on Voice Processing or use headphones.")` |
| 402 | `Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)` |
| 436 | `.accessibilityLabel("\(source.muted ? "Unmute" : "Mute") \(title)")` |
| 437 | `.accessibilityValue(statusText)` |
| 438 | `.help(saving &#124;&#124; !source.enabled ? statusText : "\(source.muted ? "Unmute" : "Mute") \(title)")` |
| 510 | `Text(title)` |
| 511 | `if source.muted { Text("Muted").foregroundStyle(.secondary) }` |
| 552 | `Text(summary(meeting)).font(.callout)` |
| 558 | `.accessibilityLabel("Recording Settings")` |
| 559 | `.accessibilityValue("\(expanded ? "Expanded" : "Collapsed"). \(summary(meeting))")` |
| 560 | `.help(expanded ? "Hide Recording Settings" : "Show Recording Settings")` |

## ServiceProvidersView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/ServiceProvidersView.swift) · SHA-256 `009ad7f844b99d50`

Types: `ServiceProvidersView`, `ServiceProviderPanel`, `ModelListState`, `ProviderPanelWindowObserver`, `ProviderPanelWindowView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 19 | `Label("This Mac", systemImage: "desktopcomputer")` |
| 20 | `Text("Live Transcription").font(.caption).foregroundStyle(.secondary)` |
| 38 | `Label(kind.title, systemImage: kind.systemImage)` |
| 48 | `.accessibilityLabel("Add Provider").help("Add Provider")` |
| 55 | `.accessibilityLabel("Remove Provider").help("Remove Provider")` |
| 73 | `Label("Service Providers", systemImage: "server.rack")` |
| 75 | `Text("Add a provider to transcribe recordings or create summaries.")` |
| 83 | `ProgressView("Removing Provider…").padding()` |
| 88 | `.alert(` |
| 92 | `Button("OK") { saveError = nil }` |
| 94 | `Text(saveError ?? "")` |
| 96 | `.confirmationDialog("Remove Provider?", isPresented: $confirmsRemoval) {` |
| 97 | `Button("Remove Provider", role: .destructive) { removeSelected() }` |
| 98 | `Button("Cancel", role: .cancel) {}` |
| 100 | `Text(` |
| 190 | `Label(draft.kind.title, systemImage: draft.kind.systemImage)` |
| 192 | `TextField("Name", text: $draft.name)` |
| 193 | `Toggle("Enable This Provider", isOn: $draft.isEnabled)` |
| 195 | `Section("Connection") {` |
| 196 | `TextField(draft.kind == .gdayWebsite ? "Website URL" : "Endpoint URL", text: $draft.endpoint)` |
| 198 | `.help(endpointHelp)` |
| 200 | `SecureField("API Key", text: $draft.apiKey)` |
| 201 | `.help("Create an API key in the provider’s account settings.")` |
| 207 | `Picker("Image Input", selection: imageInputBinding) {` |
| 208 | `Text("Automatic").tag(0)` |
| 209 | `Text("Supports Images").tag(1)` |
| 210 | `Text("Text Only").tag(2)` |
| 212 | `Text(imageInputDescription).font(.caption).foregroundStyle(.secondary)` |
| 218 | `Button("Sign Out") {` |
| 228 | `Button(signingIn ? "Signing In…" : "Sign In with Browser…") { signIn() }` |
| 232 | `if isChecking { ProgressView().controlSize(.small).accessibilityLabel("Checking Connection") }` |
| 233 | `Label(` |
| 247 | `.accessibilityLabel("About Connection Checks")` |
| 248 | `.help("About connection checks")` |
| 249 | `.popover(isPresented: $showsConnectionInfo) {` |
| 250 | `Text(` |
| 259 | `Label(saveError, systemImage: "exclamationmark.circle.fill")` |
| 264 | `Section("Audio Uploads") {` |
| 265 | `Picker("Upload Provider", selection: $draft.uploadProviderID) {` |
| 266 | `Text("None").tag(nil as UUID?)` |
| 268 | `Text(provider.name).tag(Optional(provider.id))` |
| 271 | `Label(` |
| 276 | `Text(` |
| 280 | `Button("Add Filedrop Provider…") { addProvider(.filedrop) }` |
| 285 | `Section("Summary Prompt") {` |
| 289 | `.accessibilityLabel("Summary Prompt")` |
| 290 | `Text(` |
| 294 | `Button("Restore Default") { draft.summaryPrompt = SummaryPrompt.defaultInstructions }` |
| 298 | `Section("Capabilities") {` |
| 301 | `Toggle(capability.title, isOn: capabilityBinding(capability))` |
| 302 | `Text(disclosure(capability)).font(.caption).foregroundStyle(.secondary)` |
| 310 | `Button("Save") { saveAndCheck() }` |
| 313 | `Button("Check Connection") { startCheck() }` |
| 369 | `Text("Loading Models…").font(.caption).foregroundStyle(.secondary)` |
| 371 | `Label(` |
| 379 | `Label("\(model) (not listed)", systemImage: "questionmark.circle")` |
| 381 | `.help("This provider’s model list does not include this model. It is used as entered.")` |
| 387 | `Text("Enter the endpoint URL and API key to choose from the provider’s models.")` |
| 435 | `Section("Transcription Languages") {` |
| 438 | `Label("\(catalog.languages.count) languages · Built in", systemImage: "checkmark.circle")` |
| 444 | `Label(languageStatus.text, systemImage: languageStatus.icon)` |
| 449 | `Button("Load Languages") {` |

## SettingsView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/SettingsView.swift) · SHA-256 `e9ae8e8e0fbb9e21`

Types: `SettingsView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 19 | `.tabItem { Label("General", systemImage: "slider.horizontal.3") }` |
| 22 | `.tabItem { Label("Service Providers", systemImage: "server.rack") }` |
| 25 | `.tabItem { Label("Data", systemImage: "externaldrive") }` |
| 28 | `.tabItem { Label("Data Privacy", systemImage: "hand.raised") }` |

## TaskNavigation.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/TaskNavigation.swift) · SHA-256 `4601a10fe679cf17`

Types: `ShowManagedTaskKey`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## TaskQueueView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/TaskQueueView.swift) · SHA-256 `a2a48c23c77610ac`

Types: `TaskQueueView`, `TaskQueueStatusButton`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 11 | `Text("Tasks").font(.largeTitle.bold())` |
| 13 | `Text(store.taskQueueSummary)` |
| 17 | `Text(error).foregroundStyle(.red).textSelection(.enabled)` |
| 20 | `ContentUnavailableView(` |
| 22 | `description: Text(` |
| 33 | `Label("Needs Attention", systemImage: "exclamationmark.circle.fill")` |
| 39 | `Text("Other Tasks").font(.headline)` |
| 47 | `Text("Other Activity").font(.headline)` |
| 50 | `ProgressView().controlSize(.small)` |
| 51 | `Text(store.progressText(for: job)).frame(` |
| 54 | `Button("Open Meeting") { showMeeting(id) }` |
| 78 | `ProgressView().controlSize(.small).padding(.top, 3)` |
| 87 | `Text(record.meetingTitle).font(.headline).textSelection(.enabled)` |
| 89 | `Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))` |
| 91 | `.accessibilityLabel(` |
| 94 | `Text(operation(record.kind) + providerSuffix(record)).font(.subheadline).foregroundStyle(.secondary)` |
| 95 | `Text(record.progress).font(.callout)` |
| 99 | `Text(error).font(.callout).textSelection(.enabled)` |
| 102 | `Text("Restart sends the recording to the provider again.")` |
| 106 | `Text("Dismiss discards this saved request. The provider may continue processing it.")` |
| 110 | `Text("The provider may continue processing after you stop waiting.")` |
| 133 | `Button("Restart") { store.restartManagedTask(id: record.id) }` |
| 137 | `Button(store.managedTaskActionTitle(record)) { store.retryManagedTask(id: record.id) }` |
| 141 | `Button("Open Meeting") { showMeeting(record.meetingID) }` |
| 145 | `Button("Run Next") { store.prioritizeManagedTask(id: record.id) }` |
| 147 | `Button(record.state == .queued ? "Remove from Queue" : "Stop Waiting") {` |
| 152 | `Button("Dismiss") { store.removeManagedTask(id: record.id) }` |
| 193 | `Label(` |
| 201 | `Text(store.taskQueueActivitySummary).font(.callout).foregroundStyle(.secondary)` |
| 204 | `Button(` |
| 209 | `.help("Show tasks that need attention")` |
| 220 | `Button(action: action) {` |
| 223 | `ProgressView().controlSize(.small)` |
| 228 | `Text(store.taskQueueSummary).font(.caption)` |
| 230 | `Text("Tasks").font(.caption)` |
| 237 | `.help("Show tasks").accessibilityLabel("Show Tasks: \(store.taskQueueSummary)")` |

## ThisMacProviderView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/ThisMacProviderView.swift) · SHA-256 `3f107eacfbfdc251`

Types: `ThisMacProviderView`, `SpeechModelReadiness`, `SpeechModelOption`, `SpeechModelOrdering`, `SpeechModelRow`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 12 | `Label("This Mac", systemImage: "desktopcomputer").font(.title2.weight(.semibold))` |
| 13 | `Text("Live transcription audio stays on this Mac.")` |
| 14 | `Text(` |
| 19 | `Section("Capabilities") {` |
| 20 | `Toggle(` |
| 34 | `Text("Transcribes audio during recording.").font(.caption).foregroundStyle(.secondary)` |
| 36 | `Section("Readiness") {` |
| 39 | `if let reason = result.reason { Text(reason).font(.caption).foregroundStyle(.orange) }` |
| 41 | `Section("Speech Models") {` |
| 42 | `if models.isEmpty { Text(message).foregroundStyle(.secondary) }` |
| 127 | `Text(model.language.name)` |
| 129 | `Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)` |
| 135 | `ProgressView(value: progress).frame(width: 85)` |
| 136 | `.accessibilityLabel("Speech model download")` |
| 139 | `Text("Installed").foregroundStyle(.secondary)` |
| 142 | `Button("Download") { Task { await download() } }` |
| 145 | `Text("Unavailable on this Mac").foregroundStyle(.secondary)` |
| 148 | `if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }` |

## TranscriptEditSession.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/TranscriptEditSession.swift) · SHA-256 `bdebb370a1d32193`

Types: `TranscriptEditSession`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## TranscriptRow.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/TranscriptRow.swift) · SHA-256 `d24e9ad9b5cf373a`

Types: `TranscriptRow`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 20 | `Button(action: seek) {` |
| 21 | `Text(Self.timestamp(start)).monospacedDigit().fixedSize()` |
| 29 | `.help("Play from this point")` |
| 30 | `.accessibilityLabel("Play from \(Self.timestamp(start))")` |
| 40 | `Text(speaker).fontWeight(.semibold)` |
| 48 | `if let source { Text(source) }` |
| 49 | `if provisional { Text("Draft") }` |
| 59 | `Text("00:00:00").hidden().accessibilityHidden(true)` |
| 60 | `Text(Self.timestamp(start))` |

## TranscriptSpeakerPicker.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/TranscriptSpeakerPicker.swift) · SHA-256 `6f39b3cb54a88d8e`

Types: `TranscriptSpeakerSearch`, `TranscriptSpeakerPicker`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 38 | `Text("Assign Person").font(.headline)` |
| 40 | `Toggle("Apply to This Speaker", isOn: $appliesToSpeaker)` |
| 43 | `TextField("Search people", text: $query).focused($focused)` |
| 52 | `Text(person.name)` |
| 61 | `Button("Create and Assign \(newName)") { assign(store.addPerson(name: newName)) }` |
| 64 | `Button("Remove Assignment") { assign(nil) }` |

## TranscriptionActionButton.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/TranscriptionActionButton.swift) · SHA-256 `067e15d3aceda54b`

Types: `TranscriptionActionButton`, `PendingTranscriptionActions`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 25 | `Button(` |
| 31 | `.help("Show this transcription in Tasks")` |
| 34 | `Button("Apply Saved Transcript…", systemImage: "text.bubble") { confirming = true }` |
| 38 | `Button("Resume Transcription", systemImage: "text.bubble") {` |
| 43 | `Button("\(verb) with \(provider.name)", systemImage: "text.bubble") {` |
| 48 | `Menu(verb, systemImage: "text.bubble") {` |
| 50 | `Button("\(verb) with \(provider.name)") { start(provider) }` |
| 55 | `Button("Set Up Transcription…", systemImage: "text.bubble") {` |
| 61 | `.confirmationDialog("Replace the current transcript?", isPresented: $confirming, titleVisibility: .visible) {` |
| 62 | `Button("Replace Transcript") { store.applySavedTranscriptionResult(meetingID: meeting.id) }` |
| 63 | `Button("Cancel", role: .cancel) {}` |
| 65 | `Text("The current transcript and its edits will be kept in Transcript History. The recording is kept.")` |
| 79 | `Button("Discard Pending Request…", role: .destructive) { confirming = true }` |
| 81 | `.confirmationDialog("Discard this pending request?", isPresented: $confirming, titleVisibility: .visible) {` |
| 82 | `Button("Discard Pending Request", role: .destructive) {` |
| 86 | `Button("Cancel", role: .cancel) {}` |
| 88 | `Text(` |

## ViewState.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/ViewState.swift) · SHA-256 `186f79d55ea49e4e`

Types: .

Native drawing, interaction, or supporting implementation; review with its owning component.

## VoiceLibraryView.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/VoiceLibraryView.swift) · SHA-256 `88729d376416abee`

Types: `VoiceLibraryView`, `VoiceFilter`, `Group`, `PersonVoiceSamplesView`, `VoicePreparationControls`, `VoiceExamplePlaybackButton`, `VoicePersonAssignmentView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 57 | `Text(person.map { "\($0.name)’s Voice Samples" } ?? "Review Voices").font(.title2.bold())` |
| 58 | `Text("Listen to examples before confirming a person.").foregroundStyle(.secondary)` |
| 61 | `Button("Undo", systemImage: "arrow.uturn.backward") { library.undo() }` |
| 63 | `Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)` |
| 69 | `Picker("Voices", selection: $filter) {` |
| 70 | `ForEach(VoiceFilter.allCases) { Text($0.rawValue).tag($0) }` |
| 76 | `Label(groupTitle(group), systemImage: groupIcon(group)).font(.headline)` |
| 77 | `Text(groupSummary(group))` |
| 82 | `Text("Select individual examples to change their assignments.")` |
| 101 | `Label(groups.isEmpty ? "No Voice Samples" : "Select a Voice", systemImage: "waveform")` |
| 103 | `Text(` |
| 112 | `Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)` |
| 130 | `.sheet(isPresented: $assigning) {` |
| 137 | `.sheet(isPresented: $merging) {` |
| 139 | `Text("Merge Voice Groups").font(.title2.bold())` |
| 140 | `Text("Move the selected examples into another group. Person assignments stay unchanged.")` |
| 150 | `Text(groupTitle(group)).font(.headline)` |
| 151 | `Text(groupSummary(group))` |
| 160 | `Button("Cancel") { merging = false }.keyboardShortcut(.cancelAction)` |
| 163 | `.sheet(isPresented: Binding(get: { selectedMeeting != nil }, set: { if !$0 { selectedMeeting = nil } })) {` |
| 168 | `Button("Done") { self.selectedMeeting = nil }.keyboardShortcut(.cancelAction)` |
| 208 | `Text(groupTitle(group)).font(.title3.bold())` |
| 211 | `Button("Select All") { selectedExamples = Set(group.examples.map(\.id)) }` |
| 218 | `Toggle(` |
| 231 | `).toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Select voice example")` |
| 234 | `Text(` |
| 240 | `Text(date, format: .dateTime.month(.abbreviated).day().year()).font(.caption).foregroundStyle(` |
| 244 | `Text(sourceTitle(example.source))` |
| 246 | `Button("\(TranscriptRow<Text>.timestamp(start))–\(TranscriptRow<Text>.timestamp(end))") {` |
| 253 | `Label(status(example), systemImage: example.excluded ? "minus.circle" : "person.crop.circle")` |
| 257 | `Button("Open Recording") { open(example) }.controlSize(.small)` |
| 260 | `Text("This example’s audio excerpt is unavailable. Open its recording to review it.")` |
| 268 | `Button("Confirm \(candidateName)") { library.confirm(ids: [example.id], personID: candidate) }` |
| 270 | `Button("Not \(candidateName)") { library.reject(ids: [example.id], personID: candidate) }` |
| 272 | `Button("Assign…") {` |
| 278 | `Button(example.excluded ? "Use for Voice Recognition" : "Don’t Use for Voice Recognition") {` |
| 281 | `if example.personID != nil { Button("Remove Assignment") { library.clear(ids: [example.id]) } }` |
| 282 | `Button("Separate from Group") { library.split(ids: [example.id]) }` |
| 286 | `.menuStyle(.borderlessButton).fixedSize().help("Voice example actions")` |
| 287 | `.accessibilityLabel("Voice example actions")` |
| 300 | `Text("\(selectedExamples.count) selected").font(.caption).foregroundStyle(.secondary)` |
| 302 | `Button("Assign Selected…") { presentAssignment(ids: selectedExamples) }.disabled(selectedExamples.isEmpty)` |
| 303 | `Menu("Group") {` |
| 304 | `Button("Merge with Another Group…") { merging = true }` |
| 306 | `Button("Separate Selected Examples") { library.split(ids: selectedExamples) }` |
| 308 | `Menu("More") {` |
| 309 | `Button("Don’t Use for Voice Recognition") { library.exclude(ids: selectedExamples) }` |
| 310 | `Button("Use for Voice Recognition") { library.exclude(ids: selectedExamples, excluded: false) }` |
| 311 | `Button("Remove Assignment") { library.clear(ids: selectedExamples) }` |
| 379 | `Label("Voice Samples", systemImage: "waveform").font(.headline)` |
| 381 | `Button("Review Voice Samples…", action: review)` |
| 384 | `Text("No reviewed voice samples. Review recording excerpts to confirm this person’s voice.")` |
| 388 | `Text(` |
| 397 | `Text(example.review == .confirmed ? "Confirmed Example" : "Needs Review").font(.caption)` |
| 399 | `Text(` |
| 428 | `DisclosureGroup("Speaker Association", isExpanded: $expanded) {` |
| 430 | `Text(` |
| 435 | `Picker("Provider", selection: $providerID) {` |
| 436 | `Text("Choose a Provider").tag(UUID?.none)` |
| 443 | `Text(provider.name).tag(Optional(provider.id))` |
| 446 | `if loading { ProgressView().controlSize(.small) }` |
| 450 | `Button("Prepare Reviewed Voices") { start(discover: false) }` |
| 452 | `Button("Find Voices in Recordings") { start(discover: true) }` |
| 455 | `Text("Recordings without voice examples need the Community-1 Speaker Labeling model.")` |
| 459 | `Label(reason, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)` |
| 462 | `Text("Voice examples are processed on this Mac. Compatible prepared examples are reused.")` |
| 467 | `Text("Choose a provider above. Add providers in Settings → Service Providers.")` |
| 471 | `Text("Finish the recording before preparing voice examples.").font(.caption).foregroundStyle(` |
| 474 | `if let error { Text(error).font(.caption).foregroundStyle(.red) }` |
| 478 | `Text(job.providerName).font(.headline)` |
| 479 | `Text("\(job.progress) · \(stateTitle(job.state))").font(.caption).foregroundStyle(` |
| 482 | `DisclosureGroup("\(job.failures.count) Examples Need Attention") {` |
| 484 | `Text(job.failures[key] ?? "Couldn’t prepare this example.")` |
| 492 | `Button("Pause") { store.voicePreparation.pause(jobID: job.id) }` |
| 495 | `Button(job.state == .failed ? "Retry" : "Resume") {` |
| 574 | `.help(!available ? "The recording excerpt is unavailable." : playing ? "Pause excerpt" : "Play excerpt")` |
| 575 | `.accessibilityLabel(playing ? "Pause excerpt" : "Play excerpt")` |
| 591 | `Text("Assign \(count) Selected \(count == 1 ? "Example" : "Examples")").font(.title2.bold())` |
| 592 | `Text("Only the selected examples will be confirmed for this person.").foregroundStyle(.secondary)` |
| 593 | `TextField("Search people or enter a name", text: $query)` |
| 600 | `Text(person.name)` |
| 606 | `if let error { Text(error).font(.callout).foregroundStyle(.red) }` |
| 608 | `Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)` |
| 613 | `Button("Create Person") {` |

## WaveformScrollInput.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/WaveformScrollInput.swift) · SHA-256 `ad6eb3e14b3b8537`

Types: `WaveformScrollInput`, `WaveformScrollGesture`, `WaveformScrollView`.

Native drawing, interaction, or supporting implementation; review with its owning component.

## WaveformTimeline.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/UI/WaveformTimeline.swift) · SHA-256 `3f07f17a64fef485`

Types: `WaveformTimeline`, `PlaybackPosition`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 56 | `Text(isLoading ? "Loading waveform…" : "Waveform unavailable").font(.caption2).foregroundStyle(` |
| 72 | `.accessibilityLabel(label)` |
| 73 | `.accessibilityValue("\(playbackTime(time)) of \(playbackTime(duration))")` |
| 81 | `.help("Click, drag, or scroll horizontally to seek. Arrow keys move five seconds.")` |
| 110 | `Text(playbackTime(progress.displayedTime))` |
| 112 | `Text("−" + playbackTime(max(0, duration - progress.displayedTime)))` |

## GdayMeetingsApp.swift

[Source](../../apps/client-macos-swift/Sources/GdayMeetings/GdayMeetingsApp.swift) · SHA-256 `44428a925e743a1b`

Types: `GdayMeetingsApp`, `MenuBarArtwork`, `MeetingsAppDelegate`, `RecordingMenuView`.

| Line | Control, text, or presentation expression |
| --- | --- |
| 38 | `Button("New Recording…") {` |
| 46 | `Button("Import Audio…") { MeetingPanels.importAudio(store) }.keyboardShortcut("o")` |
| 48 | `Button("Import Existing Gday Library…") { MeetingPanels.importLegacy(store) }` |
| 50 | `Button("Import Meeting Archive…") { MeetingPanels.importArchive(store) }` |
| 54 | `Button("Bold") { NSApp.sendAction(#selector(NotesTextView.markdownBold(_:)), to: nil, from: nil) }` |
| 56 | `Button("Italic") { NSApp.sendAction(#selector(NotesTextView.markdownItalic(_:)), to: nil, from: nil) }` |
| 58 | `Button("Link…") { NSApp.sendAction(#selector(NotesTextView.markdownLink(_:)), to: nil, from: nil) }` |
| 62 | `Button(store.recordingID == nil ? "Start Recording" : "Stop Recording") {` |
| 76 | `Button("Follow Logs") { MeetingPanels.followLogs(store) }` |
| 77 | `Button("Export Logs") { MeetingPanels.exportLogs(store) }` |
| 80 | `Button("Play From Line") {` |
| 83 | `Button(playback.isPlaying ? "Pause" : "Play") { playback.togglePlayPause() }` |
| 85 | `Button("Back 15 Seconds") { playback.skip(by: -15) }` |
| 87 | `Button("Forward 15 Seconds") { playback.skip(by: 15) }` |
| 100 | `Image(nsImage: MenuBarArtwork.normal).accessibilityLabel("Gday Meetings")` |
| 103 | `Image(nsImage: MenuBarArtwork.recording).accessibilityLabel("Gday Meetings — Recording")` |
| 197 | `Text("Saving recording…")` |
| 200 | `Text("Starting recording…")` |
| 203 | `Text("Recording since \(started.formatted(date: .omitted, time: .shortened))")` |
| 210 | `Button(action: openRecordingSetup) {` |
| 211 | `Label("New Recording…", systemImage: "slider.horizontal.3")` |
| 225 | `Label("Show App", systemImage: "macwindow")` |
| 231 | `Label("Quit Gday Meetings", systemImage: "power")` |
| 261 | `Label(` |
