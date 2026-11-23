#!/usr/bin/env python3
"""Builds the sample repositories for checking Kaern phase 2 against the WindowBase board.

powerlens gets the board's history commit for commit (same order, authors, bodies, branches,
tags, merges), so the graph can be compared row by row. Every git call runs with the user's
config switched off (GIT_CONFIG_GLOBAL=/dev/null, GIT_CONFIG_NOSYSTEM=1).
"""
import os
import shutil
import subprocess
import sys
import time

# Where the samples go: --root <folder> (samples.py builds each scenario into its cache), else next to this file.
ROOT = (os.path.abspath(sys.argv[sys.argv.index('--root') + 1]) if '--root' in sys.argv
        else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'samples'))
GIT = subprocess.run(['xcrun', '--find', 'git'], capture_output=True, text=True).stdout.strip() or '/usr/bin/git'
BASE_ENV = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')

# Addresses picked so Kaern's avatar palette gives the board's colors (blue, teal, rust).
PEOPLE = {
    'HH': ('Han Hyeonjin', 'hanhyeonjin@kaern.invalid'),
    'MP': ('Minji Park', 'minji.dev@kaern.invalid'),
    'SL': ('Sungho Lee', 'sungho@kaern.test'),
}


def git(cwd, *args, who='HH', when=None, stdin=None, env_extra=None, check=True):
    name, email = PEOPLE[who]
    env = dict(BASE_ENV)
    env.update({
        'GIT_AUTHOR_NAME': name, 'GIT_AUTHOR_EMAIL': email,
        'GIT_COMMITTER_NAME': name, 'GIT_COMMITTER_EMAIL': email,
    })
    if when is not None:
        env['GIT_AUTHOR_DATE'] = env['GIT_COMMITTER_DATE'] = '@%d +0900' % when
    if env_extra:
        env.update(env_extra)
    result = subprocess.run([GIT, '-c', 'init.defaultBranch=main', '-c', 'commit.gpgsign=false',
                             '-c', 'tag.gpgsign=false', '-c', 'user.name=' + name, '-c', 'user.email=' + email] + list(args),
                            cwd=cwd, env=env, input=stdin, capture_output=True, text=True)
    if check and result.returncode != 0:
        sys.exit('git %s failed in %s:\n%s' % (' '.join(args), cwd, result.stderr))
    return result.stdout.strip()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write(text)


def lines(prefix, count, start=1):
    return ''.join('%s %d\n' % (prefix, start + k) for k in range(count))


# ---------------------------------------------------------------------------------------------
# File contents of the working-copy changes (old = committed, new = on disk)

ALPHA_OLD = '''import Foundation

/// A pre-release version such as v0.9.3-alpha.7.
///
/// Alpha builds are published from tags. The release workflow reads the
/// tag, bumps the alpha number and writes the appcast entry.
///
/// See docs/RELEASE_CHECKLIST.md for the manual steps.

// MARK: - Version

struct AlphaVersion: Comparable {
    let marketing: String
    let build: Int

    init?(tag: String) {
        let parts = tag.split(separator: "-")
        guard parts.count == 2 else { return nil }
        marketing = String(parts[0])
        build = Int(parts[1].dropFirst(5)) ?? 0
    }

    init(marketing: String, build: Int) {
        self.marketing = marketing
        self.build = build
    }

    var tag: String { "v\\(marketing)-alpha.\\(build)" }

    static func < (lhs: AlphaVersion, rhs: AlphaVersion) -> Bool {
        if lhs.marketing != rhs.marketing {
            return lhs.marketing.compare(rhs.marketing, options: .numeric) == .orderedAscending
        }
        return lhs.build < rhs.build
    }
}

// MARK: - Next version

extension AlphaVersion {
    func next() -> AlphaVersion {
        AlphaVersion(marketing: marketing, build: build + 1)
    }
}
'''

ALPHA_NEW = ALPHA_OLD.replace('''    let build: Int

    init?(tag: String) {
        let parts = tag.split(separator: "-")
        guard parts.count == 2 else { return nil }
        marketing = String(parts[0])
        build = Int(parts[1].dropFirst(5)) ?? 0
    }''', '''    let alpha: Int

    init?(tag: String) {
        let pattern = /^v?(\\d+\\.\\d+\\.\\d+)-alpha\\.(\\d+)$/
        guard let match = tag.wholeMatch(of: pattern) else { return nil }
        marketing = String(match.1)
        alpha = Int(match.2) ?? 0
    }''').replace('''    init(marketing: String, build: Int) {
        self.marketing = marketing
        self.build = build
    }

    var tag: String { "v\\(marketing)-alpha.\\(build)" }''', '''    init(marketing: String, alpha: Int) {
        self.marketing = marketing
        self.alpha = alpha
    }

    var tag: String { "v\\(marketing)-alpha.\\(alpha)" }''').replace('''        return lhs.build < rhs.build''', '''        return lhs.alpha < rhs.alpha''').replace('''    func next() -> AlphaVersion {
        AlphaVersion(marketing: marketing, build: build + 1)
    }''', '''    /// Alpha numbers restart at 1 whenever the marketing version changes.
    func next(for marketingVersion: String) -> AlphaVersion {
        guard marketingVersion == marketing else {
            return AlphaVersion(marketing: marketingVersion, alpha: 1)
        }
        return AlphaVersion(marketing: marketing, alpha: alpha + 1)
    }''')

