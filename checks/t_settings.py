import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k4 import *
launch('light', 'base')
d = full_dump(); print('git at launch:', d['git'], d['gitSource'])
set_setting('KaernGitPath', '/usr/bin/git')
set_setting('KaernOnLaunch', 'welcome')
quit_app()
d = relaunch()
print('after relaunch:', d['git'], d['gitSource'], 'windows', len(d['windows']), 'welcome', d['welcome'], 'lastClosedTabs', d['lastClosedTabs'])
assert d['git'] == '/usr/bin/git' and d['gitSource'] == 'Settings'
# On launch › Show the welcome window: no main window, only the start window with last time's 11 tabs behind Reopen.
assert len(d['windows']) == 0 and d['welcome']['open'] and d['lastClosedTabs'] == 11
k('reopenLastSession')
d = settle(lambda d: len(d['windows']) == 1 and len(d['windows'][0]['tabs']) == 11 and not d['welcome']['open'], label='the last session reopened')
print('reopened tabs:', len(d['windows'][0]['tabs']))
set_setting('KaernGitPath', None)
set_setting('KaernOnLaunch', None)
# Group from the same folder: a new sample next to the others joins the group with most members there.
os.makedirs(os.path.join(SAMPLES, 'newrepo'), exist_ok=True)
subprocess.run([GIT, 'init', '-q'], cwd=os.path.join(SAMPLES, 'newrepo'), env=ENV)
k('open', os.path.join(SAMPLES, 'newrepo'))
d = settle(lambda d: any(t['name'] == 'newrepo' for t in d['windows'][0]['tabs']), label='the newrepo tab')
tab = [t for t in d['windows'][0]['tabs'] if t['name'] == 'newrepo'][0]
print('newrepo group:', repr(tab['group']))
assert tab['group'] != ''
quit_app()
d = relaunch()
print('default git again:', d['git'], d['gitSource'], 'tabs', len(d['windows'][0]['tabs']))
assert d['gitSource'] != 'Settings' and len(d['windows'][0]['tabs']) == 12
quit_app()
print('SETTINGS OK')
