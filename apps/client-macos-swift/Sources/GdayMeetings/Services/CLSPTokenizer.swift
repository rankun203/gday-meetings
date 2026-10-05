import Foundation
import Tokenizers

struct CLSPTextInput: Sendable {
    let ids: [Int32]
    let attentionMask: [Int32]
}

/// Loads only verified local RoBERTa assets; no Hub request or Python runtime.
struct CLSPTokenizer: Sendable {
    private let tokenizer: any Tokenizer
    init(directory: URL) async throws {
        tokenizer = try await AutoTokenizer.from(modelFolder: directory)
    }
    func encode(_ text: String, paddedTo: Int? = nil) throws -> CLSPTextInput {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 4096,
            paddedTo.map({ (2...512).contains($0) }) ?? true
        else { throw ServiceError("Enter a voice description containing 1–4096 characters.") }
        // Retain the tokenizer's RoBERTa postprocessor and preserve EOS when truncating.
        // The upstream padding=True pads to the longest sequence, not always to 512.
        let maximum = paddedTo ?? 512
        let encoded = tokenizer.encode(text: text)
        guard encoded.first == 0, encoded.last == 2 else {
            throw ServiceError("The voice search tokenizer is not the supported RoBERTa revision.")
        }
        var ids =
            encoded.count > maximum
            ? encoded.prefix(maximum - 1).map(Int32.init) + [2] : encoded.map(Int32.init)
        var mask = [Int32](repeating: 1, count: ids.count)
        if let paddedTo, ids.count < paddedTo {
            let padding = paddedTo - ids.count
            ids += [Int32](repeating: 1, count: padding)
            mask += [Int32](repeating: 0, count: padding)
        }
        return .init(ids: ids, attentionMask: mask)
    }
}
