import SwiftUI

struct PeopleView: View {
    @Binding var selection: Set<UUID>
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var session: DirectorySession
    @ObservedObject private var page: DirectoryPaging
    private var name: String {
        get { session.query }
        nonmutating set { session.query = newValue }
    }
    @ViewState private var deleting: Person?
    private var showExcluded: Bool {
        get { session.showExcluded }
        nonmutating set { session.showExcluded = newValue }
    }
    @ViewState private var reviewingVoices = false
    private struct MergeRequest: Identifiable {
        let id = UUID()
        let personIDs: Set<UUID>
    }
    @ViewState private var mergeRequest: MergeRequest?

    init(selection: Binding<Set<UUID>>, session: DirectorySession) {
        _selection = selection
        _session = ObservedObject(wrappedValue: session)
        _page = ObservedObject(wrappedValue: session.page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(spacing: 8) {
                TextField("Find or Add Person", text: $session.query).onSubmit(findOrAdd).accessibilityLabel(
                    "Find or Add Person")
                Button("Add Person", systemImage: "plus", action: add).labelStyle(.iconOnly).help("Add Person")
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
                .padding(.top, 12)
            if selection.count > 1 {
                HStack {
                    Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Merge…") { mergeRequest = MergeRequest(personIDs: selection) }.controlSize(.small)
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            NativeDirectoryList(
                entries: page.entries, selection: $selection, label: "People", reveal: page.revealRequest,
                retainedViewport: session.viewport, viewport: page.viewport
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
                Toggle("Show Excluded", isOn: $session.showExcluded).toggleStyle(.checkbox)
                Spacer()

                Text(page.total.formatted()).font(.caption).foregroundStyle(.secondary).accessibilityLabel(
                    "\(page.total) people")

                if page.loading && !page.entries.isEmpty { ProgressView().controlSize(.small) }
            }.padding(12)
        }
        .background(AppTheme.readingBackground, ignoresSafeAreaEdges: []).navigationTitle("People")
        .toolbar {

            ToolbarItem { peopleActions }

        }
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
    private var peopleActions: some View {
        Menu {
            Button("Review Voices…") { reviewingVoices = true }
            Button("Merge Selected People…") { mergeRequest = MergeRequest(personIDs: selection) }
                .disabled(selection.count < 2)
        } label: {
            Label("People Actions", systemImage: "ellipsis.circle")
        }.labelStyle(.iconOnly).help("People Actions")
    }
    private func refresh() {
        session.refresh(index: store.directoryIndex, kind: .people, revision: store.directoryRevision)
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
    @ObservedObject private var session: DirectorySession
    @ObservedObject private var page: DirectoryPaging
    private var name: String {
        get { session.query }
        nonmutating set { session.query = newValue }
    }
    @ViewState private var deleting: MeetingTag?
    private var selectedIDs: Binding<Set<UUID>> {
        Binding(get: { selection.map { [$0] } ?? [] }, set: { selection = $0.first })
    }
    init(selection: Binding<UUID?>, session: DirectorySession) {
        _selection = selection
        _session = ObservedObject(wrappedValue: session)
        _page = ObservedObject(wrappedValue: session.page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(spacing: 8) {
                TextField("Find or Add Tag", text: $session.query).onSubmit(findOrAdd).accessibilityLabel(
                    "Find or Add Tag")
                Button("Add Tag", systemImage: "plus", action: add).help("Add Tag").labelStyle(.iconOnly)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12)
                .padding(.top, 12)
            NativeDirectoryList(
                entries: page.entries, selection: selectedIDs, multiple: false, label: "Tags",
                reveal: page.revealRequest, retainedViewport: session.viewport, viewport: page.viewport
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

            Text("\(page.total.formatted()) \(page.total == 1 ? "tag" : "tags")").font(.caption).foregroundStyle(
                .secondary
            ).padding(12)

        }.background(AppTheme.readingBackground, ignoresSafeAreaEdges: []).navigationTitle("Tags")
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
    private func refresh() {
        session.refresh(index: store.directoryIndex, kind: .tags, revision: store.directoryRevision)
    }
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
