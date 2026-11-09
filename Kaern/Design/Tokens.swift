import AppKit
import SwiftUI

/// The canvas design tokens (`base-style.css`, `.k-light` / `.k-dark`; the Tokens board lists
/// them). Every color resolves for the current appearance, so views never branch on light/dark.
nonisolated enum K {
    // MARK: Backgrounds
    static let band = dynamic(0xdfdfe3, 0x262626)          // tab row
    static let win = dynamic(0xececec, 0x323232)           // window · toolbar · status bar
    static let content = dynamic(0xffffff, 0x1e1e1e)       // graph · lists · diff
    static let alt = dynamic(0xf6f6f7, 0x232324)           // striped rows
    static let sidebar = dynamic(0xefeff1, 0x29292b)
    static let inspector = dynamic(0xf7f7f8, 0x252527)     // right panel
    static let pop = dynamic(rgba(250, 250, 252, 0.98), rgba(44, 44, 48, 0.98))  // menus · tooltips
    static let field = dynamic(0xffffff, 0x1c1c1e)
    static let control = dynamic(0xffffff, 0x4a4a4d)       // button · capsule fill

    // MARK: Text
    static let label = dynamic(rgba(0, 0, 0, 0.85), rgba(255, 255, 255, 0.86))
    static let label2 = dynamic(rgba(0, 0, 0, 0.56), rgba(255, 255, 255, 0.58))
    static let label3 = dynamic(rgba(0, 0, 0, 0.26), rgba(255, 255, 255, 0.26))
    static let accentText = dynamic(0x0057c2, 0x5aa9ff)
    static let code = dynamic(0x1d1d1f, 0xe6e6e8)

    // MARK: Lines
    static let sep = dynamic(rgba(0, 0, 0, 0.1), rgba(255, 255, 255, 0.1))
    static let sepStrong = dynamic(rgba(0, 0, 0, 0.16), rgba(255, 255, 255, 0.16))
    static let controlBorder = dynamic(rgba(0, 0, 0, 0.14), rgba(255, 255, 255, 0.08))

    // MARK: Accent and selection
    static let accent = dynamic(0x007aff, 0x0a84ff)
    static let accentSoft = dynamic(rgba(0, 122, 255, 0.12), rgba(10, 132, 255, 0.22))
    static let sel = dynamic(0x0064e1, 0x0058d0)
    static let hover = dynamic(rgba(0, 0, 0, 0.055), rgba(255, 255, 255, 0.07))
    /// A pressed control (the tab close button under the pointer).
    static let press = dynamic(rgba(0, 0, 0, 0.1), rgba(255, 255, 255, 0.12))
    static let chip2 = dynamic(rgba(0, 0, 0, 0.07), rgba(255, 255, 255, 0.1))

    // MARK: Lanes
    static let lane1 = dynamic(0x0a6cff, 0x2f8cff)
    static let lane2 = dynamic(0xe07000, 0xff9f0a)
    static let lane3 = dynamic(0xd6336c, 0xff4f7b)
    static let lt1 = dynamic(rgba(10, 108, 255, 0.13), rgba(47, 140, 255, 0.24))
    /// `.lab.wtlab`: the ring around a branch label another worktree has checked out (one value in both).
    static let worktreeRing = dynamic(rgba(10, 108, 255, 0.35), rgba(10, 108, 255, 0.35))
    static let lt2 = dynamic(rgba(224, 112, 0, 0.15), rgba(255, 159, 10, 0.24))
    static let lt3 = dynamic(rgba(214, 51, 108, 0.13), rgba(255, 79, 123, 0.24))
    static let wip = dynamic(0x8e8e93, 0x98989d)

    // MARK: State
    static let ok = dynamic(0x1f9d55, 0x30d158)
    static let warn = dynamic(0xd97706, 0xff9f0a)
    static let err = dynamic(0xe5372b, 0xff453a)
    static let badge = dynamic(0xff3b30, 0xff453a)

    // MARK: Git LFS and submodules (ScreenMarks `.lfsb`, `.st-S`)
    static let lfs = dynamic(0x6a3ed6, 0xb79cff)
    static let lfsBg = dynamic(rgba(124, 77, 232, 0.14), rgba(150, 110, 255, 0.24))
    static let sub = dynamic(0x4f6b8a, 0x9db5d2)
    static let subBg = dynamic(rgba(79, 107, 138, 0.16), rgba(140, 170, 205, 0.22))

    // MARK: Diff
    static let add = dynamic(0x157347, 0x4cd97b)
    static let addBg = dynamic(rgba(40, 167, 69, 0.1), rgba(48, 209, 88, 0.1))
    static let addGut = dynamic(rgba(40, 167, 69, 0.19), rgba(48, 209, 88, 0.2))
    static let del = dynamic(0xc4271c, 0xff7a70)
    static let delBg = dynamic(rgba(255, 59, 48, 0.08), rgba(255, 69, 58, 0.1))
    static let delGut = dynamic(rgba(255, 59, 48, 0.17), rgba(255, 69, 58, 0.22))
    static let mod = dynamic(0xa14d00, 0xffb340)
    static let modBg = dynamic(rgba(217, 119, 6, 0.15), rgba(255, 159, 10, 0.18))
    static let addWord = dynamic(rgba(40, 167, 69, 0.28), rgba(48, 209, 88, 0.3))    // changed words
    static let delWord = dynamic(rgba(255, 59, 48, 0.22), rgba(255, 69, 58, 0.32))
    static let hunk = dynamic(0xf0f4fa, 0x222b37)
    // ScreenConflicts: the operation bar, open conflict blocks, the two sides.
    static let opBg = dynamic(0xfdecea, 0x3b2321)
    static let opText = dynamic(0x8a1f17, 0xffb4ab)
    static let okBg = dynamic(0xe6f5eb, 0x1c3326)
    static let okText = dynamic(0x13693a, 0x8de0ad)
    static let cbBg = dynamic(0xfdecea, 0x3b2321)
    static let cbText = dynamic(0x8a1f17, 0xffb4ab)
    static let oursBg = dynamic(rgba(40, 167, 69, 0.13), rgba(48, 209, 88, 0.14))
    static let theirsBg = dynamic(rgba(10, 108, 255, 0.12), rgba(10, 132, 255, 0.18))
    // ScreenExplore: Blame's age stripe, older to newer (`.ag1` … `.ag5`).
    static let blameAge1 = dynamic(0xcfe0fb, 0x2b3c57)
    static let blameAge2 = dynamic(0x9cc0f6, 0x2f5288)
    static let blameAge3 = dynamic(0x64a0f1, 0x326bbf)
    static let blameAge4 = dynamic(0x2f7fe9, 0x3a86ec)
    static let blameAge5 = dynamic(0x0a5fd8, 0x6aa8ff)
    static let hunkText = dynamic(0x36557f, 0x9db6d8)
    static let emptyA = dynamic(rgba(0, 0, 0, 0.04), rgba(255, 255, 255, 0.045))

    // MARK: Shadows (`--shadowCtl`, `--shadowPop`)
    static let shadowCtl = dynamic(rgba(0, 0, 0, 0.14), rgba(0, 0, 0, 0.45))
    static let shadowPop = dynamic(rgba(0, 0, 0, 0.18), rgba(0, 0, 0, 0.5))
    static let popRing = dynamic(rgba(0, 0, 0, 0.14), rgba(255, 255, 255, 0.12))

    static func lane(_ index: Int) -> Color {
        switch index % 3 {
        case 0: lane1
        case 1: lane2
        default: lane3
        }
    }

    static func laneTint(_ index: Int) -> Color {
        switch index % 3 {
        case 0: lt1
        case 1: lt2
        default: lt3
        }
    }

    // MARK: Building colors

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        dynamic(hex(light), hex(dark))
    }

    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.isDark ? dark : light
        })
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: alpha
        )
    }

    private static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