ALPHA_TESTS = '''import Testing
@testable import PowerLens

struct AlphaVersionTests {
    @Test func restartsWhenTheMarketingVersionChanges() {
        let current = AlphaVersion(tag: "v0.9.3-alpha.7")!
        #expect(current.next(for: "0.9.4").tag == "v0.9.4-alpha.1")
    }

    @Test func incrementsWithinTheSameVersion() {
        let current = AlphaVersion(tag: "v0.9.3-alpha.7")!
        #expect(current.next(for: "0.9.3").tag == "v0.9.3-alpha.8")
    }
}
'''

RELEASE_OLD = '''name: release
on:
  push:
    tags: ["v*"]

permissions:
  contents: write

concurrency:
  group: release
  cancel-in-progress: false

env:
  DEVELOPER_DIR: /Applications/Xcode_26.app

jobs:
  publish:
    runs-on: macos-15
    timeout-minutes: 40
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Build
        run: script/build_release.sh
      - name: Resolve version
        id: version
        run: script/resolve_release_metadata.sh
      - name: Publish
        if: startsWith(github.ref, 'refs/tags/v')
        run: script/publish_github_release.sh
'''

RELEASE_NEW = RELEASE_OLD.replace('''        run: script/resolve_release_metadata.sh
      - name: Publish
        if: startsWith(github.ref, 'refs/tags/v')''', '''        run: script/resolve_release_metadata.sh --channel alpha
        env:
          RELEASE_CHANNEL: alpha
      - name: Publish
        if: startsWith(github.ref, 'refs/tags/v') && !contains(github.ref, '-beta')''')

CI_OLD = '''name: ci
on:
  pull_request:
  push:
    branches: [develop, main]

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - run: swift test
      - name: Lint
        run: swift format lint --recursive Sources Tests
'''

CI_NEW = CI_OLD.replace('''      - uses: actions/checkout@v4
      - run: swift test''', '''      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Test
        run: swift test --parallel''')

CONTRIB_OLD = '''# Contributing to PowerLens

Thanks for helping out. PowerLens is a small menu bar app, so most changes are small too.

## Getting started

1. Clone the repository.
2. Open Package.swift in Xcode.
3. Run the PowerLens scheme.

## Branches

Work on a feature branch and open a pull request against develop.
Releases are cut from develop and merged into main.

## Code style

We use swift-format with the settings in .swift-format.
Run `swift format --in-place --recursive Sources Tests` before you push.

## Tests

Every bug fix needs a test.
New features need tests for the edge cases you can think of.

## Reporting issues

Use the issue templates. Include your macOS version and Mac model.
'''

CONTRIB_NEW = CONTRIB_OLD.replace('''Work on a feature branch and open a pull request against develop.
Releases are cut from develop and merged into main.''', '''Work on a feature branch named feature/<topic> or fix/<topic> and open a pull
request against develop. Keep pull requests focused: one change, one review.
Releases are cut from develop and merged into main by a maintainer.

### Commit messages

Start the summary with a type: feat, fix, refactor, chore or docs.
Keep the summary under 72 characters and explain the why in the body.''').replace('''Every bug fix needs a test.
New features need tests for the edge cases you can think of.''', '''Every bug fix needs a test that fails without the fix.
New features need tests for the edge cases you can think of.
Hardware-dependent code goes behind a protocol so tests can use fakes.

Run the whole suite with `swift test --parallel` before opening a pull request.''')

CHECK_OLD = '''# Release checklist

## Before tagging

- [ ] develop is green on CI
- [ ] CHANGELOG.md has an entry for the version
- [ ] The version in Info.plist matches the tag

## Tagging

- [ ] Tag the merge commit on main as vX.Y.Z
- [ ] Push the tag

## After the release

- [ ] Check the appcast in a clean user account
- [ ] Announce the release
'''

CHECK_NEW = CHECK_OLD.replace('''- [ ] Push the tag
''', '''- [ ] Push the tag

## Alpha builds

- [ ] Tag the commit on develop as vX.Y.Z-alpha.N
- [ ] The release workflow builds, signs and publishes the update
- [ ] Alpha numbers restart at 1 for each new marketing version
- [ ] Check the alpha feed with a build that has the alpha channel on
''')

