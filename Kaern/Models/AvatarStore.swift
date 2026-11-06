import AppKit
import KaernKit
import SwiftUI

/// GitHub avatars for commit authors (Settings › General › Show GitHub avatars).
///
/// GitHub's no-reply addresses (`12345+login@users.noreply.github.com`) name the account
/// themselves. For other addresses Kaern asks GitHub which accounts made a repository's latest
/// commits: with the token from Settings › Accounts when there is one, otherwise as a guest,
/// which works for public repositories. Only the repository's name goes to GitHub. Initials
/// stand in until an avatar arrives, and when there's none.
@MainActor @Observable
final class AvatarStore {
    static let shared = AvatarStore()

    /// Bumped when an avatar (or the address of one) arrives, so views and tables redraw.
    private(set) var version = 0

    @ObservationIgnored private var avatarURLs: [String: URL] = [:]
    @ObservationIgnored private var images: [URL: NSImage] = [:]
    @ObservationIgnored private var failedImages: Set<URL> = []
    @ObservationIgnored private var loadingImages: Set<URL> = []
    @ObservationIgnored private var primedRepositories: Set<String> = []
    @ObservationIgnored private var askedCommits: Set<String> = []
    /// One-commit lookups per launch: GitHub allows a guest 60 requests an hour.
    @ObservationIgnored private var lookupsLeft = 30

    private init() {}

    /// The avatar for `email` when it's here (no loading: see ``request(_:)``).
    func image(for email: String) -> NSImage? {
        guard Preferences.showAvatars, let url = avatarURL(for: email) else { return nil }
        return images[url]
    }

    /// Starts loading the avatar for `email`, when GitHub's address for it is known.
    func request(_ email: String) {
        guard Preferences.showAvatars, let url = avatarURL(for: email) else { return }
        load(url)
    }

    private func load(_ url: URL) {
        guard images[url] == nil, !loadingImages.contains(url), !failedImages.contains(url) else { return }
        loadingImages.insert(url)
        Task {
            var image: NSImage?
            if let result = try? await URLSession.shared.data(from: url),
               (result.1 as? HTTPURLResponse)?.statusCode == 200 {
                image = NSImage(data: result.0)
            }
            loadingImages.remove(url)
            if let image {
                images[url] = image
                version += 1
            } else {
                failedImages.insert(url)
            }
        }
    }

    /// Once per repository and launch: who made its latest hundred commits (one request).
    func prime(_ remote: RemoteURL?) {
        guard Preferences.showAvatars, let remote, !remote.repositoryPath.isEmpty, Self.isGitHub(remote) else { return }
        let key = "\(remote.host.lowercased())/\(remote.repositoryPath.lowercased())"
        guard primedRepositories.insert(key).inserted else { return }
        Task {
            guard let client = await Self.client(for: remote),
                  let avatars = try? await client.commitAvatars(remote.repositoryPath) else { return }
            add(avatars)
        }
    }

    /// An author the latest commits didn't cover: ask GitHub about this commit alone.
    func lookUp(email: String, commit: String, remote: RemoteURL?) {
        guard Preferences.showAvatars, let remote, !remote.repositoryPath.isEmpty, Self.isGitHub(remote),
              avatarURL(for: email) == nil, lookupsLeft > 0, askedCommits.insert(commit).inserted else { return }
        lookupsLeft -= 1
        Task {
            guard let client = await Self.client(for: remote),
                  let avatars = try? await client.commitAvatars(remote.repositoryPath, sha: commit) else { return }
            add(avatars)
            request(email)
        }
    }

    /// A GitHub account's avatar by its address (pull request authors), loading it if needed.
    func image(at url: URL) -> NSImage? {
        guard Preferences.showAvatars else { return nil }
        let sized = Self.sized(url)
        if let image = images[sized] { return image }
        load(sized)
        return nil
    }

    /// Settings › General › Show GitHub avatars changed.
    func settingChanged() {
        version += 1
    }

    // MARK: Private

    private func avatarURL(for email: String) -> URL? {
        let key = email.lowercased()
        if let url = avatarURLs[key] { return url }
        guard let url = Self.noreplyAvatar(key) else { return nil }
        avatarURLs[key] = url
        return url
    }

