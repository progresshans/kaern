import AppKit
import KaernKit
import SwiftUI

/// "M" / "A" / "D" / "R" / "U" — always a letter and a color.
struct StatusLetter: View {
    let kind: ChangeKind
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Text(kind.letter)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(prominence == .increased ? Color.white : Color(Palette.color(for: kind)))
            .frame(width: 12)
            .help(kind.label)
            .accessibilityLabel(kind.label)
    }
}

/// "Sources/PowerLens/" in secondary, "AlphaVersion.swift" in the label color. When the row is
/// too narrow the folders give way first ("…/AlphaVersion.swift").
struct PathLabel: View {
    let path: String
    var oldPath: String?
    /// Only "…/" for the folders.
    var abbreviated = false

    var body: some View {
        let (directory, name) = PathLabel.split(path)
        let folders = directory.isEmpty ? "" : "…/"
        ViewThatFits(in: .horizontal) {
            if !abbreviated {
                Text("\(Text(directory).foregroundStyle(.secondary))\(name)")
            }
            Text("\(Text(folders).foregroundStyle(.secondary))\(name)")
                .truncationMode(.tail)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .help(oldPath.map { "\($0) → \(path)" } ?? path)
    }

    static func split(_ path: String) -> (String, String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[...slash]), String(path[path.index(after: slash)...]))
    }
}

/// A file row's path, its "Submodule" / "LFS" tag and its end (line counts, or what moved). When
/// the row is too narrow for all of it, the end of a tagged row gives way first: the diff shows
/// it in full.
struct FileRowLabel: View {
    let path: String
    var oldPath: String?
    let stat: LineStat?
    let annotation: FileAnnotation?

    var body: some View {
        if let annotation {
            ViewThatFits(in: .horizontal) {
                row(PathLabel(path: path, oldPath: oldPath).fixedSize(), annotation: annotation, showsDetail: true)
                row(PathLabel(path: path, oldPath: oldPath, abbreviated: true).fixedSize(), annotation: annotation, showsDetail: true)
                row(PathLabel(path: path, oldPath: oldPath), annotation: annotation, showsDetail: false)
            }
        } else {
            HStack(spacing: 6) {
                PathLabel(path: path, oldPath: oldPath)
                Spacer(minLength: 4)
                LineStatLabel(stat: stat)
            }
        }
    }

    private func row(_ label: some View, annotation: FileAnnotation, showsDetail: Bool) -> some View {
        HStack(spacing: 6) {
            label
            FileTag(text: annotation.tag)
                .help(showsDetail ? "" : "\(annotation.tag) · \(annotation.detail)")
            Spacer(minLength: showsDetail ? 4 : 0)
            if showsDetail {
                FileRowTrailing(stat: nil, annotation: annotation)
            }
        }
    }
}

/// "Submodule" or "LFS" after a path in the file lists.
struct FileTag: View {
    let text: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onSelection = prominence == .increased
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(onSelection ? Color.white : Color.secondary)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(onSelection ? Color.white.opacity(0.6) : Color(nsColor: .separatorColor))
            )
            .fixedSize()
    }
}

/// A file row's end: line counts, or what a submodule or Git LFS file changed.
struct FileRowTrailing: View {
    let stat: LineStat?
    let annotation: FileAnnotation?
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let annotation {
            Text(annotation.detail)
                // SHAs line up in monospace; sizes only need their digits to.
                .font(annotation.isSubmodule ? .system(size: 11, design: .monospaced) : .system(size: 11).monospacedDigit())
                .foregroundStyle(prominence == .increased ? Color.white : Color.secondary)
                .lineLimit(1)
                .fixedSize()
        } else {
            LineStatLabel(stat: stat)
        }
    }
}

/// "+12 -3" (green / red), or "binary".
struct LineStatLabel: View {
    let stat: LineStat?
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let onSelection = prominence == .increased
        HStack(spacing: 4) {
            if let stat {
                if stat.isBinary {
                    Text("binary").foregroundStyle(.tertiary)
                } else {
                    if let additions = stat.additions, additions > 0 {
                        Text("+\(additions)").foregroundStyle(onSelection ? Color.white : Color(Palette.added))
                    }
                    if let deletions = stat.deletions, deletions > 0 {
                        Text("-\(deletions)").foregroundStyle(onSelection ? Color.white : Color(Palette.deleted))
                    }
                }
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
    }
}

/// Initials in a gray circle.
struct AvatarView: View {
    let initials: String
    var size: CGFloat = 28

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.gray.opacity(0.75)))
            .accessibilityHidden(true)
    }
}

/// NSButton checkbox with a mixed state (partially staged). Clicking reports the intent;
/// the checkbox always shows the model's state.
struct StageCheckbox: NSViewRepresentable {
    let state: StageState
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        button.controlSize = .small
        button.setAccessibilityLabel(String(localized: "Staged"))
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = state.controlState
        button.isEnabled = context.environment.isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func clicked(_ sender: NSButton) {
            action()
        }
    }
}

extension StageState {
    var controlState: NSControl.StateValue {
        switch self {
        case .staged: .on
        case .unstaged: .off
        case .partial: .mixed
        }
    }
}

/// A ref name in chip style for SwiftUI surfaces (inspector "On" row).
struct BranchChip: View {
    let name: String
    var isHead = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isHead ? "checkmark" : "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(isHead ? Color.accentColor : Color.primary)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHead ? Color.accentColor.opacity(0.14) : Color(Palette.chipFill))
        )
    }
}
