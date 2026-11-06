import AppKit
import KaernKit

enum HistoryMetrics {
    static let rowHeight: CGFloat = 26
    /// The author's avatar in the Author column.
    static let avatarSize: CGFloat = 16
    /// Lane centers: 14, 30, 46, … (16pt apart).
    static func laneX(_ lane: Int) -> CGFloat { 14 + CGFloat(lane) * 16 }
    static let lineWidth: CGFloat = 2
    static let nodeRadius: CGFloat = 5
    static let mergeNodeRadius: CGFloat = 3.5
}

// MARK: - Graph

/// Draws one row of the commit graph. Every edge is the same cubic curve in the upper and the
/// lower row, so each row draws its half (clipped to its bounds) and the halves meet seamlessly.
final class GraphCellView: NSTableCellView {
    var row: GraphRow? { didSet { needsDisplay = true } }
    /// Lane of the selected commit; other lanes are drawn faded.
    var highlightLane: Int? { didSet { if highlightLane != oldValue { needsDisplay = true } } }

    /// Set by the table for the selected row while it has focus (blue selection).
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }

    private var isEmphasized: Bool { backgroundStyle == .emphasized }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let height = bounds.height
        let center = height / 2

        for edge in row.up {
            stroke(edge, fromY: center - height, toY: center)
        }
        for edge in row.down {
            stroke(edge, fromY: center, toY: center + height)
        }
        drawNode(row, centerY: center)
    }

    private func color(forLane lane: Int, dashed: Bool) -> NSColor {
        let base: NSColor
        if isEmphasized {
            base = .alternateSelectedControlTextColor
        } else {
            base = dashed ? Palette.workingCopy : Palette.lane(lane)
        }
        if let highlightLane, highlightLane != lane, !dashed {
            return base.withAlphaComponent(isEmphasized ? 0.45 : 0.3)
        }
        return base
    }

    private func stroke(_ edge: GraphEdge, fromY: CGFloat, toY: CGFloat) {
        let x1 = HistoryMetrics.laneX(edge.from)
        let x2 = HistoryMetrics.laneX(edge.to)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x1, y: fromY))
        if x1 == x2 {
            path.line(to: NSPoint(x: x2, y: toY))
        } else {
            let middle = (fromY + toY) / 2
            path.curve(to: NSPoint(x: x2, y: toY),
                       controlPoint1: NSPoint(x: x1, y: middle),
                       controlPoint2: NSPoint(x: x2, y: middle))
        }
        path.lineWidth = HistoryMetrics.lineWidth
        path.lineCapStyle = .butt
        if edge.dashed {
            path.setLineDash([3, 3], count: 2, phase: 0)
        }
        color(forLane: edge.lane, dashed: edge.dashed).setStroke()
        path.stroke()
    }

    private func drawNode(_ row: GraphRow, centerY: CGFloat) {
        let x = HistoryMetrics.laneX(row.lane)
        if row.isWorkingCopy {
            let radius = HistoryMetrics.nodeRadius
            let rect = NSRect(x: x - radius, y: centerY - radius, width: radius * 2, height: radius * 2)
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            (isEmphasized ? NSColor.white : NSColor.textBackgroundColor).setFill()
            circle.fill()
            circle.lineWidth = 1.5
            circle.setLineDash([2.5, 2], count: 2, phase: 0)
            Palette.workingCopy.setStroke()
            circle.stroke()
            return
        }
        let radius = row.isMerge ? HistoryMetrics.mergeNodeRadius : HistoryMetrics.nodeRadius
        let rect = NSRect(x: x - radius, y: centerY - radius, width: radius * 2, height: radius * 2)
        if isEmphasized {
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSColor.white.setFill()
            circle.fill()
            circle.lineWidth = 2
            Palette.lane(row.lane).setStroke()
            circle.stroke()
        } else {
            let circle = NSBezierPath(ovalIn: rect)
            color(forLane: row.lane, dashed: false).setFill()
            circle.fill()
        }
    }
}

// MARK: - Ref chips

struct ChipModel: Equatable {
    enum Style: Equatable {
        /// ✓ current branch (accent tinted)
        case head
        /// local branch; `synced` when its upstream points at the same commit
        case local(synced: Bool)
        /// remote-tracking branch without a local counterpart here
        case remote
        case tag
        /// "+2" for refs that don't fit
        case more
    }

    var title: String
    var style: Style
    /// Lane of the commit, for the branch icon color.
    var lane: Int
}

