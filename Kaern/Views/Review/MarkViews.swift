import AppKit
import KaernKit
import SwiftUI

// MARK: - What a file is

/// Files Review shows as something other than lines of text (ScreenMarks).
enum SpecialFile: Equatable {
    /// Before and after, side by side, swiped or blended.
    case image
    /// A Git LFS file that isn't a picture: its pointer, and Download when the content isn't here.
    case lfs
    /// A submodule that points at another commit.
    case submodule(SubmoduleSides)

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "ico", "icns"]

    static func detect(path: String, diff: FileDiff?) -> SpecialFile? {
        let isLFS = diff?.lfsChange != nil
        if imageExtensions.contains((path as NSString).pathExtension.lowercased()), isLFS || diff?.isBinary == true {
            return .image
        }
        return isLFS ? .lfs : nil
    }
}

/// The two commits a submodule change is between.
struct SubmoduleSides: Equatable {
    enum Stage: Equatable {
        /// Checked out away from the commit the index records: Stage Submodule Change.
        case unstaged
        /// The index records another commit than HEAD: Unstage.
        case staged
        /// A commit moved it.
        case committed(String)
    }

    var old: String?
    /// `nil`: the commit checked out inside now.
    var new: String?
    var stage: Stage
    /// Files inside have changes of their own.
    var changedInside = false
}

/// Where the two versions of a file come from.
struct FileSides: Equatable {
    var old: FileVersion?
    var new: FileVersion?
    /// The old side's path, for a renamed file.
    var oldPath: String?

    /// The commit `new` is in (nil: the work tree or the index).
    var newCommit: String? {
        if case .revision(let revision)? = new { return revision }
        return nil
    }
}

/// Review's page for a file that isn't lines of text.
struct SpecialFileView: View {
    let file: ReviewFile
    let special: SpecialFile
    let repository: RepositoryModel
    /// All Files: one section among the others.
    var inList = false

    var body: some View {
        switch special {
        case .image: ImageDiffView(file: file, repository: repository, inList: inList)
        case .lfs: LFSFileView(file: file, repository: repository, inList: inList)
        case .submodule(let sides): SubmoduleChangeView(file: file, sides: sides, repository: repository, inList: inList)
        }
    }
}

