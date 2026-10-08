import SwiftUI

enum TranscriptSpeakerSearch {
    static func matches(_ people: [Person], query: String, limit: Int = 20) -> [Person] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(
            people.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.prefix(max(0, limit)))
    }

    static func speaker(for segment: TranscriptSegment, in speakers: [MeetingSpeaker]) -> MeetingSpeaker? {
        if let id = segment.speakerID, let speaker = speakers.first(where: { $0.id == id }) { return speaker }
        let candidates = speakers.filter { $0.label == segment.speaker }
        return candidates.count == 1 ? candidates.first : nil
    }
}

struct TranscriptSpeakerPicker: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID
    let speaker: MeetingSpeaker
    var completed: (() -> Void)? = nil
    var associationUncertain = false
    var restorePassage: (() async -> Bool)? = nil
    var assignment: ((UUID?) async -> Bool)? = nil
    var lineAssignment: ((UUID?) async -> Bool)? = nil
    @ViewState private var appliesToSpeaker = true
    @ViewState private var query = ""
    @ViewState private var saving = false
    @ViewState private var saveError: String?
    @FocusState private var focused: Bool

    private var matches: [Person] { TranscriptSpeakerSearch.matches(store.people, query: query) }
    private var newName: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasExactMatch: Bool {
        store.people.contains { $0.name.localizedCaseInsensitiveCompare(newName) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assign Person").font(.headline)
            if lineAssignment != nil {
                Toggle("Apply to All Speech with This Speaker Label", isOn: $appliesToSpeaker)
                    .toggleStyle(.checkbox)
            }
            if associationUncertain {
                Text(
                    "This passage’s voice match is uncertain. Assign just this passage, or explicitly apply the name to all speech with this label."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let restorePassage {
                Button("Undo Passage Assignment") {
                    guard !saving else { return }
                    saving = true
                    Task {
                        defer { saving = false }
                        if await restorePassage() {
                            completed?()
                            dismiss()
                        }
                        else {
                            saveError = store.errorMessage ?? "Couldn’t restore this passage. Try again."
                        }
                    }
                }
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            TextField("Search people", text: $query).focused($focused)
                .onSubmit { if let person = matches.first { assign(person.id) } }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(matches) { person in
                        Button {
                            assign(person.id)
                        } label: {
                            HStack {
                                Text(person.name)
                                Spacer()
                                if speaker.personID == person.id { Image(systemName: "checkmark") }
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(maxHeight: 220)
            if !newName.isEmpty && !hasExactMatch {
                Button("Create and Assign \(newName)") {
                    guard !saving else { return }
                    let name = newName
                    saving = true
                    saveError = nil
                    Task {
                        defer { saving = false }
                        let id = await store.addPerson(name: name)
                        guard store.people.contains(where: { $0.id == id }) else {
                            saveError = store.errorMessage ?? "Couldn’t save this person. Try again."
                            return
                        }
                        await performAssignment(id)
                    }
                }
            }
            if speaker.personID != nil {
                Button("Remove Assignment") { assign(nil) }
            }
        }
        .padding(16).frame(width: 320)
        .disabled(saving)
        .defaultFocus($focused, true)
        .task {
            appliesToSpeaker = !associationUncertain
        }
    }

    private func assign(_ personID: UUID?) {
        guard !saving else { return }
        saving = true
        saveError = nil
        Task {
            defer { saving = false }
            await performAssignment(personID)
        }
    }

    private func performAssignment(_ personID: UUID?) async {
        let succeeded: Bool
        if !appliesToSpeaker, let lineAssignment {
            succeeded = await lineAssignment(personID)
        }
        else if let assignment {
            succeeded = await assignment(personID)
        }
        else {
            succeeded = await store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: personID)
        }
        guard succeeded else {
            saveError = store.errorMessage ?? "Couldn’t save this assignment. Try again."
            return
        }
        completed?()
        dismiss()
    }
}
