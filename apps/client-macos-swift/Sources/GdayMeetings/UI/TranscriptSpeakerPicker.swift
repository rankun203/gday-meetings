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
    var assignment: ((UUID?) -> Void)? = nil
    var lineAssignment: ((UUID?) -> Void)? = nil
    @ViewState private var appliesToSpeaker = true
    @ViewState private var query = ""
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
                Toggle("Apply to This Speaker", isOn: $appliesToSpeaker)
                    .toggleStyle(.checkbox)
            }
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
                Button("Create and Assign \(newName)") { assign(store.addPerson(name: newName)) }
            }
            if speaker.personID != nil {
                Button("Remove Assignment") { assign(nil) }
            }
        }
        .padding(16).frame(width: 280)
        .task { focused = true }
    }

    private func assign(_ personID: UUID?) {
        if !appliesToSpeaker, let lineAssignment {
            lineAssignment(personID)
        }
        else if let assignment {
            assignment(personID)
        }
        else {
            store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: personID)
        }
        completed?()
        dismiss()
    }
}
