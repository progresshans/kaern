import Foundation
import KaernKit
import Observation

/// Every git command Kaern ran this launch, for Window › Command Log. KaernKit reports each
/// command as it starts, prints progress and ends, with secrets already masked.
@MainActor @Observable
final class CommandLog {
    static let shared = CommandLog()

    struct Entry: Identifiable {
        var record: GitCommandRecord
        /// Progress lines of a network command, newest last.
        var progress: [String] = []
        /// The repository the command ran in ("powerlens").
        var repository: String

        var id: UUID { record.id }
        var isBackground: Bool { record.isBackground }
    }

    /// Oldest first.
    private(set) var entries: [Entry] = []
    @ObservationIgnored private var handles: [UUID: GitCommandHandle] = [:]
    @ObservationIgnored private var positions: [UUID: Int] = [:]
    @ObservationIgnored private var removed = 0

    /// How many entries are kept: background ones go first when there are more.
    static let limit = 3_000

    /// The callback for `GitRunner(onCommand:)`: hops to the main thread in order.
    nonisolated static func receive(_ event: GitCommandEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { CommandLog.shared.handle(event) }
        }
    }

    func handle(_ event: GitCommandEvent) {
        switch event {
        case .started(let record, let stop):
            positions[record.id] = removed + entries.count
            entries.append(Entry(record: record, repository: Self.repositoryName(record.directory)))
            if !record.isBackground { handles[record.id] = stop }
            trim()
        case .progress(let id, let line):
            guard let index = index(of: id) else { return }
            entries[index].progress.append(line)
            if entries[index].progress.count > 200 { entries[index].progress.removeFirst(100) }
        case .finished(let record):
            handles[record.id] = nil
            if let index = index(of: record.id) {
                entries[index].record = record
            } else {
                positions[record.id] = removed + entries.count
                entries.append(Entry(record: record, repository: Self.repositoryName(record.directory)))
            }
        }
    }

    /// Stop on a running command (it ends with "stopped", not an error alert).
    func stop(_ id: UUID) {
        handles[id]?.stop()
    }

    func canStop(_ id: UUID) -> Bool { handles[id] != nil }

    private func index(of id: UUID) -> Int? {
        guard let position = positions[id] else { return nil }
        let index = position - removed
        guard entries.indices.contains(index), entries[index].id == id else {
            return entries.lastIndex { $0.id == id }
        }
        return index
    }

    private func trim() {
        guard entries.count > Self.limit else { return }
        // Drop the oldest finished background commands first, then the oldest of all.
        let excess = entries.count - Self.limit
        var dropped = 0
        var kept: [Entry] = []
        kept.reserveCapacity(entries.count)
        for entry in entries {
            if dropped < excess, entry.isBackground, !entry.record.isRunning {
                positions[entry.id] = nil
                dropped += 1
            } else {
                kept.append(entry)
            }
        }
        if kept.count > Self.limit {
            for entry in kept.prefix(kept.count - Self.limit) { positions[entry.id] = nil }
            kept.removeFirst(kept.count - Self.limit)
        }
        entries = kept
        // Positions are rebuilt after a trim.
        removed = 0
        positions.removeAll(keepingCapacity: true)
        for (index, entry) in entries.enumerated() { positions[entry.id] = index }
    }

    /// The repository a command ran in: an open tab's name when the folder is one, else the folder.
    private static func repositoryName(_ directory: String) -> String {
        let path = directory.hasSuffix("/") && directory.count > 1 ? String(directory.dropLast()) : directory
        return path.isEmpty ? "Kaern" : (path as NSString).lastPathComponent
    }
}
