import Foundation

/// Optional large-library fixtures use the normal folder and indexing pipeline.
/// Disk generation runs outside the main actor and never creates audio assets.
enum UIPreviewPerformanceFixtures {
    static func flag(_ argument: String, infoKey: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
            || Bundle.main.object(forInfoDictionaryKey: infoKey) as? Bool == true
    }

    static var librarySize: Int? {
        requestedLibrarySize(
            arguments: ProcessInfo.processInfo.arguments,
            bundleValue: Bundle.main.object(forInfoDictionaryKey: "GdaySyntheticLibrarySize") as? Int)
    }

    static func requestedLibrarySize(arguments: [String], bundleValue: Int?) -> Int? {
        let prefix = "--synthetic-library-size="
        let argument = arguments.first { $0.hasPrefix(prefix) }
        let value = argument.flatMap { Int($0.dropFirst(prefix.count)) } ?? bundleValue
        return value.flatMap { [1_000, 10_000].contains($0) ? $0 : nil }
    }

    @MainActor static func schedule(_ store: MeetingStore) {
        guard UIPreview.enabled, let total = librarySize else { return }
        let additional = max(0, total - store.meetings.count)
        let directory = store.dataDirectory
        let kind = BackgroundJob.Kind(rawValue: "previewFixtures")
        guard additional > 0,
            store.beginJob(kind, .library, progress: "Preparing \(total.formatted()) preview meetings…")
        else { return }
        Task {
            defer { store.endJob(kind, .library) }
            do {
                try await Task.detached(priority: .utility) {
                    try await generate(count: additional, directory: directory) { completed in
                        await MainActor.run {
                            store.setJobProgress(
                                kind, .library,
                                "Preparing preview meetings… \(completed.formatted()) of \(additional.formatted())")
                        }
                    }
                }.value
                // Reconciliation owns all index writes and publishes paging availability.
                store.libraryMonitor?.rebuild()
            }
            catch {
                store.errorMessage = "Couldn’t prepare the preview library. \(error.localizedDescription)"
            }
        }
    }

    static func generate(
        count: Int, directory: URL,
        progress: @escaping @Sendable (Int) async -> Void = { _ in }
    ) async throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Gday-Preview-Fixtures-\(UUID())")
        defer { try? FileManager.default.removeItem(at: staging) }
        let destination = directory.appendingPathComponent("meetings")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let referenceDate = Date()
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                var meeting = Meeting(title: String(format: "Synthetic library meeting %05d", index + 1))
                meeting.createdAt = referenceDate.addingTimeInterval(-Double(index + 1) * 3_600)
                meeting.notes = "Synthetic notes for library scrolling and search."
                meeting.summary = "### Review item \(index + 1)"
                meeting.transcript = [
                    .init(start: 0, end: 5, text: "Synthetic library passage \(index + 1).")
                ]
                let folder = try MeetingFolderLocation.newFolder(
                    id: meeting.id, date: meeting.createdAt, directory: staging)
                try MeetingFolderStorage.write(meeting, directory: staging)
                try Data(meeting.notes.utf8).write(to: folder.appendingPathComponent("notes.md"), options: .atomic)
                // A monitored folder is visible only after every fixture file is complete.
                try FileManager.default.moveItem(
                    at: folder, to: destination.appendingPathComponent(folder.lastPathComponent))
            }
            if (index + 1).isMultiple(of: 250) || index + 1 == count { await progress(index + 1) }
        }
    }
}
