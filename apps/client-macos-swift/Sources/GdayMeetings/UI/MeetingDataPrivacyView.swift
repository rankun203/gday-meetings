import AppKit
import SwiftUI

struct MeetingDataPrivacyView: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: UUID
    @ViewState private var events: [MeetingDataEvent] = []
    @ViewState private var message: String?
    @ViewState private var unreadableLines = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Data Privacy").font(.headline)
                Spacer()
                Button("Reveal Meeting Folder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: meetingID)])
                }
            }
            Text("Successful file changes and data transfers for this meeting.")
                .font(.callout).foregroundStyle(.secondary)
            if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if unreadableLines > 0 {
                Text(
                    "\(unreadableLines) event records couldn’t be read. Other events are shown. Reveal the meeting folder to inspect data-events.jsonl."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            if events.isEmpty && message == nil {
                ContentUnavailableView(
                    "No Data Events", systemImage: "arrow.left.arrow.right",
                    description: Text(
                        "New file changes and successful transfers appear here. Earlier activity isn’t reconstructed."))
            }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            eventRow(event)
                            Divider().padding(.vertical, 10)
                        }
                    }.padding(.trailing, 8)
                }
            }
        }
        .task(id: meetingID) { await watchHistory() }
    }

    private func eventRow(_ event: MeetingDataEvent) -> some View {
        let flow = event.dataFlow
        return DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                detail("Destination", flow.targetName + " · " + flow.location.rawValue.capitalized)
                if let domain = flow.domain { detail("Domain", domain) }
                detail("Started", flow.startedAt.formatted(date: .abbreviated, time: .standard))
                detail("Ended", flow.endedAt?.formatted(date: .abbreviated, time: .standard) ?? "Live session")
                detail(
                    "Duration",
                    flow.duration.map { String(format: "%.3f seconds", $0) } ?? "Not available during live processing")
                detail("Request", size(flow.requestBytes))
                detail("Response", size(flow.responseBytes))
            }
            .font(.caption)
            .textSelection(.enabled)
            .padding(.vertical, 8)
            ForEach(flow.bodies, id: \.self) { body in
                if let file = revealableFile(body) {
                    Button("Reveal \(file.lastPathComponent)", systemImage: "doc") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }.buttonStyle(.link)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        event.action.rawValue.capitalized,
                        systemImage: event.action == .sent
                            ? "arrow.up.right" : event.action == .received ? "arrow.down.left" : "doc"
                    )
                    .font(.callout.weight(.semibold))
                    Text(flow.purpose).font(.callout)
                    Spacer(minLength: 8)
                    Text(flow.startedAt, format: .dateTime.hour().minute().second())
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(flow.bodies.joined(separator: ", ")).font(.callout).textSelection(.enabled)
                Text(
                    "\(flow.location == .local ? "Local" : "Remote") · \(flow.targetName)\(flow.domain.map { " · " + $0 } ?? "")"
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .disclosureGroupStyle(AppDisclosureStyle())
    }

    private func detail(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
    private func size(_ bytes: Int?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + " (\($0) bytes)" }
            ?? "Not measured"
    }
    private func revealableFile(_ body: String) -> URL? {
        let path = body.components(separatedBy: " (").first ?? body
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let folder = store.directory(for: meetingID).resolvingSymlinksInPath()
        let file = folder.appendingPathComponent(path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(folder.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        return file
    }
    private func watchHistory() async {
        events = []
        message = nil
        unreadableLines = 0
        let folder = store.directory(for: meetingID)
        var previousSize: Int?
        var previousModified: Date?
        var first = true
        while !Task.isCancelled {
            let file = folder.appendingPathComponent(DataEventJournal.filename)
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if first || values?.fileSize != previousSize || values?.contentModificationDate != previousModified {
                first = false
                previousSize = values?.fileSize
                previousModified = values?.contentModificationDate
                do {
                    let history = try await Task.detached { try DataEventJournal.history(directory: folder) }.value
                    guard !Task.isCancelled else { return }
                    events = history.events.reversed()
                    unreadableLines = history.unreadableLines
                    message = nil
                }
                catch { message = "Couldn’t read data-events.jsonl. \(error.localizedDescription)" }
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }
}
