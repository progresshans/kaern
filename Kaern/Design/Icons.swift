import CoreGraphics

/// The glyphs the canvas boards draw, copied from their SVG markup (WindowBase, TabStates,
/// TabsF, ScreenStatusBar). Each takes the stroke width the board uses at that size.
enum Icons {
    typealias P = SVGIcon.Part

    // MARK: Tabs

    static let close = SVGIcon(10, [.path("M2.5 2.5l5 5M7.5 2.5l-5 5", width: 1.5, cap: .round)])
    /// The drawer's close button (`.xb`).
    static let closeLarge = SVGIcon(12, [.path("M3 3l6 6M9 3l-6 6", width: 1.6, cap: .round)])
    static let plus = SVGIcon(14, [.path("M7 2.5v9M2.5 7h9", width: 1.5, cap: .round)])
    static let arrowLeft = SVGIcon(12, [.path("M7.5 2.5L4 6l3.5 3.5", width: 1.6, cap: .round, join: .round)])
    static let arrowRight = SVGIcon(12, [.path("M4.5 2.5L8 6 4.5 9.5", width: 1.6, cap: .round, join: .round)])
    static let warn = SVGIcon(14, [
        .path("M7 1.8L12.9 12H1.1z", width: 1.2, join: .round, fill: .current),
        .path("M7 5.4v3.2", width: 1.5, cap: .round, stroke: .white),
        .circle(7, 10.3, 0.85, fill: .white),
    ])
    static let error = SVGIcon(14, [
        .circle(7, 7, 6, fill: .current),
        .path("M7 3.8v3.9", width: 1.6, cap: .round, stroke: .white),
        .circle(7, 10.2, 0.9, fill: .white),
    ])
    /// `.fico`: a page with a folded corner (the conflict editor's file).
    static let file = SVGIcon(16, [
        .path("M4 2.5h5.2L12.5 5.8v7.2a.8.8 0 0 1-.8.8H4a.8.8 0 0 1-.8-.8V3.3a.8.8 0 0 1 .8-.8z M9 2.6V6h3.4", width: 1.3, join: .round),
    ])
    static let missingFolder = SVGIcon(16, [
        .path("M2 4.5A1.5 1.5 0 0 1 3.5 3h3l1.5 1.5h4.5A1.5 1.5 0 0 1 14 6v5.5a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 11.5z", width: 1.4, join: .round),
        .path("M3 14L13.5 2.5", width: 1.4, cap: .round),
    ])

    // MARK: Toolbar

    static let sidebar = SVGIcon(18, [
        .rect(2.5, 3.5, 13, 11, rx: 2.5, width: 1.4),
        .path("M7 3.8v10.4", width: 1.4),
    ])
    static let details = SVGIcon(18, [
        .rect(2.5, 3.5, 13, 11, rx: 2.5, width: 1.4),
        .path("M11 3.8v10.4", width: 1.4),
    ])
    static func branch(_ width: CGFloat) -> SVGIcon {
        SVGIcon(14, [
            .circle(4, 3, 1.6, width: width),
            .circle(4, 11, 1.6, width: width),
            .circle(10, 4.5, 1.6, width: width),
            .path("M4 4.6v4.8M10 6.1c0 2.4-6 1.6-6 3.3", width: width, cap: .round),
        ])
    }
    static let branchToolbar = branch(1.4)
    static let upDown = SVGIcon(width: 10, height: 12, [
        .path("M2.5 4.5L5 2l2.5 2.5M2.5 7.5L5 10l2.5-2.5", width: 1.4, cap: .round, join: .round),
    ])
    static let undo = SVGIcon(16, [.path("M5.5 4L2.5 7l3 3M3 7h6.5a3.5 3.5 0 0 1 0 7H8", width: 1.5, cap: .round, join: .round)])
    static let redo = SVGIcon(16, [.path("M10.5 4l3 3-3 3M13 7H6.5a3.5 3.5 0 0 0 0 7H8", width: 1.5, cap: .round, join: .round)])
    static let fetch = SVGIcon(16, [.path("M13 8a5 5 0 1 1-1.5-3.6M13 2.8v2.8h-2.8", width: 1.5, cap: .round, join: .round)])
    static let pull = SVGIcon(16, [.path("M8 2.5v8M4.6 7.4L8 10.8l3.4-3.4M3.5 13.5h9", width: 1.5, cap: .round, join: .round)])
    static let push = SVGIcon(16, [.path("M8 11V3M4.6 6.1L8 2.7l3.4 3.4M3.5 13.5h9", width: 1.5, cap: .round, join: .round)])
    static let chevronDown = SVGIcon(12, [.path("M3 4.5l3 3 3-3", width: 1.8, cap: .round, join: .round)])
    static let newBranch = SVGIcon(16, [
        .circle(4.5, 3.4, 1.7, width: 1.35),
        .circle(4.5, 12.6, 1.7, width: 1.35),
        .path("M4.5 5.1v5.8M11.5 4v6M8.5 7h6", width: 1.35, cap: .round),
    ])
    static func stash(_ width: CGFloat) -> SVGIcon {
        SVGIcon(16, [.path(
            "M2.5 9.5h3l1 1.6h3l1-1.6h3M2.5 9.5l1.6-5.2a1 1 0 0 1 1-.7h5.8a1 1 0 0 1 1 .7l1.6 5.2v3a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1z",
            width: width, join: .round
        )])
    }
    static let pop = SVGIcon(16, [.path(
        "M2.5 9.5h3l1 1.6h3l1-1.6h3M2.5 9.5v3a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1v-3M8 7.5V1.8M5.6 4.2L8 1.8l2.4 2.4",
        width: 1.35, cap: .round, join: .round
    )])
    static let review = SVGIcon(16, [
        .rect(2, 2.5, 12, 11, rx: 2, width: 1.4),
        .path("M8 2.8v10.4M4.2 6h2M4.2 9h2M9.8 6h2M9.8 9h2", width: 1.3, cap: .round),
    ])
    static let focus = SVGIcon(16, [
        .path("M2.5 6V3.5a1 1 0 0 1 1-1H6M10 2.5h2.5a1 1 0 0 1 1 1V6M13.5 10v2.5a1 1 0 0 1-1 1H10M6 13.5H3.5a1 1 0 0 1-1-1V10", width: 1.4, cap: .round),
        .circle(8, 8, 1.6, fill: .current),
    ])
    static func search(_ width: CGFloat) -> SVGIcon {
        SVGIcon(14, [
            .circle(6.2, 6.2, 4.2, width: width),
            .path("M9.4 9.4L12.6 12.6", width: width, cap: .round),
        ])
    }

