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
                HStack {
                    Text(store.dataDirectory.path).textSelection(.enabled)
                        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Change Folder…", action: chooseFolder)
                        .disabled(!store.canChangeLibraryFolder)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.dataDirectory])
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
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section("Index") {
                HStack {
                    LabeledContent(
                        "Index Size",
                        value: ByteCountFormatter.string(fromByteCount: status.indexBytes, countStyle: .file))
                    Button("Rebuild Index") { store.libraryMonitor?.rebuild() }
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
                    Text("Couldn’t update the index. \(error)").foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section("Library") {
                LabeledContent("Meetings", value: status.meetingCount.formatted())
                LabeledContent("People", value: store.people.count.formatted())
                LabeledContent("Tags", value: store.tags.count.formatted())
                LabeledContent("Tasks", value: store.managedTasks.count.formatted())
            }
        }
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