PKG_README_OLD = '''# Packaging

PowerLens ships as a notarized, signed disk image.

## Requirements

- Xcode 26 or later
- A Developer ID Application certificate
- notarytool credentials stored in the keychain

## Building

Run script/build_release.sh. It archives, exports and staples the app.

## Notes

The legacy publishing script is kept for 0.8 updates.
'''

PKG_README_NEW = PKG_README_OLD.replace('''## Notes

The legacy publishing script is kept for 0.8 updates.''', '''## Publishing

Tags matching v*-alpha.* publish to the alpha feed, other v* tags to the
stable feed. The workflow signs the appcast with the EdDSA key stored in
the SPARKLE_PRIVATE_KEY secret.

## Notes

The legacy publishing script is gone; 0.8 users update through the stable
feed like everyone else.''')

GEN_OLD = '#!/usr/bin/env bash\n# Generates release notes from merged pull requests.\nset -euo pipefail\n\n' + \
    ''.join('step_%02d() { echo "step %d"; }\n' % (k, k) for k in range(1, 31)) + \
    '\nVERSION=$(git describe --tags)\nCHANNEL=stable\necho "Publishing $VERSION"\n' + \
    ''.join('step_%02d\n' % k for k in range(1, 7))
GEN_NEW = GEN_OLD.replace('VERSION=$(git describe --tags)\nCHANNEL=stable\n', 'VERSION=$(git describe --tags --match "v*")\nCHANNEL=${1:-stable}\n' +
                          ''.join('if [[ "$CHANNEL" == alpha ]]; then step_%02d; fi\n' % k for k in range(1, 17))) \
    .replace(''.join('step_%02d\n' % k for k in range(1, 7)), ''.join('step_%02d\n' % k for k in range(1, 3)))

TEST_GEN_OLD = '#!/usr/bin/env bash\n# Tests for generate_release_notes.sh\nset -euo pipefail\n\n' + \
    ''.join('test_case_%02d() { [[ -n "%d" ]]; }\n' % (k, k) for k in range(1, 21)) + \
    '\n' + ''.join('test_case_%02d\n' % k for k in range(1, 5)) + 'echo ok\n'
TEST_GEN_NEW = TEST_GEN_OLD.replace(''.join('test_case_%02d\n' % k for k in range(1, 5)),
                                    ''.join('test_case_%02d\n' % k for k in range(1, 21)) + 'test_alpha_channel\ntest_restart_numbering\n')

RESOLVED_OLD = '''{
  "originHash" : "5f4c3b2a",
  "pins" : [
    {
      "identity" : "sparkle",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/sparkle-project/Sparkle",
      "state" : {
        "revision" : "0ef1ee0220239b3776f433314515fd849025673f",
        "version" : "2.6.4"
      }
    }
  ],
  "version" : 3
}
'''
RESOLVED_NEW = RESOLVED_OLD.replace('"revision" : "0ef1ee0220239b3776f433314515fd849025673f",\n        "version" : "2.6.4"',
                                    '"revision" : "9a1d2ec7b0c3e6f4a5d8b1c2e3f4a5b6c7d8e9f0",\n        "version" : "2.7.1"')

PUBLISH = '#!/usr/bin/env bash\n# Publishes a GitHub release for the current tag.\nset -euo pipefail\n\n' + \
    ''.join('publish_step_%02d() { echo "publish %d"; }\n' % (k, k) for k in range(1, 61))
RESOLVE = '#!/usr/bin/env bash\n# Prints the version, channel and build number for a tag.\nset -euo pipefail\n\n' + \
    ''.join('resolve_%02d() { echo "resolve %d"; }\n' % (k, k) for k in range(1, 38))
LEGACY = '#!/usr/bin/env bash\n# Old publishing script (0.8).\nset -euo pipefail\n\n' + \
    ''.join('legacy_%02d() { echo "legacy %d"; }\n' % (k, k) for k in range(1, 55))

CHANNEL_OLD = '''import Foundation

/// Where updates come from.
///
/// Alpha builds read their own feed.
enum ReleaseChannel: String, CaseIterable {
    // Channels
    case stable
    case alpha

    var feedName: String { rawValue }

    static var current: ReleaseChannel { .stable }
}

extension ReleaseChannel: Identifiable {
    var id: String { rawValue }
}
'''

CHANNEL_NEW = CHANNEL_OLD.replace('''    var feedName: String { rawValue }

    static var current: ReleaseChannel { .stable }''', '''    var feedName: String {
        switch self {
        case .stable: "appcast"
        case .alpha: "alpha"
        }
    }

    static var current: ReleaseChannel {
        Bundle.main.isAlphaBuild ? .alpha : .stable
    }''')

