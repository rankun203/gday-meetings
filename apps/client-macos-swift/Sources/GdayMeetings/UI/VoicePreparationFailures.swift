import SwiftUI

struct VoicePreparationFailure: Identifiable, Equatable, Sendable {
    let id: String
    let meetingID: UUID?
    let title: String
    let message: String
    var titleResolved = false

    static func resolve(
        page: TaskFailurePage, examples: [VoiceExample], titles: [UUID: String]
    ) -> [Self] {
        let exampleIDs = Set(page.entries.compactMap { UUID(uuidString: $0.key) })
        let meetings = Dictionary(
            examples.filter { exampleIDs.contains($0.id) }.map { ($0.id, $0.meetingID) },
            uniquingKeysWith: { first, _ in first })
        return page.resolve { key, message in
            let recordingID = key.hasPrefix("recording-") ? UUID(uuidString: String(key.dropFirst(10))) : nil
            let meetingID = recordingID ?? UUID(uuidString: key).flatMap { meetings[$0] }
            return Self(
                id: key, meetingID: meetingID,
                title: meetingID.flatMap { titles[$0] } ?? (recordingID == nil ? "Voice Example" : "Recording"),
                message: message, titleResolved: meetingID.flatMap { titles[$0] } != nil)
        }
    }

    func displayTitle(indexTitles: [UUID: String]) -> String {
        titleResolved ? title : meetingID.flatMap { indexTitles[$0] } ?? title
    }

    static func loadTitles(for rows: [Self], index: LibraryIndex?) async -> [UUID: String] {
        let ids = Set(rows.filter { !$0.titleResolved }.compactMap(\.meetingID))
        guard !ids.isEmpty else { return [:] }
        let worker = Task.detached(priority: .userInitiated) {
            var result: [UUID: String] = [:]
            for id in ids {
                guard !Task.isCancelled else { break }
                if let entry = try? index?.entry(id: id) { result[id] = entry.title }
            }
            return result
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

/// A visible error page owns its title lookup; progress never hydrates whole meetings.
struct VoicePreparationFailures: View {
    @EnvironmentObject private var store: MeetingStore
    let jobID: UUID
    let failures: [String: String]
    @Binding var offset: Int
    var showMeeting: ((UUID) -> Void)? = nil
    @ViewState private var prepared: Prepared?

    private struct Request: Equatable {
        let jobID: UUID
        let failures: [String: String]
        let offset: Int
        let indexRevision: UUID
        let evidenceRevision: Int
        let directory: URL
    }
    private struct Prepared {
        let request: Request
        let page: TaskFailurePage
        let rows: [VoicePreparationFailure]
    }
    private var request: Request {
        Request(
            jobID: jobID, failures: failures, offset: offset, indexRevision: store.meetingIndexRevision,
            evidenceRevision: store.voiceLibrary.reviewMetadataRevision, directory: store.dataDirectory)
    }

    var body: some View {
        let request = request
        VStack(alignment: .leading, spacing: 10) {
            if let prepared, prepared.request.jobID == request.jobID,
                prepared.request.offset == request.offset, prepared.request.directory == request.directory
            {
                ForEach(prepared.rows) { failure in
                    HStack(alignment: .top, spacing: 12) {
                        description(failure)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let meetingID = failure.meetingID, let showMeeting {
                            Button("Open Meeting") { showMeeting(meetingID) }
                                .fixedSize().accessibilityLabel("Open Meeting, \(failure.title)")
                        }
                    }
                }
                let page = prepared.page
                if page.count > TaskFailurePage.size {
                    HStack {
                        Button("Previous Errors") { offset = page.offset - TaskFailurePage.size }
                            .disabled(!page.hasPrevious)
                        Text("\(page.offset + 1)–\(page.offset + page.entries.count) of \(page.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Next Errors") { offset = page.offset + TaskFailurePage.size }
                            .disabled(!page.hasNext)
                    }
                }
            }
            else if !failures.isEmpty {
                ProgressView("Loading Errors…").controlSize(.small)
            }
        }
        .task(id: request) {
            // Sorting and index I/O belong to preparation, never layout or activation.
            let page = await TaskFailurePage.prepare(failures: request.failures, offset: request.offset)
            guard !Task.isCancelled else { return }
            let examples = store.voiceLibrary.reviewEvidence(
                for: Set(page.entries.compactMap { UUID(uuidString: $0.key) }))
            let loadedTitles = Dictionary(
                store.meetings.map { ($0.id, $0.title) }, uniquingKeysWith: { _, latest in latest })
            let rows = VoicePreparationFailure.resolve(page: page, examples: examples, titles: loadedTitles)
            let titles = await VoicePreparationFailure.loadTitles(for: rows, index: store.libraryIndex)
            guard !Task.isCancelled, store.dataDirectory == request.directory else { return }
            prepared = Prepared(
                request: request, page: page,
                rows: rows.map { row in
                    VoicePreparationFailure(
                        id: row.id, meetingID: row.meetingID, title: row.displayTitle(indexTitles: titles),
                        message: row.message,
                        titleResolved: row.titleResolved || row.meetingID.flatMap { titles[$0] } != nil)
                })
        }
    }

    private func description(_ failure: VoicePreparationFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(failure.title)
                .font(.subheadline.weight(.semibold)).textSelection(.enabled)
            AppInlineMessage(text: failure.message, systemImage: "exclamationmark.circle", tint: .orange)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
