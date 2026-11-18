import KaernKit
import SwiftUI

/// ScreenNarrow's folded sidebar (under 1,100 pt): the sections' tiles with their counts. Each
/// opens the whole sidebar over the graph at that section (`.nwrail`).
struct SidebarRail: View {
    static var width: CGFloat { z(52) }

    let repository: RepositoryModel
    let window: WindowModel

    var body: some View {
        VStack(spacing: z(6)) {
            // Submodules only where there are some.
            ForEach(SidebarSection.allCases.filter { $0 != .submodules || !repository.submoduleItems.isEmpty }, id: \.self) { section in
                RailSectionButton(section: section, count: count(section), isOn: window.sidebarFlyout == section) {
                    window.sidebarFlyout = window.sidebarFlyout == section ? nil : section
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, z(12))
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(K.sidebar)
        .overlay(alignment: .trailing) { K.sep.frame(width: 1) }
    }

    private func count(_ section: SidebarSection) -> Int {
        switch section {
        case .local: repository.refs.localBranches.count
        case .remote: repository.refs.remoteBranches.count
        case .tags: repository.tags.count
        case .stashes: repository.stashes.count
        case .worktrees: repository.worktrees.filter { !$0.isBare }.count
        case .submodules: repository.submoduleItems.count
        }
    }
}

extension SidebarSection {
    var title: String {
        switch self {
        case .local: "Local"
        case .remote: "Remote"
        case .tags: "Tags"
        case .stashes: "Stashes"
        case .worktrees: "Worktrees"
        case .submodules: "Submodules"
        }
    }

    /// The section's tile: glyph, size and color (the sidebar's headers use the same).
    var tile: (icon: SVGIcon, size: CGFloat, color: Color) {
        switch self {
        case .local: (Icons.tileLocal, 12, Color(nsColor: K.hex(0x2f74e8)))
        case .remote: (Icons.tileRemote, 13, Color(nsColor: K.hex(0x0f8f84)))
        case .tags: (Icons.tileTag, 12, Color(nsColor: K.hex(0xc8620a)))
        case .stashes: (Icons.tileStash, 13, Color(nsColor: K.hex(0x8a4fd6)))
        case .worktrees: (Icons.tileWorktree, 13, Color(nsColor: K.hex(0x2e8f4a)))
        case .submodules: (Icons.tileSubmodule, 12, Color(nsColor: K.hex(0x4f6b8a)))
        }
    }
}

/// `.nwri`: a 38 pt button with the section's 24 pt tile and its count in a small badge.
private struct RailSectionButton: View {
    let section: SidebarSection
    let count: Int
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let tile = section.tile
        Button(action: action) {
            Icon(tile.icon, size: tile.size)
                .foregroundStyle(.white)
                .frame(width: z(24), height: z(24))
                .background(RoundedRectangle(cornerRadius: z(7), style: .continuous).fill(tile.color))
                .frame(width: z(38), height: z(38))
                .background(RoundedRectangle(cornerRadius: z(9), style: .continuous).fill(isOn ? K.accentSoft : (hovering ? K.hover : .clear)))
                .overlay(alignment: .bottomTrailing) {
                    Text("\(count)")
                        .font(.system(size: z(9.5), weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(K.label2)
                        .padding(.horizontal, z(4))
                        .frame(minWidth: z(15), minHeight: z(15))
                        .background(Capsule().fill(K.content))
                        .overlay(Capsule().strokeBorder(K.sep, lineWidth: 1))
                        .offset(y: -1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(section.title) — \(count)")
        .accessibilityLabel("\(section.title), \(count)")
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}
