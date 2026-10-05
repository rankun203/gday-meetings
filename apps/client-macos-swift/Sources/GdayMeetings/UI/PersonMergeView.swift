import SwiftUI

struct PersonMergeView: View {
    let selectedIDs: Set<UUID>
    var didMerge: (UUID) -> Void
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @ViewState private var targetID: UUID?
    @ViewState private var failure: String?

    private var target: Person? { store.people.first { $0.id == targetID } }
    private var candidates: [Person] {
        store.people.filter { selectedIDs.contains($0.id) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge People").font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Combine \(selectedIDs.count) selected people. Choose the person to keep.")
                        .fixedSize(horizontal: false, vertical: true)
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
                    if let target {
                        let combined = candidates.filter { $0.id != target.id }
                            .sorted { $0.id.uuidString < $1.id.uuidString }
                            .reduce(target) { PersonMerge.combining($1, into: $0) }
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
                "The other selected people will be removed. This can’t be undone, and voice-review undo history will be cleared."
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
                    Task {
                        if await store.mergePeople(ids: selectedIDs, into: targetID) {
                            didMerge(targetID)
                            dismiss()
                        }
                        else {
                            failure = store.errorMessage ?? "Couldn’t merge the selected people. Try again."
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    candidates.count != selectedIDs.count || candidates.count < 2 || target == nil
                        || !store.canMergePeople)
            }
        }.padding(24).frame(width: 500, height: 600)
    }
}
