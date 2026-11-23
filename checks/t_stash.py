import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
ALPHA = 'Sources/PowerLens/Release/AlphaVersion.swift'
def p4(d): return d['active']['phase4']
launch(mode, 'stash-conflict')
a = shown(); print('stashes:', a['stashes'])
alpha_head = git('show', 'HEAD:' + ALPHA)
k('openStash', 0)
d = settle(lambda d: p4(d)['stashDetails'] and ALPHA in p4(d)['stashDetails']['files'], label='the stash view')
print('stash view:', p4(d)['screen'], p4(d)['stashDetails'])
assert p4(d)['stashDetails'] and ALPHA in p4(d)['stashDetails']['files']
snap('stash-view', mode)
k('popStash', 0)
d = settle(lambda d: p4(d)['stashConflict'] and p4(d)['screen'] == 'conflicts' and p4(d)['conflictSession']['blocks'] > 0, label='the pop stopped on a conflict')
a = d['active']; print('pop:', p4(d)['stashConflict'], p4(d)['screen'], p4(d)['conflicted'], a['stashes'])
assert p4(d)['stashConflict'] and p4(d)['screen'] == 'conflicts'
snap('pop-conflict', mode)
k('undoPop')
d = settle(lambda d: not p4(d)['stashConflict'] and p4(d)['conflicted'] == [] and len(d['active']['stashes']) == 2 and d['active']['toast'], label='Undo Pop')
a = d['active']; print('undo pop:', p4(d)['stashConflict'], p4(d)['conflicted'], a['toast'], a['stashes'])
assert not p4(d)['stashConflict'] and p4(d)['conflicted'] == [] and len(a['stashes']) == 2
assert open(os.path.join(PL, ALPHA)).read() == alpha_head + ('\n' if not alpha_head.endswith('\n') else '')
assert not os.path.exists(os.path.join(PL, 'docs/NOTES.md'))
k('popStash', 0)
settle(lambda d: p4(d)['stashConflict'] and p4(d)['screen'] == 'conflicts' and p4(d)['conflictSession']['blocks'] > 0, label='the second pop stopped')
k('conflictKeep', 'theirs')
k('markResolved')
d = settle(lambda d: not p4(d)['stashConflict'] and p4(d)['screen'] == '' and 'Resolved' in toast(d), label='the pop resolved')
a = d['active']; print('resolved pop:', p4(d)['stashConflict'], p4(d)['screen'], a['toast'], a['stashes'])
assert not p4(d)['stashConflict'] and p4(d)['screen'] == '' and len(a['stashes']) == 2
# Rename keeps the order; ⌘Z names it back.
k('renameStash', 1, 'release notes, take two')
d = settle(lambda d: d['active']['stashes'][1] == 'On develop: release notes, take two', label='the stash renamed')
a = d['active']; print('renamed:', a['stashes'], a['toast'])
assert a['stashes'][1] == 'On develop: release notes, take two' and a['stashes'][0].startswith('On (no branch): Before reset')
k('undo')
d = settle(lambda d: d['active']['stashes'][1] == 'On develop: release notes', label='the rename undone'); print('undo rename:', d['active']['stashes'])
assert d['active']['stashes'][1] == 'On develop: release notes'
# Create Branch from Stash.
git_ok = subprocess.run([GIT, 'stash', 'drop', 'stash@{0}'], cwd=PL, env=ENV, capture_output=True)
subprocess.run([GIT, 'reset', '-q', '--hard'], cwd=PL, env=ENV); subprocess.run([GIT, 'clean', '-qfd'], cwd=PL, env=ENV)
# The app notices what git did in the folder.
settle(lambda d: len(d['active']['stashes']) == 1 and not d['active']['staged'] and not d['active']['unstaged'], label='the dropped stash and the clean tree')
k('stashBranch', 0, 'notes/from-stash')
d = settle(lambda d: d['active']['branch'] == 'notes/from-stash' and d['active']['stashes'] == [], label='the branch from the stash')
a = d['active']; show('branch from stash', a, ('branch', 'toast', 'stashes'))
assert a['branch'] == 'notes/from-stash' and a['stashes'] == [] and os.path.exists(os.path.join(PL, 'NOTES.md'))
# ⌘Z: back on the branch before, the new branch gone, and the stash in the list again under its name, with its
# changes in it and not loose in the folder.
k('undo')
d = settle(lambda d: d['active']['branch'] != 'notes/from-stash' and d['active']['stashes'] == ['On develop: release notes']
           and not d['active']['staged'] and not d['active']['unstaged'], label='the stash back in the list after undo')
a = d['active']; show('undo of branch from stash', a, ('branch', 'toast', 'stashes'))
branches = subprocess.run([GIT, 'branch', '--format=%(refname:short)'], cwd=PL, env=ENV, capture_output=True, text=True).stdout.split()
assert 'notes/from-stash' not in branches, branches
assert not os.path.exists(os.path.join(PL, 'NOTES.md')), 'the stash\'s file is still in the folder'
# ⇧⌘Z makes the branch from that entry again.
k('redo')
d = settle(lambda d: d['active']['branch'] == 'notes/from-stash' and d['active']['stashes'] == [], label='the branch from the stash again')
assert os.path.exists(os.path.join(PL, 'NOTES.md'))
k('undo')
settle(lambda d: d['active']['branch'] != 'notes/from-stash' and d['active']['stashes'] == ['On develop: release notes'], label='undone again')
quit_app()
print('STASH OK')