/// "412 KB", "48.2 MB".
nonisolated func byteCount(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

/// "412 → 398 KB", "1.2 → 1.3 MB", "48.2 MB" (one side).
nonisolated func sizeChange(_ old: Int?, _ new: Int?) -> String {
    switch (old, new) {
    case let (old?, new?):
        let before = byteCount(old), after = byteCount(new)
        let beforeParts = before.split(separator: " "), afterParts = after.split(separator: " ")
        if beforeParts.count == 2, afterParts.count == 2, beforeParts[1] == afterParts[1] {
            return "\(beforeParts[0]) → \(after)"
        }
        return "\(before) → \(after)"
    case let (old?, nil): return byteCount(old)
    case let (nil, new?): return byteCount(new)
    default: return ""
    }
}

// MARK: - Pictures

enum ImageDiffMode: String, CaseIterable {
    case twoUp = "2up", swipe, onion
}

/// `.imgv`: a picture before and after on a checkerboard: 2-up, Swipe (drag the divider) or
/// Onion Skin (blend with the slider).
struct ImageDiffView: View {
    let file: ReviewFile
    let repository: RepositoryModel
    var inList = false
    @AppStorage(SettingsKey.imageDiffMode, store: .kaern) private var mode = ImageDiffMode.swipe
    @State private var loaded: Loaded?
    @State private var split: CGFloat = 0.5
    @State private var blend = 0.5

    struct Loaded {
        var key: String
        var old: FileContents?
        var new: FileContents?
        var oldImage: NSImage?
        var newImage: NSImage?
    }

    private var key: String { "\(file.path)|\(file.sides.old.map { "\($0)" } ?? "-")|\(file.sides.new.map { "\($0)" } ?? "-")" }

    var body: some View {
        Group {
            if let loaded, loaded.key == key {
                if let missing = [loaded.new, loaded.old].compactMap({ $0 }).first(where: \.isMissingLFSContent), let pointer = missing.pointer {
                    LFSPointerView(file: file, pointer: pointer, repository: repository)
                } else if loaded.oldImage == nil, loaded.newImage == nil {
                    BinaryFileCard(file: file, size: (loaded.new ?? loaded.old)?.size, repository: repository)
                } else {
                    pictures(loaded)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: inList ? nil : .infinity)
        .task(id: key) {
            let key = key
            async let old = repository.fileContents(file.sides.oldPath ?? file.path, at: file.sides.old)
            async let new = repository.fileContents(file.path, at: file.sides.new)
            let (before, after) = await (old, new)
            loaded = Loaded(key: key, old: before, new: after,
                            oldImage: before?.data.flatMap(NSImage.init(data:)), newImage: after?.data.flatMap(NSImage.init(data:)))
        }
    }

    @ViewBuilder
    private func pictures(_ loaded: Loaded) -> some View {
        let both = loaded.oldImage != nil && loaded.newImage != nil
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(info(loaded))
                    .font(.system(size: 12))
                    .foregroundStyle(K.label2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if both {
                    SegmentedChoice(options: [(ImageDiffMode.twoUp, "2-up"), (.swipe, "Swipe"), (.onion, "Onion Skin")],
                                    selection: $mode, label: "Image comparison")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(K.content)
            .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
            Group {
                if both, let old = loaded.oldImage, let new = loaded.newImage {
                    switch mode {
                    case .twoUp: twoUp(old: old, new: new, loaded: loaded)
                    case .swipe: swipe(old: old, new: new)
                    case .onion: onion(old: old, new: new)
                    }
                } else if let image = loaded.newImage ?? loaded.oldImage {
                    let added = loaded.newImage != nil
                    VStack(spacing: 8) {
                        Shot(image: image, aspect: aspect(image, image))
                        Text("\(added ? "Added" : "Deleted") · \(byteCount((added ? loaded.new : loaded.old)?.size ?? 0))")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(K.label2)
                    }
                    .frame(maxWidth: Self.width(image, image))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: inList ? nil : .infinity, alignment: .top)
            .frame(height: inList ? 420 : nil)
            .background(Checkerboard())
            .clipped()
        }
    }

    /// "1440 × 900 · 412 KB → 398 KB".
    private func info(_ loaded: Loaded) -> String {
        var parts: [String] = []
        if let image = loaded.newImage ?? loaded.oldImage, let size = pixelSize(image) {
            parts.append("\(size.width) × \(size.height)")
        }
        parts.append(sizeChange(loaded.old?.size, loaded.new?.size))
        return parts.joined(separator: " · ")
    }

    private func pixelSize(_ image: NSImage) -> (width: Int, height: Int)? {
        guard let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }), rep.pixelsWide > 0 else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    /// Width over height, the wider of the two (both draw in the same frame).
    private func aspect(_ old: NSImage, _ new: NSImage) -> CGFloat {
        let size = new.size.width > 0 ? new.size : old.size
        return size.height > 0 ? size.width / size.height : 16 / 10
    }

    private func twoUp(old: NSImage, new: NSImage, loaded: Loaded) -> some View {
        HStack(alignment: .top, spacing: 18) {
            figure(old, caption: "Before · \(byteCount(loaded.old?.size ?? 0))", aspect: aspect(old, old))
            figure(new, caption: "After · \(byteCount(loaded.new?.size ?? 0))", aspect: aspect(new, new))
        }
    }

    private func figure(_ image: NSImage, caption: String, aspect: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Shot(image: image, aspect: aspect)
            Text(caption)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(K.label2)
        }
        .frame(maxWidth: .infinity)
    }

    /// The old picture on the left of the divider, the new one on the right.
    private func swipe(old: NSImage, new: NSImage) -> some View {
        VStack(spacing: 8) {
            Shot(image: new, aspect: aspect(old, new))
                .overlay {
                    GeometryReader { proxy in
                        let x = proxy.size.width * split
                        ZStack(alignment: .topLeading) {
                            Shot(image: old, aspect: aspect(old, new), shadow: false)
                                .mask(alignment: .leading) { Rectangle().frame(width: x) }
                            Rectangle().fill(Color.white).frame(width: 1.5)
                                .shadow(color: .black.opacity(0.35), radius: 1.5)
                                .offset(x: x - 0.75)
                            SwipeKnob()
                                .offset(x: x - 14, y: proxy.size.height / 2 - 14)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            split = min(max(drag.location.x / max(proxy.size.width, 1), 0), 1)
                        })
                        .pointerStyle(.columnResize)
                    }
                }
            HStack {
                Text("Before")
                Spacer()
                Text("After")
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(K.label2)
        }
        .frame(maxWidth: Self.width(old, new))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Swipe between before and after")
        .accessibilityValue("\(Int(split * 100)) percent before")
        .accessibilityAdjustableAction { direction in
            split = min(max(split + (direction == .increment ? 0.05 : -0.05), 0), 1)
        }
    }

    private func onion(old: NSImage, new: NSImage) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Shot(image: old, aspect: aspect(old, new))
                Shot(image: new, aspect: aspect(old, new), shadow: false).opacity(blend)
            }
            HStack(spacing: 10) {
                Text("Before")
                Slider(value: $blend, in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel("Blend before and after")
                Text("After")
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(K.label2)
            .frame(maxWidth: 420)
        }
        .frame(maxWidth: max(Self.width(old, new), 240))
    }

    /// The column a picture and its captions share: the picture's own width, up to 760 pt.
    private static func width(_ old: NSImage, _ new: NSImage) -> CGFloat {
        min(760, max(old.size.width, new.size.width, 1))
    }
}

/// `.ishot`: a picture in a rounded frame with a soft shadow.
private struct Shot: View {
    let image: NSImage
    let aspect: CGFloat
    var shadow = true

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(aspect, contentMode: .fit)
            // Small pictures stay at their own size instead of blowing up.
            .frame(maxWidth: max(image.size.width, 1), maxHeight: max(image.size.height, 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.black.opacity(shadow ? 0.18 : 0), lineWidth: 0.5))
            .shadow(color: .black.opacity(shadow ? 0.14 : 0), radius: 11, y: 6)
    }
}

/// The swipe divider's handle: a white circle with ‹ ›.
private struct SwipeKnob: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.white)
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            HStack(spacing: 3) {
                Icon(Icons.arrowLeft, size: 8)
                Icon(Icons.arrowRight, size: 8)
            }
            .foregroundStyle(Color(white: 0.23))
        }
        .frame(width: 28, height: 28)
        .allowsHitTesting(false)
    }
}