nonisolated extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Type scale from the Tokens board. Sizes the system text styles don't have use
/// `.system(size:)`, the board's own SwiftUI mapping.
nonisolated enum KFont {
    /// 13 regular: rows, menus, fields.
    static let body = Font.system(size: 13)
    static let bodySemibold = Font.system(size: 13, weight: .semibold)
    /// The board's 650 weight (section titles, count pills, the current branch).
    static let body650 = weighted(13, 0.35)
    static let file = Font.system(size: 12.5)
    static let note = Font.system(size: 12)
    static let caption = Font.system(size: 11.5)
    static let label = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let hash = Font.system(size: 11.5, design: .monospaced)

    /// A system font at a weight between the named ones (`NSFont.Weight` raw values:
    /// semibold 0.3, bold 0.4).
    static func weighted(_ size: CGFloat, _ weight: CGFloat) -> Font {
        Font(NSFont.systemFont(ofSize: size, weight: NSFont.Weight(rawValue: weight)))
    }
}

/// Heights and radii from the Tokens board.
nonisolated enum KMetric {
    static let tabRow: CGFloat = 36
    static let toolbar: CGFloat = 44
    static let statusBar: CGFloat = 26
    static let graphRow: CGFloat = 28
    static let wipRow: CGFloat = 34
    static let sidebarRow: CGFloat = 28
    static let fileRow: CGFloat = 26
    static let sidebarWidth: CGFloat = 230
    static let panelWidth: CGFloat = 316
}

