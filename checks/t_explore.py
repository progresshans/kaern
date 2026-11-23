import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
def e(d): return d['active']['phase4']['explore']
launch(mode, 'base')
a = shown()
# A file with a rename in its history, made here (writes only in the sample).
subprocess.run([GIT, 'stash', 'push', '-q', '-u', '-m', 'kaern-explore-test'], cwd=PL, env=ENV)
def commit(msg, who='Han Hyeonjin'):
    subprocess.run([GIT, 'add', '-A'], cwd=PL, env=ENV)
    subprocess.run([GIT, '-c', 'user.name=' + who, '-c', 'user.email=hh@kaern.invalid', 'commit', '-q', '-m', msg], cwd=PL, env=ENV)
os.makedirs(os.path.join(PL, 'Sources/PowerLens/Release'), exist_ok=True)
src = open(os.path.join(PL, 'Sources/PowerLens/Release/AlphaVersion.swift')).read()
open(os.path.join(PL, 'Sources/PowerLens/Release/AlphaVersion.swift'), 'w').write(src.replace('struct AlphaVersion', '/// Moved and reworded.\nstruct AlphaVersion'))
commit('feat: document AlphaVersion')
subprocess.run([GIT, 'mv', 'Sources/PowerLens/Release/AlphaVersion.swift', 'Sources/PowerLens/AlphaVersion.swift'], cwd=PL, env=ENV)
commit('refactor: move AlphaVersion up a folder')
src = open(os.path.join(PL, 'Sources/PowerLens/AlphaVersion.swift')).read()
open(os.path.join(PL, 'Sources/PowerLens/AlphaVersion.swift'), 'w').write(src.replace('let marketing: String', 'let marketing: String  // "0.9.4"'))
# The app notices the two commits and the one changed file.
settle(lambda d: d['active']['head'] == git('rev-parse', 'HEAD')[:7] and d['active']['unstaged'] == ['Sources/PowerLens/AlphaVersion.swift']
       and d['active']['staged'] == [], label='the commits made in the folder')
k('history', 'Sources/PowerLens/AlphaVersion.swift')
d = settle(lambda d: len(e(d)['history']) == 3 and e(d)['diffHunks'] == 0 and e(d)['panel'], label='the file history')
x = e(d); print('history:', x['history'], x['selected'], x['diffHunks'], x['panel'], x['summary'])
assert len(x['history']) == 3 and x['diffHunks'] == 0 and x['panel']
k('historySelect', 1)
d = settle(lambda d: e(d)['diffHunks'] >= 1 and e(d)['panel'] == e(d)['selected'] and e(d)['selected'] != x['selected'], label='the second entry')
x = e(d); print('select 1:', x['selected'], x['panel'], x['diffHunks'])
assert x['diffHunks'] >= 1 and x['panel'] == x['selected']
snap('explore-history', mode)
k('exploreMode', 'blame')
d = settle(lambda d: any(c.startswith('0000000') for c in e(d)['chunks']) and len(e(d)['chunks']) >= 3, label='the blame')
x = e(d); print('blame chunks:', x['chunks'], x['focused'], x['summary'])
assert any(c.startswith('0000000') for c in x['chunks']) and len(x['chunks']) >= 3
k('blameFocus', 2)
d = settle(lambda d: e(d)['focused'] == x['chunks'][2].split(':')[0] and e(d)['panel'] == e(d)['focused'], label='the focused chunk')
snap('explore-blame', mode)
x = e(d); print('focused:', x['focused'], x['panel'])
k('blameBefore')
# Either the blame moves to the commit before, or the toast says there is nothing before it.
d = settle(lambda d: e(d)['blameAt'] != '' or toast(d) != '', label='Blame Before')
x = e(d); print('before:', x['path'], x['blameAt'], len(x['chunks']), d['active']['toast'])
k('showInHistory')
d = settle(lambda d: d['active']['phase4']['screen'] == '' and d['active']['selection'].startswith('commit'), label='back in the graph')
print('back to graph:', d['active']['phase4']['screen'], d['active']['selection'])
subprocess.run([GIT, 'checkout', '-q', '--', '.'], cwd=PL, env=ENV)
print('EXPLORE OK')
quit_app()
