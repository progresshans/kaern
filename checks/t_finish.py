"""t_finish.py [light|dark] — Finish Feature: a feature/… branch goes into develop in one step.
The item is in a feature branch's right-click menu when the repository has develop, and nowhere else. Finishing
with a merge commit makes one with the message typed, though develop could fast-forward, and leaves the branch;
⌘Z takes the merge back, then the checkout. With Delete ticked the branch goes too, and the next sheet starts
with the boxes as they were left. With Rebase and no merge commit, the branch is replayed on develop, which then
fast-forwards to it. A finish that meets a conflict stops there, as a merge does, with the message kept and the
branch still there."""
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from k5 import _file
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
ROOT = os.path.join(SAMPLES, 'powerlens')


def add(name):
    with open(os.path.join(ROOT, name), 'w') as f: f.write(name + '\n')
    g(ROOT, 'add', name); g(ROOT, 'commit', '-q', '-m', 'Add ' + name)


def prepare():
    """develop at HEAD, and three feature branches from it: one with two commits, two and three with one each."""
    g(ROOT, 'branch', '-f', 'develop', 'HEAD')
    for branch, names in (('feature/one', ['one-a.txt', 'one-b.txt']), ('feature/two', ['two.txt']), ('feature/three', ['three.txt']),
                          ('feature/four', ['clash.txt'])):
        g(ROOT, 'switch', '-q', '-c', branch, 'develop')
        for name in names: add(name)
    g(ROOT, 'switch', '-q', 'feature/one')


_menus = [0]
def menu(*spec):
    _menus[0] += 1
    os.makedirs(REPLIES, exist_ok=True)
    path = os.path.join(REPLIES, 'menu-%d-%d.json' % (os.getpid(), _menus[0]))
    k('menuItems', path, *spec)
    return {i['title']: (i['hint'], i['enabled']) for i in json.loads(_file(path)) if 'title' in i}
def rev(name): return g(ROOT, 'rev-parse', name).strip()
def head(fmt): return g(ROOT, 'log', '-1', '--format=' + fmt).strip()
def has(branch): return bool(g(ROOT, 'branch', '--list', branch).strip())
def branch(d): return d['active']['branch']
def p4(d): return d['active']['phase4']
def said(d, start): return (toast(d) or '').startswith(start)

def check_saved_options(expected):
    settle(lambda d: p4(d)['finishOptions'] == expected
           and (stored_setting('KaernFinishOptions') or {}).get(ROOT) == expected,
           label='Finish options saved for powerlens: ' + expected)

launch_prepared(mode, prepare=prepare)
show_tab('powerlens')
d = until(lambda d: branch(d) == 'feature/one' and p4(d)['finishTarget'] == 'develop', label='the feature branch, with develop there')
base = rev('develop')

# The menu: on a feature branch only.
items = menu('branch', 'feature/two')
assert items.get('Finish Feature…') == ('', True), items
assert 'Finish Feature…' not in menu('branch', 'develop')
print('menu: Finish Feature… on feature/two, not on develop')
k('menuRun', 'branch', 'feature/one', '|', 'Finish', 'Feature…')
d = until(lambda d: p4(d)['sheet'] == 'finish:feature/one', label='the Finish sheet')
snap('finish-sheet', mode)
k('sheetClose'); until(lambda d: p4(d)['sheet'] == '', label='the sheet closed')

