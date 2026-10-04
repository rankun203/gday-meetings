import SwiftUI

struct PersonMergeView: View {
    let sourceID: UUID
    var didMerge: (UUID) -> Void
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var targetID: UUID?
    @ViewState private var query = ""
    @ViewState private var failure: String?

    private var source: Person? { store.people.first { $0.id == sourceID } }
    private var target: Person? { store.people.first { $0.id == targetID } }
    private var candidates: [Person] {
        store.people.filter {
            $0.id != sourceID
                && (query.isEmpty || $0.name.localizedStandardContains(query)
                    || $0.email.localizedStandardContains(query))
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge Person").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Merge “\(source?.name ?? "")” into the person you select below.")
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Find Person to Keep", text: $query)
                        .accessibilityLabel("Find Person to Keep")
                    List(selection: $targetID) {
                        ForEach(candidates) { person in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.name)
                                Text(person.email.isEmpty ? "No email" : person.email).foregroundStyle(.secondary)
                                Text(
                                    "\((try? store.libraryIndex?.count(personID: person.id)) ?? 0) associated meetings"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }.tag(person.id)
                        }
                    }.frame(height: 150)
                    if let source, let target {
                        let combined = PersonMerge.combining(source, into: target)
                        Text("Keep: \(target.name)").font(.headline)
                        if !combined.email.isEmpty { Text(combined.email).textSelection(.enabled) }
                        if !combined.notes.isEmpty {
                            Text(combined.notes).frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(
                "Meetings, tags, notes, chat history, and voice samples will be combined. Other names and email addresses will be kept in Notes."
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(
                "The duplicate person will be removed. This can’t be undone, and voice-review undo history will be cleared."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if !store.canMergePeople {
                Text("Wait for recording, processing, and indexing to finish. The library must be writable.")
                    .foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge People") {
                    guard let targetID else { return }
                    if store.mergePerson(id: sourceID, into: targetID) {
                        didMerge(targetID)
                        dismiss()
                    }
                    else {
                        failure = store.errorMessage ?? "Couldn’t merge these people. Try again."
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(source == nil || target == nil || !store.canMergePeople)
            }
        }.padding(24).frame(width: 500, height: 600)
    }
}
