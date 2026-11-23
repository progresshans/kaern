import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
def p4(d): return d['active']['phase4']
launch(mode, 'base')
a = shown()
k('autoFetchNow')
d = settle(lambda d: any('Auto-fetch (every 5 min) :: git fetch' in l and l.startswith('bg 0') for l in p4(d)['fetchCommands']), label='the auto-fetch')
print('auto-fetch ok:', p4(d)['fetchProblem'], p4(d)['activityRecent'], p4(d)['fetchCommands'])
assert any('Auto-fetch (every 5 min) :: git fetch' in l and l.startswith('bg 0') for l in p4(d)['fetchCommands'])
# A remote that turns the sign-in down (writes only in the sample's own config).
git_cmd = lambda *args: subprocess.run([GIT] + list(args), cwd=PL, env=ENV, capture_output=True, text=True)
git_cmd('config', 'protocol.ext.allow', 'always')
git_cmd('remote', 'add', 'mirror', "ext::sh -c echo% remote:% Invalid% username% or% token.>&2;echo% fatal:% Authentication% failed% for% 'https://github.com/kaern/powerlens.git/'>&2;exit% 128")
settle(lambda d: 'mirror' in d['phase5']['remotes'], label='the new remote')
k('autoFetchNow')
d = settle(lambda d: p4(d)['fetchProblem'].startswith('signIn') and p4(d)['autoFetchPaused'], label='the sign-in failure')
print('auth failure:', p4(d)['fetchProblem'], p4(d)['autoFetchPaused'], p4(d)['activityRecent'])
assert p4(d)['fetchProblem'].startswith('signIn') and p4(d)['autoFetchPaused']
snap('status-signin', mode)
k('activity')
until(lambda d: window_open(d, 'Popover'), label='the Activity popover')
snap('activity', mode, composite=True)
k('press', 'escape'); sync()  # goes to the main window, as before: the popover may stay open
# Paused: the next auto-fetch skips this repository.
before = dump()['phase4']['fetchCommands']
k('autoFetchNow')
d = settle(label='the auto-fetch round that skips it')
after = p4(d)['fetchCommands']
print('paused skip:', len(before), len(after))
assert before == after
k('commandLog')
until(lambda d: window_open(d, 'Command Log'), label='the Command Log window')
k('commandLogFilter', 'failed')
k('commandLogSelect', 'fetch --progress --prune --all')
snap('log-why', mode, window='Command Log')
print('ACTIVITY OK')
quit_app()
