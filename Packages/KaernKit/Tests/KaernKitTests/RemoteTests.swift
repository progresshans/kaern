import Foundation
import Testing
@testable import KaernKit

@Suite("Remote URLs and failures")
struct RemoteTests {
    @Test func parsesHTTPSAndSSHRemotes() throws {
        let https = try #require(RemoteURL("https://progresshans@github.com/progresshans/powerlens.git"))
        #expect(https.scheme == .https)
        #expect(https.user == "progresshans")
        #expect(https.host == "github.com")
        #expect(https.path == "progresshans/powerlens.git")
        #expect(https.sshEquivalent == "git@github.com:progresshans/powerlens.git")

        let scp = try #require(RemoteURL("git@github.com:progresshans/powerlens"))
        #expect(scp.isSSH)
        #expect(scp.user == "git")
        #expect(scp.host == "github.com")
        #expect(scp.httpsEquivalent == "https://github.com/progresshans/powerlens.git")

        let ssh = try #require(RemoteURL("ssh://git@gitlab.example.com:2222/team/app.git"))
        #expect(ssh.isSSH)
        #expect(ssh.host == "gitlab.example.com")
        #expect(ssh.path == "team/app.git")

        #expect(RemoteURL("/Users/me/src/repo") == nil)
        #expect(RemoteURL("../other") == nil)
    }

    @Test func classifiesRemoteFailures() {
        #expect(RemoteFailure.classify("remote: Invalid username or token. Password authentication is not supported for Git operations.\nfatal: Authentication failed for 'https://github.com/o/r.git/'") == .authentication(overSSH: false))
        #expect(RemoteFailure.classify("fatal: could not read Username for 'https://github.com': terminal prompts disabled") == .authentication(overSSH: false))
        #expect(RemoteFailure.classify("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.") == .authentication(overSSH: true))
        #expect(RemoteFailure.classify("Host key verification failed.\nfatal: Could not read from remote repository.") == .unknownHostKey)
        #expect(RemoteFailure.classify("fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com") == .unreachable)
        #expect(RemoteFailure.classify("ssh: Could not resolve hostname github.com: nodename nor servname provided") == .unreachable)
        #expect(RemoteFailure.classify("error: RPC failed; curl 28 Operation too slow. Less than 1000 bytes/sec transferred the last 30 seconds") == .unreachable)
        #expect(RemoteFailure.classify(" ! [rejected]        main -> main (fetch first)") == .other)
    }
}
