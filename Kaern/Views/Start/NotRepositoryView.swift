import AppKit
import KaernKit
import SwiftUI

/// ScreenInit's 폴더가 레포가 아님: a folder that isn't a Git repository yet — what's in it, and
/// Create Repository Here… / Open Another Folder….
struct NotRepositoryView: View {
    let repository: RepositoryModel
    let window: WindowModel
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            FolderQuestionArt()
                .frame(width: 76, height: 64)
            Text("\(repository.name) isn’t a Git repository yet")
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 16)
            Text(Formatters.abbreviatedPath(repository.path))
                .font(.system(size: 12.5))
                .foregroundStyle(K.label2)
                .padding(.top, 4)
            if let survey = repository.folderSurvey {
                HStack(spacing: 6) {
                    ForEach(Self.chips(survey), id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(K.label2)
                            .padding(.horizontal, 9)
                            .frame(height: 22)
                            .background(Capsule().fill(K.hover))
                    }
                }
                .padding(.top, 14)
            } else {
                ProgressView().controlSize(.small).padding(.top, 14)
            }
            HStack(spacing: 8) {
                PrimaryButton(title: "Create Repository Here…", height: 30, fontSize: 13) {
                    app.showCreate(in: window, folder: URL(filePath: repository.path, directoryHint: .isDirectory))
                }
                SheetActionButton(title: "Open Another Folder…") { app.showOpenPanel(for: window) }
            }
            .padding(.top, 22)
            Text("Kaern looked for a .git folder here and in every folder above it and found none. If this folder belongs to a repository somewhere else, open that one instead.")
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(K.label2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .padding(.top, 22)
        }
        .padding(EdgeInsets(top: 0, leading: 40, bottom: 60, trailing: 40))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(K.content)
    }

    /// "Astro site · package.json", "142 files · 3.4 MB", "node_modules/ · 1,842 files to leave out".
    static func chips(_ survey: FolderSurvey) -> [String] {
        var chips: [String] = []
        if let kind = survey.kind, let marker = survey.marker { chips.append("\(kind) · \(marker)") }
        let size = ByteCountFormatter.string(fromByteCount: survey.bytes, countStyle: .file)
        chips.append((survey.isCapped ? "More than " : "") + Formatters.count(survey.files, "file", "files") + " · " + size)
        if let biggest = survey.generated.first {
            chips.append("\(biggest.name) · \(Formatters.count(biggest.files, "file", "files")) to leave out")
        }
        return chips
    }
}

/// `.nofi`: a folder with a question mark badge, in the accent color.
private struct FolderQuestionArt: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 76, size.height / 64)
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            let back = Path(SVGPathParser.parse("M4 12a6 6 0 0 1 6-6h17l6 6h33a6 6 0 0 1 6 6v34a6 6 0 0 1-6 6H10a6 6 0 0 1-6-6z")).applying(transform)
            let front = Path(SVGPathParser.parse("M4 20h68v32a6 6 0 0 1-6 6H10a6 6 0 0 1-6-6z")).applying(transform)
            context.fill(back, with: .color(K.accent.opacity(0.18)))
            context.fill(front, with: .color(K.accent.opacity(0.32)))
            let badge = Path(ellipseIn: CGRect(x: 46, y: 32, width: 24, height: 24)).applying(transform)
            context.fill(badge, with: .color(K.content))
            context.stroke(badge, with: .color(K.accent), lineWidth: 2.4 * scale)
            var mark = Path()
            mark.move(to: CGPoint(x: 58, y: 38.5))
            mark.addLine(to: CGPoint(x: 58, y: 45.5))
            mark.move(to: CGPoint(x: 58, y: 49.5))
            mark.addLine(to: CGPoint(x: 58, y: 49.7))
            context.stroke(mark.applying(transform), with: .color(K.accent),
                           style: StrokeStyle(lineWidth: 2.6 * scale, lineCap: .round))
        }
        .accessibilityHidden(true)
    }
}

/// `.inbanner`: a repository Kaern just made that's only on this Mac — Publish to GitHub… /
/// Add Remote… / ×.
struct PublishBanner: View {
    let repository: RepositoryModel
    let window: WindowModel
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Icon(Icons.cloud, size: 18)
                .foregroundStyle(K.accentText)
            Text("\(Text("\(repository.name) is only on this Mac.").bold()) Publish it to keep a copy on GitHub and pick it up on other Macs.")
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            PrimaryButton(title: "Publish to GitHub…") { app.showPublish(repository, in: window) }
            GhostButton(title: "Add Remote…") { repository.sheet = .repositorySettings }
            Button {
                withAnimation(.easeOut(duration: 0.15)) { repository.showsPublishBanner = false }
            } label: {
                Icon(Icons.closeLarge, size: 11)
                    .foregroundStyle(K.label2)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverPlateStyle(radius: 6))
            .accessibilityLabel("Hide")
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(K.accentSoft)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(K.sep, lineWidth: 0.5)))
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .background(K.content)
        .overlay(alignment: .bottom) { K.sep.frame(height: 1) }
    }
}
