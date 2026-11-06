import AppKit
import KaernKit
import SwiftUI

/// Kaern's own color tokens, copied from the design's variables (collection "Kaern", Light/Dark).
/// Everything else uses system semantic colors.
enum Palette {
    // graph/lane-1…8. Lane color = lane position.
    static let lanes: [NSColor] = [
        .dynamic(light: 0x0A6CFF, dark: 0x0A84FF),
        .dynamic(light: 0xE07000, dark: 0xFF9F0A),
        .dynamic(light: 0xE0245E, dark: 0xFF375F),
        .dynamic(light: 0x9A45C8, dark: 0xBF5AF2),
        .dynamic(light: 0x248A3D, dark: 0x30D158),
        .dynamic(light: 0x00829B, dark: 0x40CBE0),
        .dynamic(light: 0x8B6B45, dark: 0xAC8E68),
        .dynamic(light: 0xB58B00, dark: 0xFFD60A),
    ]

    static func lane(_ index: Int) -> NSColor {
        lanes[((index % lanes.count) + lanes.count) % lanes.count]
    }

    /// graph/wip — the working-copy node and its dashed link to HEAD.
    static let workingCopy = NSColor.dynamic(light: 0x8E8E93, dark: 0x98989D)

    // status/*
    static let modified = NSColor.dynamic(light: 0xC93400, dark: 0xFF9F0A)
    static let added = NSColor.dynamic(light: 0x1E7E34, dark: 0x30D158)
    static let deleted = NSColor.dynamic(light: 0xD70015, dark: 0xFF453A)
    static let renamed = NSColor.dynamic(light: 0x0040DD, dark: 0x409CFF)
    static let untracked = NSColor.dynamic(light: 0x8E8E93, dark: 0x98989D)

    // diff/*
    static let diffAddedBackground = NSColor.dynamic(lightRGBA: 0x34C7_5921, darkRGBA: 0x30D1_5826)
    static let diffRemovedBackground = NSColor.dynamic(lightRGBA: 0xFF3B_301C, darkRGBA: 0xFF45_3A26)
    static let diffAddedGutter = NSColor.dynamic(lightRGBA: 0x34C7_5938, darkRGBA: 0x30D1_5840)
    static let diffRemovedGutter = NSColor.dynamic(lightRGBA: 0xFF3B_302E, darkRGBA: 0xFF45_3A3D)
    static let diffGutter = NSColor.dynamic(light: 0xF4F4F6, dark: 0x202022)
    static let diffSelection = NSColor.dynamic(lightRGBA: 0x007A_FF29, darkRGBA: 0x0A84_FF3D)
    static let diffHunkBackground = NSColor.dynamic(lightRGBA: 0x0000_0009, darkRGBA: 0xFFFF_FF0D)
    /// The words that changed inside a modified line, on top of the line's own color.
    static let diffAddedWord = NSColor.dynamic(lightRGBA: 0x34C7_5960, darkRGBA: 0x30D1_5866)
    static let diffRemovedWord = NSColor.dynamic(lightRGBA: 0xFF3B_3050, darkRGBA: 0xFF45_3A66)

    // chip/*
    static let chipFill = NSColor.dynamic(lightRGBA: 0x0000_000F, darkRGBA: 0xFFFF_FF1A)
    static let chipBorder = NSColor.dynamic(lightRGBA: 0x0000_002E, darkRGBA: 0xFFFF_FF38)
    static let chipOnSelection = NSColor(white: 1, alpha: 0x38 / 255)

    /// badge/count
    static let badge = NSColor.dynamic(light: 0xFF3B30, dark: 0xFF453A)

    /// system/inspectorBackground
    static let inspectorBackground = NSColor.dynamic(light: 0xF7F7F8, dark: 0x252527)
    /// The bar across the top of a repository window and the controls on it.
    static let titleBar = NSColor.dynamic(light: 0xECECEE, dark: 0x2B2B2D)
    static let titleBarControl = NSColor.dynamic(light: 0xFFFFFF, dark: 0x3A3A3C)

    static func color(for kind: ChangeKind) -> NSColor {
        switch kind {
        case .modified, .typeChanged: modified
        case .added, .copied: added
        case .deleted, .conflicted: deleted
        case .renamed: renamed
        case .untracked: untracked
        }
    }
}

extension NSColor {
    /// A color that follows the effective appearance (Aqua / Dark Aqua, including high contrast).
    nonisolated static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        dynamic(lightRGBA: light << 8 | 0xFF, darkRGBA: dark << 8 | 0xFF)
    }

    nonisolated static func dynamic(lightRGBA: UInt32, darkRGBA: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
                .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
            return NSColor(rgba: isDark ? darkRGBA : lightRGBA)
        }
    }

    nonisolated convenience init(rgba: UInt32) {
        self.init(
            srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255,
            green: CGFloat((rgba >> 16) & 0xFF) / 255,
            blue: CGFloat((rgba >> 8) & 0xFF) / 255,
            alpha: CGFloat(rgba & 0xFF) / 255
        )
    }
}

extension Color {
    init(_ color: NSColor) {
        self.init(nsColor: color)
    }
}