/// Folder-group colors for tab groups. The board's groups use green, gray and a warm brown;
/// the rest are the system palette.
enum GroupColor: String, Codable, CaseIterable, Sendable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray, brown

    var nsColor: NSColor {
        switch self {
        case .blue: K.hex(0x007aff)
        case .purple: K.hex(0xaf52de)
        case .pink: K.hex(0xff2d55)
        case .red: K.hex(0xff3b30)
        case .orange: K.hex(0xff9500)
        case .yellow: K.hex(0xffcc00)
        case .green: K.hex(0x34c759)
        case .teal: K.hex(0x30b0c7)
        case .gray: K.hex(0x8e8e93)
        case .brown: K.hex(0xc08a4a)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    var title: String { rawValue.capitalized }

    /// The chip's fill: the color at 18% (light) or 30% (dark), stronger when the chip stands in
    /// for the selected tab of a folded group.
    func chipFill(strong: Bool) -> Color {
        let base = nsColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            let alpha: CGFloat = appearance.isDark ? (strong ? 0.5 : 0.3) : (strong ? 0.34 : 0.18)
            return base.withAlphaComponent(alpha)
        })
    }
}

/// Author avatar colors (the board's nodes use deep blue, teal and rust).
nonisolated enum AvatarPalette {
    private static let colors: [UInt32] = [0x2f62c8, 0x0f7f71, 0xb4430d, 0x7a4fc9, 0xb3266b, 0x2f7d32, 0x8a6116, 0x4c5a6b, 0x1f7a99, 0xa63d3d]

    static func color(for key: String) -> Color {
        // FNV-1a, so similar addresses still spread over the palette.
        var hash: UInt32 = 2_166_136_261
        for byte in key.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Color(nsColor: K.hex(colors[Int(hash % UInt32(colors.count))]))
    }
}

extension View {
    /// `.cap` / control look: control fill, 0.5 pt border and the small control shadow.
    func controlSurface(radius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(K.control)
                .shadow(color: K.shadowCtl, radius: 0.75, y: 0.5)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(K.controlBorder, lineWidth: 0.5)
                )
        }
    }

    /// `--pop` surface with `--shadowPop` (menus, tooltips, popovers).
    func popSurface(radius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(K.pop)
                .shadow(color: K.shadowPop, radius: 8, y: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(K.popRing, lineWidth: 0.5)
                )
        }
    }
}
