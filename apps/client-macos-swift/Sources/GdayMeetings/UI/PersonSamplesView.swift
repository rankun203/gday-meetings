import SwiftUI

struct PersonSamplesSummary: View {
    @ObservedObject var library: VoiceLibraryStore
    let personID: UUID
    let open: () -> Void
    private var associated: [VoiceExample] {
        VoiceMatchReviewSession.referenceExamples(library.referenceEvidence(for: personID), personID: personID)
    }
    private var confirmed: Int { associated.filter { $0.personID == personID && $0.review == .confirmed }.count }
    var body: some View {
        HStack(spacing: 12) {
            Label(
                "\(associated.count) associated \(associated.count == 1 ? "sample" : "samples") · \(confirmed) confirmed",
                systemImage: "waveform"
            )
            .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Voice Samples…", action: open).controlSize(.small)
        }.padding(.horizontal, AppTheme.contentInset).padding(.bottom, 16)
    }
}

/// The profile is a derived subset; editing a name always changes the source sample decision.
struct PersonSamplesView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: VoiceLibraryStore
    let personID: UUID
    @ViewState private var filter = SampleFilter.associated
    @ViewState private var editing = false
    @ViewState private var managingSamples = false
    @ViewState private var meetings: [UUID: MeetingListEntry] = [:]
    private enum SampleFilter: String, CaseIterable, Identifiable {
        case associated = "All Associated"
        case confirmed = "Confirmed"
        var id: Self { self }
    }
    private var name: String { store.people.first { $0.id == personID }?.name ?? "Person" }
    private var associated: [VoiceExample] {
        VoiceMatchReviewSession.referenceExamples(library.referenceEvidence(for: personID), personID: personID)
    }
    private var confirmed: [VoiceExample] { associated.filter { $0.personID == personID && $0.review == .confirmed } }
    private var visible: [VoiceExample] {
        switch filter {
        case .associated: return associated
        case .confirmed: return confirmed
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.title2.bold())
                    Text("Voice Samples").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Manage Samples…") { managingSamples = true }
                Button("Done") {
                    playback.pause()
                    dismiss()
                }.keyboardShortcut(.cancelAction)
            }
            Picker("Samples", selection: $filter) {
                Text("All Associated (\(associated.count))").tag(SampleFilter.associated)
                Text("Confirmed (\(confirmed.count))").tag(SampleFilter.confirmed)
            }.pickerStyle(.segmented)
            Text(description).font(.callout).foregroundStyle(.secondary)
            if let error = library.errorMessage ?? store.errorMessage {
                AppInlineMessage(text: error, systemImage: "exclamationmark.triangle", tint: .red)
            }
            List {
                ForEach(visible) { example in
                    HStack(spacing: 12) {
                        VoiceExamplePlaybackButton(example: example).disabled(editing)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(meetings[example.meetingID]?.title ?? "Saved Recording").font(.headline).lineLimit(1)
                            Text(
                                PersonMatchReviewView.metadataLabel(
                                    example, date: meetings[example.meetingID]?.createdAt)
                            )
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                            .help(
                                PersonMatchReviewView.metadataHelp(
                                    example, date: meetings[example.meetingID]?.createdAt))
                            VoiceSampleNameLabel(
                                example: example, editing: $editing,
                                createAndAssign: { name in
                                    await store.nameVoiceGroup(
                                        exampleIDs: [example.id], confirmedExampleID: example.id, personID: nil,
                                        newPersonName: name, expectedExamples: [example]) != nil
                                }
                            ) { id in
                                await store.reviewVoiceExamples(
                                    .confirm(ids: [example.id], personID: id), expectedExamples: [example])
                            }
                        }
                        Spacer()
                        VoiceSampleStatusLabel(
                            title: example.excluded
                                ? "Ignored" : example.review == .confirmed ? "Confirmed" : "Needs Review",
                            kind: example.excluded ? .ignored : example.review == .confirmed ? .confirmed : .needsReview
                        )
                    }.padding(.vertical, 6)
                        .contextMenu {
                            Button("Not \(name)") {
                                playback.pause()
                                Task {
                                    _ = await store.reviewVoiceExamples(
                                        .reject(ids: [example.id], personID: personID), expectedExamples: [example])
                                }
                            }.disabled(!store.libraryWritable)
                        }
                }
                if !visible.isEmpty {
                    ListCountFooter(
                        text: ListCountFooter.text(count: visible.count, singular: "Sample", plural: "Samples")
                    )
                    .selectionDisabled()
                }
            }.listStyle(.inset)
                .overlay {
                    if visible.isEmpty {
                        ContentUnavailableView(
                            "No Samples", systemImage: "waveform",
                            description: Text("Confirm voice matches to help identify this person in recordings."))
                    }
                }
        }.padding(24).frame(width: 700, height: 540)
            .task(id: Set(associated.map(\.meetingID))) {
                guard let index = store.libraryIndex else { return }
                let ids = Set(associated.map(\.meetingID))
                let loaded = await Task.detached {
                    var result: [UUID: MeetingListEntry] = [:]
                    for id in ids { if let entry = try? index.entry(id: id) { result[id] = entry } }
                    return result
                }.value
                if !Task.isCancelled { meetings = loaded }
            }
            .onDisappear { playback.pause() }
            .sheet(isPresented: $managingSamples) { VoiceSampleManagementView(library: library, personID: personID) }
    }
    private var description: String {
        switch filter {
        case .associated: return "Samples linked or suggested to this person. Suggestions are awaiting your review."
        case .confirmed:
            return
                "Samples you explicitly confirmed for this person. Compatible samples are selected automatically for recognition."
        }
    }
}

