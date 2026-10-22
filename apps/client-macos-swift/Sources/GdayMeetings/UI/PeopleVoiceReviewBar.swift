import SwiftUI

struct PeopleVoiceReviewBar: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.showManagedTask) private var showManagedTask
    @ObservedObject var library: VoiceLibraryStore
    @Binding var reviewingVoices: Bool

    @ViewState private var peopleWithMatches = 0
    @ViewState private var unnamedGroups = 0
    @ViewState private var loaded: Request?
    @ViewState private var failed: Request?
    @ViewState private var failureMessage: String?

    private struct Request: Equatable {
        let people: Set<UUID>
        let policy: VoiceMatchingPolicy
        let revision: Int
        let metadataRevision: Int
        let reviewingVoices: Bool
    }

    private var request: Request {
        Request(
            people: Set(store.people.map(\.id)),
            policy: store.settings.serviceProviders.first { $0.id == store.settings.diarizationProviderID }?
                .voiceMatchingPolicy ?? .default, revision: library.reviewEvidenceRevision,
            metadataRevision: library.reviewMetadataRevision, reviewingVoices: reviewingVoices)
    }

    private var hasCurrentMetadata: Bool {
        loaded?.people == request.people && loaded?.metadataRevision == request.metadataRevision
            && loaded?.policy == request.policy
    }

    private var hasPendingReviews: Bool {
        failed != request && hasCurrentMetadata && (peopleWithMatches > 0 || unnamedGroups > 0)
    }

    private var summary: String {
        if failed == request { return "Couldn’t load voice matches" }
        guard hasCurrentMetadata else { return "Checking for voice matches" }
        var parts: [String] = []
        if peopleWithMatches > 0 {
            parts.append("\(peopleWithMatches) \(peopleWithMatches == 1 ? "person" : "people") with new matches")
        }
        if unnamedGroups > 0 {
            parts.append("\(unnamedGroups) unidentified \(unnamedGroups == 1 ? "voice" : "voices")")
        }
        return parts.isEmpty ? "No pending voice reviews" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: "person.2")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hasPendingReviews ? "People to Review" : "People Library")
                        .font(.headline)
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(hasPendingReviews ? "People to Review" : "People Library"), \(summary.replacingOccurrences(of: " · ", with: ", "))"
                )
                .help(failed == request ? (failureMessage ?? summary) : summary)
                Spacer(minLength: 16)
                if hasCurrentMetadata && !hasPendingReviews && failed != request {
                    PeopleScanStartButton(store: store, library: library, showTask: showManagedTask)
                }
                Button("Review Library") { reviewingVoices = true }
                    .buttonStyle(.bordered)
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
        }
        .background(.bar)
        .task(id: request) {
            let current = request
            // The chooser owns refreshes while open. Re-read its result on close,
            // including recovery that succeeded without changing library evidence.
            failed = nil
            failureMessage = nil
            guard !current.reviewingVoices else { return }
            do {
                let snapshot = try await library.reviewSnapshot(for: current.people, policy: current.policy)
                guard !Task.isCancelled, current == request else { return }
                peopleWithMatches = snapshot.candidates.values.filter { !$0.isEmpty }.count
                unnamedGroups = snapshot.unnamedGroups.count
                loaded = current
            }
            catch {
                guard !Task.isCancelled, current == request else { return }
                failureMessage = error.localizedDescription
                failed = current
            }
        }
    }
}
