import Foundation

struct MissingManagedTaskMeeting: LocalizedError {
    var errorDescription: String? { "Meeting not found. No further processing will run." }
}

extension MeetingStore {
    /// Require a readable library listing. A missing mount or unreadable meeting is not a deletion.
    func managedTaskMeetingIsMissing(_ id: UUID) async -> Bool {
        guard !isChangingLibrary, !deletingMeetingIDs.contains(id) else { return false }
        let root = dataDirectory
        let missing = await Task.detached(priority: .utility) {
            do {
                let meetings = root.appendingPathComponent("meetings")
                try MeetingFolderLocation.validate(
                    meetings.appendingPathComponent(MeetingIdentity.string(id)), directory: root)
                let entries = try FileManager.default.contentsOfDirectory(
                    at: meetings, includingPropertiesForKeys: nil)
                return !entries.contains { MeetingFolderLocation.identity($0.lastPathComponent) == id }
            }
            catch { return false }
        }.value
        return missing && dataDirectory == root && !isChangingLibrary && !deletingMeetingIDs.contains(id)
    }
}
