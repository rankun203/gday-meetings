import Foundation

@main
struct NemotronTimingChecks {
    static func main() {
        func piece(_ text: String, _ start: Double, _ end: Double) -> NemotronTimedPiece {
            .init(text: text, start: start, end: end)
        }
        let english = groupNemotronTimings(
            text: "Hello world again",
            pieces: [
                piece("▁Hello", 0, 0.08), piece("▁", 1, 1.08),
                piece("▁world", 2, 2.08), piece("▁again", 15, 15.08),
            ], duration: 16)
        precondition(english.granularity == "decoder-token-group")
        precondition(english.segments.map(\.text).joined() == "Hello world again")
        precondition(english.segments.count == 2)
        let chinese = groupNemotronTimings(
            text: "你好。再见",
            pieces: [
                piece("▁你", 0, 0.08), piece("好。", 0.08, 0.16),
                piece("再见", 13, 13.08),
            ], duration: 14)
        precondition(chinese.segments.count == 2)
        precondition(chinese.segments.map(\.text).joined() == "你好。再见")
        let pause = groupNemotronTimings(
            text: "Hello world", pieces: [piece("▁Hello", 0, 0.08), piece("▁world", 2, 2.08)], duration: 3
        )
        precondition(pause.segments.count == 2)
        let canonicalMismatch = groupNemotronTimings(
            text: "é", pieces: [piece("e\u{301}", 0, 0.08)], duration: 1)
        precondition(canonicalMismatch.granularity == "whole-recording")
        precondition(canonicalMismatch.segments[0].text.utf8.elementsEqual("é".utf8))
        let padding = groupNemotronTimings(
            text: "end", pieces: [piece("▁end", 0.96, 1.04)], duration: 1)
        precondition(padding.segments.first?.end == 1)
        let invalidCases: [[NemotronTimedPiece]] = [
            [], [piece("wrong", 0, 0.08)], [piece("end", .nan, 1)],
            [piece("end", 0.5, 0.4)], [piece("end", 1.1, 1.18)],
            [piece("en", 0.5, 0.58), piece("d", 0.2, 0.28)],
            [piece("end", 0.9, 1.2)],
        ]
        for pieces in invalidCases {
            let result = groupNemotronTimings(text: "end", pieces: pieces, duration: 1)
            precondition(result.granularity == "whole-recording")
            precondition(result.segments.first?.text == "end")
        }
        let empty = groupNemotronTimings(text: "", pieces: [], duration: 1)
        precondition(empty.segments.isEmpty)
        print(
            "Nemotron timing checks passed (text parity, Unicode, grouping, final frame, invalid timing fallback)."
        )
    }
}