    // MARK: Sidebar

    static let tileLocal = branch(1.6)
    static let tileRemote = SVGIcon(16, [.path("M5 12.5h6.6a2.9 2.9 0 0 0 .3-5.8A4 4 0 0 0 4.3 7.6 2.5 2.5 0 0 0 5 12.5z", width: 1.6, join: .round)])
    static let tileTag = SVGIcon(16, [
        .path("M2.5 3.5v4l6 6 5-5-6-6h-4a1 1 0 0 0-1 1z", width: 1.7, join: .round),
        .circle(5.5, 5.6, 1.1, fill: .current),
    ])
    static let tileStash = stash(1.6)
    static let tileWorktree = SVGIcon(16, [.path(
        "M2.5 4.5a1 1 0 0 1 1-1h3l1.2 1.3h4.8a1 1 0 0 1 1 1V7M2.5 4.5v7a1 1 0 0 0 1 1h3.5M10.5 8.5v5M10.5 10.5c0-1.4 1.4-2 3-2",
        width: 1.5, cap: .round, join: .round
    )])
    static let rowBranch = branch(1.3)
    static let check = SVGIcon(16, [.path("M3.5 8.4l2.9 2.9 6.1-6.6", width: 2, cap: .round, join: .round)])
    static let folder = SVGIcon(16, [.path("M2.2 5a1 1 0 0 1 1-1h3.1l1.3 1.4h5.2a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1H3.2a1 1 0 0 1-1-1z", width: 1.3, join: .round)])

    // MARK: History labels

    static let labelHead = SVGIcon(10, [.path("M2 5.3l2 2 4-4.6", width: 1.7, cap: .round, join: .round)])
    static let labelLocal = SVGIcon(16, [
        .rect(3, 3.5, 10, 7, rx: 1.2, width: 1.4),
        .path("M1.8 12.5h12.4", width: 1.4, cap: .round),
    ])
    static let labelRemote = SVGIcon(16, [.path("M5 12.5h6.6a2.9 2.9 0 0 0 .3-5.8A4 4 0 0 0 4.3 7.6 2.5 2.5 0 0 0 5 12.5z", width: 1.5, join: .round)])
    static let labelTag = SVGIcon(16, [.path("M2.5 3.5v4l6 6 5-5-6-6h-4a1 1 0 0 0-1 1z", width: 1.6, join: .round)])
    static let copy = SVGIcon(14, [
        .rect(4.6, 4.6, 7.4, 7.4, rx: 1.6, width: 1.3),
        .path("M2.6 9.2V3.4a.8.8 0 0 1 .8-.8h5.8", width: 1.3, cap: .round),
    ])

    // MARK: Status bar

    static let rebase = SVGIcon(14, [
        .circle(4, 3, 1.6, width: 1.5),
        .circle(4, 11, 1.6, width: 1.5),
        .circle(10.5, 7, 1.6, width: 1.5),
        .path("M4 4.6v4.8M8.9 7H6.5a2.5 2.5 0 0 0-2.5 2.5", width: 1.5, cap: .round),
    ])
    static let conflict = SVGIcon(14, [
        .circle(7, 7, 6, fill: .current),
        .path("M4.8 4.8l4.4 4.4M9.2 4.8L4.8 9.2", width: 1.6, cap: .round, stroke: .white),
    ])
    static let detached = SVGIcon(14, [
        .path("M7 1.6L12.4 7 7 12.4 1.6 7z", width: 1.6, join: .round),
        .circle(7, 7, 1.6, fill: .current),
    ])
    static let info = SVGIcon(14, [
        .circle(7, 7, 6, fill: .current),
        .path("M7 6.2v4", width: 1.6, cap: .round, stroke: .white),
        .circle(7, 4.1, 0.9, fill: .white),
    ])
    /// ScreenInit's banner: a cloud (the repository is only on this Mac).
    static let cloud = SVGIcon(16, [.path("M5 12.5h6.6a2.9 2.9 0 0 0 .3-5.8A4 4 0 0 0 4.3 7.6 2.5 2.5 0 0 0 5 12.5z", width: 1.4, join: .round)])
    static let download = SVGIcon(14, [.path("M7 2v7.5M3.8 6.5L7 9.7l3.2-3.2M2.5 12h9", width: 1.6, cap: .round, join: .round)])

    // MARK: Compare

    static let arrowRightLong = SVGIcon(14, [.path("M2.5 7h9M8.5 4l3 3-3 3", width: 1.5, cap: .round, join: .round)])
    static let checkSmall = SVGIcon(12, [.path("M2.6 6.3l2.2 2.2 4.6-5", width: 1.8, cap: .round, join: .round)])
    static let swap = SVGIcon(14, [.path("M3 5h8.5M9 2.5L11.5 5 9 7.5M11 9H2.5M5 6.5L2.5 9 5 11.5", width: 1.4, cap: .round, join: .round)])
}
