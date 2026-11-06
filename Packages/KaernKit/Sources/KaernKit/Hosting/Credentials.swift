import Foundation

// MARK: - Credentials outside a repository (Settings › Accounts)

extension GitRunner {
    /// `credential.helper` from the user's and the system's config.
    public func credentialHelpers() async -> [String] {
        guard let output = try? await run(["config", "--get-all", "credential.helper"], in: nil, acceptedStatus: [0, 1]) else { return [] }
        return output.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Hands a token to git's credential helpers (`git credential approve`): the Keychain item
    /// Terminal's git uses too. Kaern keeps no copy.
    public func approveCredential(host: String, username: String, secret: String) async throws {
        let input = "protocol=https\nhost=\(host)\nusername=\(username)\npassword=\(secret)\n\n"
        let helper: [String] = await credentialHelpers().isEmpty ? ["-c", "credential.helper=osxkeychain"] : []
        try await run(helper + ["credential", "approve"], in: nil, input: Data(input.utf8))
    }

    /// The token git's helpers have for `username` at `host` (`git credential fill`), `nil`
    /// when there's none. Never prompts: git's terminal prompts are off.
    public func credential(host: String, username: String) async -> String? {
        let input = "protocol=https\nhost=\(host)\nusername=\(username)\n\n"
        let helper: [String] = await credentialHelpers().isEmpty ? ["-c", "credential.helper=osxkeychain"] : []
        guard let output = try? await run(helper + ["credential", "fill"], in: nil, input: Data(input.utf8)) else { return nil }
        for line in output.text.split(separator: "\n") where line.hasPrefix("password=") {
            let secret = String(line.dropFirst("password=".count))
            return secret.isEmpty ? nil : secret
        }
        return nil
    }

    /// Removes the stored token (`git credential reject`).
    public func rejectCredential(host: String, username: String) async {
        let input = "protocol=https\nhost=\(host)\nusername=\(username)\n\n"
        let helper: [String] = await credentialHelpers().isEmpty ? ["-c", "credential.helper=osxkeychain"] : []
        _ = try? await run(helper + ["credential", "reject"], in: nil, input: Data(input.utf8))
    }
}

/// Who a GitLab token belongs to (`GET /api/v4/user`).
public enum GitLabClient {
    public static func user(host: String, token: String, baseURL: URL? = nil) async throws -> HostingUser {
        let url = (baseURL ?? URL(string: "https://\(host)/api/v4")!).appending(path: "user")
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("Kaern", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw HostingError(status: status, message: HTTPURLResponse.localizedString(forStatusCode: status))
        }
        struct User: Decodable {
            var username: String
            var name: String?
            var id: Int?
            var email: String?
            var publicEmail: String?
            enum CodingKeys: String, CodingKey {
                case username, name, id, email
                case publicEmail = "public_email"
            }
        }
        let user = try JSONDecoder().decode(User.self, from: data)
        return HostingUser(login: user.username, name: user.name, id: nil, email: user.publicEmail ?? user.email)
    }
}
