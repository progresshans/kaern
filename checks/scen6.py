"""Phase-6 sample states made with git in the scratch samples (isolated config).

many_remotes, many_changes and marks_sample take the samples folder to work in (`root`, this run's by
default): samples.py builds them once into its cache (kinds remotes-3000, changes-3000, signed) and a check
takes a copy with big_remotes(), big_changes() or launch_prepared(scenario='signed')."""
import os, random, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *

WHO = {'Han Hyeonjin': 'hanhyeonjin@kaern.invalid', 'Mina Park': 'mina@kaern.invalid', 'Sungho Lee': 'sungho@kaern.invalid'}

def run(cwd, *args, who='Han Hyeonjin', stdin=None, when=None):
    env = dict(ENV, GIT_AUTHOR_NAME=who, GIT_COMMITTER_NAME=who, GIT_AUTHOR_EMAIL=WHO.get(who, 'x@kaern.invalid'),
               GIT_COMMITTER_EMAIL=WHO.get(who, 'x@kaern.invalid'))
    if when:
        env['GIT_AUTHOR_DATE'] = env['GIT_COMMITTER_DATE'] = when
    r = subprocess.run([GIT] + list(args), cwd=cwd, env=env, capture_output=True, text=True, input=stdin)
    if r.returncode != 0: raise SystemExit('git %s failed: %s' % (' '.join(args), r.stderr))
    return r.stdout.strip()

# ScreenBigRepo › 브랜치 1,243개: the prefixes and how many remote branches each has.
FOLDERS = [('dependabot', 134), ('env', 6), ('feature', 236), ('hotfix', 12), ('release', 41), ('renovate', 812)]
NAMED = {
    'dependabot': ['github_actions/actions/cache-4.1.2', 'github_actions/docker/build-push-action-6.10.0', 'npm_and_yarn/docs/cross-spawn-7.0.5'],
    'env': ['expo-preview', 'orders-staging', 'gateway-perf', 'billing-qa', 'search-load', 'powerlens-beta'],
    'feature': ['orders-staging', 'gateway-canary', 'billing-batch-ns', 'search-hpa', 'powerlens-eu', 'argo-notifications'],
    'hotfix': ['gateway-oom', 'orders-cert', 'billing-dns'],
    'renovate': ['argocd-2.x', 'cert-manager-1.x', 'ingress-nginx-4.x', 'kube-prometheus-stack-66.x', 'loki-6.x', 'release-drafter-6.x'],
}
# Commits only these remote branches have (newest in the repository, so "all branches" shows them on top).
REMOTE_ONLY = {'env/expo-preview': 'feat(recipes): add an expo preview environment', 'feature/powerlens-eu': 'feat(powerlens): serve the feed from eu-central-1'}
LOCAL_ONLY = 'feat(orders): add a staging overlay for the scheduler'

def release_names():
    names = []
    for y in range(41):
        mo, yr = 11 - y, 2026
        while mo < 1: mo, yr = mo + 12, yr - 1
        names.append('%d.%02d%s' % (yr, mo, '-hotfix%d' % (y % 3 + 1) if y > 11 else ''))
    return names