# ---------------------------------------------------------------------------------------------
# The board's history, newest first: (subject, author, body, files changed {path: content})


def stub(name, subject):
    return 'import Foundation\n\n/// %s\nstruct %s {\n    var isEnabled = true\n}\n' % (subject, name)


HISTORY = [
    ('feat: reorganize settings navigation', 'MP', 'Group the sidebar by task and move release settings under Advanced.',
     {'Sources/PowerLens/Settings/SettingsSidebar.swift': stub('SettingsSidebar', 'Settings grouped by task.')}),
    ('fix: reset alpha numbering per version', 'HH', 'Alpha builds pick the feed from the release channel, and the counter restarts at 1 when the version changes.',
     {'Sources/PowerLens/Release/ReleaseChannel.swift': CHANNEL_NEW,
      'Sources/PowerLens/Release/ReleaseFeed.swift': stub('ReleaseFeed', 'The feed for the current channel.')}),
    ('fix: restore automatic alpha releases', 'HH', 'Tags matching v*-alpha.* publish again after the channel split.',
     {'.github/workflows/release.yml': RELEASE_OLD}),
    ('feat: sign the Sparkle appcast with EdDSA', 'HH', '',
     {'Sources/PowerLens/Updates/AppcastSigner.swift': stub('AppcastSigner', 'Signs the appcast with EdDSA.')}),
    ('feat: present managed charging states', 'MP', 'Show when macOS holds the charge at 80% and why.',
     {'Sources/PowerLens/Charging/ManagedChargingView.swift': stub('ManagedChargingView', 'Managed charging states.')}),
    ('feat: add an alpha channel to the release feed', 'HH', '',
     {'Sources/PowerLens/Release/ReleaseChannel.swift': CHANNEL_OLD}),
    ('chore: bump develop after 0.9.3-alpha.7', 'HH', '', {'VERSION': '0.9.3\n'}),
    ('chore: add contribution and security workflows', 'MP', '',
     {'CONTRIBUTING.md': CONTRIB_OLD, 'SECURITY.md': '# Security\n\nReport issues to security@powerlens.invalid.\n'}),
    ('chore: harden release packaging and automation', 'HH', 'Notarize in CI and fail the job when stapling does not succeed.',
     {'Packaging/README.md': PKG_README_OLD, 'script/build_release.sh': '#!/usr/bin/env bash\nset -euo pipefail\nxcodebuild archive\n'}),
    ('Merge pull request #10 from feature/charge-limit-awareness', 'HH', '', None),
    ('fix: reject voltage-less sensor mismatches', 'MP', '',
     {'Sources/PowerLens/Sensors/SensorMatcher.swift': stub('SensorMatcher', 'Rejects mismatches without voltage.')}),
    ('fix: retain approximation markers at zero', 'MP', '',
     {'Sources/PowerLens/Sensors/Approximation.swift': stub('Approximation', 'Keeps markers at zero.')}),
    ('feat: improve telemetry and history reliability', 'HH', 'Write history in batches and recover the store after a crash.',
     {'Sources/PowerLens/Telemetry/HistoryStore.swift': stub('HistoryStore', 'Batched history writes.')}),
    ('refactor: centralize power delivery transitions', 'SL', '',
     {'Sources/PowerLens/Power/PowerDelivery.swift': stub('PowerDelivery', 'One place for transitions.')}),
    ('fix: append power provenance to CSV exports', 'SL', '',
     {'Sources/PowerLens/Export/CSVExport.swift': stub('CSVExport', 'Exports with provenance.')}),
    ('Merge pull request #9 from fix/power-provenance', 'HH', '', None),
    ('fix: preserve confirmed shortfalls through recovery', 'SL', '',
     {'Sources/PowerLens/Power/Shortfall.swift': stub('Shortfall', 'Confirmed shortfalls survive recovery.')}),
    ('chore: tag 0.9.3-alpha.6', 'HH', '', {'VERSION': '0.9.3-alpha.6\n'}),
    ('chore: formalize Apple silicon-only distribution', 'HH', '',
     {'docs/RELEASE_CHECKLIST.md': CHECK_OLD, 'Package.resolved': RESOLVED_OLD}),
    ('fix: stabilize managed charging state transitions', 'MP', '',
     {'Sources/PowerLens/Charging/ChargeState.swift': stub('ChargeState', 'Stable transitions.')}),
    ('fix: guard against a missing battery serial', 'HH', '',
     {'Sources/PowerLens/Battery/BatterySerial.swift': stub('BatterySerial', 'Missing serials are handled.')}),
    ('fix: handle Objective-C BOOL return encodings', 'HH', '',
     {'Sources/PowerLens/Bridge/ObjCBool.swift': stub('ObjCBoolBridge', 'BOOL encodings.')}),
    ('Merge pull request #7 from develop', 'HH', '', None),
    ('chore: finalize the 0.9.2 changelog', 'MP', '', {'CHANGELOG.md': '# Changelog\n\n## 0.9.2\n\n- Charging policies\n'}),
    ('fix: guard startup when the helper is missing', 'HH', '',
     {'Sources/PowerLens/Helper/HelperCheck.swift': stub('HelperCheck', 'Startup without the helper.')}),
    ('feat: observe macOS charging policies', 'SL', '',
     {'README.md': '# PowerLens\n\nA menu bar app that explains what your Mac does with power.\n',
      'Sources/PowerLens/Release/AlphaVersion.swift': ALPHA_OLD,
      '.github/workflows/ci.yml': CI_OLD,
      'script/generate_release_notes.sh': GEN_OLD,
      'script/test_generate_release_notes.sh': TEST_GEN_OLD,
      'script/legacy_publish.sh': LEGACY,
      'Sources/PowerLens/Charging/ChargePolicy.swift': stub('ChargePolicy', 'Observes charging policies.')}),
]

