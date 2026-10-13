import SwiftUI

struct PersonTagsView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.showTag) private var showTag
    let personID: UUID
    private var person: Person? { store.people.first { $0.id == personID } }

    var body: some View {
        HStack(spacing: 8) {
            Text("Tags").font(.callout).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(store.tags.filter { person?.tagIDs.contains($0.id) ?? false }) { tag in
                        TagAssociationChip(
                            name: tag.name, removalHelp: "Remove \(tag.name) from this person",
                            open: { showTag(tag.id) }, remove: { setTag(tag.id, selected: false) })
                    }
                    Menu {
                        ForEach(store.tags) { tag in
                            Toggle(
                                tag.name,
                                isOn: Binding(
                                    get: { person?.tagIDs.contains(tag.id) ?? false },
                                    set: { setTag(tag.id, selected: $0) }
                                ))
                        }
                    } label: {
                        Label("Add Tag", systemImage: "plus").labelStyle(.iconOnly)
                            .frame(minWidth: 28, minHeight: 28)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(store.tags.isEmpty)
                    .help("Add tags to this person")
                }
            }.scrollIndicators(.hidden).frame(height: 32)
        }
    }

    private func setTag(_ id: UUID, selected: Bool) {
        Task {
            guard var person else { return }
            person.tagIDs.removeAll { $0 == id }
            if selected { person.tagIDs.append(id) }
            await store.updatePerson(person)
        }
    }
}
