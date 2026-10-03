import SwiftUI

struct MeetingTagsView: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: UUID
    @ViewState private var addingTag = false
    @ViewState private var tagName = ""
    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }

    var body: some View {
        HStack(spacing: 8) {
            Text("Tags").font(.callout).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(store.tags.filter { meeting?.tagIDs.contains($0.id) ?? false }) { tag in
                        Button {
                            setTag(tag.id, selected: false)
                        } label: {
                            Label(tag.name, systemImage: "xmark.circle.fill")
                                .font(.callout).padding(.horizontal, 8).padding(.vertical, 4)
                                .frame(minHeight: 28)
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary, in: Capsule())
                        .help("Remove \(tag.name) from this meeting")
                        .accessibilityLabel("Remove tag \(tag.name)")
                    }
                    Menu {
                        ForEach(store.tags) { tag in
                            Toggle(
                                tag.name,
                                isOn: Binding(
                                    get: { meeting?.tagIDs.contains(tag.id) ?? false },
                                    set: { setTag(tag.id, selected: $0) }))
                        }
                        Divider()
                        Button("New Tag…") {
                            tagName = ""
                            addingTag = true
                        }
                    } label: {
                        Label("Add Tag", systemImage: "plus").labelStyle(.iconOnly)
                            .frame(minWidth: 28, minHeight: 28)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Add tags to this meeting")
                }
            }.scrollIndicators(.hidden).frame(height: 32)
        }
        .sheet(isPresented: $addingTag) {
            VStack(alignment: .leading, spacing: 16) {
                Text("New Tag").font(.headline)
                TextField("Name", text: $tagName).onSubmit(addTag)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { addingTag = false }.keyboardShortcut(.cancelAction)
                    Button("Add Tag", action: addTag).keyboardShortcut(.defaultAction)
                        .disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 320)
        }
    }

    private func setTag(_ id: UUID, selected: Bool) {
        guard var meeting else { return }
        meeting.tagIDs.removeAll { $0 == id }
        if selected { meeting.tagIDs.append(id) }
        store.updateMeeting(meeting)
    }
    private func addTag() {
        let name = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let id =
            store.tags.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.id
            ?? store.addTag(name: name)
        setTag(id, selected: true)
        addingTag = false
    }
}

struct MeetingSpeakersView: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: UUID
    @ViewState private var newPersonSpeaker: MeetingSpeaker?
    @ViewState private var personName = ""
    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let meeting {
                let speakers = meeting.speakers.filter { $0.canAssignPerson || $0.personID != nil }
                ForEach(speakers) { speaker in
                    speakerRow(speaker)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .sheet(item: $newPersonSpeaker) { speaker in
            VStack(alignment: .leading, spacing: 16) {
                Text("New Person").font(.headline)
                TextField("Name", text: $personName).onSubmit { createPerson(speaker) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { newPersonSpeaker = nil }.keyboardShortcut(.cancelAction)
                    Button("Assign Person") { createPerson(speaker) }.keyboardShortcut(.defaultAction)
                        .disabled(personName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 320)
        }
    }

    private func speakerRow(_ speaker: MeetingSpeaker) -> some View {
        HStack(spacing: 12) {
            Text(speaker.displayLabel.isEmpty ? "Unlabeled" : speaker.displayLabel)
                .font(.callout.monospaced())
                .lineLimit(1)
                .help([speaker.providerName, speaker.track].filter { !$0.isEmpty }.joined(separator: " · "))
            Spacer(minLength: 8)
            if !speaker.canAssignPerson {
                Text(personName(for: speaker) ?? "Unassigned").lineLimit(1)
            }
            actions(speaker)
        }
        .frame(minHeight: 28)
    }

    private func personName(for speaker: MeetingSpeaker) -> String? {
        store.people.first(where: { $0.id == speaker.personID })?.name
    }

    @ViewBuilder private func actions(_ speaker: MeetingSpeaker) -> some View {
        if !speaker.canAssignPerson {
            Button("Remove Assignment") {
                store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: nil)
            }
        }
        else {
            HStack(spacing: 8) {
                Menu(personName(for: speaker) ?? "Assign Person") {
                    ForEach(store.people) { person in
                        Button(person.name) {
                            store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: person.id)
                        }
                    }
                    Divider()
                    Button("New Person…") {
                        personName = ""
                        newPersonSpeaker = speaker
                    }
                    if speaker.personID != nil {
                        Button("Remove Assignment") {
                            store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: nil)
                        }
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: 240, alignment: .trailing)
                .accessibilityLabel(
                    "Assign \(speaker.displayLabel.isEmpty ? "unlabeled speaker" : speaker.displayLabel) to a person"
                )
                .accessibilityValue(personName(for: speaker) ?? "Unassigned")
                .help(
                    "Assign a person to this speaker. Assignments with a saved voice sample can recognize them in future transcripts from this provider."
                )
            }
        }
    }

    private func createPerson(_ speaker: MeetingSpeaker) {
        let name = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let personID = store.addPerson(name: name)
        store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: personID)
        newPersonSpeaker = nil
    }
}
