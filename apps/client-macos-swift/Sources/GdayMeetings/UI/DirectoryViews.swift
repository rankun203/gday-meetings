import SwiftUI

struct PeopleView: View {
    @Binding var selection: Set<UUID>
    @EnvironmentObject private var store: MeetingStore
    @StateObject private var page = DirectoryPaging()
    @ViewState private var name = ""
    @ViewState private var deleting: Person?
    @ViewState private var showExcluded = false
    @ViewState private var reviewingVoices = false
    private struct MergeRequest: Identifiable {
        let id = UUID()
        let personIDs: Set<UUID>
    }
    @ViewState private var mergeRequest: MergeRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceListHeader(
                title: "People", subtitle: "\(page.total.formatted()) \(page.total == 1 ? "person" : "people")"
            ) {
                Menu {
                    Button("Review Voices…") { reviewingVoices = true }
                    Button("Merge Selected People…") { mergeRequest = MergeRequest(personIDs: selection) }
                        .disabled(selection.count < 2)
                } label: {
                    Label("People Actions", systemImage: "ellipsis.circle")
                }.menuStyle(.borderlessButton).fixedSize().help("People Actions")
            }
            HStack(spacing: 8) {
                TextField("Find or Add Person", text: $name).onSubmit(findOrAdd).accessibilityLabel(
                    "Find or Add Person")
                Button("Add Person", systemImage: "plus", action: add).labelStyle(.iconOnly).help("Add Person")
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
            if selection.count > 1 {
                HStack {
                    Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Merge…") { mergeRequest = MergeRequest(personIDs: selection) }.controlSize(.small)
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            NativeDirectoryList(
                entries: page.entries, selection: $selection, label: "People", reveal: page.revealRequest,
                viewport: page.viewport
            ) { entry in
                deleting = store.people.first { $0.id == entry.id }
            }
            .overlay {
                directoryState(page: page, indexError: store.directoryIndexError, kind: "People") {
                    store.refreshDirectoryIndex(rebuild: true)
                    refresh()
                }
            }
            HStack {
                Toggle("Show Excluded", isOn: $showExcluded).toggleStyle(.checkbox)
                Spacer()
                if page.loading && !page.entries.isEmpty { ProgressView().controlSize(.small) }
            }.padding(12)
        }
        .background(AppTheme.readingBackground).navigationTitle("People")
        .task(id: "\(name)|\(showExcluded)|\(store.directoryRevision)") { refresh() }
        .sheet(item: $mergeRequest) { request in
            PersonMergeView(selectedIDs: request.personIDs) { keptID in
                name = ""
                if let person = store.people.first(where: { $0.id == keptID }),
                    !store.excludedTagIDs.isDisjoint(with: person.tagIDs)
                {
                    showExcluded = true
                }
                selection = [keptID]
                page.reveal(keptID, query: "", expectedName: store.people.first(where: { $0.id == keptID })?.name)
            }
        }
        .sheet(isPresented: $reviewingVoices) { VoiceLibraryView(library: store.voiceLibrary) }
        .focusedValue(\.directoryControlFocus, true)
        .confirmationDialog(
            "Delete \(deleting?.name ?? "person")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Person", role: .destructive) {
                if let deleting {
                    store.deletePerson(id: deleting.id)
                    if !store.people.contains(where: { $0.id == deleting.id }) { selection.remove(deleting.id) }
                }
                deleting = nil
            }
        } message: {
            Text("The person will be removed from your directory and meeting assignments.")
        }
    }
    private func refresh() {
        page.configure(index: store.directoryIndex, kind: .people, query: name, showExcluded: showExcluded)
    }
    private func findOrAdd() {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let index = store.directoryIndex else { return }
        Task {
            do {
                let id = try await Task.detached { try index.exactPerson(name: query) }.value
                guard name.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                if let id {
                    if let person = store.people.first(where: { $0.id == id }),
                        !store.excludedTagIDs.isDisjoint(with: person.tagIDs)
                    {
                        showExcluded = true
                    }
                    selection = [id]
                    page.reveal(id, query: query, expectedName: store.people.first(where: { $0.id == id })?.name)
                }
                else {
                    add()
                }
            }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func add() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let id = store.addPerson(name: value)
        selection = [id]
        name = ""
        page.reveal(id, query: "", expectedName: value)
    }
}

struct TagsView: View {
    @Binding var selection: UUID?
    @EnvironmentObject private var store: MeetingStore
    @StateObject private var page = DirectoryPaging()
    @ViewState private var name = ""
    @ViewState private var deleting: MeetingTag?
    private var selectedIDs: Binding<Set<UUID>> {
        Binding(get: { selection.map { [$0] } ?? [] }, set: { selection = $0.first })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkspaceListHeader(
                title: "Tags", subtitle: "\(page.total.formatted()) \(page.total == 1 ? "tag" : "tags")"
            ) { EmptyView() }
            HStack(spacing: 8) {
                TextField("Find or Add Tag", text: $name).onSubmit(findOrAdd).accessibilityLabel("Find or Add Tag")
                Button("Add Tag", systemImage: "plus", action: add).help("Add Tag").labelStyle(.iconOnly)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
            NativeDirectoryList(
                entries: page.entries, selection: selectedIDs, multiple: false, label: "Tags",
                reveal: page.revealRequest, viewport: page.viewport
            ) { entry in
                deleting = store.tags.first { $0.id == entry.id }
            }
            .overlay {
                directoryState(page: page, indexError: store.directoryIndexError, kind: "Tags") {
                    store.refreshDirectoryIndex(rebuild: true)
                    refresh()
                }
            }
            if page.loading && !page.entries.isEmpty { ProgressView().controlSize(.small).padding(12) }
        }.background(AppTheme.readingBackground).navigationTitle("Tags")
            .task(id: "\(name)|\(store.directoryRevision)") { refresh() }
            .confirmationDialog(
                "Delete \(deleting?.name ?? "tag")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Tag", role: .destructive) {
                    if let deleting {
                        store.deleteTag(id: deleting.id)
                        if !store.tags.contains(where: { $0.id == deleting.id }), selection == deleting.id {
                            selection = nil
                        }
                    }
                    deleting = nil
                }
            } message: {
                Text("The tag will be removed from all meetings and people.")
            }
    }
    private func refresh() { page.configure(index: store.directoryIndex, kind: .tags, query: name, showExcluded: true) }
    private func findOrAdd() {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let index = store.directoryIndex else { return }
        Task {
            do {
                let id = try await Task.detached { try index.exactTag(name: query) }.value
                guard name.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                if let id {
                    selection = id
                    page.reveal(id, query: query, expectedName: store.tags.first(where: { $0.id == id })?.name)
                }
                else {
                    add()
                }
            }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func add() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let id = store.addTag(name: value, color: "blue")
        selection = id
        name = ""
        page.reveal(id, query: "", expectedName: value)
    }
}

@MainActor @ViewBuilder private func directoryState(
    page: DirectoryPaging, indexError: String?, kind: String, retry: @escaping () -> Void
) -> some View {
    if let error = page.error ?? indexError {
        VStack(spacing: 12) {
            Text(error).font(.callout).multilineTextAlignment(.center)
            Button("Try Again", action: retry)
        }.padding()
    }
    else if page.loading && page.entries.isEmpty {
        ProgressView("Loading \(kind.lowercased())…")
    }
    else if page.entries.isEmpty {
        ContentUnavailableView(
            "No \(kind) Found", systemImage: kind == "People" ? "person.2" : "tag",
            description: Text("Enter a name to find or add \(kind == "People" ? "a person" : "a tag")."))
    }
}
