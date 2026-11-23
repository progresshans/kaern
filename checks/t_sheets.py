import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
def sheet(d): return d['active']['phase4']['sheet']
launch('light', 'base')
a = shown()
# New Branch: typed with a space (becomes a dash), Return creates and checks it out.
k('sheet', 'newBranch')
type_text('feature/alpha notes', into='feature/name')
snap('sheet-branch-typed')
k('press', 'return')
d = settle(lambda d: d['active']['branch'] == 'feature/alpha-notes' and sheet(d) == '', label='the new branch')
a = d['active']; show('new branch', a, ('branch', 'toast'))
assert a['branch'] == 'feature/alpha-notes' and a['phase4']['sheet'] == ''
# A name that exists keeps the sheet open (Return does nothing).
k('sheet', 'newBranch')
type_text('develop', into='feature/name')
k('press', 'return'); sync()
d = settle(label='nothing after Return on a name that exists'); print('existing name -> sheet still open:', sheet(d))
assert sheet(d).startswith('branch') and d['active']['branch'] == 'feature/alpha-notes'
k('press', 'escape'); until(lambda d: sheet(d) == '', label='the sheet closed')
# New Tag on row 2 with the suggested name.
k('sheet', 'tag', 2)
until(lambda d: field_ready(d, 'v1.0.0', holding='v0.9.3-alpha.8'), label='the tag sheet with its suggested name')
k('press', 'return')
d = settle(lambda d: 'v0.9.3-alpha.8' in git('tag', '--points-at', git('rev-parse', 'HEAD~1')) and sheet(d) == '', label='the tag')
print('tag toast:', d['active']['toast'])
assert 'v0.9.3-alpha.8' in git('tag', '--points-at', git('rev-parse', 'HEAD~1'))
# Rename the current branch.
k('sheet', 'rename')
until(lambda d: field_ready(d, 'feature/name', holding='feature/alpha-notes'), label='the rename sheet')
k('key', 'a', 'cmd')
type_text('feature/renamed', into='feature/name')
k('press', 'return')
d = settle(lambda d: d['active']['branch'] == 'feature/renamed' and sheet(d) == '', label='the rename')
show('renamed', d['active'], ('branch', 'toast'))
assert d['active']['branch'] == 'feature/renamed'
# Delete a branch from the picker (preselected); ⌘Z brings it back.
tip = git('rev-parse', 'feature/harden-sparkle-releases')
k('sheet', 'delete', 'feature/harden-sparkle-releases')
settle(lambda d: sheet(d) == 'pick:delete', label='the delete sheet')
k('press', 'return')
d = settle(lambda d: git('rev-parse', '--verify', '-q', 'refs/heads/feature/harden-sparkle-releases') == '' and 'Deleted' in toast(d), label='the delete')
print('delete toast:', d['active']['toast'])
assert git('rev-parse', '--verify', '-q', 'refs/heads/feature/harden-sparkle-releases') == ''
k('undo')
settle(lambda d: git('rev-parse', '--verify', '-q', 'refs/heads/feature/harden-sparkle-releases') == tip, label='the branch back')
assert git('rev-parse', 'feature/harden-sparkle-releases') == tip
print('SHEETS OK')
quit_app()
