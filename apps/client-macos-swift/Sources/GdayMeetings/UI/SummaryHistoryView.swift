import SwiftUI

struct SummaryHistoryView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    let meetingID: UUID
    @ViewState private var history = HistorySnapshot()
    @ViewState private var selectedID: UUID?
    @ViewState private var selected: SavedSummary?
    @ViewState private var historyError: String?
    @ViewState private var selectionError: String?
    @ViewState private var restoreError: String?
    @ViewState private var loadingHistory = true
    @ViewState private var loadingSelection = false
    @ViewState private var restoring = false
    @ViewState private var reloadID = UUID()

    private struct HistorySnapshot: Sendable {
        struct Entry: Identifiable, Sendable {
            let id: UUID
            let date: Date
            let providerName: String
        }
        var currentID: UUID?
        var entries: [Entry] = []
    }

    private struct SavedSummary: Sendable {
        let id: UUID
        let result: String?
    }

    private struct ReadKey: Equatable, Sendable {
        let revision: Int
        let summary: String?
        let reloadID: UUID
    }

    private struct SelectionReadKey: Equatable {
        let id: UUID?
        let reloadID: UUID
    }

    private var readKey: ReadKey {
        ReadKey(
            revision: store.summaryHistoryRevisions[meetingID, default: 0],
            summary: store.meeting(id: meetingID)?.summary, reloadID: reloadID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Summary History").font(.title2.bold())
            if loadingHistory && history.entries.isEmpty {
                ProgressView("Loading History…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else if historyError != nil && history.entries.isEmpty {
                Spacer()
            }
            else if history.entries.isEmpty {
                ContentUnavailableView(
                    "No Saved Versions", systemImage: "clock.arrow.circlepath",
                    description: Text("Generate a summary to save a version here."))
            }
            else {
                HStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(history.entries) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(
                                    entry.date,
                                    format: .dateTime.month(.abbreviated).day().year().hour().minute()
                                )
                                .font(.headline)
                                Text(entry.providerName).font(.callout).foregroundStyle(.secondary)
                                if entry.id == history.currentID {
                                    Label("Current", systemImage: "checkmark.circle.fill")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(entry.id)
                        }
                        ListCountFooter(
                            text: ListCountFooter.text(
                                count: history.entries.count, singular: "Saved Version", plural: "Saved Versions")
                        )
                        .selectionDisabled()
                    }
                    .accessibilityLabel("Saved summary versions")
                    .disabled(restoring)
                    .frame(width: 230)
                    Divider()
                    if loadingSelection {
                        ProgressView("Loading Summary…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    else if let selected, let result = selected.result {
                        MeetingMarkdownReadingView(
                            meetingID: meetingID, markdown: result, showsTimestamps: false,
                            emptyMessage: "This summary is empty."
                        )
                        .id(selected.id)
                        .padding(.leading, 16)
                        .accessibilityLabel("Saved summary")
                    }
                    else if selectionError == nil {
                        ContentUnavailableView("Select a Version", systemImage: "doc.text")
                    }
                    else {
                        Spacer()
                    }
                }
            }
            if let errorMessage = restoreError ?? historyError ?? selectionError {
                AppInlineMessage(text: errorMessage, systemImage: "exclamationmark.triangle", tint: .red)
                Button("Reload History") {
                    restoreError = nil
                    reloadID = UUID()
                }
                .disabled(restoring)
            }
            HStack {
                Button("Use This Summary") {
                    guard let selectedID else { return }
                    restoring = true
                    restoreError = nil
                    Task {
                        if await store.restoreSummaryGeneration(id: selectedID, meetingID: meetingID) {
                            reloadID = UUID()
                        }
                        else {
                            restoreError = store.errorMessage ?? "Couldn’t restore this summary. Try again."
                        }
                        restoring = false
                    }
                }
                .disabled(
                    !store.libraryWritable || selected?.result == nil || restoring || loadingSelection || loadingHistory
                        || historyError != nil
                        || selected?.result == store.meeting(id: meetingID)?.summary)
                if restoring { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(restoring)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 460, idealHeight: 560)
        .task(id: readKey) { await loadHistory() }
        .task(id: SelectionReadKey(id: selectedID, reloadID: reloadID)) { await loadSelection() }
    }

    private func loadHistory() async {
        let key = readKey
        let folder = store.directory(for: meetingID)
        loadingHistory = true
        do {
            let snapshot = try await Task.detached(priority: .utility) {
                let saved = try SummaryHistory.read(at: folder)
                let currentID: UUID?
                if let id = saved.currentID,
                    let generation = try? SummaryGeneration.read(id: id, at: folder),
                    generation.result == key.summary
                {
                    currentID = id
                }
                else {
                    currentID = nil
                }
                return HistorySnapshot(
                    currentID: currentID,
                    entries: saved.entries.compactMap { entry in
                        guard let date = entry.completedAt else { return nil }
                        return HistorySnapshot.Entry(id: entry.id, date: date, providerName: entry.providerName)
                    }.sorted { $0.date > $1.date })
            }.value
            guard !Task.isCancelled, readKey == key else { return }
            history = snapshot
            historyError = nil
            if !history.entries.contains(where: { $0.id == selectedID }) {
                selectedID = history.currentID ?? history.entries.first?.id
            }
        }
        catch {
            guard !Task.isCancelled, readKey == key else { return }
            historyError = "Couldn’t load summary history. \(error.localizedDescription)"
        }
        loadingHistory = false
    }

    private func loadSelection() async {
        selected = nil
        selectionError = nil
        loadingSelection = false
        guard let selectedID else { return }
        let folder = store.directory(for: meetingID)
        loadingSelection = true
        do {
            let value = try await Task.detached(priority: .utility) {
                let generation = try SummaryGeneration.read(id: selectedID, at: folder)
                return SavedSummary(id: generation.id, result: generation.result)
            }.value
            guard !Task.isCancelled, self.selectedID == selectedID else { return }
            selected = value
        }
        catch {
            guard !Task.isCancelled, self.selectedID == selectedID else { return }
            selectionError = "Couldn’t load this summary. \(error.localizedDescription)"
        }
        loadingSelection = false
    }
}
