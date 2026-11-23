import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
FIELD = 'Branches, commits'
def p4(d): return d['active']['phase4']

def quick_open():
    """Opens Quick Open and waits until its field has the keyboard and it has read the repository's files
    (a git command it starts when it opens): typing before that finds no file."""
    n = commands(full_dump())
    k('quickOpen', 'on')
    settle(lambda d: p4(d)['quickOpen'] and field_ready(d, FIELD, holding='') and commands(d) > n, label='Quick Open ready')

launch(mode, 'base'); shown()
quick_open()
type_text('rest', into=FIELD)
snap('quickopen', mode)
# The first result is the current branch; ↓ ↓ picks the remote branch row and Return checks it out (already local → switch).
k('press', 'escape')
a = until(lambda d: p4(d)['quickOpen'] is False, label='Quick Open closed')['active']; print('closed:', a['phase4']['quickOpen'])
assert a['phase4']['quickOpen'] is False
quick_open()
type_text('reorganize settings', into=FIELD)
k('press', 'return')
d = settle(lambda d: d['active']['selection'].startswith('commit 0') and p4(d)['quickOpen'] is False, label='the commit selected')
a = d['active']; print('selected:', a['selection'], a['phase4']['quickOpen'])
assert a['selection'].startswith('commit 0') and a['phase4']['quickOpen'] is False
quick_open()
type_text('AlphaVersion.swift', into=FIELD)
k('press', 'return')
d = settle(lambda d: p4(d)['explore']['path'].endswith('AlphaVersion.swift'), label='the file history')
print('file history:', p4(d).get('explore', {}).get('path'))
assert p4(d)['explore']['path'].endswith('AlphaVersion.swift')
print('QUICK OPEN OK')
quit_app()