def many_remotes(name='cluster-config', root=None):
    """Gives samples/<name> (a bigsample) an origin with 1,243 branches in six prefix folders plus main and
    develop, two of them with commits no local branch has, origin/HEAD -> origin/main, and local
    branches like the board's (feature/orders-staging one commit ahead, release/2026.11)."""
    root = root or SAMPLES
    repo = os.path.join(root, name)
    bare = os.path.join(root, 'remotes', name + '.git')
    subprocess.run(['rm', '-rf', bare], check=True)
    os.makedirs(os.path.dirname(bare), exist_ok=True)
    run(root, 'clone', '-q', '--bare', repo, bare)
    commits = run(repo, 'rev-list', '--first-parent', 'main').split('\n')
    random.seed(11)
    lines = []
    for prefix, count in FOLDERS:
        names = release_names() if prefix == 'release' else list(NAMED.get(prefix, []))
        while len(names) < count:
            names.append('%s-%04d' % ({'dependabot': 'npm_and_yarn/bump', 'feature': 'topic', 'hotfix': 'fix', 'renovate': 'chart'}[prefix], len(names)))
        for n in names[:count]:
            lines.append('update refs/heads/%s/%s %s' % (prefix, n, random.choice(commits[20:])))
    run(bare, 'update-ref', '--stdin', stdin='\n'.join(lines) + '\n')
    tree = run(repo, 'rev-parse', 'main^{tree}')
    when = 1_800_000_000
    for branch, subject in REMOTE_ONLY.items():
        when += 60
        tip = run(repo, 'commit-tree', tree, '-p', commits[2], '-m', subject, who='Sungho Lee', when='%d +0900' % when)
        # commit-tree wrote the object in the sample; the bare remote needs it too.
        run(repo, 'push', '-q', bare, '%s:refs/heads/%s' % (tip, branch))
    run(repo, 'remote', 'add', 'origin', bare)
    run(repo, 'fetch', '-q', 'origin')
    run(repo, 'remote', 'set-head', 'origin', 'main')
    run(repo, 'branch', '-q', '--set-upstream-to=origin/main', 'main')
    run(repo, 'branch', '-q', 'release/2026.11', 'main~40')
    run(repo, 'branch', '-q', 'feature/gateway-canary', 'main~25')
    # A local branch with a commit of its own (no upstream), dated newest.
    tip = run(repo, 'commit-tree', tree, '-p', commits[0], '-m', LOCAL_ONLY, who='Han Hyeonjin', when='%d +0900' % (when + 60))
    run(repo, 'branch', '-q', 'feature/orders-staging', tip)
    return len(run(repo, 'for-each-ref', 'refs/remotes').split('\n'))

