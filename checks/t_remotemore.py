"""t_remotemore.py — a remote folder's "N more" in the sidebar: a click shows 100 more names, coming back to the tab
shows no more than that, and scrolling down to the row shows the next ones."""
import os, re, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen6 import big_remotes
NAME = 'cluster-config'
KEY = 'origin/renovate'


def remote(d): return d['phase6']['sidebarRemote']


def more(d):
    """The folder's "N more" count (0: every name shows)."""
    lines = remote(d)
    i = next(n for n, l in enumerate(lines) if l.startswith('  renovate '))
    for line in lines[i + 1:]:
        if not line.startswith('    '): break
        m = re.fullmatch(r'    ([\d,]+) more', line)
        if m: return int(m.group(1).replace(',', ''))
    return 0


launch_prepared('light', prepare=lambda: print('remote refs:', big_remotes(NAME)))
show_tab(NAME, lambda d: d['phase6']['commits'] >= 400, seconds=40)
k('remoteOpen', 'origin', 'on')
k('remoteFolder', KEY, 'on')
d = settle(lambda d: '  renovate 812 ▾' in remote(d), label='the renovate folder open')
first = more(d)
print('folded: %d more' % first)
assert first == 806, first

k('remoteMore', KEY)
d = settle(lambda d: more(d) < first, label='a click on "more"')
clicked = more(d)
print('after a click: %d more' % clicked)
assert clicked == 706, clicked

# Away and back: the sidebar is made again; the folder shows what it showed.
show_tab('powerlens')
d = show_tab(NAME)
time.sleep(0.5)
d = settle(label='back on the tab')
print('after coming back to the tab: %d more' % more(d))
assert more(d) == clicked, 'coming back to the tab showed more names: %d' % more(d)

# Scrolled down to the row: the next names come.
k('scrollRun', 100, 500, -40, 120, 120)
d = settle(lambda d: more(d) < clicked, seconds=20, label='more names after scrolling to the row')
print('after scrolling to the row: %d more' % more(d))

quit_app()
print('t_remotemore ok')