/// The transparency checkerboard behind pictures: 9 pt squares in the row tints.
struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 9
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(K.content))
            var path = Path()
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : side
                while x < size.width {
                    path.addRect(CGRect(x: x, y: y, width: side, height: side))
                    x += side * 2
                }
                y += side
                row += 1
            }
            context.fill(path, with: .color(K.alt))
        }
    }
}

// MARK: - Git LFS

/// A Git LFS file that isn't a picture: Download while only its pointer is here, else the
/// binary file's card with Quick Look.
struct LFSFileView: View {
    let file: ReviewFile
    let repository: RepositoryModel
    var inList = false
    @State private var loaded: (key: String, contents: FileContents?)?

    private var key: String { "\(file.path)|\(file.sides.new.map { "\($0)" } ?? "-")|\(file.sides.old.map { "\($0)" } ?? "-")" }

    var body: some View {
        Group {
            if let loaded, loaded.key == key {
                if let contents = loaded.contents, contents.isMissingLFSContent, let pointer = contents.pointer {
                    LFSPointerView(file: file, pointer: pointer, repository: repository)
                } else {
                    BinaryFileCard(file: file, size: loaded.contents?.size, repository: repository, inLFS: true)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: inList ? nil : .infinity, alignment: .top)
        .task(id: key) {
            let key = key
            let deleted = file.sides.new == nil
            let contents = await repository.fileContents(deleted ? (file.sides.oldPath ?? file.path) : file.path,
                                                         at: deleted ? file.sides.old : file.sides.new, limit: 1 << 20)
            loaded = (key, contents)
        }
    }
}

/// `.lfsv`: only the pointer is here. "Stored in Git LFS · 48.2 MB", the pointer, Download.
struct LFSPointerView: View {
    let file: ReviewFile
    let pointer: LFSPointer
    let repository: RepositoryModel
    @State private var autoStarted = false

    private var isDownloading: Bool { repository.activity?.statusText.hasPrefix("Downloading") == true }

    var body: some View {
        let size = byteCount(pointer.size)
        VStack(spacing: 0) {
            Icon(FileGlyph.forPath(file.path), size: 54)
                .foregroundStyle(K.label3)
                .frame(width: 54, height: 54)
            Text("Stored in Git LFS · \(size)")
                .font(.system(size: 17, weight: .bold))
                .padding(.top, 14)
            Text(file.sides.newCommit == nil
                 ? "This checkout has only the pointer file. Kaern downloads LFS files when you open one, or all of them with Fetch LFS Files."
                 : "This Mac has only the pointer for this version. Download gets its content from the LFS server; the work tree stays as it is.")
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(K.label2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .padding(.top, 6)
            Text(verbatim: "version https://git-lfs.github.com/spec/v1\noid \(pointer.oid)\nsize \(String(pointer.size))")
                .font(.system(size: 11, design: .monospaced))
                .lineSpacing(5)
                .foregroundStyle(K.label2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(K.field))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
                .frame(maxWidth: 560)
                .padding(.top, 18)
            HStack(spacing: 8) {
                if isDownloading {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(size)…").font(.system(size: 12)).foregroundStyle(K.label2)
                } else {
                    PrimaryButton(title: "Download \(size)") { download() }
                        .disabled(repository.activity != nil)
                    GhostButton(title: repository.alwaysDownloadsLFS ? "Stop Downloading in \(repository.name)" : "Always Download in \(repository.name)") {
                        repository.alwaysDownloadsLFS.toggle()
                        if repository.alwaysDownloadsLFS { download() }
                    }
                }
            }
            .frame(height: 28)
            .padding(.top, 18)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity)
        .onAppear {
            // Always Download: opening the file downloads it.
            guard repository.alwaysDownloadsLFS, !autoStarted, repository.activity == nil else { return }
            autoStarted = true
            download()
        }
    }

    private func download() {
        repository.from("LFS file") {
            repository.downloadLFS([file.path], at: file.sides.newCommit)
        }
    }
}

/// A binary file Kaern can't draw: its size, and Quick Look (Space).
struct BinaryFileCard: View {
    let file: ReviewFile
    let size: Int?
    let repository: RepositoryModel
    var inLFS = false

    var body: some View {
        VStack(spacing: 0) {
            Icon(FileGlyph.forPath(file.path), size: 54)
                .foregroundStyle(K.label3)
                .frame(width: 54, height: 54)
            Text(size.map { "\(file.name) · \(byteCount($0))" } ?? file.name)
                .font(.system(size: 15, weight: .bold))
                .padding(.top, 14)
            Text(inLFS ? "A binary file stored in Git LFS. Quick Look shows it: press Space." : "A binary file. Quick Look shows it: press Space.")
                .font(.system(size: 12.5))
                .foregroundStyle(K.label2)
                .padding(.top, 6)
            GhostButton(title: "Quick Look") { repository.quickLook(file) }
                .padding(.top, 16)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
}

/// Big glyphs for files Kaern can't show as text.
enum FileGlyph {
    static let film = SVGIcon(54, [
        .path("M13 9h28a6 6 0 0 1 6 6v24a6 6 0 0 1-6 6H13a6 6 0 0 1-6-6V15a6 6 0 0 1 6-6z", width: 2.4),
        .path("M7 18h40M7 36h40M16 9v9M27 9v9M38 9v9M16 36v9M27 36v9M38 36v9", width: 2.4),
        .filled("M23 23.5v7l6-3.5z"),
    ])
    static let picture = SVGIcon(54, [
        .path("M11 10h32a4 4 0 0 1 4 4v26a4 4 0 0 1-4 4H11a4 4 0 0 1-4-4V14a4 4 0 0 1 4-4z", width: 2.4),
        .path("M8 37l11-11 9 9 6-6 12 12", width: 2.4, join: .round),
        .path("M37 19.5a3.5 3.5 0 1 1-7 0 3.5 3.5 0 0 1 7 0z", width: 2.4),
    ])
    static let document = SVGIcon(54, [
        .path("M14 6h18l11 11v29a3 3 0 0 1-3 3H14a3 3 0 0 1-3-3V9a3 3 0 0 1 3-3z", width: 2.4, join: .round),
        .path("M32 6v11h11M18 28h18M18 35h18M18 42h11", width: 2.4, join: .round),
    ])

    static func forPath(_ path: String) -> SVGIcon {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["mov", "mp4", "m4v", "avi", "mkv", "webm"].contains(ext) { return film }
        if SpecialFile.imageExtensions.contains(ext) || ["psd", "sketch", "fig", "svg", "ai"].contains(ext) { return picture }
        return document
    }
}

// MARK: - Submodules

/// `.subv`: the commit recorded for the submodule → the one checked out now (or staged, or
/// committed), the commits in between, and Stage / Update to Recorded.
struct SubmoduleChangeView: View {
    let file: ReviewFile
    let sides: SubmoduleSides
    let repository: RepositoryModel
    var inList = false
    @State private var loaded: (key: SubmoduleSides, change: SubmoduleChange)?

    var body: some View {
        if inList {
            content
        } else {
            ScrollView { content }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loaded, loaded.key == sides {
                details(loaded.change)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: sides) {
            let sides = sides
            var new = sides.new
            if new == nil { new = await repository.submoduleHead(file.path) }
            let change = await repository.submoduleChange(file.path, from: sides.old, to: new)
            loaded = (sides, change)
        }
    }

    @ViewBuilder
    private func details(_ change: SubmoduleChange) -> some View {
        HStack(alignment: .center, spacing: 14) {
            card(oldLabel, commit: change.old, tag: change.oldTag, isNow: false)
            Icon(Icons.arrowRightLong, size: 18)
                .foregroundStyle(K.label2)
            card(newLabel, commit: change.new, tag: change.newTag, isNow: true)
            Spacer(minLength: 0)
            GhostButton(title: "Open Submodule") { repository.openSubmodule(file.path) }
                .disabled(!change.isInitialized)
        }
        Text(sentence(change))
            .font(.system(size: 12.5))
            .lineSpacing(3)
            .foregroundStyle(K.label2)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.top, 14)
        if !change.added.isEmpty {
            commitList(sides.stage == .unstaged ? "Commits in \(file.path)" : "New commits in \(file.path)",
                       commits: change.added, total: change.addedCount)
        }
        if !change.removed.isEmpty {
            commitList("Commits it goes back over", commits: change.removed, total: change.removedCount)
        }
        buttons(change)
            .padding(.top, 18)
    }

    private var oldLabel: String {
        switch sides.stage {
        case .unstaged: "Recorded in \(repository.name)"
        case .staged: "Recorded in HEAD"
        case .committed: "Recorded before"
        }
    }

    private var newLabel: String {
        switch sides.stage {
        case .unstaged: "Checked out now"
        case .staged: "Staged"
        case .committed(let id): "Recorded in \(String(id.prefix(7)))"
        }
    }

    /// `.subc`: what a side records; the side it moves to is tinted.
    private func card(_ label: String, commit: String?, tag: String?, isNow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(KFont.weighted(11, 0.33))
                .foregroundStyle(K.label2)
            Text(commit.map { String($0.prefix(7)) } ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
            if let tag {
                Text(tag)
                    .font(KFont.weighted(11, 0.33))
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(K.content))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(K.sepStrong, lineWidth: 0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isNow ? K.accentSoft : K.hover))
    }

    private func sentence(_ change: SubmoduleChange) -> String {
        let path = file.path
        guard change.isInitialized else {
            return "\(path) isn’t cloned on this Mac, so Kaern can’t list its commits. Initialize clones it at the commit \(repository.name) records."
        }
        if change.old == change.new, sides.changedInside {
            return "Files inside \(path) have changes of their own. Commit them in the submodule: Open Submodule."
        }
        let movement: String
        if change.isFastForward {
            movement = "\(Formatters.count(change.addedCount, "new commit", "new commits")), fast-forward."
        } else if change.addedCount == 0, change.removedCount > 0 {
            movement = "\(Formatters.count(change.removedCount, "commit", "commits")) back."
        } else if change.addedCount > 0, change.removedCount > 0 {
            movement = "\(change.addedCount) new and \(change.removedCount) left out: the two went apart."
        } else {
            movement = "The same commit."
        }
        let short = change.new.map { String($0.prefix(7)) } ?? "—"
        switch sides.stage {
        case .unstaged:
            return "\(movement) Staging records \(path) at \(short) in \(repository.name); nothing inside the submodule changes."
        case .staged:
            return "\(movement) Committing records \(path) at \(short) in \(repository.name)."
        case .committed:
            return "This commit moved \(path): \(movement.prefix(1).lowercased() + movement.dropFirst())"
        }
    }

    @ViewBuilder
    private func commitList(_ title: String, commits: [Commit], total: Int) -> some View {
        Text(title)
            .font(KFont.weighted(11.5, 0.33))
            .foregroundStyle(K.label2)
            .padding(.top, 16)
            .padding(.bottom, 6)
        VStack(spacing: 0) {
            ForEach(commits) { commit in
                HStack(spacing: 8) {
                    Text(String(commit.id.prefix(7)))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(K.label2)
                    Text(commit.subject)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Formatters.shortDate(commit.author.date))
                        .font(.system(size: 11.5))
                        .foregroundStyle(K.label2)
                }
                .frame(minHeight: 30)
                .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
            }
            if total > commits.count {
                Text("and \(total - commits.count) more")
                    .font(.system(size: 11.5))
                    .foregroundStyle(K.label2)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            }
        }
        .frame(maxWidth: 720)
    }

    @ViewBuilder
    private func buttons(_ change: SubmoduleChange) -> some View {
        HStack(spacing: 8) {
            if !change.isInitialized {
                PrimaryButton(title: "Initialize") {
                    repository.from("Submodule") { repository.updateSubmoduleToRecorded(file.path, label: change.old.map { String($0.prefix(7)) } ?? "") }
                }
            } else {
                switch sides.stage {
                case .unstaged where change.old != change.new:
                    PrimaryButton(title: "Stage Submodule Change") {
                        repository.from("Submodule") { repository.stage([file.path]) }
                    }
                    let recorded = change.oldTag ?? change.old.map { String($0.prefix(7)) } ?? ""
                    GhostButton(title: "Update to Recorded (\(recorded))") {
                        repository.from("Submodule") { repository.updateSubmoduleToRecorded(file.path, label: recorded) }
                    }
                case .staged:
                    PrimaryButton(title: "Unstage") {
                        repository.from("Submodule") { repository.unstage([file.path]) }
                    }
                default:
                    EmptyView()
                }
            }
        }
        .disabled(!repository.canChangeIndex)
    }
}

// MARK: - File list marks

/// `.lfsb`: "LFS" on a purple tint.
struct LFSBadge: View {
    var selected = false

    var body: some View {
        Text("LFS")
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(selected ? Color.white.opacity(0.9) : K.lfs)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(selected ? Color.white.opacity(0.2) : K.lfsBg))
            .fixedSize()
    }
}

/// `.ptr`: "not downloaded".
struct PointerPill: View {
    var selected = false

    var body: some View {
        Text("not downloaded")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(selected ? Color.white.opacity(0.9) : K.label2)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(selected ? Color.white.opacity(0.2) : K.hover))
            .fixedSize()
    }
}

/// What a file row shows on its right for LFS files and moved submodules, instead of line
/// counts: "LFS 412 → 398 KB", "LFS not downloaded", "3 commits".
struct FileMarks: View {
    var lfs: LFSSizes?
    var notDownloaded = false
    var submoduleNote: String?
    var selected = false

    var body: some View {
        HStack(spacing: 6) {
            if lfs != nil || notDownloaded { LFSBadge(selected: selected) }
            if notDownloaded {
                PointerPill(selected: selected)
            } else if let lfs {
                Text(sizeChange(lfs.old, lfs.new))
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? .white.opacity(0.85) : K.label2)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let submoduleNote {
                Text(submoduleNote)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? .white.opacity(0.85) : K.label2)
                    .fixedSize()
            }
        }
    }

    var isEmpty: Bool { lfs == nil && !notDownloaded && submoduleNote == nil }
}
