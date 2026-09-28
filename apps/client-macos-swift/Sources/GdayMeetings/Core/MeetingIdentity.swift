import Foundation

enum MeetingIdentity {
    private static let lock = NSLock()
    private static var last: UInt64 = 0
    static func newID() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        last = max(now, last + 1)
        return uuid(high: 0, low: last)
    }
    static func string(_ id: UUID) -> String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "")
        var high = UInt64(hex.prefix(16), radix: 16)!
        var low = UInt64(hex.suffix(16), radix: 16)!
        var result = ""
        repeat {
            let quotientHigh = high / 36
            let remainderHigh = high % 36
            let division = UInt64(36).dividingFullWidth((high: remainderHigh, low: low))
            result.insert(Array("0123456789abcdefghijklmnopqrstuvwxyz")[Int(division.remainder)], at: result.startIndex)
            high = quotientHigh
            low = division.quotient
        } while high != 0 || low != 0
        return result
    }
    static func parse(_ string: String) -> UUID? {
        guard !string.isEmpty, string.count <= 25, string == string.lowercased() else { return nil }
        var high: UInt64 = 0
        var low: UInt64 = 0
        for character in string {
            guard let digit = UInt64(String(character), radix: 36) else { return nil }
            let product = low.multipliedFullWidth(by: 36)
            let h = high.multipliedReportingOverflow(by: 36)
            let h2 = h.partialValue.addingReportingOverflow(product.high)
            let l = product.low.addingReportingOverflow(digit)
            let h3 = h2.partialValue.addingReportingOverflow(l.overflow ? 1 : 0)
            guard !h.overflow, !h2.overflow, !h3.overflow else { return nil }
            high = h3.partialValue
            low = l.partialValue
        }
        let id = uuid(high: high, low: low)
        return self.string(id) == string ? id : nil
    }
    private static func uuid(high: UInt64, low: UInt64) -> UUID {
        let hex = String(format: "%016llx%016llx", high, low)
        let chars = Array(hex)
        let value = [
            String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]),
            String(chars[20..<32]),
        ].joined(separator: "-")
        return UUID(uuidString: value)!
    }
}
