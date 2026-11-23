"""t_historyfail.py [light|dark] — a git log that fails (a branch pointing at a missing object) keeps the
history that was there and says why in the status bar, with Try Again; the Command Log has the failed
command. An empty repository (Create New Repository without a first commit) reads as no history, not as
an error."""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
def p6(d): return d['phase6']
def sheet(d): return d['phase5']['sheet']

launch_prepared(mode)
d = show_tab('powerlens', lambda d: p6(d)['commits'] > 0)
n = p6(d)['commits']; print('loaded', n, 'commits')
broken = os.path.join(PL, '.git', 'refs', 'heads', 'broken')
open(broken, 'w').write('1234567890123456789012345678901234567890\n')
# The app reads the history again (the folder changed) and git fails.
d = settle(lambda d: p6(d)['historyError'] != '', label='history error')
x = p6(d); print('error:', x['historyError'], '| commits', x['commits'])
assert x['commits'] == n, 'the list keeps what it had'
assert 'broken' in x['historyError'], x['historyError']
log = [e for e in d['active']['commandLog'] if ':: git log' in e or 'log --date-order' in e]
print('command log:', log[-1] if log else None)
assert log and log[-1].split()[1] not in ('0', '…'), 'the failed git log is in the Command Log with its status'
snap('history-failed', mode)
os.remove(broken)
k('retryHistory')
d = settle(lambda d: p6(d)['historyError'] == '' and p6(d)['commits'] == n, label='history back')
print('after Try Again:', p6(d)['commits'], 'commits, no error')

# An empty repository: no commits, no error.
k('create')
k('createField', 'name', 'empty-repo')
k('createField', 'location', SAMPLES)
k('createField', 'first', 'off')
k('createField', 'readme', 'off')
k('createField', 'ignore', 'none')
k('createField', 'license', 'none')
settle(lambda d: sheet(d)['kind'] == 'create' and sheet(d)['name'] == 'empty-repo' and sheet(d)['canCreate'], label='the create sheet filled in')
k('createStart')
d = settle(lambda d: d['active'].get('name') == 'empty-repo' and d['phase5']['phase'] == 'ready', label='empty repository tab')
x = p6(d); print('empty repository:', x['commits'], 'commits | error:', repr(x['historyError']))
assert x['commits'] == 0 and x['historyError'] == ''
quit_app()
print('OK t_historyfail', mode)
