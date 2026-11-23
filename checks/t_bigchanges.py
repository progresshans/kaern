"""t_bigchanges.py [light|dark] — ScreenBigRepo › 변경 파일 1만 개 on a 3,000-commit sample with 12,409 changed files
(scen6.many_changes): the panel lists folders with counts (biggest first) instead of 12,409 rows and stays
responsive; the card suggests ignoring charts/vendor/ (11,920 new files); Add to .gitignore takes them out of the
list and ⌘Z puts .gitignore back; Not Now puts the card away; a folder's checkbox stages it and ⌘Z unstages it.
It prints how long the list takes and asserts the memory, so the suite runs it alone (the serial lane)."""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen6 import big_changes, launch6
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
NAME = 'cluster-config'; REPO = os.path.join(SAMPLES, NAME)
def p6(d): return d['phase6']
def big(d): return d['phase6']['big']

launch6(mode, prepare=lambda: big_changes(NAME), drop=['-KaernFileTree'])
k('fileList', 'tree'); sync()
t = time.time(); k('activateName', NAME)
d = until(lambda d: d['phase5']['phase'] == 'ready' and d['active']['name'] == NAME and big(d), seconds=60, label='big list')
print('ready in %.1f s' % (time.time() - t))
b = big(d); print('big:', b['total'], 'files |', b['folders'], '| suggestion', b['suggestion'])
assert b['total'] == 12409 and b['folders'] == ['charts/vendor/ 11920 0', 'apps/orders/ 312 0', 'clusters/prod/ 164 0', 'docs/ 13 0'], b['folders']
assert b['suggestion'] == 'charts/vendor/ 11920' and b['shownSuggestion'] == b['suggestion']
for i in range(3):
    t = time.time(); full_dump(); print('dump %.2f s' % (time.time() - t))
settle(label='the list loaded')
k('changeFolder', 'apps/orders/', 'on')
# The tab was loaded in the background after launch; its line counts come when it shows.
d = settle(lambda d: big(d)['openStats'] and '-1' not in ' '.join(big(d)['openStats']), label='line counts')
print('line counts:', big(d)['openStats'])
snap('big-changes', mode)
print('rss MB', rss_mb())
assert rss_mb() < 1200

# A folder's checkbox stages it; ⌘Z takes it back.
k('stageFolder', 'docs/')
d = settle(lambda d: big(d)['staged'] == 13, label='docs staged')
print('docs staged | undo', p6(d)['undo'][-1:])
assert p6(d)['undo'][-1] == 'Stage docs/'
k('undo')
d = settle(lambda d: big(d)['staged'] == 0, label='docs unstaged')

# Add to .gitignore: 11,920 files leave the list; ⌘Z puts .gitignore back.
k('ignoreSuggestion', 'add')
d = settle(lambda d: p6(d)['changeCount'] < 1000 and p6(d)['toast'].startswith('Ignored'), seconds=40, label='ignored')
x = p6(d); print('ignored:', x['toast'], '| changes', x['changeCount'], '| big', x['big'], '| .gitignore', repr(x['gitignore']))
assert x['toast'] == 'Ignored charts/vendor/ · 11,920 files left the list' and x['big'] is None and x['gitignore'] == 'charts/vendor/\n'
snap('big-changes-ignored', mode, changed=True, toast=True)
k('undo')
d = settle(lambda d: p6(d)['changeCount'] == 12409 and big(d) and big(d)['shownSuggestion'], seconds=40, label='undo ignore')
print('undo: .gitignore', repr(p6(d)['gitignore']), '| card back')
assert not os.path.exists(os.path.join(REPO, '.gitignore'))

# Not Now: the card goes away for this folder (kept in the settings).
k('ignoreSuggestion', 'notNow')
d = until(lambda d: big(d)['suggestion'] and not big(d)['shownSuggestion'] and 'charts/vendor/' in d['settings'].get('KaernIgnoreSuggestionsDismissed', ''),
          label='the card put away')
x = big(d)
assert x['suggestion'] and not x['shownSuggestion']
assert 'charts/vendor/' in d['settings'].get('KaernIgnoreSuggestionsDismissed', '')
print('not now: card hidden, kept in settings')

# Path lists the first 300 paths and stays responsive.
k('fileList', 'path'); sync()
t = time.time(); full_dump(); print('path mode dump %.2f s | rss MB %d' % (time.time() - t, rss_mb()))
k('fileList', 'tree'); sync()
quit_app()
print('OK t_bigchanges', mode)
