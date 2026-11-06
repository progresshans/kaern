import KaernKit
import SwiftUI

/// Thin bars under the toolbar for files that are missing: submodules that aren't cloned, and
/// Git LFS pointers when git-lfs isn't installed. × hides one until the window closes.
struct RepositoryNoticeBar: View {
    let model: RepositoryModel

    var body: some View {
        ForEach(model.notices) { notice in
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .frame(width: 16)
                Text(text(for: notice))
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                buttons(for: notice)
                    .controlSize(.small)
                    .fixedSize()
                Button {
                    model.dismissedNotices.insert(notice.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Hide until this window closes")
                .accessibilityLabel("Hide")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    Color.orange.opacity(0.08)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(text(for: notice))
        }
    }

    private func text(for notice: RepositoryNotice) -> String {
        switch notice {
        case .submodulesNotCloned(let submodules):
            if submodules.count == 1 {
                return String(localized: "\(submodules[0].name) isn't cloned, so its files are missing.")
            }
            let names = submodules.map(\.name).formatted(.list(type: .and))
            return String(localized: "\(names) aren't cloned, so their files are missing.")
        case .lfsNotInstalled(let pointers):
            return pointers == 1
                ? String(localized: "git-lfs isn't installed — 1 file is still a pointer.")
                : String(localized: "git-lfs isn't installed — \(pointers) files are still pointers.")
        }
    }

    @ViewBuilder
    private func buttons(for notice: RepositoryNotice) -> some View {
        switch notice {
        case .submodulesNotCloned(let submodules):
            Button(submodules.count == 1 ? "Clone Submodule" : "Clone Submodules") {
                Task { await model.cloneSubmodules(submodules) }
            }
            .disabled(model.activity != nil)
        case .lfsNotInstalled:
            Button("Copy Install Command") { Pasteboard.copy(RepositoryModel.lfsInstallCommand) }
                .help(RepositoryModel.lfsInstallCommand)
        }
    }
}