# First parent and second parent by row (None: root). Rows are newest first.
PARENTS = {
    0: [4], 1: [2], 2: [5], 3: [6], 4: [5], 5: [6], 6: [7], 7: [8], 8: [9], 9: [12, 10],
    10: [11], 11: [12], 12: [13], 13: [14], 14: [15], 15: [17, 16], 16: [17], 17: [18],
    18: [19], 19: [20], 20: [21], 21: [22], 22: [25, 23], 23: [24], 24: [25], 25: [],
}


def board_dates(now):
    """Commit times, newest first, like the board's dates (2 hours ago … Sep 11)."""
    import datetime
    day = 86400
    today = datetime.datetime.fromtimestamp(now)
    yesterday = today - datetime.timedelta(days=1)

    def at(d, hour, minute=0):
        return int(datetime.datetime(d.year, d.month, d.day, hour, minute).timestamp())

    def sep(day_of_month, hour):
        return int(datetime.datetime(2026, 9, day_of_month, hour, 0).timestamp())

    dates = [now - 2 * 3600, now - 3 * 3600, now - 5 * 3600, now - 8 * 3600,
            at(yesterday, 18, 40), at(yesterday, 15, 5), at(yesterday, 10, 20),
            sep(27, 17), sep(27, 13), sep(27, 11),
            sep(26, 18), sep(26, 15), sep(26, 11),
            sep(25, 17), sep(25, 14), sep(25, 11),
            sep(24, 16), sep(24, 11), sep(23, 15), sep(21, 15), sep(20, 15), sep(19, 15),
            sep(14, 15), sep(13, 15), sep(12, 15), sep(11, 15)]
    # Shortly after midnight "8 hours ago" is older than yesterday evening: keep the order.
    for index in range(1, len(dates)):
        if dates[index] >= dates[index - 1]:
            dates[index] = dates[index - 1] - 3600
    return dates


