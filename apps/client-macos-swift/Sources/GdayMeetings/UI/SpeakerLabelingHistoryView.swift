import SwiftUI

/// Progress changes do not reread result files. Run state and source changes do.
struct SpeakerLabelingHistoryReadKey: Equatable {
    let meetingID: UUID
    let sourceID: UUID?
    var labelingResultID: UUID? = nil
    let taskStates: [String]
}

struct SpeakerLabelingHistoryView: View {
    @Binding var history: SpeakerLabelingHistory?
    var restoreChoices: [TranscriptRevision] = []
    var currentSnapshotID: UUID? = nil
    var canRestore = false
    var restore: (TranscriptRevision) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Speaker Labeling History").font(.headline)
            if !restoreChoices.isEmpty {
                Menu("Restore Labels", systemImage: "arrow.uturn.backward") {
                    ForEach(restoreChoices) { revision in
                        Button {
                            restore(revision)
                        } label: {
                            let name = revision.speakerLabelSource?.providerName ?? "Original Labels"
                            let date = revision.speakerLabelSource?.generatedAt ?? revision.savedAt
                            let title = name + " · " + date.formatted(date: .abbreviated, time: .shortened)
                            if revision.id == currentSnapshotID {
                                Label(title, systemImage: "checkmark")
                            }
                            else {
                                Text(title)
                            }
                        }.disabled(revision.id == currentSnapshotID)
                    }
                }.disabled(!canRestore || restoreChoices.count < 2)
                Text("Restores labels for this transcript’s current words and timing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let history {
                if history.entries.isEmpty {
                    Text("No speaker labeling runs or saved analyses were found for this recording.")
                        .foregroundStyle(.secondary)
                    ListCountFooter(text: "0 Entries Shown")
                }
                else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(history.entries) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(
                                            entry.date,
                                            format: .dateTime.month(.abbreviated).day().year().hour().minute()
                                        )
                                        .font(.callout.bold())
                                        Spacer()
                                        Text(entry.status).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(providerDescription(entry))
                                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    if ["Failed", "Cancelled", "Running"].contains(entry.status),
                                        let detail = entry.detail, !detail.isEmpty
                                    {
                                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                            ListCountFooter(
                                text: ListCountFooter.text(
                                    count: history.entries.count, singular: "Entry Shown", plural: "Entries Shown"))
                        }
                    }.frame(maxHeight: 360)
                }
                if history.entries.contains(where: { $0.status == "Saved analysis" }) {
                    Text("Saved analyses don’t record whether their labels were applied.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let warning = history.warning {
                    Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            else {
                ProgressView("Loading History…").frame(maxWidth: .infinity, alignment: .center).padding()
            }
        }.padding(20).frame(width: 440)
    }

    private func providerDescription(_ entry: SpeakerLabelingHistory.Entry) -> String {
        let provider = entry.providerName ?? "Provider not recorded"
        guard let revision = entry.modelRevision, !revision.isEmpty, revision != "unknown" else { return provider }
        return "\(provider) · Model \(revision)"
    }
}
