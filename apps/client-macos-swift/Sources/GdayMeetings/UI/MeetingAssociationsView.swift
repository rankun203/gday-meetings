import AppKit
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
        Task {
            guard var meeting else { return }
            meeting.tagIDs.removeAll { $0 == id }
            if selected { meeting.tagIDs.append(id) }
            await store.updateMeeting(meeting)
        }
    }
    private func addTag() {
        let name = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        addingTag = false
        Task {
            let id: UUID
            if let existing = store.tags.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
            {
                id = existing.id
            }
            else {
                id = await store.addTag(name: name)
            }
            guard store.tags.contains(where: { $0.id == id }) else { return }
            setTag(id, selected: true)
        }
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
                let speakers = meeting.speakers.filter {
                    $0.canReviewVoice
                }
                let slots = MeetingSpeakerColors.slots(for: meeting.speakers)
                ForEach(speakers) { speaker in
                    speakerRow(speaker, slots: slots)
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

    private func speakerRow(_ speaker: MeetingSpeaker, slots: [UUID: Int]) -> some View {
        HStack(spacing: 12) {
            Text(speaker.displayLabel.isEmpty ? "Unlabeled" : speaker.displayLabel)
                .font(.callout.monospaced())
                .lineLimit(1)
                .help([speaker.providerName, speaker.track].filter { !$0.isEmpty }.joined(separator: " · "))
            Spacer(minLength: 8)
            if !speaker.canAssignPerson {
                Text(personName(for: speaker) ?? "Unassigned").lineLimit(1)
            }
            actions(speaker, slots: slots)
        }
        .frame(minHeight: 28)
    }

    private func personName(for speaker: MeetingSpeaker) -> String? {
        store.people.first(where: { $0.id == speaker.personID })?.name
    }

    @ViewBuilder private func actions(_ speaker: MeetingSpeaker, slots: [UUID: Int]) -> some View {
        if !speaker.canAssignPerson {
            Button("Remove Assignment") {
                Task { await store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: nil) }
            }
        }
        else {
            HStack(spacing: 8) {
                Menu {
                    ForEach(store.people) { person in
                        Button(person.name) {
                            Task {
                                await store.assignSpeaker(
                                    meetingID: meetingID, speakerID: speaker.id, personID: person.id)
                            }
                        }
                    }
                    Divider()
                    Button("New Person…") {
                        personName = ""
                        newPersonSpeaker = speaker
                    }
                    if speaker.personID != nil {
                        Button("Remove Assignment") {
                            Task {
                                await store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: nil)
                            }
                        }
                    }
                } label: {
                    if let name = personName(for: speaker),
                        let tint = TranscriptSpeakerPalette.assignmentTint(for: speaker, slots: slots)
                    {
                        Text(name)
                            .foregroundStyle(Color(nsColor: TranscriptSpeakerPalette.foreground(for: tint)))
                    }
                    else {
                        Text("Assign Person")
                    }
                }
                .modifier(
                    SpeakerAssignmentMenuStyle(
                        tint: personName(for: speaker) == nil
                            ? nil : TranscriptSpeakerPalette.assignmentTint(for: speaker, slots: slots))
                )
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
        newPersonSpeaker = nil
        Task {
            let personID = await store.addPerson(name: name)
            guard store.people.contains(where: { $0.id == personID }) else { return }
            await store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: personID)
        }
    }
}

extension TranscriptSpeakerPalette {
    /// Use the same complete-meeting allocation as saved transcript badges.
    static func assignmentTint(for speaker: MeetingSpeaker, slots: [UUID: Int]) -> NSColor? {
        guard speaker.personID != nil else { return nil }
        let identity = MeetingSpeakerColors.identity(speaker)
        return color(for: identity.uuidString, index: slots[identity])
    }
}

private struct SpeakerAssignmentMenuStyle: ViewModifier {
    let tint: NSColor?

    @ViewBuilder func body(content: Content) -> some View {
        if let tint {
            content
                .menuStyle(.borderlessButton)
                .foregroundStyle(Color(nsColor: TranscriptSpeakerPalette.foreground(for: tint)))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(nsColor: tint).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        }
        else {
            content
        }
    }
}
