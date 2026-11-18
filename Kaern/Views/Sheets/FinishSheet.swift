import AppKit
import KaernKit
import SwiftUI

/// Finish Feature…: the merge commit's message and how to go about it, as the repository last chose.
struct FinishSheet: View {
    let repository: RepositoryModel
    let request: FinishSheetRequest
    @State private var message = ""
    @State private var options = FinishOptions()
    @FocusState private var focused: Bool

    var body: some View {
        SheetCard {
            SheetTitle("Finish “\(request.branch)”", subtitle: "Merges it into \(request.target).")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                SheetFormRow(label: "Message") {
                    SheetField(placeholder: "Merge \(request.branch)", text: $message, focus: $focused, onSubmit: submit)
                }
                GridRow {
                    Color.clear.frame(width: 72, height: 1)
                    FieldMessage(text: options.mergeCommit ? "The merge commit’s message: say what the feature was."
                                                           : "Used when \(request.target) can’t fast-forward and a merge commit is made.")
                }
                GridRow {
                    Color.clear.frame(width: 72, height: 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Always create a merge commit (no fast-forward)", isOn: $options.mergeCommit)
                        Toggle("Delete the branch after merging", isOn: $options.deleteBranch)
                        Toggle("Rebase on \(request.target) first", isOn: $options.rebaseFirst)
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
                }
            }
            .padding(.top, 14)
            SheetButtons(leading: "Kaern keeps these choices for this repository.", confirmTitle: "Finish",
                         cancel: { repository.sheet = nil }, confirm: submit)
        }
        .onAppear {
            options = repository.finishOptions
            message = RepositoryModel.finishMessageStart(for: request.branch)
            DispatchQueue.main.async {
                focused = true
                // A field that takes focus has its text selected: typing would replace "Merge feature/zoom: ".
                // The cursor goes after it instead, to go on with what the feature was.
                DispatchQueue.main.async { putCursorAtEnd() }
            }
        }
    }

    private func putCursorAtEnd() {
        for window in NSApp.windows {
            guard let editor = window.firstResponder as? NSTextView, editor.string == message else { continue }
            editor.setSelectedRange(NSRange(location: (message as NSString).length, length: 0))
        }
    }

    private func submit() {
        repository.sheet = nil
        repository.from("Finish Feature sheet") { repository.confirmFinish(request, message: message, options: options) }
    }
}
