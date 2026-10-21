import SwiftUI

// Select the native property wrapper when Command Line Tools also expose an
// unavailable State macro. This does not change SwiftUI's state behavior.
private typealias NativeState<Value> = SwiftUI.State<Value>

@main
struct NativeSidebarApp: App {
    @NativeState private var visibility: NavigationSplitViewVisibility = .doubleColumn
    @NativeState private var collection: String? = "Notes"
    @NativeState private var selectedNote: Int? = 1

    var body: some Scene {
        Window("Astra Native Sidebar", id: "main") {
            NavigationSplitView(columnVisibility: $visibility) {
                List(selection: $collection) {
                    Label("Notes", systemImage: "doc.text").tag("Notes")
                    Label("Projects", systemImage: "folder").tag("Projects")
                    Label("Archive", systemImage: "archivebox").tag("Archive")
                }
                .navigationTitle("Collections")
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            } content: {
                List(1...30, id: \.self, selection: $selectedNote) { number in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sample Note \(number)").font(.headline)
                        Text("A summary of plans and next steps.").foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .navigationTitle(collection ?? "Notes")
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
            } detail: {
                if let selectedNote {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Sample Note \(selectedNote)").font(.largeTitle)
                            ForEach(1...12, id: \.self) { number in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Discussion \(number)").font(.headline)
                                    Text(
                                        "The group reviewed the draft schedule and discussed how to make each step easier to follow. The next version will include a short explanation of the work, a clear owner for each activity, and enough time for review. Participants agreed to collect questions before the next discussion so that everyone can prepare. The plan will be updated after the remaining estimates are available. A final review will check that the sequence is practical and that the instructions describe what happens next."
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                    }
                    .navigationTitle("Sample Note \(selectedNote)")
                }
                else {
                    ContentUnavailableView("Select a Note", systemImage: "doc.text")
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .defaultSize(width: 1200, height: 800)
        .commands { SidebarCommands() }
    }
}