# (1) A merge commit with the message typed; the branch stays.
k('finishFeature', 'feature/one', 'merge', '--', 'Merge', 'feature/one:', 'the', 'first', 'one')
d = until(lambda d: branch(d) == 'develop' and said(d, 'Merged feature/one into develop with '), seconds=30, label='feature/one finished')
print('(1)', toast(d), '| subject:', head('%s'), '| parents:', len(head('%P').split()), '| kept:', p4(d)['finishOptions'])
assert head('%s') == 'Merge feature/one: the first one' and len(head('%P').split()) == 2
assert has('feature/one')
check_saved_options('merge')
assert not said(d, 'Merged feature/one into develop with ') or 'deleted' not in toast(d)
merged = rev('develop')
# The next sheet starts with the boxes as they were left: Delete isn't ticked.
k('sheet', 'finish', 'feature/two')
until(lambda d: p4(d)['sheet'] == 'finish:feature/two', label='the next Finish sheet')
snap('finish-sheet-kept', mode)
k('sheetClose'); until(lambda d: p4(d)['sheet'] == '', label='the sheet closed')
# settle, not until: git shows the merge taken back a moment before the app is done with that undo, and a ⌘Z
# that comes while one is still under way does nothing.
k('undo'); settle(lambda d: rev('develop') == base, label='⌘Z: the merge taken back')
k('undo'); d = settle(lambda d: branch(d) == 'feature/one', label='⌘Z again: back on feature/one')
print('    ⌘Z ⌘Z: develop at', rev('develop')[:7], '(was %s), on' % merged[:7], branch(d))
steady()

# (2) Delete ticked as well: develop could fast-forward, a merge commit is made all the same, and the branch goes.
k('finishFeature', 'feature/two', 'merge', 'delete', '--', 'Merge', 'feature/two:', 'the', 'second')
d = until(lambda d: branch(d) == 'develop' and (toast(d) or '').endswith('deleted feature/two'), seconds=30, label='feature/two finished and deleted')
print('(2)', toast(d), '| subject:', head('%s'), '| parents:', len(head('%P').split()), '| kept:', p4(d)['finishOptions'])
assert head('%s') == 'Merge feature/two: the second' and len(head('%P').split()) == 2
assert not has('feature/two')
check_saved_options('merge,delete')
k('undo'); settle(lambda d: has('feature/two'), label='⌘Z: feature/two is back')
print('    ⌘Z: feature/two is back at', rev('feature/two')[:7])
steady()

# (3) Rebase first, no merge commit, the message left as it starts: three's commit is replayed on develop, which
# has moved since, and develop fast-forwards to it.
before = rev('feature/three')
k('finishFeature', 'feature/three', 'rebase')
d = until(lambda d: branch(d) == 'develop' and said(d, 'Fast-forwarded develop to feature/three'), seconds=30, label='feature/three rebased and finished')
print('(3)', toast(d), '| subject:', head('%s'), '| parents:', len(head('%P').split()), '| kept:', p4(d)['finishOptions'])
assert rev('develop') == rev('feature/three') != before and head('%s') == 'Add three.txt' and len(head('%P').split()) == 1
assert has('feature/three')
check_saved_options('rebase')
assert g(ROOT, 'log', '-1', '--format=%s', 'develop~1').strip() == 'Merge feature/two: the second'
steady()

# (4) develop gets a clash.txt of its own: finishing feature/four stops on the conflict, like a merge.
with open(os.path.join(ROOT, 'clash.txt'), 'w') as f: f.write('develop has its own\n')
g(ROOT, 'add', 'clash.txt'); g(ROOT, 'commit', '-q', '-m', 'Add another clash.txt')
tip = rev('develop')
until(lambda d: d['active']['head'] == tip[:7], label='the commit made outside in the app')
k('finishFeature', 'feature/four', 'merge', 'delete', '--', 'Merge', 'feature/four:', 'both', 'add', 'clash.txt')
d = until(lambda d: d['active']['operation'] and p4(d)['conflicted'] == ['clash.txt'], seconds=30, label='the finish stopped on the conflict')
kept = open(os.path.join(ROOT, '.git', 'MERGE_MSG')).read().split('\n')[0]
print('(4) stopped:', d['active']['operation'], '| conflicted:', p4(d)['conflicted'], '| message kept:', kept)
assert has('feature/four') and rev('develop') == tip and kept == 'Merge feature/four: both add clash.txt'
k('abortOp'); until(lambda d: not d['active']['operation'], label='the merge given up')
print('FINISH OK')
quit_app()
