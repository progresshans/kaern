import Foundation

/// Helpers for splitting git's NUL / unit-separator delimited output.
enum Records {
    static let nul: UInt8 = 0x00
    static let unitSeparator: Character = "\u{1F}"

    /// Splits raw output on NUL bytes, dropping the empty trailing record.
    static func splitNUL(_ data: Data) -> [String] {
        var result: [String] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == nul {
                result.append(String(decoding: data[start..<index], as: UTF8.self))
                start = data.index(after: index)
            }
            index = data.index(after: index)
        }
        if start < data.endIndex {
            result.append(String(decoding: data[start..<data.endIndex], as: UTF8.self))
        }
        return result
    }

    /// Splits a record into unit-separator delimited fields.
    static func fields(_ record: some StringProtocol, maxSplits: Int = Int.max) -> [String] {
        String(record)
            .split(separator: unitSeparator, maxSplits: maxSplits, omittingEmptySubsequences: false)
            .map(String.init)
    }

    static func date(fromUnix text: String) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int(text.trimmingCharacters(in: .whitespaces)) ?? 0))
    }
}
