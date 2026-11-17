import Foundation

/// Suggests the next version tag from the existing ones, for the New Tag sheet:
/// `v0.9.3-alpha.7` → `v0.9.3-alpha.8`; after `v0.9.3` (with alphas before it) → `v0.9.4-alpha.1`.
public enum TagNaming {
    struct Version: Comparable {
        var prefix: String
        var major: Int
        var minor: Int
        var patch: Int
        /// `alpha`, `beta`, `rc`… (`nil` for a release).
        var label: String?
        var number: Int?

        static func < (lhs: Version, rhs: Version) -> Bool {
            if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
                return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
            }
            // A release sorts after its prereleases.
            switch (lhs.label, rhs.label) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            default:
                if lhs.label != rhs.label { return lhs.label! < rhs.label! }
                return (lhs.number ?? 0) < (rhs.number ?? 0)
            }
        }

        var name: String {
            var text = "\(prefix)\(major).\(minor).\(patch)"
            if let label { text += "-\(label)" + (number.map { ".\($0)" } ?? "") }
            return text
        }
    }

    static func parse(_ tag: String) -> Version? {
        var rest = Substring(tag)
        var prefix = ""
        if rest.first == "v" || rest.first == "V" {
            prefix = String(rest.first!)
            rest = rest.dropFirst()
        }
        // Nothing left after the prefix ("v"), or only a dash ("v-"): not a version.
        let parts = rest.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".")
        guard numbers.count == 3, let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]) else {
            return nil
        }
        var version = Version(prefix: prefix, major: major, minor: minor, patch: patch)
        if parts.count == 2 {
            let pre = parts[1].split(separator: ".")
            guard let label = pre.first, label.allSatisfy(\.isLetter) else { return nil }
            version.label = String(label)
            if pre.count == 2 {
                guard let number = Int(pre[1]) else { return nil }
                version.number = number
            } else if pre.count > 2 {
                return nil
            }
        }
        return version
    }

    /// The next tag name, or `nil` when there are no version tags.
    public static func suggestion(after tags: [String]) -> String? {
        let versions = tags.compactMap(parse)
        guard var latest = versions.max() else { return nil }
        if latest.label != nil {
            latest.number = (latest.number ?? 0) + 1
            return latest.name
        }
        latest.patch += 1
        // Keep going with prereleases if that's how this project tags.
        let lastPrerelease = versions.filter { $0.label != nil }.max()
        if let lastPrerelease {
            latest.label = lastPrerelease.label
            latest.number = 1
        }
        return latest.name
    }
}
