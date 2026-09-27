import SwiftUI

/// Shared columns keep timestamps aligned as recordings pass one hour. Live
/// transcripts omit the speaker column because an input source is not a person.
struct TranscriptRow<Content: View>: View {
    let start: Double
    var speaker = ""
    var source: String? = nil
    var provisional = false
    var showsSpeakerColumn = false
    var seek: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Text("00:00:00").hidden().accessibilityHidden(true)
                    if let seek {
                        Button(Self.timestamp(start), action: seek)
                            .buttonStyle(.link).help("Play from this point")
                    }
                    else {
                        Text(Self.timestamp(start)).foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit().fixedSize()
                if showsSpeakerColumn || !speaker.isEmpty {
                    Text(speaker).fontWeight(.semibold)
                        .frame(width: 100, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    content().frame(maxWidth: .infinity, alignment: .leading)
                    if source != nil || provisional {
                        HStack(spacing: 8) {
                            if let source { Text(source) }
                            if provisional { Text("Draft") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    static func timestamp(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(min(seconds, Double(Int.max / 2)))) : 0
        if value >= 3600 {
            return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