/// The person detail owns one availability load for all of its review entry points.
struct PersonMatchReviewAvailability: ViewModifier {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject var library: VoiceLibraryStore
    let personID: UUID?
    var reviewingVoices = false
    @ViewState private var loaded: Request?
    @ViewState private var count = 0
    @ViewState private var error: String?
    private struct Request: Equatable {
        let personID: UUID?
        let people: Set<UUID>
        let revision: Int
        let metadataRevision: Int
        let reviewingVoices: Bool
    }
    private var request: Request {
        Request(
            personID: personID, people: Set(store.people.map(\.id)), revision: library.reviewEvidenceRevision,
            metadataRevision: library.reviewMetadataRevision, reviewingVoices: reviewingVoices)
    }
    private var hasCurrentMetadata: Bool {
        loaded?.personID == request.personID && loaded?.people == request.people
            && loaded?.metadataRevision == request.metadataRevision
    }
    func body(content: Content) -> some View {
        content.environment(
            \.personMatchReviewStatus,
            PersonMatchReviewStatus(
                count: hasCurrentMetadata ? count : 0,
                help: error
                    ?? (!hasCurrentMetadata
                        ? "Checking for matches…"
                        : count == 0
                            ? "No playable samples need review for this person."
                            : "Review \(count) samples for this person."))
        )
        .task(id: request) {
            let current = request
            if !hasCurrentMetadata { count = 0 }
            error = nil
            guard !current.reviewingVoices else { return }
            guard let personID = current.personID else {
                loaded = current
                return
            }
            do {
                let snapshot = try await library.reviewSnapshot(for: current.people)
                guard !Task.isCancelled, current == request else { return }
                count = snapshot.candidates[personID]?.count ?? 0
            }
            catch {
                guard !Task.isCancelled, current == request else { return }
                self.error = error.localizedDescription
            }
            loaded = current
        }
    }
}

private struct PersonMatchReviewStatus {
    var count = 0
    var help = "Checking for matches…"
}
private struct PersonMatchReviewStatusKey: EnvironmentKey {
    static let defaultValue = PersonMatchReviewStatus()
}
extension EnvironmentValues {
    fileprivate var personMatchReviewStatus: PersonMatchReviewStatus {
        get { self[PersonMatchReviewStatusKey.self] }
        set { self[PersonMatchReviewStatusKey.self] = newValue }
    }
}
struct PersonMatchReviewButton: View {
    @Environment(\.personMatchReviewStatus) private var status
    let action: () -> Void
    var body: some View {
        Button(status.count > 0 ? "Review This Person (\(status.count))" : "Review This Person", action: action)
            .disabled(status.count == 0).help(status.help)
    }
}
