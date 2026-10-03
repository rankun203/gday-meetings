import Foundation

/// Derived UTF-16 offsets for repeated layout queries within one document revision.
struct NotesEditorLineIndex {
    private let starts: [Int]
    private let ends: [Int]

    init(_ document: NotesDocument) {
        var starts: [Int] = []
        var ends: [Int] = []
        starts.reserveCapacity(document.lines.count)
        ends.reserveCapacity(document.lines.count)
        var offset = 0
        for line in document.lines {
            starts.append(offset)
            offset += line.text.utf16.count + line.newline.utf16.count
            ends.append(offset)
        }
        self.starts = starts
        self.ends = ends
    }

    func line(at offset: Int) -> Int {
        var lower = 0
        var upper = ends.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if offset < ends[middle] {
                upper = middle
            }
            else {
                lower = middle + 1
            }
        }
        return min(lower, max(0, ends.count - 1))
    }

    func start(of line: Int) -> Int { starts[line] }
}
