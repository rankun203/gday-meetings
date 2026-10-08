import SwiftUI

struct VoiceExampleDetailsView: View {
    @ObservedObject var library: VoiceLibraryStore
    let example: VoiceExample
    @ViewState private var isExpanded = false
    @ViewState private var hydrated: VoiceExample?

    var body: some View {
        DisclosureGroup("Voice Details", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    detail("Audio", library.availabilityReason(for: example) ?? "Current recorded excerpt")
                    detail("Audio File", example.audioFile ?? "Not recorded")
                    if let range = example.range, range.supportSpans.count > 1 {
                        detail("Playback", "\(range.supportSpans.count) short excerpts; gaps are skipped")
                    }
                    detail("Review", review)
                }
                if hydrated == nil {
                    Text("Model details are unavailable.").foregroundStyle(.secondary)
                }
                else if hydrated?.voiceEmbeddings.isEmpty == true {
                    Text("No model representations are saved for this sample.").foregroundStyle(.secondary)
                }
                ForEach(Array((hydrated?.voiceEmbeddings ?? []).enumerated()), id: \.offset) { index, embedding in
                    representation(embedding, title: "Model \(index + 1)")
                }
            }.font(.caption).padding(.top, 8).padding(.leading, 18)
        }.disclosureGroupStyle(AppDisclosureStyle())
            .task(id: isExpanded) {
                hydrated = isExpanded ? library.hydratedExample(id: example.id) : nil
                library.releaseRepresentations()
            }
            .onChange(of: example) { _, _ in
                if isExpanded { hydrated = library.hydratedExample(id: example.id) }
                library.releaseRepresentations()
            }
            .onChange(of: library.representationsRevision) { _, _ in
                if isExpanded { hydrated = library.hydratedExample(id: example.id) }
                library.releaseRepresentations()
            }
    }

    private func representation(_ embedding: TypedVoiceEmbedding, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                detail("Status", representationStatus(embedding))
                detail("Model", recorded(embedding.type.modelID))
                detail("Revision", recorded(embedding.type.revision))
                detail("Recorded Provenance", recorded(embedding.provenance))
                detail("Compatibility", recorded(embedding.type.compatibilityVersion))
                detail("Dimensions", String(embedding.type.dimension))
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recorded(_ value: String?) -> String {
        guard let value, !value.isEmpty, value != "unknown" else { return "Not recorded" }
        return value
    }

    private var review: String {
        if example.excluded { return "Excluded from voice recognition" }
        if example.review == .rejected { return "Assignment rejected" }
        if example.manuallyCleared { return "Assignment removed" }
        switch example.review {
        case .confirmed: return "Confirmed"
        case .suggested: return "Suggested · Needs review"
        case .rejected: return "Assignment rejected"
        case .unassigned: return example.manuallyCleared ? "Assignment removed" : "Unassigned"
        }
    }

    private func representationStatus(_ embedding: TypedVoiceEmbedding) -> String {
        if !embedding.type.supportsMatching { return "Model identity is incomplete · Not used for matching" }
        if !embedding.isValid { return "Invalid representation · Not used for matching" }
        if example.excluded { return "Excluded from voice recognition" }
        if example.review == .rejected || example.manuallyCleared { return "Prepared · Not used to confirm identity" }
        if example.review != .confirmed { return "Needs confirmation" }
        if let reason = library.matchingBlockReason(for: example) { return reason }
        return "Ready for matching"
    }
}
