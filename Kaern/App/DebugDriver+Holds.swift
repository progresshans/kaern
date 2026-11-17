#if DEBUG
import Foundation

/// Debug commands that make a refresh wait, so a check can put what git read on one side of an
/// action and what the model does with it on the other. That's the order a race needs, set up
/// on purpose instead of waited for:
///
///     hold status       a refresh's `git status` waits once git has answered, before it's shown
///                       (a first load's too)
///     hold decide       a refresh waits once everything it read is shown, before the screens
///                       conclude anything from it (the conflict bar and editor, the stash view)
///     hold statusNow    the status read right after a change waits once git has answered
///     hold decideNow    that read waits once its status is shown, before what follows from it
///                       (the conflict editor opening after a stop on conflicts)
///     hold lineStats    the next read of the line counts waits once git has answered, before they're
///                       shown (that one only: reads after it go on)
///     release [point]   what waits there goes on, and the point isn't held anymore
///                       (every point when none is named)
///     refresh           a full refresh of the shown repository, as when Kaern becomes active
///
/// `hold` is for the shown repository, or with a folder after the point (`hold status <folder>`)
/// for the repository there, which may be opened afterwards: its first load then waits. A point
/// stays held until it's released. `release`
/// is for every repository, so a refresh held in a tab that was switched away from or closed
/// since doesn't wait for ever. `dump` lists the points where something waits now in the shown
/// repository as `driver.holding`.
extension DebugDriver {
    static let holdCommands: Set<String> = ["hold", "release", "refresh"]

    func holds(_ command: String, _ args: [String]) {
        let point = args.first.flatMap(RepositoryModel.DebugHold.init(rawValue:))
        if command == "release" {
            // A name that isn't a point releases nothing (a typo shouldn't let everything go).
            if args.isEmpty || point != nil { DebugHolds.shared.release(point) }
            return
        }
        if command == "hold", args.count > 1, let point {
            DebugHolds.shared.hold(point, in: args.dropFirst().joined(separator: " "))
            return
        }
        guard let window, let tab = window.activeTab else { return }
        let repository = app.repository(for: tab.path)
        switch command {
        case "hold":
            if let point { DebugHolds.shared.hold(point, in: repository.id) }
        case "refresh":
            repository.refreshAfterActivation()
        default:
            break
        }
    }
}

extension RepositoryModel {
    /// Where the debug driver can make a refresh wait (`hold <point>`).
    enum DebugHold: String, CaseIterable {
        case status, decide, statusNow, decideNow, lineStats
    }

    /// Waits while the debug driver holds `point`; returns at once when it doesn't.
    func debugHold(_ point: DebugHold) async {
        await DebugHolds.shared.wait(at: point, in: id)
    }
}

/// The points the debug driver holds, by repository, and what waits at each.
@MainActor
final class DebugHolds {
    static let shared = DebugHolds()

    private var held: [String: Set<RepositoryModel.DebugHold>] = [:]
    private var waiting: [String: [RepositoryModel.DebugHold: [CheckedContinuation<Void, Never>]]] = [:]

    func hold(_ point: RepositoryModel.DebugHold, in repository: String) {
        held[repository, default: []].insert(point)
    }

    /// Stops holding `point` (every point when `nil`) in every repository and lets what waits
    /// there go on.
    func release(_ point: RepositoryModel.DebugHold?) {
        let points = point.map { [$0] } ?? RepositoryModel.DebugHold.allCases
        for repository in Set(held.keys).union(waiting.keys) {
            for point in points {
                held[repository]?.remove(point)
                for continuation in waiting[repository]?.removeValue(forKey: point) ?? [] {
                    continuation.resume()
                }
            }
        }
    }

    func wait(at point: RepositoryModel.DebugHold, in repository: String) async {
        guard held[repository]?.contains(point) == true else { return }
        // `lineStats` holds the next read only: the ones after it, which a check makes overlap it,
        // go on.
        if point == .lineStats { held[repository]?.remove(point) }
        await withCheckedContinuation { continuation in
            waiting[repository, default: [:]][point, default: []].append(continuation)
        }
    }

    /// The points where something waits now.
    func waiting(in repository: String) -> [String] {
        (waiting[repository] ?? [:]).filter { !$0.value.isEmpty }.map(\.key.rawValue).sorted()
    }
}
#endif
