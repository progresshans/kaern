"""t_scope.py [light|dark] — ScreenBigRepo on a 3,000-commit sample with 1,243 remote branches (scen6.many_remotes):
the graph opens at Local + main (local branches, their upstreams and origin/main; no remote-only commits), a remote
branch picked in the sidebar is drawn and selected, Current branch only leaves out other branches, picking Local +
main again lets go of the picked one. The Remote section: prefix folders (folded, counts), six names and "35 more",
"N more" showing the rest, and while filtering "release", open folders with "1 of 812"."""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen6 import big_remotes, REMOTE_ONLY, LOCAL_ONLY
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
NAME = 'cluster-config'
REPO = os.path.join(SAMPLES, NAME)
EXPO = REMOTE_ONLY['env/expo-preview']
def p6(d): return d['phase6']
def remote(d): return p6(d)['sidebarRemote']

launch_prepared(mode, prepare=lambda: print('remote refs:', big_remotes(NAME)))
d = show_tab(NAME, lambda d: p6(d)['commits'] >= 400 and p6(d)['total'] >= 0, seconds=40)
x = p6(d)
print('scope:', x['graphScope'], '|', x['graphScopeLabel'], '| bar', x['showsBar'], '| total', x['total'], '| drawn', x['drawnRemotes'])
assert x['graphScope'] == 'local' and x['showsGraphScope'] and x['graphScopeLabel'] == 'Local + main'
assert x['drawnRemotes'][0] == 'origin/main'
assert EXPO not in x['subjects'], 'remote-only commits are not drawn'
assert LOCAL_ONLY in x['subjects'], "a local branch's own commit is drawn"
all_count = int(g(REPO, 'rev-list', '--count', '--branches', '--remotes', '--tags'))
assert x['total'] == all_count - len(REMOTE_ONLY), (x['total'], all_count)
snap('graph-scope', mode)
# The Graph: menu, open under the chip: All branches, Local branches and main (checked), Current branch only.
menu_snap('graph-scope-menu', 'menu', 'graphScope', '-', 364, 110)

# The Remote section: prefix folders, folded, with counts.
k('remoteOpen', 'origin', 'on')
lines = remote(until(lambda d: remote(d)[:1] == ['origin ▾'], label='origin opened'))
print('\n'.join(lines))
assert lines[:7] == ['origin ▾', '  dependabot 134 ▸', '  env 6 ▸', '  feature 236 ▸', '  hotfix 12 ▸', '  release 41 ▸', '  renovate 812 ▸'], lines
assert lines[7:] == ['  develop', '  main'], lines[7:]

# Filtering "release": folders with matches open, "35 more", "1 of 812" (board 브랜치 1,243개).
k('sidebarFilter', 'release')
lines = remote(until(lambda d: p6(d)['filter'] == 'release' and '  release 41 ▾' in remote(d), label='the filter'))
print('\n'.join(lines))
assert '  release 41 ▾' in lines and '    35 more' in lines and '  renovate 1 of 812 ▾' in lines and '    release-drafter-6.x' in lines
snap('remote-folders', mode, changed=True)
k('sidebarFilter', '')
until(lambda d: p6(d)['filter'] == '', label='the filter cleared')

# A folder opened by hand: six names, then "N more" shows the rest.
k('remoteFolder', 'origin/release', 'on')
lines = remote(until(lambda d: '  release 41 ▾' in remote(d), label='the release folder opened'))
i = lines.index('  release 41 ▾')
assert lines[i + 7] == '    35 more', lines[i:i + 9]
k('remoteMore', 'origin/release')
lines = remote(until(lambda d: '    35 more' not in remote(d), label='the rest of the release folder'))
i = lines.index('  release 41 ▾')
assert not [l for l in lines[i + 1:i + 43] if l.endswith('more')] and lines[i + 41].startswith('    '), lines[i + 38:i + 44]
print('release folder: 41 names after "35 more"')

# Picking a remote-only branch draws it and selects its commit.
k('showRemote', 'origin/env/expo-preview')
d = settle(lambda d: EXPO in p6(d)['subjects'] and p6(d)['selection'] == EXPO and p6(d)['total'] >= 0, label='expo drawn')
x = p6(d); print('picked:', x['pickedRemotes'], '| toast', x['toast'], '| total', x['total'])
assert x['pickedRemotes'] == ['origin/env/expo-preview'] and 'is now drawn in the graph' in x['toast']
snap('graph-scope-picked', mode, changed=True, toast=True)

# Current branch only: the local branch's own commit and the picked branch are gone.
k('graphScope', 'current')
d = settle(lambda d: p6(d)['graphScope'] == 'current' and LOCAL_ONLY not in p6(d)['subjects']
           and EXPO not in p6(d)['subjects'] and p6(d)['total'] >= 0, label='current branch')
x = p6(d); print('current:', x['graphScopeLabel'], '| total', x['total'], '| picked', x['pickedRemotes'])
assert x['total'] == int(g(REPO, 'rev-list', '--count', 'HEAD')) and x['graphScopeLabel'] == 'Current branch'

# All branches (added at the user's request): every remote branch and tag, remote-only commits included.
k('graphScope', 'all')
d = settle(lambda d: p6(d)['graphScope'] == 'all' and EXPO in p6(d)['subjects'] and LOCAL_ONLY in p6(d)['subjects']
           and p6(d)['total'] >= 0, seconds=40, label='all branches')
x = p6(d); print('all:', x['graphScopeLabel'], '| total', x['total'], '| bar', x['showsBar'])
assert x['graphScopeLabel'] == 'All branches' and x['total'] == all_count and x['showsBar']
snap('graph-scope-all', mode, changed=True)

# Local + main again: back to local branches, no picked remote branch.
k('graphScope', 'local')
d = settle(lambda d: p6(d)['graphScope'] == 'local' and LOCAL_ONLY in p6(d)['subjects'] and EXPO not in p6(d)['subjects'], label='local again')
x = p6(d); assert x['pickedRemotes'] == [] and EXPO not in x['subjects']
kept = d['settings'].get('KaernGraphScopes', '')
print('kept:', kept.replace('\n', ' ')[:200])
assert 'local' in kept
quit_app()
print('OK t_scope', mode)
