import SwiftUI

struct PeopleView: View {
    @Binding var selection: Set<UUID>
    @EnvironmentObject private var store: MeetingStore
    @ViewState private var name = ""
    @ViewState private var deleting: Person?
    @ViewState private var showExcluded = false
    @ViewState private var reviewingVoices = false
    private struct MergeRequest: Identifiable {
        let id = UUID()
        let personIDs: Set<UUID>
    }
    @ViewState private var mergeRequest: MergeRequest?
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
        VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
            HStack(spacing: 8) {
                Button("Review Voices…") { reviewingVoices = true }
                if selection.count > 1 {
                    Button("Merge…") {
                        mergeRequest = MergeRequest(personIDs: selection)
                    }
                    .accessibilityLabel("Merge Selected People")
                    .help("Merge selected people")
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .padding(.horizontal, AppTheme.contentInset).padding(.top, AppTheme.contentInset)
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
            }.textFieldStyle(.roundedBorder)
                .padding(.horizontal, AppTheme.contentInset)
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
            }.listStyle(.inset)
            Toggle("Show Excluded", isOn: $showExcluded).toggleStyle(.checkbox)
                .padding(.horizontal, AppTheme.contentInset).padding(.bottom, AppTheme.contentSpacing)
        }.background(AppTheme.readingBackground).navigationTitle("People")
            .onChange(of: visiblePeople.map(\.id)) { _, ids in
                selection.formIntersection(ids)
            }
            .sheet(item: $mergeRequest) { request in
                PersonMergeView(selectedIDs: request.personIDs) { keptID in
                    name = ""
                    if let kept = store.people.first(where: { $0.id == keptID }),
                        !store.excludedTagIDs.isDisjoint(with: kept.tagIDs)
                    {
                        showExcluded = true
                    }
                    selection = [keptID]
                }
            }
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
            selection = [person.id]
        }
        else {
            add()
        }
    }
    private func add() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        selection = [store.addPerson(name: value)]
        name = ""
    }
}

struct TagsView: View {
    @Binding var selection: UUID?
    @EnvironmentObject private var store: MeetingStore
    @ViewState private var name = ""
    @ViewState private var deleting: MeetingTag?
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
            HStack {
                TextField("New Tag", text: $name).onSubmit(add).accessibilityLabel("New Tag")
                Button("Add Tag", systemImage: "plus", action: add).help("Add Tag").labelStyle(.iconOnly).disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.textFieldStyle(.roundedBorder).padding(AppTheme.contentInset)
            List(selection: $selection) {
                ForEach(store.tags) { tag in
                    HStack {
                        TextField(
                            "Tag Name",
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
            }.listStyle(.inset)
        }.background(AppTheme.readingBackground).navigationTitle("Tags")
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
