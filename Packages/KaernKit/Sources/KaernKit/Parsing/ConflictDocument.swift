import Foundation

/// A file with conflict markers, split into the lines both sides agree on and the conflicting
/// blocks. Resolving a block replaces it with the chosen lines; ``text`` writes the file back and
/// keeps the markers of blocks that are still open, so nothing is lost.
public struct ConflictDocument: Sendable, Hashable {
    public struct Block: Sendable, Hashable {
        public var ours: [String]
        /// Only with `merge.conflictStyle = diff3` or `zdiff3`.
        public var base: [String]?
        public var theirs: [String]
        /// The marker lines exactly as git wrote them, so unresolved blocks round-trip unchanged.
        var startMarker: String
        var baseMarker: String?
        var separatorMarker: String
        var endMarker: String

        /// What follows `<<<<<<<` ("HEAD", "7b1e04d (fix: …)").
        public var oursLabel: String { Self.label(startMarker) }
        /// What follows `>>>>>>>`.
        public var theirsLabel: String { Self.label(endMarker) }

        static func label(_ marker: String) -> String {
            String(marker.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func lines(for resolution: Resolution) -> [String] {
            switch resolution {
            case .ours: ours
            case .theirs: theirs
            case .both: ours + theirs
            }
        }

        var markedLines: [String] {
            var lines = [startMarker] + ours
            if let baseMarker {
                lines.append(baseMarker)
                lines += base ?? []
            }
            return lines + [separatorMarker] + theirs + [endMarker]
        }
    }

    public enum Segment: Sendable, Hashable {
        case common([String])
        case conflict(Block)
    }

    public enum Resolution: Sendable, Hashable {
        case ours
        case theirs
        /// Ours, then theirs.
        case both
    }

    /// One line of the file as one side sees it, with the conflict it belongs to.
    public struct SideLine: Sendable, Hashable {
        public var text: String
        /// Index of the conflict block (0-based), `nil` for lines both sides agree on.
        public var conflict: Int?
    }

    public private(set) var segments: [Segment]
    /// Whether the file ends with a newline (kept when writing it back).
    public private(set) var endsWithNewline: Bool

    public init(text: String) {
        // Split the UTF-8 bytes: in Swift "\r\n" is one Character, so splitting the String on
        // "\n" would leave CRLF files in one piece. Lines keep their "\r".
        var lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        endsWithNewline = text.utf8.last == 0x0A
        if endsWithNewline || text.isEmpty {
            lines.removeLast()
        }
        segments = Self.parse(lines)
    }

    public var conflictCount: Int {
        segments.count { if case .conflict = $0 { true } else { false } }
    }

    public var hasConflicts: Bool { conflictCount > 0 }

    /// The blocks in file order.
    public var blocks: [Block] {
        segments.compactMap { if case .conflict(let block) = $0 { block } else { nil } }
    }

    /// The file as one side wrote it: common lines plus that side of every block.
    public func lines(for side: ConflictSide) -> [SideLine] {
        var result: [SideLine] = []
        var conflict = 0
        for segment in segments {
            switch segment {
            case .common(let lines):
                result += lines.map { SideLine(text: $0, conflict: nil) }
            case .conflict(let block):
                let lines = side == .ours ? block.ours : block.theirs
                result += lines.map { SideLine(text: $0, conflict: conflict) }
                conflict += 1
            }
        }
        return result
    }

    /// Replaces conflict block `index` (0-based) with the chosen lines.
    public func resolving(_ index: Int, with resolution: Resolution) -> ConflictDocument {
        var copy = self
        var conflict = 0
        for (position, segment) in segments.enumerated() {
            guard case .conflict(let block) = segment else { continue }
            if conflict == index {
                copy.segments[position] = .common(block.lines(for: resolution))
                copy.mergeAdjacentCommonSegments()
                return copy
            }
            conflict += 1
        }
        return copy
    }

    /// Resolves every block the same way.
    public func resolvingAll(with resolution: Resolution) -> ConflictDocument {
        var copy = self
        copy.segments = segments.map { segment in
            if case .conflict(let block) = segment { .common(block.lines(for: resolution)) } else { segment }
        }
        copy.mergeAdjacentCommonSegments()
        return copy
    }

    /// Replaces blocks with hand-picked lines, keyed by block index (0-based, in file order).
    /// Blocks without an entry stay unresolved; an empty array removes the block.
    public func applying(_ resolutions: [Int: [String]]) -> ConflictDocument {
        var copy = self
        var conflict = 0
        copy.segments = segments.map { segment in
            guard case .conflict = segment else { return segment }
            defer { conflict += 1 }
            if let lines = resolutions[conflict] { return .common(lines) }
            return segment
        }
        copy.mergeAdjacentCommonSegments()
        return copy
    }

    /// The file contents, with markers for blocks that are still unresolved.
    public var text: String {
        var lines: [String] = []
        for segment in segments {
            switch segment {
            case .common(let common): lines += common
            case .conflict(let block): lines += block.markedLines
            }
        }
        var text = lines.joined(separator: "\n")
        if endsWithNewline { text += "\n" }
        return text
    }

    // MARK: - Parsing

    private static func isMarker(_ line: String, _ prefix: String) -> Bool {
        guard line.hasPrefix(prefix) else { return false }
        let rest = line.dropFirst(prefix.count)
        guard let next = rest.first else { return true }
        return next == " " || next == "\r" || next == "\t"
    }

    private static func isSeparator(_ line: String) -> Bool {
        line == "=======" || line == "=======\r"
    }

    private static func parse(_ lines: [String]) -> [Segment] {
        enum Part { case ours, base, theirs }
        var segments: [Segment] = []
        var common: [String] = []
        var part: Part?
        var raw: [String] = []
        var start = "", baseMarker: String?, separator = ""
        var ours: [String] = [], base: [String]?, theirs: [String] = []

        func flushCommon() {
            if !common.isEmpty {
                segments.append(.common(common))
                common = []
            }
        }

        for line in lines {
            switch part {
            case nil:
                if isMarker(line, "<<<<<<<") {
                    flushCommon()
                    part = .ours
                    raw = [line]
                    start = line
                    baseMarker = nil
                    ours = []
                    base = nil
                    theirs = []
                } else {
                    common.append(line)
                }
            case .ours:
                raw.append(line)
                if isMarker(line, "|||||||") {
                    baseMarker = line
                    base = []
                    part = .base
                } else if isSeparator(line) {
                    separator = line
                    part = .theirs
                } else {
                    ours.append(line)
                }
            case .base:
                raw.append(line)
                if isSeparator(line) {
                    separator = line
                    part = .theirs
                } else {
                    base?.append(line)
                }
            case .theirs:
                raw.append(line)
                if isMarker(line, ">>>>>>>") {
                    segments.append(.conflict(Block(
                        ours: ours, base: base, theirs: theirs,
                        startMarker: start, baseMarker: baseMarker,
                        separatorMarker: separator, endMarker: line
                    )))
                    part = nil
                } else {
                    theirs.append(line)
                }
            }
        }
        // An unterminated block isn't a conflict git wrote; keep its lines as they are.
        if part != nil {
            common += raw
        }
        flushCommon()
        return segments
    }

    private mutating func mergeAdjacentCommonSegments() {
        var merged: [Segment] = []
        for segment in segments {
            if case .common(let lines) = segment, case .common(let previous)? = merged.last {
                merged[merged.count - 1] = .common(previous + lines)
            } else {
                merged.append(segment)
            }
        }
        segments = merged
    }
}