def pull_behind(name='powerlens', subjects=('fix: guard the feed against empty alpha tags', 'docs: note the alpha channel in the changelog'),
                files=None):
    """Pushes commits to the current branch's upstream from another clone (who: Mina Park), then fetches,
    so samples/<name> is behind (and still ahead by its own commits)."""
    repo = os.path.join(SAMPLES, name)
    branch = run(repo, 'branch', '--show-current')
    upstream = run(repo, 'rev-parse', '--abbrev-ref', '@{u}')
    remote, remote_branch = upstream.split('/', 1)
    url = run(repo, 'remote', 'get-url', remote)
    other = os.path.join(SAMPLES, 'remotes', name + '-pull')
    subprocess.run(['rm', '-rf', other], check=True)
    run(SAMPLES, 'clone', '-q', '-b', remote_branch, url, other)
    for i, subject in enumerate(subjects):
        path, text = (files or {}).get(i, ('theirs-%d.txt' % i, 'theirs %d\n' % i))
        full = os.path.join(other, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        open(full, 'w').write(text)
        run(other, 'add', '-A')
        run(other, 'commit', '-q', '-m', subject, who='Mina Park')
    run(other, 'push', '-q', 'origin', 'HEAD:' + remote_branch)
    run(repo, 'fetch', '-q', remote)
    return branch, run(repo, 'rev-list', '--left-right', '--count', 'HEAD...@{u}')

def many_changes(name='cluster-config', root=None):
    """ScreenBigRepo › 변경 파일 1만 개: 12,408 changed files in samples/<name> — 11,920 new ones under charts/vendor/
    (a vendored chart nobody ignored), 312 under apps/orders/, 164 under clusters/prod/ and 12 in docs/."""
    repo = os.path.join(root or SAMPLES, name)
    def put(rel, text):
        full = os.path.join(repo, rel); os.makedirs(os.path.dirname(full), exist_ok=True); open(full, 'w').write(text)
    # Tracked first, changed afterwards (M), plus a few new files (A).
    for i in range(309):
        put('apps/orders/base/svc-%03d.yaml' % i, 'name: svc-%d\nreplicas: 1\n' % i)
    put('apps/orders/base/scheduler.yaml', 'name: scheduler\nreplicas: 1\n')
    put('apps/orders/base/api.yaml', 'name: api\nreplicas: 1\n')
    for i in range(162):
        put('clusters/prod/apps/app-%03d/values.yaml' % i, 'image: app-%d:1.0\n' % i)
    put('clusters/prod/apps.yaml', 'apps: []\n')
    put('clusters/prod/apps/orders-api/values.yaml', 'image: orders-api:1.0\n')
    run(repo, 'add', '-A', 'apps', 'clusters')
    run(repo, 'commit', '-q', '-m', 'chore: add the orders app and the prod cluster')
    for i in range(309):
        put('apps/orders/base/svc-%03d.yaml' % i, 'name: svc-%d\nreplicas: 2\n' % i)
    put('apps/orders/base/scheduler.yaml', 'name: scheduler\nreplicas: 2\nschedule: "*/5 * * * *"\n')
    put('apps/orders/base/api.yaml', 'name: api\nreplicas: 3\n')
    put('apps/orders/overlays/staging/kustomization.yaml', 'resources:\n  - ../../base\n')
    for i in range(162):
        put('clusters/prod/apps/app-%03d/values.yaml' % i, 'image: app-%d:1.1\n' % i)
    put('clusters/prod/apps.yaml', 'apps: [orders-api]\n')
    put('clusters/prod/apps/orders-api/values.yaml', 'image: orders-api:1.1\n')
    for i in range(12):
        with open(os.path.join(repo, 'docs', 'notes-%d.md' % (i + 2)), 'a') as f: f.write('more\n')
    n = 0
    for chart in range(40):
        for t in range(298):
            put('charts/vendor/chart-%02d/templates/t-%03d.yaml' % (chart, t), 'kind: ConfigMap\n')
            n += 1
    return n

def launch6(mode='light', scenario='base', prepare=None, extra=(), drop=()):
    """launch_prepared without the launch arguments named in `drop` (a setting a check changes must not be a
    launch argument, or the argument wins)."""
    return launch_prepared(mode, scenario, prepare, extra, drop)


def big_remotes(name='cluster-config'):
    """samples/<name> as many_remotes leaves a 3,000-commit bigsample, with its origin in samples/remotes
    (a copy from the cache). Returns how many remote refs it has."""
    assert name == samples.BIG_NAME
    samples.install('remotes-3000', SAMPLES)
    return len(g(os.path.join(SAMPLES, name), 'for-each-ref', 'refs/remotes').split('\n'))


def big_changes(name='cluster-config'):
    """samples/<name> as many_changes leaves a 3,000-commit bigsample: 12,409 changed files (a copy from the cache)."""
    assert name == samples.BIG_NAME
    samples.install('changes-3000', SAMPLES)


KEYS = os.path.join(SAMPLES, 'keys')

def ssh_key(name, keys=None):
    keys = keys or KEYS
    os.makedirs(keys, exist_ok=True)
    path = os.path.join(keys, name)
    if not os.path.exists(path):
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', name, '-f', path], check=True)
    return path

def raw(cwd, *args, stdin=None, env=None):
    r = subprocess.run([GIT] + list(args), cwd=cwd, env=env or ENV, capture_output=True, input=stdin)
    if r.returncode != 0: raise SystemExit('git %s failed: %s' % (' '.join(args), r.stderr.decode()))
    return r.stdout

def ident(line):
    # "Name <email> 1758000000 +0900"
    name, rest = line.split(' <', 1)
    email, date = rest.split('> ', 1)
    return name, email, date

SIGNED_BAD = 'fix: append power provenance to CSV exports'
SIGNED_UNTRUSTED = 'feat: present managed charging states'

def marks_sample(name='powerlens', root=None):
    """ScreenMarks › 서명 and 워크트리 in samples/<name>: the history again, SSH-signed like the board — Han and
    Minji with keys in the allowed signers (verified), merges by a GitHub key (verified), 'feat: present managed
    charging states' with a key of Minji's that isn't listed (signed, not verified), Sungho unsigned except
    'fix: append power provenance to CSV exports', whose signature no longer matches (bad). The worktree
    powerlens-hotfix gets hotfix/0.9.3.1 at 'chore: formalize Apple silicon-only distribution' with 2 changes."""
    root = root or SAMPLES
    keys = os.path.join(root, 'keys')
    repo = os.path.join(root, name)
    han, minji, laptop, sungho, github = [ssh_key(k, keys) for k in ('han', 'minji', 'minji-laptop', 'sungho', 'github')]
    allowed = os.path.join(keys, 'allowed_signers')
    with open(allowed, 'w') as f:
        for principal, key in (('hanhyeonjin@kaern.invalid', han), ('minji.dev@kaern.invalid', minji), ('noreply@github.com', github)):
            f.write('%s %s\n' % (principal, open(key + '.pub').read().strip()))
    run(repo, 'config', 'gpg.ssh.allowedSignersFile', allowed)
    revs = run(repo, 'rev-list', '--topo-order', '--reverse', '--branches', '--remotes', '--tags').split()
    mapping = {}
    for old in revs:
        headers, message = raw(repo, 'cat-file', 'commit', old).split(b'\n\n', 1)
        tree, parents, author, committer = None, [], None, None
        for line in headers.decode().split('\n'):
            if line.startswith('tree '): tree = line[5:]
            elif line.startswith('parent '): parents.append(line[7:])
            elif line.startswith('author '): author = line[7:]
            elif line.startswith('committer '): committer = line[10:]
        subject = message.decode().split('\n')[0]
        aname, aemail, adate = ident(author); cname, cemail, cdate = ident(committer)
        if subject.startswith('Merge pull request'): key = github
        elif subject == SIGNED_UNTRUSTED: key = laptop
        elif subject == SIGNED_BAD: key = sungho
        elif aname == 'Han Hyeonjin': key = han
        elif aname == 'Minji Park': key = minji
        else: key = None
        env = dict(ENV, GIT_AUTHOR_NAME=aname, GIT_AUTHOR_EMAIL=aemail, GIT_AUTHOR_DATE=adate,
                   GIT_COMMITTER_NAME=cname, GIT_COMMITTER_EMAIL=cemail, GIT_COMMITTER_DATE=cdate)
        args = ['-c', 'gpg.format=ssh'] + (['-c', 'user.signingkey=' + key + '.pub'] if key else []) + ['commit-tree', tree]
        for p in parents: args += ['-p', mapping.get(p, p)]
        if key: args.append('-S')
        new = raw(repo, *args, stdin=message, env=env).decode().strip()
        if subject == SIGNED_BAD:
            # The author's time moves a second after signing: the signature no longer matches.
            obj = raw(repo, 'cat-file', 'commit', new).decode()
            stamp = adate.split(' ')[0]
            obj = obj.replace(' %s ' % stamp, ' %d ' % (int(stamp) + 1), 1)
            new = raw(repo, 'hash-object', '-t', 'commit', '-w', '--stdin', stdin=obj.encode()).decode().strip()
        mapping[old] = new
    for line in run(repo, 'for-each-ref', '--format=%(refname) %(objecttype) %(objectname)', 'refs/heads', 'refs/remotes', 'refs/tags').split('\n'):
        ref, kind, obj = line.split(' ')
        if ref.endswith('/HEAD'): continue
        if kind == 'commit':
            run(repo, 'update-ref', ref, mapping.get(obj, obj))
        elif kind == 'tag':
            text = raw(repo, 'cat-file', 'tag', obj).decode()
            target = text.split('\n')[0].split(' ')[1]
            tag = raw(repo, 'hash-object', '-t', 'tag', '-w', '--stdin', stdin=text.replace(target, mapping.get(target, target), 1).encode()).decode().strip()
            run(repo, 'update-ref', ref, tag)
    # The remote has the same history again.
    for line in run(repo, 'for-each-ref', '--format=%(refname:strip=3)', 'refs/remotes/origin').split('\n'):
        if line and line != 'HEAD':
            run(repo, 'push', '-q', '--force', 'origin', 'refs/remotes/origin/%s:refs/heads/%s' % (line, line))
    # The worktree: hotfix/0.9.3.1 with two changes.
    tree_dir = os.path.join(root, name + '-hotfix')
    git_dir = run(tree_dir, 'rev-parse', '--git-dir')
    head_file = os.path.join(tree_dir, git_dir, 'HEAD') if not os.path.isabs(git_dir) else os.path.join(git_dir, 'HEAD')
    old_head = open(head_file).read().strip()
    open(head_file, 'w').write(mapping.get(old_head, old_head) + '\n')
    formalize = [new for old, new in mapping.items() if run(repo, 'log', '-1', '--format=%s', new) == 'chore: formalize Apple silicon-only distribution'][0]
    run(tree_dir, 'checkout', '-q', '-f', '-b', 'hotfix/0.9.3.1', formalize)
    swift = sorted(f for f in run(tree_dir, 'ls-files', 'Sources').split('\n') if f.endswith('.swift'))
    feed = os.path.join(tree_dir, swift[-1])
    lines = open(feed).read().split('\n')
    open(feed, 'w').write('\n'.join(lines[:-3] + ['    // hotfix: retry the feed once', '    var retries = 1', '    var timeout = 30', '    var cache = true', '    var region = "eu"', '    var mirror = ""'] + lines[-1:]))
    with open(os.path.join(tree_dir, 'CHANGELOG.md'), 'a') as f: f.write('\n## 0.9.3.1\n- Retry the release feed once\n- Keep the cache\n')
    return mapping
