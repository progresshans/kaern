import SwiftUI

extension EnvironmentValues {
    /// Icon and Text toolbar (`.tb-text`): names under the icons, no pills.
    @Entry var toolbarShowsText = false
}

/// A toolbar group (`.cap`): 30 pt tall, 9 pt corners, control fill with a hairline and the
/// small control shadow. With names (`.tb-text .cap`): 46 pt, no fill.
struct ToolbarCap<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.toolbarShowsText) private var showsText

    var body: some View {
        if showsText {
            HStack(spacing: 0) { content }
                .frame(height: 46)
        } else {
            HStack(spacing: 0) { content }
                .padding(.horizontal, 2)
                .frame(height: 30)
                .controlSurface(radius: 9)
        }
    }
}

/// `.tb-text .cap + .cap::before`: the hairline between groups when names show.
struct ToolbarGroupSeparator: View {
    @Environment(\.toolbarShowsText) private var showsText

    var body: some View {
        if showsText {
            K.sepStrong.frame(width: 1, height: 22).padding(.horizontal, 2)
        }
    }
}

enum TipPlacement {
    case center, leading, trailing

    var alignment: Alignment {
        switch self {
        case .center: .top
        case .leading: .topLeading
        case .trailing: .topTrailing
        }
    }
}

/// An icon-only toolbar button (`.cb`): at least 34 pt wide, 7 pt hover plate. Hovering shows a
/// tooltip with its name and shortcut after 0.35 s.
struct ToolbarButton: View {
    let icon: SVGIcon
    var iconSize: CGFloat = 16
    let name: String
    /// The name under the icon in Icon and Text ("Undo" where the tooltip says "Undo Checkout develop").
    var label: String?
    var shortcut: String?
    var tip: TipPlacement = .center
    var isOn = false
    var badge: Int?
    var accessibilityLabel: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.toolbarShowsText) private var showsText
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Icon(icon, size: iconSize)
                if showsText {
                    Text(label ?? name)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
                .foregroundStyle(isOn ? K.accentText : K.label)
                .padding(.horizontal, showsText ? 6 : 8)
                .frame(minWidth: showsText ? 46 : 34)
                .frame(maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn ? K.accentSoft : (hovering && isEnabled ? K.hover : .clear))
                )
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if let badge, badge > 0 { ToolbarBadge(count: badge).offset(x: -1, y: 1) }
                }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .toolbarTooltip(name: name, shortcut: shortcut, placement: tip, hovering: $hovering)
        .accessibilityLabel(accessibilityLabel ?? name)
    }
}

/// The red count on Push and Pull.
struct ToolbarBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9.5, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 14, minHeight: 14)
            .background(Capsule().fill(K.badge))
            .background(Capsule().stroke(K.control, lineWidth: 3))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// The board's tooltip (`.tip`): pop surface, name, then the shortcut in secondary text.
struct ToolbarTooltip: View {
    let name: String
    let shortcut: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(K.label)
            if let shortcut {
                Text(shortcut).font(.system(size: 11.5)).foregroundStyle(K.label2)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .popSurface(radius: 6)
        .fixedSize()
        .allowsHitTesting(false)
    }
}

#if DEBUG
/// The debug driver can pin one tooltip open (`tooltip Fetch`) to check how it looks.
@MainActor @Observable
final class DebugTooltip {
    static let shared = DebugTooltip()
    var pinned: String?
}
#endif

private struct TooltipModifier: ViewModifier {
    let name: String
    let shortcut: String?
    let placement: TipPlacement
    @Binding var hovering: Bool
    @State private var hoverShows = false

    private var shows: Bool {
        #if DEBUG
        if DebugTooltip.shared.pinned == name { return true }
        #endif
        return hoverShows
    }
    @State private var task: Task<Void, Never>?
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                task?.cancel()
                if inside, isEnabled {
                    task = Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.1)) { hoverShows = true }
                    }
                } else {
                    hoverShows = false
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                task?.cancel()
                hoverShows = false
            })
            .overlay(alignment: placement.alignment) {
                if shows {
                    // 8 pt below the 30 pt button, like the board's `.tip` (top: 100% + 8px).
                    ToolbarTooltip(name: name, shortcut: shortcut)
                        .offset(y: 38)
                        .transition(.opacity.combined(with: .offset(y: -3)))
                        .zIndex(100)
                }
            }
    }
}

extension View {
    func toolbarTooltip(name: String, shortcut: String?, placement: TipPlacement = .center, hovering: Binding<Bool>) -> some View {
        modifier(TooltipModifier(name: name, shortcut: shortcut, placement: placement, hovering: hovering))
    }
}
