import SwiftUI

struct PeopleView: View {
    @Binding var selection: UUID?
    @EnvironmentObject private var store: MeetingStore
    @ViewState private var name = ""
    @ViewState private var deleting: Person?
    @ViewState private var showExcluded = false
    @ViewState private var reviewingVoices = false
    private var visiblePeople: [Person] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (showExcluded ? store.people : store.listedPeople)
            .filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }
    var body: some View {
        VStack(alignment: .leading) {
            Button("Review Voices…", systemImage: "waveform") { reviewingVoices = true }
                .buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.top)
            HStack {
                TextField("Find or Add Person", text: $name).onSubmit(findOrAdd)
                    .accessibilityLabel("Find or Add Person")
                if !name.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { name = "" }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Clear Search")
                }
                Button("Add Person", systemImage: "plus", action: add).help("Add Person").labelStyle(.iconOnly)
                    .disabled(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding()
            List(selection: $selection) {
                ForEach(visiblePeople) { person in
                    HStack {
                        Label(person.name, systemImage: "person.crop.circle")
                        Spacer()
                        if !store.excludedTagIDs.isDisjoint(with: person.tagIDs) {
                            Text("Excluded").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Delete Person…", systemImage: "trash", role: .destructive) { deleting = person }.help(
                            "Delete person"
                        ).labelStyle(.iconOnly).buttonStyle(.borderless).modifier(ActionHover())
                    }.tag(person.id)
                }
            }
            Toggle("Show Excluded", isOn: $showExcluded).toggleStyle(.checkbox).padding(.horizontal).padding(.bottom)
        }.navigationTitle("People")
            .sheet(isPresented: $reviewingVoices) {
                VoiceLibraryView(library: store.voiceLibrary)
            }
            .focusedValue(\.directoryControlFocus, true)
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
    private func findOrAdd() {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let person = visiblePeople.first(where: {
            $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == .orderedSame
        }) {
            selection = person.id
        }
        else {
            add()
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
                        if tag.isExcluded { Text("Excluded").font(.caption).foregroundStyle(.secondary) }
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
                Text("The tag will be removed from all meetings and people.")
            }
    }
    private func add() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        selection = store.addTag(name: value, color: "blue")
        name = ""
    }
}
