import SwiftUI

/// Shared rhythm for live, editable, and recovered transcript text. Track labels
/// describe an input source; only actual speaker attribution uses the headline.
struct TranscriptRow<Content: View>: View {
    let start: Double
    var speaker = ""
    var source: String? = nil
    var provisional = false
    var seek: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let seek {
                    Button(Self.timestamp(start), action: seek)
                        .buttonStyle(.link).monospacedDigit().help("Play from this point")
                }
                else {
                    Text(Self.timestamp(start)).monospacedDigit().foregroundStyle(.secondary)
                }
                if !speaker.isEmpty { Text(speaker).font(.headline) }
                if let source { Text(source).font(.caption).foregroundStyle(.secondary) }
                if provisional { Text("Draft").font(.caption).foregroundStyle(.secondary) }
            }
            content()
            Divider()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    static func timestamp(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(min(seconds, Double(Int.max / 2)))) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