enum ChipBuilder {
    /// Head · local (synced) · remote · tags, as in the Ref Chip component.
    static func chips(
        for commitID: String, lane: Int, refs: RefSnapshot, status: WorkingTreeStatus,
        detachedTitle: String = "HEAD"
    ) -> [ChipModel] {
        let atCommit = refs.refs(at: commitID)
        guard !atCommit.isEmpty || (status.branch == nil && status.headID == commitID) else { return [] }

        var consumedRemotes = Set<String>()
        var head: [ChipModel] = []
        var locals: [ChipModel] = []
        for ref in atCommit where ref.kind == .localBranch {
            // Synced: the upstream (or a same-named remote branch) points at this commit too.
            let counterpart = atCommit.first { remote in
                remote.kind == .remoteBranch && (remote.name == ref.upstream || (ref.upstream == nil && remote.branchName == ref.name))
            }
            let synced = counterpart != nil
            if let counterpart { consumedRemotes.insert(counterpart.name) }
            if ref.isHead {
                head.append(ChipModel(title: ref.name, style: .head, lane: lane))
            } else {
                locals.append(ChipModel(title: ref.name, style: .local(synced: synced), lane: lane))
            }
        }
        if status.branch == nil, status.headID == commitID {
            head.append(ChipModel(title: detachedTitle, style: .head, lane: lane))
        }
        let remotes = atCommit
            .filter { $0.kind == .remoteBranch && !consumedRemotes.contains($0.name) }
            .map { ChipModel(title: $0.name, style: .remote, lane: lane) }
        let tags = atCommit
            .filter { $0.kind == .tag }
            .map { ChipModel(title: $0.name, style: .tag, lane: lane) }
        return head + locals + remotes + tags
    }
}

/// A ref chip drawn in AppKit (18pt tall, 4pt radius) so hundreds of rows stay cheap to scroll.
final class RefChipView: NSView {
    var chip: ChipModel {
        didSet {
            if chip != oldValue {
                invalidateIntrinsicContentSize()
                needsDisplay = true
            }
        }
    }

    var isOnSelection = false { didSet { if isOnSelection != oldValue { needsDisplay = true } } }

    private static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let iconSize: CGFloat = 11
    private static let horizontalPadding: CGFloat = 6
    private static let spacing: CGFloat = 4

