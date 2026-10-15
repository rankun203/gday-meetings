import SwiftUI

struct PeopleVoiceReviewBar: View {
    @ObservedObject var library: VoiceLibraryStore
    @ObservedObject private var notice: VoiceReviewNotice
    @Binding var reviewingVoices: Bool

    init(library: VoiceLibraryStore, reviewingVoices: Binding<Bool>) {
        self.library = library
        _notice = ObservedObject(wrappedValue: library.reviewNotice)
        _reviewingVoices = reviewingVoices
    }

    var body: some View {
        if notice.isVisible(for: library.examples) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    let count = VoiceReviewNotice.voiceCount(in: library.examples)
                    Text(count == 1 ? "1 voice to review" : "\(count) voices to review")
                    Spacer(minLength: 12)
                    Button("Review Voices…") { reviewingVoices = true }
                        .buttonStyle(.bordered)
                    Button("Dismiss Voice Review Notice", systemImage: "xmark") {
                        notice.dismiss(examples: library.examples)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Dismiss Voice Review Notice")
                }
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
            }
            .background(.bar)
        }
    }
}
