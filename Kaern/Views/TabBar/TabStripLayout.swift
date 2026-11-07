import AppKit

/// Widths for the tab strip ("readable shrink", board F).
///
/// - A tab's natural width is its label at the selected tab's weight plus chrome, capped at
///   220 pt (200 pt inside a group).
/// - When the strip is short, tabs shrink in proportion to their width (CSS `flex: 0 1 auto`),
///   but never below the width that still shows about 12 characters (all of a short name;
///   Settings › General › Tabs picks 8, 12 or 16).
/// - When even that doesn't fit, tabs stay at that width and the strip scrolls, with ‹ ›.
enum TabStripLayout {
    static let tabMax: CGFloat = 220
    static let memberMax: CGFloat = 200
    @MainActor static var readableCharacters: CGFloat { CGFloat(AppSettings.tabCharacters) }
    /// Board: label padding 12 + 4, slot 18, tab padding 5.
    static let tabChrome: CGFloat = 39
    /// Free space kept at the end of the strip (also a place to drag the window).
    static let filler: CGFloat = 24
    /// ‹ and › with their margins.
    static let arrows: CGFloat = 56
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let chipFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let chipCountFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    @MainActor private static var widthCache: [String: CGFloat] = [:]

    @MainActor
    static func textWidth(_ text: String, font: NSFont = labelFont) -> CGFloat {
        let key = "\(font.pointSize)|\(font.fontName)|\(text)"
        if let cached = widthCache[key] { return cached }
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        if widthCache.count > 2000 { widthCache.removeAll() }
        widthCache[key] = width
        return width
    }

    /// The narrowest a tab with this label gets.
    @MainActor
    static func minWidth(label: String) -> CGFloat {
        ceil(min(textWidth(label), readableCharacters * 6.5) + tabChrome + 2)
    }

    /// The width that shows the whole label (2 pt of slack, as in the minimum, so rounding in
    /// text layout never truncates a label that fits).
    @MainActor
    static func naturalWidth(label: String, member: Bool) -> CGFloat {
        min(textWidth(label) + tabChrome + 2, member ? memberMax : tabMax)
    }

    struct Item {
        var natural: CGFloat
        var minimum: CGFloat
    }

    struct Solution {
        var widths: [CGFloat]
        var overflows: Bool
        var contentWidth: CGFloat
    }

    /// Resolves widths like CSS flexbox with `flex-shrink: 1` (shrink in proportion to the
    /// natural width), freezing items at their minimum.
    static func solve(_ items: [Item], available: CGFloat) -> Solution {
        let room = available - filler
        let naturalTotal = items.reduce(0) { $0 + $1.natural }
        if naturalTotal <= room {
            return Solution(widths: items.map(\.natural), overflows: false, contentWidth: naturalTotal + filler)
        }
        let minimumTotal = items.reduce(0) { $0 + min($1.minimum, $1.natural) }
        if minimumTotal > room {
            let widths = items.map { min($0.minimum, $0.natural) }
            return Solution(widths: widths, overflows: true, contentWidth: minimumTotal + filler)
        }
        var widths = items.map(\.natural)
        var frozen = items.map { $0.natural <= $0.minimum }
        for _ in 0..<items.count + 1 {
            let frozenTotal = zip(widths, frozen).reduce(0) { $0 + ($1.1 ? $1.0 : 0) }
            let flexible = items.indices.filter { !frozen[$0] }
            let flexibleNatural = flexible.reduce(0) { $0 + items[$1].natural }
            guard flexibleNatural > 0 else { break }
            let overflow = flexibleNatural + frozenTotal - room
            var violated = false
            for index in flexible {
                let width = items[index].natural - overflow * items[index].natural / flexibleNatural
                if width < items[index].minimum {
                    widths[index] = items[index].minimum
                    frozen[index] = true
                    violated = true
                } else {
                    widths[index] = width
                }
            }
            if !violated { break }
        }
        let total = widths.reduce(0, +)
        return Solution(widths: widths, overflows: false, contentWidth: total + filler)
    }

    /// Splits a long label so the end stays readable: "weather-dashboard-app" → "weather-dashboard" + "-app".
    /// The head truncates in the middle of the name; the tail (the last word, or 5 letters)
    /// always shows.
    static func split(_ label: String) -> (head: String, tail: String) {
        guard label.count > 12 else { return (label, "") }
        let characters = Array(label)
        let separators: Set<Character> = ["-", "_", ".", " "]
        let last = characters.lastIndex { separators.contains($0) } ?? -1
        let tailLength = last > 0 && characters.count - last <= 8 ? characters.count - last : 5
        return (String(characters[..<(characters.count - tailLength)]), String(characters[(characters.count - tailLength)...]))
    }

    /// A member's label inside its group: the group name drops off the front
    /// ("godj-web" in "godj" → "web").
    static func shortName(_ name: String, inGroup group: String) -> String {
        let lowerName = name.lowercased()
        let lowerGroup = group.lowercased()
        for separator in ["-", "_", ".", " "] where lowerName.hasPrefix(lowerGroup + separator) && name.count > group.count + 1 {
            return String(name.dropFirst(group.count + 1))
        }
        return name
    }

    /// Chip width: padding, dot, name and what the folded chip adds (count or "› tab", and an
    /// attention dot), plus its margins (6 before, 4 after).
    @MainActor
    static func chipWidth(name: String, trailing: String?, trailingBold: Bool, attention: Bool) -> CGFloat {
        var width: CGFloat = 10 + 8 + 6 + textWidth(name, font: chipFont)
        if let trailing {
            width += 6 + textWidth(trailing, font: trailingBold ? chipFont : chipCountFont)
        }
        if attention { width += 6 + 7 }
        return width + 10 + 6 + 4
    }
}
