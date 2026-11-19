import SwiftUI

extension View {
    /// A list that ↑ and ↓ step through while it has keyboard focus, like the history: a click on
    /// one of its rows gives it focus (sets `focused`), and holding an arrow keeps stepping. `step`
    /// gets −1 or 1. Arrows with ⇧, ⌃, ⌥ or ⌘ are left to others.
    func arrowKeySteps(_ focused: FocusState<Bool>.Binding, step: @escaping (Int) -> KeyPress.Result) -> some View {
        modifier(ArrowKeySteps(focused: focused, step: step))
    }
}

private struct ArrowKeySteps: ViewModifier {
    let focused: FocusState<Bool>.Binding
    let step: (Int) -> KeyPress.Result
    /// While a key is held, SwiftUI keeps calling the handler it had when the key went down. That
    /// one's `step` knows the row that was current then, and would go to the row after it again
    /// and again: the handler calls the newest `step` through this instead.
    @State private var latest = LatestStep()

    func body(content: Content) -> some View {
        latest.step = step
        return content
            .focusable()
            .focusEffectDisabled()
            .focused(focused)
            .onKeyPress(keys: [.upArrow, .downArrow]) { [latest] press in
                guard press.modifiers.isDisjoint(with: [.shift, .control, .option, .command]) else { return .ignored }
                return latest.step?(press.key == .upArrow ? -1 : 1) ?? .ignored
            }
    }
}

private final class LatestStep {
    var step: ((Int) -> KeyPress.Result)?
}

nonisolated enum ArrowKeyStep {
    /// Where ↑ or ↓ goes in a list of `count` rows from row `index`: the next one up or down,
    /// stopping at the ends, or the first (↓) or the last (↑) when no row is current.
    static func target(from index: Int?, by offset: Int, count: Int) -> Int {
        guard let index else { return offset > 0 ? 0 : count - 1 }
        return min(max(index + offset, 0), count - 1)
    }
}