    private func add(_ avatars: [String: URL]) {
        var changed = false
        for (email, url) in avatars where avatarURLs[email] == nil {
            avatarURLs[email] = Self.sized(url)
            changed = true
        }
        if changed { version += 1 }
    }

    /// `12345+login@users.noreply.github.com`, or the older `login@users.noreply.github.com`.
    static func noreplyAvatar(_ email: String) -> URL? {
        let suffix = "@users.noreply.github.com"
        guard email.hasSuffix(suffix) else { return nil }
        let local = email.dropLast(suffix.count)
        if let plus = local.firstIndex(of: "+"), let id = Int(local[..<plus]) {
            return URL(string: "https://avatars.githubusercontent.com/u/\(id)?v=4&s=80")
        }
        guard !local.isEmpty, local.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return URL(string: "https://github.com/\(local).png?size=80")
    }

    /// 80 px: sharp at the 40 pt the inspector shows on Retina screens.
    private static func sized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "s" }
        items.append(URLQueryItem(name: "s", value: "80"))
        components.queryItems = items
        return components.url ?? url
    }

    private static func isGitHub(_ remote: RemoteURL) -> Bool {
        remote.host.lowercased() == "github.com" || AppModel.shared.account(forHost: remote.host)?.kind == .github
    }

    /// With the token of the Settings › Accounts account for the host, when there is one.
    private static func client(for remote: RemoteURL) async -> GitHubClient? {
        if let account = AppModel.shared.account(forHost: remote.host), account.kind == .github {
            let token = await AppModel.shared.token(for: account) ?? ""
            return GitHubClient(baseURL: account.apiURL, token: token)
        }
        guard remote.host.lowercased() == "github.com" else { return nil }
        return GitHubClient(baseURL: GitHubClient.apiURL(for: remote.host), token: "")
    }
}

/// A commit author's GitHub avatar, or their initials in a gray circle.
struct AuthorAvatar: View {
    let name: String
    let email: String
    var size: CGFloat = 28
    /// Asks GitHub about this commit when the latest ones didn't cover its author.
    var commitID: String?
    var remote: RemoteURL?

    var body: some View {
        let store = AvatarStore.shared
        let _ = store.version
        Group {
            if let image = store.image(for: email) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .accessibilityHidden(true)
            } else {
                AvatarView(initials: Signature(name: name, email: email, date: .now).initials, size: size)
            }
        }
        .task(id: "\(email)|\(commitID ?? "")") {
            store.request(email)
            if let commitID { store.lookUp(email: email, commit: commitID, remote: remote) }
        }
    }
}

/// A pull request author's avatar (GitHub sends its address with the pull request).
struct AccountAvatar: View {
    let login: String
    let url: URL?
    var size: CGFloat = 28

    var body: some View {
        let store = AvatarStore.shared
        let _ = store.version
        if let url, let image = store.image(at: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .accessibilityHidden(true)
        } else {
            AvatarView(initials: String(login.prefix(2)).uppercased(), size: size)
        }
    }
}

extension AvatarStore {
    /// A small round avatar for the history's Author column, or the author's initials.
    func columnImage(name: String, email: String, size: CGFloat) -> NSImage {
        if let image = image(for: email) {
            return Self.circular(image, size: size)
        }
        request(email)
        return Self.initials(Signature(name: name, email: email, date: .now).initials, size: size)
    }

    private static let circleCache = NSCache<NSString, NSImage>()

    private static func circular(_ image: NSImage, size: CGFloat) -> NSImage {
        let key = "\(ObjectIdentifier(image).hashValue)-\(size)" as NSString
        if let cached = circleCache.object(forKey: key) { return cached }
        let result = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
            return true
        }
        circleCache.setObject(result, forKey: key)
        return result
    }

    private static func initials(_ text: String, size: CGFloat) -> NSImage {
        let key = "initials-\(text)-\(size)" as NSString
        if let cached = circleCache.object(forKey: key) { return cached }
        let result = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.systemGray.withAlphaComponent(0.75).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let font = NSFont.systemFont(ofSize: size * 0.42, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let string = text as NSString
            let textSize = string.size(withAttributes: attributes)
            string.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
            return true
        }
        circleCache.setObject(result, forKey: key)
        return result
    }
}
