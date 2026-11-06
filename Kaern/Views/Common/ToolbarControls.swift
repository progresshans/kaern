import SwiftUI

/// A toolbar group (`.cap`): 30 pt tall, 9 pt corners, control fill with a hairline and the
/// small control shadow.
struct ToolbarCap<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, 2)
            .frame(height: 30)
            .controlSurface(radius: 9)
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
    var shortcut: String?
    var tip: TipPlacement = .center
    var isOn = false
    var badge: Int?
    var accessibilityLabel: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Icon(icon, size: iconSize)
                .foregroundStyle(isOn ? K.accentText : K.label)
                .padding(.horizontal, 8)
                .frame(minWidth: 34)
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

private struct TooltipModifier: ViewModifier {
    let name: String
    let shortcut: String?
    let placement: TipPlacement
    @Binding var hovering: Bool
    @State private var shows = false
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
                        withAnimation(.easeOut(duration: 0.1)) { shows = true }
                    }
                } else {
                    shows = false
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                task?.cancel()
                shows = false
            })
            .overlay(alignment: placement.alignment) {
                if shows {
                    ToolbarTooltip(name: name, shortcut: shortcut)
                        .alignmentGuide(.top) { $0[.top] - 38 }
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
