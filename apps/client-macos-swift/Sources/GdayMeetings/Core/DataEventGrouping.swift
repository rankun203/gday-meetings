import Foundation

/// One body and action at one destination. Byte measurements belong to each
/// complete receipt, including its other bodies; they are not file-specific totals.
struct DataEventGroup: Identifiable, Equatable, Sendable {
    struct Destination: Equatable, Sendable {
        let targetID: UUID?
        /// Without a recorded target ID, two receipts cannot prove a shared provider.
        let legacyEventID: UUID?
        let legacyLocalStorage: Bool
        let location: DataFlow.Location
        let domain: String?
        /// The newest receipt supplies the display name; names never define identity.
        let targetName: String
    }

    /// A length-prefixed value, not Swift's process-randomized hash or a new UUID.
    let id: String
    /// Explicit meeting-relative path, or exact legacy body text. Empty when unnamed.
    let file: String
    let isFile: Bool
    let action: MeetingDataEvent.Action
    let destination: Destination
    /// Unique event IDs, newest start first. Equal starts sort by event ID.
    var events: [MeetingDataEvent]
    var latest: MeetingDataEvent { events[0] }

    static func groups(_ events: [MeetingDataEvent]) -> [Self] { DataEventGrouping.groups(events) }
}

enum DataEventGrouping {
    /// Input revisions follow journal order: the last occurrence of an event ID
    /// replaces earlier versions before grouping, including changed body lists.
    static func groups(_ events: [MeetingDataEvent]) -> [DataEventGroup] {
        var latest: [UUID: MeetingDataEvent] = [:]
        for event in events { latest[event.id] = event }
        let ordered = latest.values.sorted {
            if $0.dataFlow.startedAt != $1.dataFlow.startedAt {
                return $0.dataFlow.startedAt > $1.dataFlow.startedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        var groups: [String: DataEventGroup] = [:]
        for event in ordered {
            let flow = event.dataFlow
            // Only this complete old writer schema proves a built-in destination.
            // Keep it separate from new UUID-bearing receipts and all provider receipts.
            let legacyStorage =
                flow.targetID == nil && flow.location == .local && flow.domain == nil
                && (event.action == .created || event.action == .modified)
                && flow.purpose == "Saved file" && flow.targetName == "This Mac"
            let isFile = !flow.filePaths.isEmpty || legacyStorage
            let destination = DataEventGroup.Destination(
                targetID: flow.targetID, legacyEventID: flow.targetID == nil && !legacyStorage ? event.id : nil,
                legacyLocalStorage: legacyStorage,
                location: flow.location, domain: flow.domain, targetName: flow.targetName)
            // Repeated body labels within a receipt still represent one occurrence.
            let references = flow.filePaths.isEmpty ? flow.bodies : flow.filePaths
            let bodies: Set<String?> = references.isEmpty ? [nil] : Set(references.map { Optional($0) })
            for body in bodies {
                let id = identity(
                    body: body, isFile: isFile, action: event.action, destination: destination)
                if groups[id] != nil {
                    groups[id]?.events.append(event)
                }
                else {
                    groups[id] = DataEventGroup(
                        id: id, file: body ?? "", isFile: isFile, action: event.action,
                        destination: destination, events: [event])
                }
            }
        }
        return groups.values.sorted {
            // Every group has at least one event, already sorted above.
            let left = $0.events[0].dataFlow.startedAt
            let right = $1.events[0].dataFlow.startedAt
            return left != right ? left > right : $0.id < $1.id
        }
    }

    private static func identity(
        body: String?, isFile: Bool, action: MeetingDataEvent.Action, destination: DataEventGroup.Destination
    ) -> String {
        let fields: [String?] = [
            body, isFile ? "file" : "body", action.rawValue, destination.targetID?.uuidString,
            destination.legacyEventID?.uuidString, destination.legacyLocalStorage ? "legacy-local-storage" : nil,
            destination.location.rawValue, destination.domain,
        ]
        return fields.map { field in
            guard let field else { return "-" }
            return "\(field.utf8.count):\(field)"
        }.joined()
    }
}
