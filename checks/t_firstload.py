"""t_firstload.py — a commit and a new file made while a tab's first load is under way (its `git status` has
answered and waits: `hold status <folder>`) show once the load is done: the file events that came in meanwhile
start a refresh instead of being dropped."""
import os, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from k3 import _files_seen
NAME = 'latecomer'
REPO = os.path.join(SAMPLES, NAME)


def commit(text, message):
    with open(os.path.join(REPO, 'notes.txt'), 'a') as f: f.write(text)
    g(REPO, 'add', 'notes.txt')
    g(REPO, '-c', 'user.name=T', '-c', 'user.email=t@t', 'commit', '-q', '-m', message)
    return g(REPO, 'rev-parse', 'HEAD')[:7]


def prepare():
    os.makedirs(REPO)
    g(REPO, 'init', '-q', '-b', 'main')
    commit('one\n', 'first')


launch_prepared('light', prepare=prepare)
first = g(REPO, 'rev-parse', 'HEAD')[:7]
hold_at('status', os.path.realpath(REPO))
k('open', REPO)
d = until(lambda d: active_name(d) == NAME and 'status' in d['driver']['holding'], label='the first load to wait with its status')
print('first load held: phase %s, head %r' % (d['phase5']['phase'], d['active'].get('head')))

second = commit('two\n', 'second, made while the tab loads')
with open(os.path.join(REPO, 'new.txt'), 'w') as f: f.write('x\n')
_files_seen(full_dump(), time.time() + 10, 'the file events during the load', 10)
d = full_dump()
assert 'status' in d['driver']['holding'], 'the load should still wait: %s' % d['driver']['holding']

k('release')
d = settle(lambda d: d['phase5']['phase'] == 'ready' and d['active']['head'] == second, seconds=15,
           label='the commit made during the load (%s, not %s)' % (second, first))
changes = tab(d, NAME)['changes']
print('after the load: head %s, %d change(s)' % (d['active']['head'], changes))
assert changes == 1, changes
quit_app()
print('t_firstload ok')