def build_powerlens():
    path = os.path.join(ROOT, 'powerlens')
    git(ROOT, 'init', '-q', path)
    index = os.path.join(path, '.git', 'kaern-build-index')
    env = {'GIT_INDEX_FILE': index}
    dates = board_dates(int(time.time()))
    ids = {}
    for row in range(len(HISTORY) - 1, -1, -1):
        subject, who, body, files = HISTORY[row]
        parents = [ids[p] for p in PARENTS[row]]
        if files is None:
            # A merge: git merge-tree writes the combined tree (the sides touch different files).
            tree = git(path, 'merge-tree', '--write-tree', parents[0], parents[1]).split('\n')[0]
        else:
            if parents:
                git(path, 'read-tree', parents[0], env_extra=env)
            else:
                git(path, 'read-tree', '--empty', env_extra=env)
            for file_path, content in files.items():
                blob = git(path, 'hash-object', '-w', '--stdin', stdin=content)
                mode = '100755' if file_path.endswith('.sh') else '100644'
                git(path, 'update-index', '--add', '--cacheinfo', '%s,%s,%s' % (mode, blob, file_path), env_extra=env)
            tree = git(path, 'write-tree', env_extra=env)
        message = subject + ('\n\n' + body if body else '') + '\n'
        args = ['commit-tree', tree]
        for parent in parents:
            args += ['-p', parent]
        ids[row] = git(path, *args, who=who, when=dates[row], stdin=message)
    os.remove(index)

    refs = {
        'refs/heads/feature/reliability-and-release': 0,
        'refs/heads/feature/restore-automatic-alpha': 1,
        'refs/heads/feature/harden-sparkle-releases': 3,
        'refs/heads/develop': 6,
        'refs/heads/feature/charge-limit-awareness': 10,
        'refs/heads/main': 20,
    }
    for ref, row in refs.items():
        git(path, 'update-ref', ref, ids[row])
    git(path, 'tag', 'v0.9.3-alpha.7', ids[12])
    git(path, 'tag', '-a', 'v0.9.3-alpha.6', '-m', '0.9.3 alpha 6', ids[17], when=dates[17])
    git(path, 'tag', 'v0.9.2', ids[22])
    git(path, 'symbolic-ref', 'HEAD', 'refs/heads/feature/restore-automatic-alpha')
    git(path, 'reset', '-q', '--hard')

    # origin with three branches at the board's remote labels
    remote = os.path.join(ROOT, 'remotes', 'powerlens.git')
    git(ROOT, 'init', '-q', '--bare', remote)
    git(path, 'remote', 'add', 'origin', remote)
    git(path, 'push', '-q', 'origin', ids[5] + ':refs/heads/feature/restore-automatic-alpha',
        ids[8] + ':refs/heads/develop', ids[16] + ':refs/heads/fix/power-provenance')
    git(path, 'fetch', '-q', 'origin')
    git(path, 'branch', '-q', '-u', 'origin/feature/restore-automatic-alpha', 'feature/restore-automatic-alpha')
    git(path, 'branch', '-q', '-u', 'origin/develop', 'develop')

    # A stash made on develop ("On develop: release notes"), without touching the work tree's branch.
    git(path, 'switch', '-q', 'develop')
    write(os.path.join(path, 'NOTES.md'), 'release notes draft\n')
    git(path, 'add', 'NOTES.md')
    git(path, 'stash', 'push', '-q', '-m', 'release notes', when=dates[10])
    git(path, 'switch', '-q', 'feature/restore-automatic-alpha')

    # A second worktree (detached at the alpha 7 tag, so the graph keeps the board's labels).
    git(path, 'worktree', 'add', '-q', '--detach', os.path.join(ROOT, 'powerlens-hotfix'), 'v0.9.3-alpha.7')

    # Uncommitted changes: 3 staged files, 10 unstaged ones (two new, one deleted).
    def put(rel, text):
        write(os.path.join(path, rel), text)
    put('Sources/PowerLens/Release/AlphaVersion.swift', ALPHA_NEW)
    put('Tests/PowerLensTests/AlphaVersionTests.swift', ALPHA_TESTS)
    put('.github/workflows/release.yml', RELEASE_NEW)
    git(path, 'add', 'Sources/PowerLens/Release/AlphaVersion.swift', 'Tests/PowerLensTests/AlphaVersionTests.swift',
        '.github/workflows/release.yml')
    put('.github/workflows/ci.yml', CI_NEW)
    put('CONTRIBUTING.md', CONTRIB_NEW)
    put('docs/RELEASE_CHECKLIST.md', CHECK_NEW)
    put('Packaging/README.md', PKG_README_NEW)
    put('script/generate_release_notes.sh', GEN_NEW)
    put('script/publish_github_release.sh', PUBLISH)
    put('script/resolve_release_metadata.sh', RESOLVE)
    os.remove(os.path.join(path, 'script/legacy_publish.sh'))
    put('script/test_generate_release_notes.sh', TEST_GEN_NEW)
    put('Package.resolved', RESOLVED_NEW)
    return ids


def simple(name, count, branch=None, change=False):
    path = os.path.join(ROOT, name)
    git(ROOT, 'init', '-q', path)
    base = int(time.time()) - 86400 * 12
    for k in range(1, count + 1):
        write(os.path.join(path, 'CHANGELOG.md'), lines('feat: step', k))
        git(path, 'add', '-A')
        git(path, 'commit', '-q', '-m', 'feat: step %d of %s' % (k, name), when=base + k * 3600 * 5)
    if branch:
        git(path, 'switch', '-q', '-c', branch)
    if change:
        with open(os.path.join(path, 'CHANGELOG.md'), 'a', encoding='utf-8') as handle:
            handle.write('change\n')


def build_rebasing():
    path = os.path.join(ROOT, 'quiz-app')
    git(ROOT, 'init', '-q', path)
    write(os.path.join(path, 'base.txt'), 'base\n')
    git(path, 'add', '-A')
    git(path, 'commit', '-q', '-m', 'base')
    git(path, 'switch', '-q', '-c', 'topic')
    write(os.path.join(path, 'conflict.txt'), 'topic\n')
    git(path, 'add', '-A')
    git(path, 'commit', '-q', '-m', 'topic change')
    git(path, 'switch', '-q', 'main')
    write(os.path.join(path, 'conflict.txt'), 'main\n')
    git(path, 'add', '-A')
    git(path, 'commit', '-q', '-m', 'main change')
    git(path, 'switch', '-q', 'topic')
    git(path, 'rebase', 'main', check=False)


