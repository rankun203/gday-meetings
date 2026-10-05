import AppKit
import SwiftUI

struct MeetingDataPrivacyView: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: UUID
    @ViewState private var groups: [DataEventGroup] = []
    @ViewState private var message: String?
    @ViewState private var expandedGroups: Set<DataEventGroup.ID> = []
    @ViewState private var unreadableLines = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("Data Privacy").font(.headline)
                Spacer()
                Button("Reveal Meeting Folder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: meetingID)])
                }
                .fixedSize()
            }
            .frame(maxWidth: .infinity)
            Text("File changes and data transfers, grouped by file, action, and destination.")
                .font(.callout).foregroundStyle(.secondary)
            if let message {
                AppInlineMessage(text: message, systemImage: "exclamationmark.circle", tint: .red)
            }
            if unreadableLines > 0 {
                AppInlineMessage(
                    text:
                        "\(unreadableLines) event records couldn’t be read. Other events are shown. Reveal the meeting folder to inspect data-events.jsonl.",
                    systemImage: "exclamationmark.triangle", tint: .orange)
            }
            if groups.isEmpty && message == nil {
                ContentUnavailableView(
                    "No Data Events", systemImage: "arrow.left.arrow.right",
                    description: Text(
                        "New file changes and successful transfers appear here. Earlier activity isn’t reconstructed.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            groupRow(group)
                            Divider().padding(.vertical, 10)
                        }
                        ListCountFooter(
                            text: ListCountFooter.text(count: groups.count, singular: "Group", plural: "Groups"))
                    }.padding(.trailing, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .focusedValue(\.directoryControlFocus, true)
        .task(id: meetingID) { await watchHistory() }
    }

    private var destinations: [UUID: ServiceProvider] {
        Dictionary(store.settings.serviceProviders.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    private func destination(_ flow: DataFlow) -> String {
        guard let id = flow.targetID else { return flow.targetName + " (recorded name)" }
        let providers = destinations
        let name = flow.resolvedTargetName(providers: providers)
        if id == ThisMacProvider.id { return name }
        guard providers[id] != nil else { return name + " (removed provider)" }
        let namesakes = providers.values.filter { $0.name == name }
        return namesakes.count > 1 ? name + " · " + String(id.uuidString.prefix(8)) : name
    }

    private func groupRow(_ group: DataEventGroup) -> some View {
        let flow = group.latest.dataFlow
        return DisclosureGroup(
            isExpanded: Binding(
                get: { expandedGroups.contains(group.id) },
                set: { expanded in
                    if expanded {
                        expandedGroups.insert(group.id)
                    }
                    else {
                        expandedGroups.remove(group.id)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if group.isFile, let file = revealableFile(group.file) {
                    Button("Reveal File", systemImage: "doc") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }.buttonStyle(.link)
                }
                ForEach(group.events) { event in
                    receipt(event)
                }
            }
            .padding(.leading, 18)
            .padding(.vertical, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        group.file.isEmpty ? "Other Data" : group.file,
                        systemImage: group.action == .sent
                            ? "arrow.up.right" : group.action == .received ? "arrow.down.left" : "doc"
                    )
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(group.events.count == 1 ? "1 event" : "\(group.events.count) events")
                        .font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                Text("\(group.action.rawValue.capitalized) · \(destination(flow))")
                    .font(.callout)
                HStack(alignment: .firstTextBaseline) {
                    Text("\(flow.location == .local ? "Local" : "Remote")\(flow.domain.map { " · " + $0 } ?? "")")
                    Spacer(minLength: 8)
                    Text("Latest \(flow.startedAt.formatted(date: .abbreviated, time: .standard))")
                        .multilineTextAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .disclosureGroupStyle(AppDisclosureStyle())
    }

    private func receipt(_ event: MeetingDataEvent) -> some View {
        let flow = event.dataFlow
        return DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                detail("Destination", destination(flow))
                detail("Destination ID", flow.targetID?.uuidString ?? "Not recorded")
                if destination(flow) != flow.targetName { detail("Recorded Name", flow.targetName) }
                if let domain = flow.domain { detail("Domain", domain) }
                detail("Started", flow.startedAt.formatted(date: .abbreviated, time: .standard))
                detail("Ended", flow.endedAt?.formatted(date: .abbreviated, time: .standard) ?? "Live session")
                detail(
                    "Duration",
                    flow.duration.map { String(format: "%.3f seconds", $0) } ?? "Not available during live processing")
                detail("Total Request", size(flow.requestBytes))
                detail("Total Response", size(flow.responseBytes))
                detail("Contents", flow.bodies.joined(separator: ", "))
            }
            .font(.caption)
            .textSelection(.enabled)
            .padding(.vertical, 8)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(flow.purpose).font(.callout)
                Spacer(minLength: 8)
                Text(flow.startedAt, format: .dateTime.hour().minute().second())
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        let path = body
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let folder = store.directory(for: meetingID).resolvingSymlinksInPath()
        let file = folder.appendingPathComponent(path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(folder.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        return file
    }
    private func watchHistory() async {
        groups = []
        expandedGroups = []
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
                    let (history, updatedGroups) = try await Task.detached {
                        let history = try DataEventJournal.history(directory: folder)
                        return (history, DataEventGroup.groups(history.events))
                    }.value
                    guard !Task.isCancelled else { return }
                    groups = updatedGroups
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
