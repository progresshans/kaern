"""bigsample.py <samples dir> <name> <commits> — the history of a deployment repository, with bot runs (git fast-import);
'feat: the needle commit to find' sits about 92% of the way down."""
import os, subprocess, sys, random
root, name, total = sys.argv[1], sys.argv[2], int(sys.argv[3])
GIT = subprocess.run(['xcrun', '--find', 'git'], capture_output=True, text=True).stdout.strip()
ENV = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
repo = os.path.join(root, name)
os.makedirs(repo, exist_ok=True)
subprocess.run([GIT, 'init', '-q', '-b', 'main', repo], env=ENV, check=True)
random.seed(7)
people = [('Han Hyeonjin', 'hanhyeonjin@kaern.invalid'), ('Mina Park', 'mina@kaern.invalid'), ('Sungho Lee', 'sungho@kaern.invalid'), ('Jiwoo Kim', 'jiwoo@kaern.invalid')]
apps = ['orders-api', 'orders-web', 'powerlens-feed', 'billing-batch', 'search-worker', 'edge-gateway']
deps = ['ingress-nginx', 'argocd', 'loki', 'argo-rollouts', 'cert-manager', 'external-dns']
human = ['fix(gateway): raise the memory limit', 'feat(search): enable HPA for the worker', 'docs: runbook for rolling back an Argo CD sync',
         'chore(release): cut the release', 'fix(powerlens): pin the feed region', 'feat(billing): add a preview environment', 'chore: rotate the sealed-secrets key']
out = []
mark = 0
when = 1_790_000_000
version = {a: [1, 0, 0] for a in apps}
def commit(author, subject, path, body):
    global mark, when
    mark += 1
    when += 600
    n, e = author
    data = body.encode(); msg = subject.encode()
    out.append(b'commit refs/heads/main\nmark :%d\nauthor %s <%s> %d +0000\ncommitter %s <%s> %d +0000\ndata %d\n%s\n' % (
        mark, n.encode(), e.encode(), when, n.encode(), e.encode(), when, len(msg), msg))
    if mark > 1: out.append(b'from :%d\n' % (mark - 1))
    out.append(b'M 100644 inline %s\ndata %d\n%s\n' % (path.encode(), len(data), data))
i = 0
needle_at = int(total * 0.08)
needle_done = False
while i < total:
    r = random.random()
    if r < 0.45 and i < total - 6:
        bot = ('deployer[bot]', 'deployer[bot]@users.noreply.github.com')
        for _ in range(random.randint(3, 9)):
            a = random.choice(apps); version[a][2] += 1
            v = '.'.join(map(str, version[a]))
            commit(bot, 'build: automatic update of %s to %s' % (a, v), 'apps/%s/values.yaml' % a, 'image: %s:%s\n' % (a, v)); i += 1
    elif r < 0.55 and i < total - 4:
        bot = ('renovate[bot]', '29139614+renovate[bot]@users.noreply.github.com')
        for _ in range(random.randint(3, 5)):
            d = random.choice(deps)
            commit(bot, 'chore(deps): update helm release %s to v%d.%d' % (d, random.randint(1, 9), random.randint(0, 20)), 'charts/%s/Chart.yaml' % d, 'version: %d\n' % i); i += 1
    else:
        subject = random.choice(human)
        if i >= needle_at and not needle_done:
            subject = 'feat: the needle commit to find'; needle_done = True
        commit(random.choice(people), subject, 'docs/notes-%d.md' % (i % 50), 'note %d\n' % i); i += 1
p = subprocess.run([GIT, 'fast-import', '--quiet'], cwd=repo, env=ENV, input=b''.join(out))
assert p.returncode == 0
subprocess.run([GIT, 'reset', '-q', '--hard', 'main'], cwd=repo, env=ENV, check=True)
subprocess.run([GIT, 'branch', 'develop', 'main~3'], cwd=repo, env=ENV, check=True)
open(os.path.join(repo, 'docs', 'notes-1.md'), 'a').write('local change\n')
print(subprocess.run([GIT, 'rev-list', '--count', 'HEAD'], cwd=repo, env=ENV, capture_output=True, text=True).stdout.strip(), 'commits in', repo)