    init(chip: ChipModel) {
        self.chip = chip
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var iconName: String? {
        switch chip.style {
        case .head: "checkmark"
        case .local: "arrow.triangle.branch"
        case .remote: "cloud"
        case .tag: "tag"
        case .more: nil
        }
    }

    private var showsSyncedIcon: Bool {
        if case .local(let synced) = chip.style { return synced }
        return false
    }

    private var textWidth: CGFloat {
        ceil((chip.title as NSString).size(withAttributes: [.font: Self.font]).width)
    }

    override var intrinsicContentSize: NSSize {
        var width = Self.horizontalPadding * 2 + textWidth
        if iconName != nil { width += Self.iconSize + Self.spacing }
        if showsSyncedIcon { width += Self.iconSize + Self.spacing }
        return NSSize(width: width, height: 18)
    }

    private var textColor: NSColor {
        if isOnSelection { return .alternateSelectedControlTextColor }
        switch chip.style {
        case .head: return .controlAccentColor
        case .remote, .more: return .secondaryLabelColor
        case .local, .tag: return .labelColor
        }
    }

    private var iconColor: NSColor {
        if isOnSelection { return .alternateSelectedControlTextColor }
        switch chip.style {
        case .head: return .controlAccentColor
        case .local: return Palette.lane(chip.lane)
        case .remote, .more: return .secondaryLabelColor
        case .tag: return .labelColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        if isOnSelection {
            Palette.chipOnSelection.setFill()
            shape.fill()
        } else {
            switch chip.style {
            case .head:
                NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
                shape.fill()
            case .remote, .more:
                Palette.chipBorder.setStroke()
                shape.lineWidth = 1
                shape.stroke()
            case .local, .tag:
                Palette.chipFill.setFill()
                shape.fill()
            }
        }

        var x = Self.horizontalPadding
        let iconY = (bounds.height - Self.iconSize) / 2
        if let iconName {
            drawSymbol(iconName, at: NSPoint(x: x, y: iconY), color: iconColor)
            x += Self.iconSize + Self.spacing
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: textColor, .paragraphStyle: paragraph]
        let textHeight = ceil(Self.font.ascender - Self.font.descender)
        let trailingReserve = Self.horizontalPadding + (showsSyncedIcon ? Self.iconSize + Self.spacing : 0)
        let available = max(0, bounds.width - x - trailingReserve)
        let textRect = NSRect(x: x, y: (bounds.height - textHeight) / 2, width: min(textWidth, available), height: textHeight)
        (chip.title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        if showsSyncedIcon {
            drawSymbol("cloud", at: NSPoint(x: textRect.maxX + Self.spacing, y: iconY),
                        color: isOnSelection ? .alternateSelectedControlTextColor : .secondaryLabelColor)
        }
    }

    private func drawSymbol(_ name: String, at origin: NSPoint, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let rect = NSRect(
            x: origin.x + (Self.iconSize - size.width) / 2,
            y: origin.y + (Self.iconSize - size.height) / 2,
            width: size.width,
            height: size.height
        )
        image.draw(in: rect)
    }
}

// MARK: - Cells

/// Chips, then the subject; the working-copy row also shows "13 files · 3 staged" on the right.
final class DescriptionCellView: NSTableCellView {
    private let subject = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var chipViews: [RefChipView] = []
    private static let maximumChips = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        subject.font = .systemFont(ofSize: 13)
        subject.lineBreakMode = .byTruncatingTail
        subject.cell?.truncatesLastVisibleLine = true
        subject.textColor = .labelColor
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        addSubview(subject)
        addSubview(detail)
        textField = subject
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(subject text: String, chips: [ChipModel], detail detailText: String?) {
        subject.stringValue = text
        detail.stringValue = detailText ?? ""
        detail.isHidden = detailText == nil

        var visible = Array(chips.prefix(Self.maximumChips))
        if chips.count > Self.maximumChips {
            visible.append(ChipModel(title: "+\(chips.count - Self.maximumChips)", style: .more, lane: 0))
        }
        while chipViews.count < visible.count {
            let view = RefChipView(chip: visible[chipViews.count])
            addSubview(view)
            chipViews.append(view)
        }
        for (index, view) in chipViews.enumerated() {
            if index < visible.count {
                view.chip = visible[index]
                view.isHidden = false
            } else {
                view.isHidden = true
            }
        }
        toolTip = chips.isEmpty ? text : chips.map(\.title).joined(separator: ", ") + "\n" + text
        applyBackgroundStyle()
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyBackgroundStyle() }
    }

    private func applyBackgroundStyle() {
        let emphasized = backgroundStyle == .emphasized
        detail.cell?.backgroundStyle = backgroundStyle
        for view in chipViews {
            view.isOnSelection = emphasized
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        var x: CGFloat = 8
        for view in chipViews where !view.isHidden {
            let size = view.intrinsicContentSize
            let width = min(size.width, max(bounds.width * 0.45, 60))
            view.frame = NSRect(x: x, y: (height - size.height) / 2, width: width, height: size.height)
            x += width + 6
        }
        var trailing = bounds.width - 8
        if !detail.isHidden {
            let width = ceil(detail.intrinsicContentSize.width)
            detail.frame = NSRect(x: trailing - width, y: (height - 16) / 2, width: width, height: 16)
            trailing -= width + 8
        }
        subject.frame = NSRect(x: x, y: (height - 16) / 2, width: max(0, trailing - x), height: 16)
    }
}

/// The Author column: the author's GitHub avatar (or initials) and name. Without avatars
/// (Settings › General) the name starts at the column's edge.
final class AuthorCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let avatar = NSImageView()
    private var avatarWidth: NSLayoutConstraint!
    private var gap: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.imageScaling = .scaleProportionallyUpOrDown
        addSubview(avatar)
        addSubview(label)
        textField = label
        avatarWidth = avatar.widthAnchor.constraint(equalToConstant: HistoryMetrics.avatarSize)
        gap = label.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 6)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarWidth,
            avatar.heightAnchor.constraint(equalToConstant: HistoryMetrics.avatarSize),
            gap,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(name: String, image: NSImage?, toolTip: String?) {
        label.stringValue = name
        avatar.image = image
        avatar.isHidden = image == nil
        avatarWidth.constant = image == nil ? 0 : HistoryMetrics.avatarSize
        gap.constant = image == nil ? 0 : 6
        self.toolTip = toolTip
    }
}

/// Author, date and SHA columns.
final class TextCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(monospaced: Bool) {
        super.init(frame: .zero)
        if monospaced {
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .tertiaryLabelColor
        } else {
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
        }
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ text: String, toolTip: String? = nil) {
        label.stringValue = text
        self.toolTip = toolTip
    }
}

/// The Commit column: the short SHA, with a seal before it for signed commits (green when git
/// verified the key, orange when it couldn't vouch for it).
final class CommitCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let seal = NSImageView()

    init() {
        super.init(frame: .zero)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        seal.translatesAutoresizingMaskIntoConstraints = false
        seal.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        addSubview(seal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            seal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            seal.centerYAnchor.constraint(equalTo: centerYAnchor),
            seal.widthAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: seal.trailingAnchor, constant: 3),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ text: String, signature: Character?, toolTip: String?) {
        label.stringValue = text
        switch signature {
        case "G":
            seal.image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: String(localized: "Verified signature"))
            seal.contentTintColor = Palette.added
        case "U", "E", "X", "Y":
            seal.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: String(localized: "Unverified signature"))
            seal.contentTintColor = .systemOrange
        case "B", "R":
            seal.image = NSImage(systemSymbolName: "xmark.shield.fill", accessibilityDescription: String(localized: "Bad signature"))
            seal.contentTintColor = Palette.deleted
        default:
            seal.image = nil
        }
        self.toolTip = toolTip
    }
}