# ---------------------------------------------------------------------------------------------
# Phase 3 scenarios (ScreenFlowPush): run with --scenario first-push | force-push | hook | slow

def commit_on(path, parent, files, subject, who='HH', when=None):
    """A commit on top of `parent` with `files` changed, made with a scratch index (the real index
    and working tree are left alone)."""
    index = os.path.join(path, '.git', 'kaern-scenario-index')
    env = {'GIT_INDEX_FILE': index}
    git(path, 'read-tree', parent, env_extra=env)
    for file_path, content in files.items():
        blob = git(path, 'hash-object', '-w', '--stdin', stdin=content)
        git(path, 'update-index', '--add', '--cacheinfo', '100644,%s,%s' % (blob, file_path), env_extra=env)
    tree = git(path, 'write-tree', env_extra=env)
    os.remove(index)
    return git(path, 'commit-tree', tree, '-p', parent, who=who, when=when, stdin=subject + '\n')


def scenario_first_push(path):
    """A new branch with one commit and no upstream (첫 Push), plus a second remote to pick."""
    notes = '# 0.9.4-alpha.1\n\n- Alpha numbering restarts at 1 for each version.\n- Release builds pick the alpha feed again.\n'
    head = git(path, 'rev-parse', 'HEAD')
    commit = commit_on(path, head, {'docs/release-notes/0.9.4-alpha.1.md': notes},
                       'docs: draft release notes for 0.9.4-alpha.1', when=int(time.time()) - 60)
    git(path, 'update-ref', 'refs/heads/feature/alpha-release-notes', commit)
    git(path, 'symbolic-ref', 'HEAD', 'refs/heads/feature/alpha-release-notes')
    write(os.path.join(path, 'docs/release-notes/0.9.4-alpha.1.md'), notes)
    git(path, 'add', 'docs/release-notes/0.9.4-alpha.1.md')
    upstream = os.path.join(ROOT, 'remotes', 'powerlens-upstream.git')
    git(ROOT, 'init', '-q', '--bare', upstream)
    git(path, 'remote', 'add', 'upstream', upstream)


def scenario_force_push(path, ids):
    """The branch rewrote two commits that are on origin (Force Push): origin has their old
    versions, and the branch's reflog shows it had them."""
    now = int(time.time())
    tree2 = git(path, 'rev-parse', ids[2] + '^{tree}')
    tree1 = git(path, 'rev-parse', ids[1] + '^{tree}')
    old2 = git(path, 'commit-tree', tree2, '-p', ids[5], when=now - 9 * 3600, stdin='fix: restore automatic alpha releases\n')
    old1 = git(path, 'commit-tree', tree1, '-p', old2, when=now - 7 * 3600, stdin='fix: reset alpha numbering per version\n')
    git(path, 'push', '-q', '--force', 'origin', old1 + ':refs/heads/feature/restore-automatic-alpha')
    git(path, 'fetch', '-q', 'origin')
    branch = 'refs/heads/feature/restore-automatic-alpha'
    git(path, 'update-ref', '-m', 'pull: fast-forward', branch, old1)
    git(path, 'update-ref', '-m', 'rebase (finish): onto ' + ids[5], branch, ids[1])


HOOK_TOOL = '''#!/bin/sh
sleep 1.4
if [ -f "MARKER" ]; then exit 0; fi
touch "MARKER"
echo "Sources/PowerLens/Release/AlphaVersion.swift:44:1: error: [TrailingWhitespace] remove trailing whitespace"
echo "Tests/PowerLensTests/AlphaVersionTests.swift:12:9: error: [NeverForceUnwrap] do not force unwrap AlphaVersion(tag:)"
echo "Sources/PowerLens/Release/AlphaVersion.swift:31:1: warning: [OrderedImports] sort import statements lexicographically"
exit 1
'''


def scenario_hook(path):
    """A pre-commit hook that runs a stand-in for swift-format: it fails once with two errors
    and a warning, then passes."""
    hooks = os.path.join(path, '.git', 'hooks')
    tool_dir = os.path.join(hooks, 'bin')
    os.makedirs(tool_dir, exist_ok=True)
    marker = os.path.join(path, '.git', 'kaern-hook-failed-once')
    tool = os.path.join(tool_dir, 'swift-format')
    write(tool, HOOK_TOOL.replace('MARKER', marker))
    os.chmod(tool, 0o755)
    hook = os.path.join(hooks, 'pre-commit')
    write(hook, '#!/usr/bin/env -S PATH=%s:/usr/bin:/bin sh\nswift-format lint --strict --recursive Sources Tests\n' % tool_dir)
    os.chmod(hook, 0o755)


