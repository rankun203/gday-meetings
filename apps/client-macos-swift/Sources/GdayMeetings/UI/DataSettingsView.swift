import AppKit
import SwiftUI

struct DataSettingsView: View {
    @EnvironmentObject private var store: MeetingStore
    var body: some View {
        DataSettingsContent(status: store.libraryDataStatus)
    }
}

private struct DataSettingsContent: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    @ObservedObject var status: LibraryDataStatus
    @ViewState private var proposedFolder: URL?
    @ViewState private var copyCurrent = false
    @ViewState private var confirmsFolder = false

    var body: some View {
        Form {
            Section("Data Folder") {
                VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
                    Label {
                        Text(store.dataDirectory.path).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Change Folder…", action: chooseFolder)
                            .disabled(!store.canChangeLibraryFolder)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.dataDirectory])
                        }
                    }
                }
                if store.isCopyingLibrary {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Copying library… \(store.copiedLibraryFiles.formatted()) files verified")
                        Spacer()
                        Button("Cancel") { store.cancelLibraryFolderChange() }
                    }
                }
                if let pending = store.pendingLibraryFolder {
                    Text("Data folder after restart: \(pending.path)").textSelection(.enabled)
                    Text("Quit and reopen Gday Meetings to use this folder. The original files are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel Change") { store.cancelLibraryFolderChange() }
                        Button("Quit Gday Meetings") { NSApp.terminate(nil) }
                    }
                }
                else if !store.isCopyingLibrary {
                    Text(
                        "Choose an empty folder to copy your library, or an existing library to open after restarting."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Text("For iCloud Drive, keep the data folder downloaded and use it on one Mac at a time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.libraryFolderError {
                    AppInlineMessage(text: error, systemImage: "exclamationmark.circle", tint: .red)
                }
            }
            Section("Library Index") {
                HStack {
                    LabeledContent(
                        "Index Size",
                        value: ByteCountFormatter.string(fromByteCount: status.indexBytes, countStyle: .file))
                    Button("Rebuild Library Index") { store.libraryMonitor?.rebuild() }
                        .disabled(status.isBuilding || store.isChangingLibrary)
                }
                if store.indexDirectory != store.dataDirectory {
                    Text("Local index: \(store.indexDirectory.appendingPathComponent("index.db").path)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if status.isBuilding {
                    HStack {
                        ProgressView().controlSize(.small)
                        if status.isDiscovering {
                            Text("Reading meeting folders… \(status.discoveredFolders.formatted()) checked")
                        }
                        else {
                            Text("Building index… \(status.processed.formatted()) meetings processed")
                        }
                    }
                    Text("Counts are incomplete while the index is building.").font(.caption).foregroundStyle(
                        .secondary)
                }
                if let error = status.error {
                    AppInlineMessage(
                        text: "Couldn’t update the index. \(error)", systemImage: "exclamationmark.circle", tint: .red)
                }
            }
            SearchIndexSettings(controller: store.localSearch)
            Section("Library") {
                LabeledContent("Meetings", value: status.meetingCount.formatted())
                LabeledContent("People", value: store.people.count.formatted())
                LabeledContent("Tags", value: store.tags.count.formatted())
                LabeledContent("Tasks", value: store.managedTaskCount.formatted())
            }
        }
        .formStyle(.grouped)
        .alert(
            copyCurrent ? "Copy Library to This Folder?" : "Open This Library After Restart?",
            isPresented: $confirmsFolder
        ) {
            Button("Cancel", role: .cancel) {}
            Button(copyCurrent ? "Copy Library" : "Use Library") {
                guard let proposedFolder else { return }
                store.libraryCopyTask = Task {
                    await store.changeLibraryFolder(to: proposedFolder, copyCurrent: copyCurrent)
                }
            }
        } message: {
            Text(
                copyCurrent
                    ? "Your library will be copied to \(proposedFolder?.path ?? ""). Editing pauses until you restart or cancel the change. The original files are kept."
                    : "Gday Meetings will open \(proposedFolder?.path ?? "") after restarting. Your current library stays in its existing folder."
            )
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Data Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            copyCurrent = try LibraryFolderChoice.inspect(url, current: store.dataDirectory) == .empty
            proposedFolder = url
            confirmsFolder = true
            store.libraryFolderError = nil
        }
        catch { store.libraryFolderError = error.localizedDescription }
    }
}

private struct SearchIndexSettings: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject var controller: LocalSearchController
    var body: some View {
        Section("Search Index") {
            if let provider = store.selectedSearchProvider {
                LabeledContent("Model", value: (provider.localSearch ?? .init()).selectedModel.title)
                Text(controller.status).font(.callout)
                if let progress = controller.progress {
                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                    Text("\(progress.completed) of \(progress.total) passages in the current meeting")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = controller.error {
                    AppInlineMessage(text: error, systemImage: "exclamationmark.circle", tint: .orange)
                }
                Button("Rebuild Search Index") { store.scheduleSearchIndexing(rebuild: true) }
                    .disabled(!store.libraryWritable || store.isChangingLibrary || controller.scanTask != nil)
            }
            else {
                Text("Add Local Search in Service Providers to search by meaning.")
            }
        }
    }
}
