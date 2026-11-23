"""Phase-5 sample states made with git in the scratch samples (isolated config)."""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *

def run(cwd, *args, who='Han Hyeonjin'):
    env = dict(ENV, GIT_AUTHOR_NAME=who, GIT_COMMITTER_NAME=who, GIT_AUTHOR_EMAIL='hh@kaern.invalid', GIT_COMMITTER_EMAIL='hh@kaern.invalid')
    r = subprocess.run([GIT] + list(args), cwd=cwd, env=env, capture_output=True, text=True)
    if r.returncode != 0: raise SystemExit('git %s failed: %s' % (' '.join(args), r.stderr))
    return r.stdout.strip()

def diverge(name, ahead, behind):
    """Gives samples/<name> an origin it is `ahead` commits ahead of and `behind` behind."""
    repo = os.path.join(SAMPLES, name)
    bare = os.path.join(SAMPLES, 'remotes', name + '.git')
    if not os.path.exists(bare):
        run(SAMPLES, 'clone', '-q', '--bare', repo, bare)
    branch = run(repo, 'branch', '--show-current')
    if 'origin' not in run(repo, 'remote').split(): run(repo, 'remote', 'add', 'origin', bare)
    run(repo, 'fetch', '-q', 'origin')
    run(repo, 'branch', '-q', '--set-upstream-to=origin/' + branch)
    other = os.path.join(SAMPLES, 'remotes', name + '-other')
    if not os.path.exists(other): run(SAMPLES, 'clone', '-q', bare, other)
    for i in range(behind):
        open(os.path.join(other, 'theirs-%d.txt' % i), 'w').write('theirs %d\n' % i)
        run(other, 'add', '-A'); run(other, 'commit', '-q', '-m', 'theirs %d' % i, who='Mina Park')
    run(other, 'push', '-q', 'origin', 'HEAD:' + branch)
    for i in range(ahead):
        open(os.path.join(repo, 'ours-%d.txt' % i), 'w').write('ours %d\n' % i)
        run(repo, 'add', 'ours-%d.txt' % i); run(repo, 'commit', '-q', '-m', 'ours %d' % i)
    run(repo, 'fetch', '-q', 'origin')
    return run(repo, 'rev-list', '--left-right', '--count', 'HEAD...@{u}')
