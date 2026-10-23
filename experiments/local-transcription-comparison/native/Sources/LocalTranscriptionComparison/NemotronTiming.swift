import Foundation

struct NemotronTimedPiece {
    var text: String
    var start: Double
    var end: Double
}

struct NemotronTimedSegment {
    var start: Double
    var end: Double
    var text: String
}

/// Groups real decoder emission times; no interpolation or forced word alignment.
/// Exact detokenized text parity is required before exposing these timestamps.
func groupNemotronTimings(
    text: String, pieces: [NemotronTimedPiece], duration: Double
) -> (segments: [NemotronTimedSegment], granularity: String, validationCode: Int) {
    func fallback(_ code: Int) -> ([NemotronTimedSegment], String, Int) {
        (text.isEmpty ? [] : [.init(start: 0, end: duration, text: text)], "whole-recording", code)
    }
    guard duration.isFinite, duration >= 0 else { return fallback(1) }
    guard !pieces.isEmpty else { return fallback(2) }
    var previousStart = -Double.infinity
    for piece in pieces {
        guard piece.start.isFinite, piece.end.isFinite else { return fallback(3) }
        guard piece.start >= 0, piece.end >= piece.start else { return fallback(4) }
        guard piece.start >= previousStart else { return fallback(5) }
        guard piece.start <= duration else { return fallback(6) }
        // One 80 ms decoder frame can straddle the final sample.
        guard piece.end <= duration + 0.081 else { return fallback(7) }
        previousStart = piece.start
    }
    func decode(_ raw: String) -> String {
        raw.replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
    }
    guard decode(pieces.map(\.text).joined()).utf8.elementsEqual(text.utf8) else {
        return fallback(8)
    }

    // Normalize spaces once across the entire stream so concatenation preserves
    // the exact SDK text even where a segment boundary falls inside a sentence.
    var normalized: [(NemotronTimedPiece, String)] = []
    var emittedText = ""
    for piece in pieces {
        var value = ""
        for character in piece.text.replacingOccurrences(of: "▁", with: " ") {
            if character == " " && (emittedText.isEmpty || emittedText.last == " ") { continue }
            value.append(character)
            emittedText.append(character)
        }
        normalized.append((piece, value))
    }
    while emittedText.last?.isWhitespace == true {
        emittedText.removeLast()
        for index in normalized.indices.reversed() where !normalized[index].1.isEmpty {
            normalized[index].1.removeLast()
            break
        }
    }
    guard emittedText.utf8.elementsEqual(text.utf8) else { return fallback(9) }

    var segments: [NemotronTimedSegment] = []
    for (piece, value) in normalized where !value.isEmpty {
        let startNew: Bool
        if let last = segments.last {
            startNew = piece.start - last.end >= 1.0 || piece.start - last.start >= 12.0
        }
        else {
            startNew = true
        }
        if startNew {
            segments.append(.init(start: piece.start, end: min(piece.end, duration), text: value))
        }
        else {
            segments[segments.count - 1].end = max(segments.last!.end, min(piece.end, duration))
            segments[segments.count - 1].text += value
        }
    }
    guard segments.map(\.text).joined().utf8.elementsEqual(text.utf8) else { return fallback(10) }
    return (segments, "decoder-token-group", 0)
}
