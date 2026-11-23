import SwiftUI

/// Tells whether a one-line text got less room than it needs, so it ends in "…".
///
/// It goes behind the text (`.background`), where it has the room the text got, and is handed the same
/// text again as `whole`, which it measures at its whole width and never shows. The font comes from
/// where the text has it: set it on `whole` too if the text sets its own.
///
/// It costs a second text, so a list with many rows asks only for the row the pointer is on.
struct CutReader<Whole: View>: View {
    let whole: Whole
    let action: (Bool) -> Void
    @State private var wholeWidth: CGFloat = 0

    var body: some View {
        GeometryReader { shown in
            whole
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { wholeWidth = $0 }
                // A text with room for all of it is exactly as wide as the whole one.
                .onChange(of: wholeWidth > shown.size.width + 0.05, initial: true) { _, isCut in action(isCut) }
        }
        .allowsHitTesting(false)
    }
}
