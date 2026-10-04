import SwiftUI

/// Settings → Data Privacy. Rows are derived from current provider settings, so
/// opening this tab reads no credentials and makes no network requests.
struct DataPrivacyView: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var server = GdayServerService.shared

    var body: some View {
        DataPrivacyForm(
            rows: DataPrivacy.rows(
                PrivacyContext(
                    settings: store.settings, signedInWebsiteOrigin: server.connected ? server.origin : nil,
                    pendingTranscriptions: store.pendingMeetingTranscriptions))
        ) { MeetingPanels.exportLogs(store) }
    }
}

/// Separate from the store so layout can be checked with synthetic rows.
struct DataPrivacyForm: View {
    let rows: [PrivacyRow]
    let exportLogs: () -> Void

    var body: some View {
        Form {
            Section {
                Text(
                    "Meeting files are saved in your data folder. If you choose a synced folder, its cloud service controls synchronization. The providers below receive data when the listed actions run."
                )
                .foregroundStyle(.secondary)
            }
            Section("Data") {
                ForEach(rows) { DataPrivacyRowView(row: $0) }
            }
            Section("Logs") {
                Text(
                    "Each transmission is logged with its provider, address, data type, and size. Logs don’t include meeting content or credentials."
                )
                VStack(alignment: .leading, spacing: AppTheme.compactSpacing) {
                    Button("Export Logs", action: exportLogs)
                    Text("Saves this session’s logs from the last hour to ~/Library/Logs/Gday Meetings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataPrivacyRowView: View {
    let row: PrivacyRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.contentSpacing) {
            Image(systemName: row.type.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.compactSpacing) {
                Text(row.type.title).font(.headline)
                if let contents = row.type.contents {
                    Text(contents).font(.caption).foregroundStyle(.secondary)
                }
                // Symbols distinguish file storage and provider transmissions without relying on color.
                if row.destinations.isEmpty {
                    Label(row.storageStatus, systemImage: row.storageSymbol)
                        .foregroundStyle(.secondary)
                }
                else {
                    ForEach(row.destinations) { destination in
                        Label {
                            Text(destination.text)
                        } icon: {
                            Image(systemName: "arrow.up.forward.circle").foregroundStyle(.tint)
                        }
                    }
                }
                if let note = row.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AppTheme.compactSpacing)
        // One VoiceOver element per data type: name, contents, status, then note.
        .accessibilityElement(children: .combine)
    }
}
