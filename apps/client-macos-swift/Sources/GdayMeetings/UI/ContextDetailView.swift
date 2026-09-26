import SwiftUI

struct ContextDetailView: View {
    @EnvironmentObject private var store: MeetingStore
    let title: String
    let personID: UUID?
    let tagID: UUID?
    @ViewState private var draft = ""
    private var messages: [ChatMessage] {
        store.contextualChats[MeetingStore.contextChatKey(personID: personID, tagID: tagID)] ?? []
    }
    @ViewState private var selectedMeeting: UUID?
    private var meetings: [Meeting] {
        store.meetings.filter { meeting in
            if let personID { return meeting.personIDs.contains(personID) }
            if let tagID { return meeting.tagIDs.contains(tagID) }
            return false
        }.sorted { $0.createdAt > $1.createdAt }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.largeTitle)
            if let personID, let person = store.people.first(where: { $0.id == personID }) {
                Form {
                    TextField("Name", text: personBinding(person, \.name))
                    TextField("Email", text: personBinding(person, \.email))
                    TextField("Notes", text: personBinding(person, \.notes), axis: .vertical).lineLimit(1...4)
                }
            }
            Text("\(meetings.count) associated meetings").foregroundStyle(.secondary)
            List(meetings) { meeting in
                Button {
                    selectedMeeting = meeting.id
                } label: {
                    HStack {
                        Text(meeting.title)
                        Spacer()
                        Text(meeting.createdAt, style: .date).foregroundStyle(.secondary)
                    }
                }.buttonStyle(ActionButtonStyle())
            }.frame(minHeight: 100, maxHeight: 200)
            Divider()
            Text("Ask across these meetings").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(message.role == "user" ? "You" : "Gday").font(.headline)
                            Text(message.content).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            HStack {
                TextField("Ask a question", text: $draft, axis: .vertical).lineLimit(1...5).onSubmit(send)
                Button("Send", systemImage: "arrow.up", action: send).disabled(
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || store.isJobRunning(
                            .contextChat, .context(MeetingStore.contextChatKey(personID: personID, tagID: tagID)))
                        || meetings.isEmpty)
            }
        }.padding(20).navigationTitle(title)
            .sheet(isPresented: Binding(get: { selectedMeeting != nil }, set: { if !$0 { selectedMeeting = nil } })) {
                if let selectedMeeting {
                    VStack {
                        HStack {
                            Spacer()
                            Button("Done") { self.selectedMeeting = nil }.keyboardShortcut(.cancelAction)
                        }.padding()
                        MeetingDetailView(meetingID: selectedMeeting)
                    }.frame(width: 800, height: 650)
                }
            }
    }
    private func personBinding(_ person: Person, _ path: WritableKeyPath<Person, String>) -> Binding<String> {
        Binding(
            get: { store.people.first(where: { $0.id == person.id })?[keyPath: path] ?? "" },
            set: { value in
                guard var updated = store.people.first(where: { $0.id == person.id }) else { return }
                updated[keyPath: path] = value
                store.updatePerson(updated)
            })
    }
    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        Task { _ = await store.sendContextChat(personID: personID, tagID: tagID, message: question) }
    }
}
