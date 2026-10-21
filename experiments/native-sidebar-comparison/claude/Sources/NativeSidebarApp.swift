import SwiftUI

// Minimal three-column NavigationSplitView baseline. The split view is the
// window's root so any sidebar motion problem can be attributed to SwiftUI
// itself rather than to surrounding layout.

@main
struct NativeSidebarApp: App {
    var body: some Scene {
        WindowGroup("Claude Native Sidebar") {
            RootSplitView()
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            SidebarCommands()
        }
    }
}

struct RootSplitView: View {
    // Starts with the sidebar hidden and the content and detail columns visible.
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    @State private var selectedCategoryID: SampleCategory.ID? = SampleData.categories.first?.id
    @State private var selectedEntryID: SampleEntry.ID? = SampleData.entries(
        in: SampleData.categories.first?.id
    ).first?.id

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SampleData.categories, selection: $selectedCategoryID) { category in
                Label(category.name, systemImage: category.symbolName)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } content: {
            List(SampleData.entries(in: selectedCategoryID), selection: $selectedEntryID) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
            // Keep the detail column populated when the category changes.
            .onChange(of: selectedCategoryID) { _, newCategoryID in
                selectedEntryID = SampleData.entries(in: newCategoryID).first?.id
            }
        } detail: {
            if let entry = SampleData.entry(withID: selectedEntryID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(entry.title)
                            .font(.largeTitle)
                        ForEach(entry.paragraphs.indices, id: \.self) { index in
                            Text(entry.paragraphs[index])
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(entry.title)
            }
            else {
                ContentUnavailableView(
                    "No Entry Selected",
                    systemImage: "doc.text",
                    description: Text("Select an entry to view its text.")
                )
            }
        }
    }
}

struct SampleCategory: Identifiable, Hashable {
    let id: Int
    let name: String
    let symbolName: String
}

struct SampleEntry: Identifiable, Hashable {
    let id: Int
    let categoryID: SampleCategory.ID
    let title: String
    let summary: String
    let paragraphs: [String]
}

// Synthetic, deterministic content built once at launch.
enum SampleData {
    static let categories: [SampleCategory] = [
        SampleCategory(id: 0, name: "Inbox", symbolName: "tray"),
        SampleCategory(id: 1, name: "Drafts", symbolName: "pencil"),
        SampleCategory(id: 2, name: "Reference", symbolName: "book"),
        SampleCategory(id: 3, name: "Shared", symbolName: "person.2"),
        SampleCategory(id: 4, name: "Archive", symbolName: "archivebox"),
    ]

    static let entriesPerCategory = 8
    static let paragraphsPerEntry = 14

    static let allEntries: [SampleEntry] = categories.flatMap { category in
        (0..<entriesPerCategory).map { offset in
            let id = category.id * entriesPerCategory + offset
            let paragraphs = (0..<paragraphsPerEntry).map { paragraph(entryID: id, index: $0) }
            return SampleEntry(
                id: id,
                categoryID: category.id,
                title: "\(category.name) Entry \(offset + 1)",
                summary: paragraphs[0],
                paragraphs: paragraphs
            )
        }
    }

    static func entries(in categoryID: SampleCategory.ID?) -> [SampleEntry] {
        allEntries.filter { $0.categoryID == categoryID }
    }

    static func entry(withID id: SampleEntry.ID?) -> SampleEntry? {
        allEntries.first { $0.id == id }
    }

    private static let sentences = [
        "This paragraph is placeholder text used to fill the detail column.",
        "Each line should wrap at the column edge instead of extending past it.",
        "When the sidebar opens or closes, the text reflows to the new column width.",
        "The sample describes an ordinary task list with a few related notes.",
        "A second item follows the first and repeats the same general structure.",
        "Nothing in this text refers to a real person, place, or project.",
        "Longer sentences make the wrapping behavior easier to observe while resizing.",
        "The content column lists entries, and the detail column shows the selected one.",
        "Scrolling should remain smooth while the window changes size.",
        "This sentence exists only to vary the length of each paragraph.",
    ]

    // Rotates through the sentence pool so neighboring paragraphs differ in length and wording.
    private static func paragraph(entryID: Int, index: Int) -> String {
        let sentenceCount = 4 + (entryID + index) % 5
        return (0..<sentenceCount)
            .map { sentences[(entryID * 3 + index * 7 + $0) % sentences.count] }
            .joined(separator: " ")
    }
}
