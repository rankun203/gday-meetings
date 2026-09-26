import SwiftUI

struct ServerLibraryView: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var server = GdayServerService.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "defaults"
    private var provider: ServiceProvider? {
        store.settings.serviceProviders.first {
            $0.kind == .gdayWebsite && $0.supports(.search)
                && (try? ServiceHTTP.origin($0.endpoint).absoluteString) == server.origin
        }
    }
    @ViewState private var query = ""
    @ViewState private var results: [ServerMeeting] = []
    @ViewState private var searching = false
    @ViewState private var searched = false
    @ViewState private var imported: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Library").font(.largeTitle)
            if !server.connected || provider == nil {
                ContentUnavailableView {
                    Label("Set Up Website Search", systemImage: "network")
                } description: {
                    Text("Add a Gday Meetings website, sign in, and enable Search in Service Providers.")
                } actions: {
                    Button("Open Service Providers") {
                        settingsTab = "providers"
                        openSettings()
                    }
                }
            }
            else {
                HStack {
                    TextField("Search server meetings", text: $query).onSubmit(search)
                    Button("Search", systemImage: "magnifyingglass", action: search).disabled(searching)
                    if searching { ProgressView().controlSize(.small) }
                }
                List(results) { result in
                    DisclosureGroup {
                        Text(result.transcript.isEmpty ? "No transcript available." : result.transcript).textSelection(
                            .enabled)
                        Button(imported.contains(result.id) ? "Imported" : "Import Transcript to My Library") {
                            let id = store.createMeeting(title: result.title)
                            if var meeting = store.meetings.first(where: { $0.id == id }) {
                                meeting.transcript = [
                                    TranscriptSegment(speaker: "Server transcript", text: result.transcript)
                                ]
                                store.updateMeeting(meeting)
                                imported.insert(result.id)
                            }
                        }.disabled(imported.contains(result.id))
                    } label: {
                        Text(result.title).font(.headline)
                    }
                }.overlay {
                    if searched && results.isEmpty && !searching { ContentUnavailableView.search(text: query) }
                }
            }
        }.padding(20)
    }
    private func search() {
        guard !searching, let provider else { return }
        searching = true
        Task {
            defer {
                searching = false
                searched = true
            }
            do {
                let found = try await GdaySearchProvider(provider: provider).search(query: query)
                guard self.provider?.id == provider.id else { return }
                results = found.map {
                    ServerMeeting(id: $0.meetingID, externalID: $0.externalID, title: $0.title, transcript: $0.excerpt)
                }
            }
            catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}
