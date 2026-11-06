import KaernKit
import SwiftUI

/// A submodule in the file list: which commit it moved to, instead of the "Subproject commit"
/// lines of its diff, and how to record it, go back, or open it.
struct SubmoduleNote: View {
    enum Change: Equatable {
        case working(StatusEntry)
        case commit(FileChange)
    }

    let model: RepositoryModel
    let path: String
    let change: Change
    @State private var commitDistance: CommitDistance?

    private var name: String { (path as NSString).lastPathComponent }
    private var submodule: Submodule? { model.submodule(at: path) }

    private var move: SubmoduleMove? {
        switch change {
        case .working(let entry): model.submoduleMove(for: entry)
        case .commit(let file): file.submodule
        }
    }

    private var status: SubmoduleStatus? {
        if case .working(let entry) = change { return entry.submodule }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: "shippingbox")
                }
                .font(.system(size: 13, weight: .semibold))
                ForEach(sentences, id: \.self) { sentence in
                    Text(sentence)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack {
                    if submodule != nil, submodule?.state != .notInitialized {
                        Button("Open in New Window") { model.openSubmodule(path) }
                    }
                    if let recorded = recordedToGoBackTo, let submodule {
                        Button("Check Out \(String(recorded.prefix(7)))") { Task { await model.updateSubmodule(submodule) } }
                            .help("Check out the commit this repository records for \(name) (git submodule update)")
                            .disabled(model.activity != nil)
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(String(describing: move))|\(status?.commitChanged ?? false)") { await loadDistance() }
    }

    private func short(_ id: String?) -> String { id.map { String($0.prefix(7)) } ?? "" }

    /// The recorded commit "Check Out" goes back to, when something else is checked out.
    private var recordedToGoBackTo: String? {
        guard let status, status.commitChanged else { return nil }
        return status.indexCommit
    }

    private var title: String {
        guard let move else { return name }
        switch change {
        case .working:
            if let status, !status.commitChanged, move.old == move.new {
                return String(localized: "\(name) has changes inside")
            }
            return String(localized: "\(name) is at \(short(move.new))")
        case .commit:
            switch (move.old, move.new) {
            case (nil, _?): return String(localized: "This commit adds \(name)")
            case (_?, nil): return String(localized: "This commit removes \(name)")
            default: return String(localized: "This commit moves \(name) to \(short(move.new))")
            }
        }
    }

    private var sentences: [String] {
        guard let move else { return [] }
        var sentences: [String] = []
        switch change {
        case .working(let entry):
            guard let status else { return [] }
            if status.commitChanged {
                sentences.append(movedSentence(recorded: status.indexCommit, checkedOut: move.new))
            } else if entry.hasStagedChanges, move.old != move.new {
                sentences.append(String(localized: "Committing records \(short(move.new)) for \(name) instead of \(short(move.old))\(distanceSuffix(commitDistance))."))
            }
            if status.hasModifiedContent || status.hasUntrackedContent {
                let what = status.hasModifiedContent
                    ? String(localized: "changes of its own that aren't committed")
                    : String(localized: "untracked files")
                sentences.append(String(localized: "\(name) has \(what). Commit them in its own window: this repository only records which commit it's on."))
            }
        case .commit:
            switch (move.old, move.new) {
            case (nil, let new?): sentences.append(String(localized: "\(name) starts at \(short(new))."))
            case (let old?, nil): sentences.append(String(localized: "It was at \(short(old))."))
            case (let old?, let new?): sentences.append(String(localized: "From \(short(old)) to \(short(new))\(distanceSuffix(commitDistance))."))
            default: break
            }
        }
        return sentences
    }

    /// "3 commits checked out inside Sparkle aren't recorded yet. Stage this row to record
    /// 9f8e7d6, or go back."
    private func movedSentence(recorded: String?, checkedOut: String?) -> String {
        let new = short(checkedOut)
        let record = String(localized: "Stage this row to record \(new), or go back.")
        guard let distance = model.submoduleDistances[path] else {
            return String(localized: "\(name) has \(new) checked out, not the recorded \(short(recorded)).") + " " + record
        }
        switch (distance.ahead, distance.behind) {
        case (let ahead, 0) where ahead > 0:
            let commits = ahead == 1
                ? String(localized: "1 commit checked out inside \(name) isn't recorded yet.")
                : String(localized: "\(ahead) commits checked out inside \(name) aren't recorded yet.")
            return commits + " " + record
        case (0, let behind) where behind > 0:
            let commits = behind == 1
                ? String(localized: "\(name) is checked out 1 commit behind the recorded \(short(recorded)).")
                : String(localized: "\(name) is checked out \(behind) commits behind the recorded \(short(recorded)).")
            return commits + " " + record
        default:
            return String(localized: "\(name) is on a commit \(distance.ahead) ahead of and \(distance.behind) behind the recorded \(short(recorded)).") + " " + record
        }
    }

    /// " (3 commits)", " (2 commits back)", or nothing when the submodule can't tell.
    private func distanceSuffix(_ distance: CommitDistance?) -> String {
        guard let distance else { return "" }
        switch (distance.ahead, distance.behind) {
        case (0, 0): return ""
        case (let ahead, 0): return ahead == 1 ? String(localized: " (1 commit)") : String(localized: " (\(ahead) commits)")
        case (0, let behind): return behind == 1 ? String(localized: " (1 commit back)") : String(localized: " (\(behind) commits back)")
        default: return String(localized: " (\(distance.ahead) ahead, \(distance.behind) behind)")
        }
    }

    /// How far a staged or committed move goes, when the submodule has both commits.
    private func loadDistance() async {
        commitDistance = nil
        guard let repository = model.repository, let move, let old = move.old, let new = move.new, old != new,
              submodule?.state != .notInitialized else { return }
        if case .working = change, status?.commitChanged == true { return }   // model.submoduleDistances has it
        commitDistance = await repository.submoduleDistance(path, recorded: old, checkedOut: new)
    }
}
