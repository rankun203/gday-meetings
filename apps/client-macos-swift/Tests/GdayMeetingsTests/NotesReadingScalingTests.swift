import Foundation
import Testing

@testable import GdayMeetings

struct NotesReadingScalingTests {
    @Test func linearTimesPreserveBlockAndExplicitTimestampSemantics() {
        let fixtures = [
            "",
            "Plain <!-- gday:t=0:12 -->\nUntimed\nNext <!-- gday:t=0:24 -->",
            "<!-- gday:t=0:12 -->\n```swift\nvalue\n````\nAfter <!-- gday:t=0:24 -->",
            "<!-- gday:t=0:12 -->\n~~~text\n```\nvalue\n~~~\nAfter",
            "<!-- gday:t=0:12 -->\n```\nUnclosed\nvalue <!-- gday:t=0:24 -->",
            "<!-- gday:t=0:12 -->\n| Item | Count |\n| --- | ---: |\n| Example | 2 |\n\nAfter",
            "<!-- gday:t=0:12 -->\n| Item | Count |\n| --- | --- |\n| Example | 2 |\nNo pipe\nNew | line",
            "<!-- gday:t=0:12 -->\n    ```\nIndented fence\n    ```\nAfter",
            "<!-- gday:t=0:12 -->\n| Header |\n| --- |\n| Row |\n| Next |\n| --- |\n| Last |",
            "甲 <!-- gday:t=0:12 --> 乙 <!-- gday:t=0:24 -->\r\n👩🏽‍💻 e\u{301}\n",
            "```text\n<!-- gday:t=0:12 -->\n```\n\n# Heading <!-- gday:t=0:24 -->",
        ]
        for source in fixtures {
            let document = NotesDocument(source)
            let expected = document.lines.indices.map { originalTimedLine($0, lines: document.lines) }
            #expect(document.lineTimes == expected.map { document.lines[$0].time })
            for index in document.lines.indices {
                #expect(document.timedLine(for: index) == expected[index])
            }
            for block in NotesReadingDocument(source).blocks {
                #expect(block.time == document.lines[expected[block.id]].time)
            }
        }
        let code = NotesDocument("<!-- gday:t=0:12 -->\n```\nExample\n```\nAfter")
        #expect(code.lineTimes == [12, 12, 12, nil])
        let table = NotesDocument("<!-- gday:t=0:24 -->\n| Item |\n| --- |\n| Example |\nAfter")
        #expect(table.lineTimes == [24, 24, 24, nil])
        let ordinary = NotesDocument("First <!-- gday:t=0:12 -->\nUntimed")
        #expect(ordinary.lineTimes == [12, nil])
    }

    @Test func parserPayloadBenchmark() {
        guard ProcessInfo.processInfo.environment["GDAY_READING_PARSER_BENCHMARK"] == "1" else { return }
        let paragraph = "**结论：**示例内容与后续行动。 Review the next step [00:12].\n\n"
        for target in [10_240, 102_400, 512_000] {
            let source = String(repeating: paragraph, count: target / paragraph.utf8.count + 1)
            let document = NotesDocument(source)
            var repeated: [TimeInterval?]?
            var oldDuration: Duration?
            if target <= 102_400 {
                let oldStarted = ContinuousClock.now
                repeated = document.lines.indices.map { document.time(atLine: $0) }
                oldDuration = oldStarted.duration(to: .now)
            }
            let linearStarted = ContinuousClock.now
            let linear = document.lineTimes
            let linearDuration = linearStarted.duration(to: .now)
            let readerStarted = ContinuousClock.now
            let reader = NotesReadingDocument(source)
            let readerDuration = readerStarted.duration(to: .now)
            if let repeated { #expect(linear == repeated) }
            #expect(!reader.blocks.isEmpty)
            print(
                "Reading parser benchmark: bytes=\(source.utf8.count) lines=\(document.lines.count) repeated=\(oldDuration.map(String.init(describing:)) ?? "not measured") linear=\(linearDuration) reader=\(readerDuration)"
            )
        }
    }

    // Independent reference for the original prefix-scanning behavior, including
    // incomplete and indented blocks accepted by the timestamp parser.
    private func originalTimedLine(_ line: Int, lines: [NotesDocument.Line]) -> Int {
        func fenceToken(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespaces)
            guard let first = value.first, first == "`" || first == "~" else { return nil }
            let token = String(value.prefix { $0 == first })
            return token.count >= 3 ? token : nil
        }
        var block: Int?
        var fence: String?
        for index in 0...min(line, lines.count - 1) {
            let text = lines[index].text.trimmingCharacters(in: .whitespaces)
            if let token = fence {
                if index == line { return block ?? line }
                if let closing = fenceToken(text), closing.first == token.first, closing.count >= token.count,
                    text.dropFirst(closing.count).trimmingCharacters(in: .whitespaces).isEmpty
                {
                    fence = nil
                    block = nil
                }
            }
            else if let token = fenceToken(text) {
                fence = token
                block = index
            }
            else if index + 1 < lines.count, lines[index].text.contains("|"),
                lines[index + 1].text.range(of: #"^\s*\|?\s*:?-{3,}:?\s*\|"#, options: .regularExpression) != nil
            {
                block = index
            }
            else if !text.contains("|") {
                block = nil
            }
        }
        return block ?? line
    }
}
