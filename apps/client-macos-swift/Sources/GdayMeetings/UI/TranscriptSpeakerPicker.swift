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
    let explanation: TranscriptSpeakerAssignmentExplanation
    var restorePassage: (() async -> Bool)? = nil
    var assignment: ((UUID?) async -> Bool)? = nil
    @ViewState private var query = ""
    @ViewState private var saving = false
    @ViewState private var saveError: String?
    @ViewState private var selectedPersonID: UUID?

    private var matches: [Person] { TranscriptSpeakerSearch.matches(store.people, query: query) }
    private var newName: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedPerson: Person? { matches.first { $0.id == selectedPersonID } ?? matches.first }
    private var hasExactMatch: Bool {
        store.people.contains { $0.name.localizedCaseInsensitiveCompare(newName) == .orderedSame }
    }

    var body: some View {
        let highlightedID = selectedPerson?.id
        VStack(alignment: .leading, spacing: 10) {
            Text(TranscriptSpeakerAssignmentExplanation.title(for: speaker)).font(.headline)
            TextField("Search people", text: $query)
                .onSubmit { if let person = selectedPerson { assign(person.id) } }
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }
                .onChange(of: query) { _, _ in selectedPersonID = matches.first?.id }
            Text(
                restorePassage == nil ? "Applies to this speaker throughout the recording." : "Applies to this passage."
            )
            .font(.caption).foregroundStyle(.secondary)
            if explanation.hasDottedOutline {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dotted outline").fontWeight(.medium)
                    ForEach(explanation.dottedReasons, id: \.self) { reason in
                        Text(reason.text)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            if explanation.automaticallyMatched {
                Text("Automatically matched person.")
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
            ScrollViewReader { proxy in
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
                                }.padding(.vertical, 5).padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                                    .background(
                                        highlightedID == person.id ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(highlightedID == person.id ? .isSelected : [])
                                .id(person.id)
                        }
                    }
                }.frame(maxHeight: 220)
                    .onChange(of: highlightedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
            }
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
    }

    private func moveSelection(_ offset: Int) {
        let candidates = matches
        guard !saving, !candidates.isEmpty else { return }
        let current = candidates.firstIndex { $0.id == selectedPersonID } ?? 0
        selectedPersonID = candidates[min(max(current + offset, 0), candidates.count - 1)].id
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
        if let assignment {
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
