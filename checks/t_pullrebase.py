"""t_pullrebase.py [light|dark] — Pull (rebase) with staged and unstaged changes: they go aside and come
back as they were (staged still staged), ⌘Z moves the branch back and ⇧⌘Z forward again; a second pull
is up to date. When the rebase stops on a conflict, the changes wait in Stashes, the conflict editor
opens, and Abort brings them back."""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen6 import pull_behind
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
def p6(d): return d['phase6']

def counts(): return g(PL, 'rev-list', '--left-right', '--count', 'HEAD...@{u}').split()

# 1. Clean case: the incoming commits touch other files.
launch_prepared(mode, prepare=lambda: print('pull_behind', pull_behind('powerlens')))
d = show_tab('powerlens', lambda d: p6(d)['commits'] > 0)
before = p6(d); head0 = g(PL, 'rev-parse', 'HEAD')
print('before:', counts(), '| staged', len(before['staged']), '| unstaged', len(before['unstaged']))
assert counts() == ['2', '2'] and before['staged'] and before['unstaged']
k('pullWith', 'rebase')
d = settle(lambda d: p6(d)['toast'].startswith('Pulled') and counts() == ['2', '0'], seconds=40, label='pulled')
x = p6(d); print('pulled:', x['toast'], '| ahead/behind', counts(), '| undo', x['undo'][-1:])
assert counts() == ['2', '0']
assert x['staged'] == before['staged'] and x['unstaged'] == before['unstaged'], 'staged stays staged, unstaged stays unstaged'
assert not [s for s in x['stashes'] if 'Before Pull' in s], 'nothing left in Stashes'
assert x['undo'][-1] == 'Pull'
head1 = g(PL, 'rev-parse', 'HEAD')
k('undo')
d = settle(lambda d: g(PL, 'rev-parse', 'HEAD') == head0 and p6(d)['redo'][-1:] == ['Pull'], label='undo')
x = p6(d); print('undo:', counts(), '| redo', x['redo'][-1:])
assert x['staged'] == before['staged'] and x['unstaged'] == before['unstaged']
k('redo')
d = settle(lambda d: g(PL, 'rev-parse', 'HEAD') == head1 and p6(d)['undo'][-1:] == ['Pull'], label='redo')
print('redo:', counts())
k('pullWith', 'rebase')
d = settle(lambda d: p6(d)['toast'] == 'Already up to date', seconds=40, label='up to date')
assert p6(d)['staged'] == before['staged'] and p6(d)['unstaged'] == before['unstaged']
print('second pull: up to date, changes as they were')
quit_app()

# 2. The rebase stops: an incoming commit changes ReleaseFeed.swift, which a local commit changes too.
def conflicting():
    print('pull_behind', pull_behind('powerlens', subjects=('fix: rename the feed URL',),
                                     files={0: ('Sources/PowerLens/Release/ReleaseFeed.swift', 'let feed = "theirs"\n')}))
launch_prepared(mode, prepare=conflicting)
d = show_tab('powerlens', lambda d: p6(d)['commits'] > 0)
before = p6(d)
k('pullWith', 'rebase')
d = settle(lambda d: p6(d)['operation'] == 'rebase' and 'conflicts' in p6(d)['screen'], seconds=40, label='stopped')
x = p6(d); print('stopped:', x['operation'], x['screen'], '| toast', x['toast'], '| stashes', x['stashes'][:2])
assert [s for s in x['stashes'] if 'Before Pull' in s], 'the changes wait in Stashes'
snap('pull-rebase-stopped', mode, toast=True)
k('abortOp')
d = settle(lambda d: p6(d)['operation'] == '' and 'Aborted' in p6(d)['toast'], seconds=40, label='aborted')
x = p6(d); print('aborted:', x['toast'], '| staged', len(x['staged']), '| unstaged', len(x['unstaged']))
assert x['staged'] == before['staged'] and x['unstaged'] == before['unstaged']
assert not [s for s in x['stashes'] if 'Before Pull' in s]
quit_app()
print('OK t_pullrebase', mode)
