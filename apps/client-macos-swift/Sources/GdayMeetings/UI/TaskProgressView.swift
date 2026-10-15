import SwiftUI

/// Presents measured phase work without turning a time prediction into completion.
struct TaskProgressView: View {
    let progress: TaskProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)
                .accessibilityLabel(progress.phase)
            if let remaining = progress.remainingTimeText {
                Text(remaining).font(.caption).foregroundStyle(.secondary)
            }
            else {
                Text("Elapsed: \(progress.startedAt, style: .timer)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
