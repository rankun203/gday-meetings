import SwiftUI

struct PeopleView: View {
    @Binding var selection: UUID?
    @EnvironmentObject private var store: MeetingStore
    @ViewState private var name = ""
    @ViewState private var deleting: Person?
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("New person", text: $name).onSubmit(add)
                Button("Add", systemImage: "plus", action: add).help("Add").labelStyle(.iconOnly).disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
            List(selection: $selection) {
                ForEach(store.people) { person in
                    HStack {
                        Label(person.name, systemImage: "person.crop.circle")
                        Spacer()
                        Button("Delete Person…", systemImage: "trash", role: .destructive) { deleting = person }.help(
                            "Delete person"
                        ).labelStyle(.iconOnly).buttonStyle(.borderless).modifier(ActionHover())
                    }.tag(person.id)
                }
            }
        }.navigationTitle("People")
            .confirmationDialog(
                "Delete \(deleting?.name ?? "person")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Person", role: .destructive) {
                    if let deleting { store.deletePerson(id: deleting.id) }
                    deleting = nil
                }
            } message: {
                Text("The person will be removed from your directory and meeting assignments.")
            }
    }
    private func add() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        selection = store.addPerson(name: value)
        name = ""
    }
}

struct TagsView: View {
    @Binding var selection: UUID?
    @EnvironmentObject private var store: MeetingStore
    @ViewState private var name = ""
    @ViewState private var deleting: MeetingTag?
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                TextField("New tag", text: $name).onSubmit(add)
                Button("Add", systemImage: "plus", action: add).help("Add").labelStyle(.iconOnly).disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
            List(selection: $selection) {
                ForEach(store.tags) { tag in
                    HStack {
                        TextField(
                            "Tag name",
                            text: Binding(
                                get: { store.tags.first(where: { $0.id == tag.id })?.name ?? "" },
                                set: { value in
                                    var changed = tag
                                    changed.name = value
                                    store.updateTag(changed)
                                }))
                        Spacer()
                        Text("\((try? store.libraryIndex?.count(tagID: tag.id)) ?? 0)").foregroundStyle(
                            .secondary)
                        Button("Delete Tag…", systemImage: "trash", role: .destructive) { deleting = tag }.help(
                            "Delete tag"
                        ).labelStyle(.iconOnly).buttonStyle(.borderless).modifier(ActionHover())
                    }.tag(tag.id)
                }
            }
        }.navigationTitle("Tags")
            .confirmationDialog(
                "Delete \(deleting?.name ?? "tag")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Tag", role: .destructive) {
                    if let deleting { store.deleteTag(id: deleting.id) }
                    deleting = nil
                }
            } message: {
                Text("The tag will be removed from all meetings.")
            }
    }
    private func add() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        selection = store.addTag(name: value, color: "blue")
        name = ""
    }
}
