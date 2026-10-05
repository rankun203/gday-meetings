import SwiftUI

struct AgentsView: View {
    @EnvironmentObject private var store: MeetingStore
    @ViewState private var markdown: String?
    @ViewState private var loadError: String?
    @ViewState private var reloadID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let markdown {
                NativeMarkdownReadingView(
                    markdown: AgentGuides.displayBody(markdown), showsTimestamps: false,
                    emptyMessage: "AGENTS.md is empty.", directory: store.dataDirectory, play: { _ in }
                )
                .accessibilityLabel("AGENTS.md")
            }
            else if let loadError {
                AppInlineMessage(text: loadError, systemImage: "exclamationmark.triangle", tint: .orange)
                Button("Try Again") { reloadID = UUID() }
                    .modifier(MarkdownControlCursor())
                Spacer()
            }
            else {
                ProgressView("Reading AGENTS.md…")
                Spacer()
            }
        }
        .padding(AppTheme.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.readingBackground)
        .task(id: reloadID) {
            markdown = nil
            loadError = nil
            let folder = store.dataDirectory
            do {
                let text = try await Task.detached { try AgentGuides.read(directory: folder) }.value
                guard !Task.isCancelled else { return }
                markdown = text
            }
            catch {
                guard !Task.isCancelled else { return }
                loadError = "Couldn’t read AGENTS.md. \(error.localizedDescription)"
            }
        }
    }
}
