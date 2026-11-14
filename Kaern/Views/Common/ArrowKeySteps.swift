import SwiftUI

extension View {
    /// A list that ↑ and ↓ step through while it has keyboard focus, like the history: a click on
    /// one of its rows gives it focus (sets `focused`), and holding an arrow keeps stepping. `step`
    /// gets −1 or 1. Arrows with ⇧, ⌃, ⌥ or ⌘ are left to others.
    func arrowKeySteps(_ focused: FocusState<Bool>.Binding, step: @escaping (Int) -> KeyPress.Result) -> some View {
        focusable()
            .focusEffectDisabled()
            .focused(focused)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard press.modifiers.isDisjoint(with: [.shift, .control, .option, .command]) else { return .ignored }
                return step(press.key == .upArrow ? -1 : 1)
            }
    }
}

nonisolated enum ArrowKeyStep {
    /// Where ↑ or ↓ goes in a list of `count` rows from row `index`: the next one up or down,
    /// stopping at the ends, or the first (↓) or the last (↑) when no row is current.
    static func target(from index: Int?, by offset: Int, count: Int) -> Int {
        guard let index else { return offset > 0 ? 0 : count - 1 }
        return min(max(index + offset, 0), count - 1)
    }
}
