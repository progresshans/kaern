import SwiftUI

/// One repository tab (TabStates board): 30 pt tall at the bottom of the row. The selected tab
/// takes the window color and joins the toolbar below; others are plain text with a hover
/// plate. The slot on the right shows × on hover (and on the selected tab when there's
/// nothing to report), otherwise the repository's mark.
struct TabItemView: View {
    let label: String
    let isActive: Bool
    let isHovered: Bool
    let isDragged: Bool
    let showsSeparator: Bool
    let groupColor: Color?
    let mark: TabMark
    let width: CGFloat
    let help: String
    let onClose: () -> Void

    @State private var closeHovered = false

    private var showsClose: Bool { isHovered || (isActive && mark == .none) }

    var body: some View {
        let parts = TabStripLayout.split(label)
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(parts.head)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !parts.tail.isEmpty {
                    Text(parts.tail)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            .foregroundStyle(mark == .missing ? K.label3 : (isActive ? K.label : K.label2))
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            slot
                .frame(width: 18, height: 18)
        }
        .padding(.trailing, 5)
        .frame(width: width, height: 30)
        .background { background }
        .overlay(alignment: .bottom) {
            if let groupColor {
                Capsule()
                    .fill(groupColor)
                    .frame(height: 2)
                    .padding(.horizontal, 10)
                    .padding(.bottom, isActive ? 3 : 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if showsSeparator {
                K.sep.frame(width: 1, height: 14).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var background: some View {
        if isDragged {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(K.win)
                .shadow(color: .black.opacity(0.22), radius: 9, y: 6)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(K.controlBorder, lineWidth: 0.5))
        } else if isActive {
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8, style: .continuous)
                .fill(K.win)
                .overlay(TabOutline().stroke(K.sep, lineWidth: 1))
        } else if isHovered {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(K.hover)
                .padding(EdgeInsets(top: 2, leading: 2, bottom: 4, trailing: 2))
        }
    }

    @ViewBuilder
    private var slot: some View {
        if showsClose {
            Button(action: onClose) {
                Icon(Icons.close, size: 10)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(closeHovered ? K.label : K.label2)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(closeHovered ? K.press : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { closeHovered = $0 }
            .accessibilityLabel("Close \(label)")
        } else {
            switch mark {
            case .none:
                EmptyView()
            case .changes:
                Circle().fill(K.label2).frame(width: 7, height: 7)
                    .accessibilityLabel("Uncommitted changes")
            case .busy:
                RingSpinner(size: 12)
            case .warning:
                Icon(Icons.warn, size: 13).foregroundStyle(K.warn)
                    .accessibilityLabel("Needs attention")
            case .error:
                Icon(Icons.error, size: 13).foregroundStyle(K.err)
                    .accessibilityLabel("Couldn't read the repository")
            case .missing:
                Icon(Icons.missingFolder, size: 13).foregroundStyle(K.label2)
                    .accessibilityLabel("Folder not found")
            }
        }
    }
}

/// The selected tab's 1 pt outline: left, top (with the rounded corners) and right, open at
/// the bottom where the tab joins the toolbar.
nonisolated struct TabOutline: Shape {
    var radius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: 0.5, dy: 0.5)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        path.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius), control: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: rect.maxY))
        return path
    }
}

/// A folder group's chip: dot, name, and when folded the tab count (or "› tab" when the
/// selected tab is inside) with an attention dot for the most urgent member mark.
struct GroupChipView: View {
    let group: TabGroup
    let count: Int
    let activeLabel: String?
    let attention: TabMark
    let isDragged: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(group.color.color).frame(width: 8, height: 8)
            Text(group.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(K.label)
            if group.collapsed {
                if let activeLabel {
                    Text("› \(activeLabel)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(K.label)
                } else {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(K.label2)
                }
                if attention != .none {
                    Circle().fill(attentionColor).frame(width: 7, height: 7)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            Capsule()
                .fill(group.color.chipFill(strong: group.collapsed && activeLabel != nil))
                .brightness(hovering ? -0.03 : 0)
                .shadow(color: .black.opacity(isDragged ? 0.22 : 0), radius: 9, y: 6)
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(group.collapsed ? "Show the \(count) tabs in \(group.name)" : "Fold \(group.name)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name), \(count) tabs, \(group.collapsed ? "collapsed" : "expanded")")
        .accessibilityAddTraits(.isButton)
    }

    private var attentionColor: Color {
        switch attention {
        case .error: K.err
        case .warning: K.warn
        default: K.label2
        }
    }
}

/// ‹ and › (only while the strip overflows).
struct ArrowButton: View {
    let icon: SVGIcon
    let label: String
    let disabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 12)
                .frame(width: 24, height: 28)
                .foregroundStyle(hovering && !disabled ? K.label : K.label2)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && !disabled ? K.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
    }
}

/// + : opens another repository in a new tab, from the recent list or a folder.
struct NewTabButton: View {
    @Bindable var window: WindowModel
    @State private var hovering = false

    var body: some View {
        Button {
            window.showsNewTab.toggle()
        } label: {
            Icon(Icons.plus, size: 14)
                .frame(width: 28, height: 28)
                .foregroundStyle(hovering ? K.label : K.label2)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? K.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open another repository in a new tab (⌘T)")
        .accessibilityLabel("New tab")
        .popover(isPresented: $window.showsNewTab, arrowEdge: .bottom) {
            NewTabPopover(window: window)
        }
    }
}

/// A small spinning ring (fetch or push running).
struct RingSpinner: View {
    var size: CGFloat
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(K.label3, lineWidth: 1.75)
            Circle().trim(from: 0, to: 0.25).stroke(K.accent, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: size - 1.75, height: size - 1.75)
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
        }
        .accessibilityLabel("In progress")
    }
}
