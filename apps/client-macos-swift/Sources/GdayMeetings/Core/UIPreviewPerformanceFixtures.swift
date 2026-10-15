import Foundation

/// Optional large-library fixtures use the normal folder and indexing pipeline.
/// Disk generation runs outside the main actor and never creates audio assets.
enum UIPreviewPerformanceFixtures {
    private static let transcriptPassages = [
        "Yes.",
        "Agreed.",
        "Let's check that tomorrow.",
        "The room is available after lunch. We can move the discussion to the afternoon.",
        "Please keep the original draft so we can compare it with the revised version. The introduction needs a shorter explanation, but the examples can stay as they are.",
        "We have three things to check before the workshop: the room booking, the printed handouts, and the demonstration. The first two are ready. For the demonstration, let's walk through each step together and note where someone might need more information. We should leave enough time at the end for questions.",
        "好。",
        "我们先确认时间，再整理需要讨论的问题。",
        "这次讨论先从准备工作开始。材料已经分成几个部分，每个部分都有一个简单的例子。我们可以先看第一部分，确认说明是否清楚，再继续检查后面的内容。如果发现遗漏，就记录下来，等全部看完以后一起修改。这样可以避免在同一个地方反复调整，也方便比较修改前后的版本。",
        "The draft is ready for review。我们可以先看概述，再检查每个 example 是否清楚。Please note any missing steps before the next discussion.",
        (0..<3).map { _ in
            "For the practice session, start with a short introduction and explain what participants will do. Give everyone a few minutes to read the example before asking for suggestions. Some people may want to work through the steps independently, while others may prefer to discuss them with a partner. Keep both options available. After the exercise, collect the questions that remain and use them to improve the instructions. We can review those changes together at the next session."
        }.joined(separator: " "),
        "Let's separate the preparation from the follow-up.\n\nBefore the session, confirm the room and share the agenda. After the session, collect the notes, check the open questions, and send a short record of the decisions. The record should explain what changed and who will take the next step.",
    ]

    static func longTranscriptText(at index: Int) -> String {
        // A fixed sequence varies neighboring row lengths without changing between launches.
        var value = UInt64(index) &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        let passage = transcriptPassages[Int(value % UInt64(transcriptPassages.count))]
        return "Segment \(index + 1). \(passage)"
    }

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