def scenario_slow(path):
    """A remote that takes 40 s and fails: `fetch` then shows a running command in the Command Log."""
    git(path, 'config', 'protocol.ext.allow', 'always')
    git(path, 'remote', 'add', 'mirror', 'ext::sh -c sleep% 40')


# ---------------------------------------------------------------------------------------------
# Phase 4 scenarios: --scenario conflict | stash-conflict

def conflicting(parent, child, mark='develop'):
    """`parent` with the lines `child` changed changed another way, so a 3-way merge conflicts."""
    import difflib
    p = parent.split('\n')
    c = child.split('\n')
    out = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, p, c).get_opcodes():
        if tag == 'equal':
            out += p[i1:i2]
        elif tag in ('replace', 'delete'):
            out += [line + ('  // %s' % mark if line.strip() else '') for line in p[i1:i2]]
        else:
            out.append('// %s: kept as it was' % mark)
    return '\n'.join(out)


def commit_wip(path):
    """Commits the three staged files on the feature branch and drops the rest of the changes."""
    git(path, 'commit', '-q', '-m', 'fix: alpha numbering for release builds', when=int(time.time()) - 900)
    git(path, 'reset', '-q', '--hard')
    git(path, 'clean', '-qfd')


ALPHA_TESTS_DEVELOP = 'import Testing\n\n@Suite struct AlphaVersionTests {\n    @Test func parsesTags() {\n        #expect(AlphaVersion(tag: "v0.9.3-alpha.7") != nil)\n    }\n}\n'


def scenario_conflict(path, ids):
    """Rebasing the feature branch onto develop stops at its 4th commit with two conflicts
    (AlphaVersion.swift, AlphaVersionTests.swift); release.yml merges on its own."""
    commit_wip(path)
    develop = commit_on(path, ids[6], {
        'Sources/PowerLens/Release/AlphaVersion.swift': conflicting(ALPHA_OLD, ALPHA_NEW),
        'Tests/PowerLensTests/AlphaVersionTests.swift': ALPHA_TESTS_DEVELOP,
        'docs/RELEASE_CHECKLIST.md': CHECK_OLD + '\n- [ ] Notarization log attached\n',
    }, 'chore: harden alpha numbering on develop', when=int(time.time()) - 1800)
    git(path, 'update-ref', 'refs/heads/develop', develop)


def scenario_stash_conflict(path, ids):
    """A stash made one commit back changes AlphaVersion.swift's lines another way: popping it stops
    on a conflict (ScreenStash's 'Before reset to c92aa17')."""
    commit_wip(path)
    git(path, 'switch', '-q', '--detach', 'HEAD~1')
    write(os.path.join(path, 'Sources/PowerLens/Release/AlphaVersion.swift'), conflicting(ALPHA_OLD, ALPHA_NEW, 'stash'))
    write(os.path.join(path, 'docs/NOTES.md'), 'Notes kept with the stash.\n')
    git(path, 'add', 'docs/NOTES.md')
    git(path, 'stash', 'push', '-q', '-m', 'Before reset to %s' % ids[2][:7], when=int(time.time()) - 3600)
    git(path, 'switch', '-q', 'feature/restore-automatic-alpha')


def main():
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(os.path.join(ROOT, 'remotes'))
    ids = build_powerlens()
    powerlens = os.path.join(ROOT, 'powerlens')
    scenario = sys.argv[sys.argv.index('--scenario') + 1] if '--scenario' in sys.argv else 'base'
    if scenario == 'first-push':
        scenario_first_push(powerlens)
    elif scenario == 'force-push':
        scenario_force_push(powerlens, ids)
    elif scenario == 'hook':
        scenario_hook(powerlens)
    elif scenario == 'slow':
        scenario_slow(powerlens)
    elif scenario == 'conflict':
        scenario_conflict(powerlens, ids)
    elif scenario == 'stash-conflict':
        scenario_stash_conflict(powerlens, ids)
    simple('cluster-config', 6, 'develop', change=True)
    simple('recipe-box', 4, change=True)
    simple('recipe-app', 3, 'feature/onboarding')
    simple('orders-api', 8, change=True)
    simple('travel-notes', 2)
    simple('CRM', 3)
    simple('weather-dashboard-app', 5, 'feature/billing-export', change=True)
    simple('weather-mobile-app', 4, 'release/2.4')
    simple('travel-blog', 2, 'draft/kaern-intro')
    build_rebasing()
    print('samples in', ROOT)


if __name__ == '__main__':
    main()
