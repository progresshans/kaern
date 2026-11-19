import AppKit
import SwiftUI

/// How much larger or smaller Kaern draws: its text, rows, icons and the space between them
/// (View › Zoom In, Zoom Out, Actual Size). Every size from the design goes through `z(_:)`;
/// lines a point wide or thinner stay as they are.
///
/// The sizes are values, not a transform: a window drawn larger by scaling its view takes clicks
/// in the wrong place (SwiftUI reads a pointer's position without the scale of the views above).
nonisolated enum UIScale {
    static let steps: [Double] = [0.8, 0.9, 1, 1.1, 1.25, 1.5]

    /// The scale sizes are drawn at. Written on the main thread only: at launch, and when the
    /// setting changes, before the windows' views are made again. Read wherever a size is.
    nonisolated(unsafe) static var value: CGFloat = 1

    static func nearest(_ value: Double) -> Double {
        // Nothing kept reads as 0.
        guard value > 0 else { return 1 }
        return steps.min { abs($0 - value) < abs($1 - value) } ?? 1
    }

    static func larger(than value: Double) -> Double? { steps.first { $0 > value + 0.001 } }
    static func smaller(than value: Double) -> Double? { steps.last { $0 < value - 0.001 } }

    /// What the settings keep, as one of the steps.
    @MainActor static var kept: Double { nearest(UserDefaults.kaern.double(forKey: SettingsKey.zoom)) }

    @MainActor static func keep(_ value: Double) {
        UserDefaults.kaern.set(nearest(value), forKey: SettingsKey.zoom)
    }

    /// Takes the kept scale into use.
    @MainActor static func load() { value = CGFloat(kept) }
}

/// A size from the design (at actual size), as Kaern draws it at the current zoom.
@inline(__always) nonisolated func z(_ size: CGFloat) -> CGFloat { size * UIScale.value }

extension View {
    /// For the root view of a window: its views are made again when the zoom changes, at the new sizes.
    func zoomed() -> some View { modifier(Zoomed()) }
}

private struct Zoomed: ViewModifier {
    @AppStorage(SettingsKey.zoom, store: .kaern) private var kept = 1.0

    func body(content: Content) -> some View {
        let scale = UIScale.nearest(kept)
        // Before the views below are made: they read it.
        let _ = (UIScale.value = CGFloat(scale))
        content.id(scale)
    }
}
