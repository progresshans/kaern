"""t_keptscreens.py — a window keeps the screens of the tabs used last (five, the shown one included), each in a
view of its own behind the window's (TabScreensView), so a tab comes back without being made again. The kept ones
are the last five in the order they showed; a tab that closes takes its screen along; a screen that comes back
takes clicks where its rows are and has caught up with what happened in its repository meanwhile."""
import os, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *

d = launch_prepared('light')
names = [t['name'] for t in d['windows'][0]['tabs']]
def kept(d): return d['windows'][0]['keptScreens']
def selection(d): return d['active']['selection']
def folder(name): return os.path.basename(tab(full_dump(), name)['path'])
order = [n for n in names if n != active_name(d)][:6]
assert len(order) == 6, names
folders = {n: folder(n) for n in order}

for count, name in enumerate(order[:5], 1):
    show_tab(name)
    d = until(lambda d: active_name(d) == name and kept(d)[-1] == folders[name], label='%s showing, its screen kept last' % name)
print('five visited: kept', kept(d))
assert kept(d)[-5:] == [folders[n] for n in order[:5]] and len(kept(d)) <= 5, kept(d)
show_tab(order[5])
d = until(lambda d: kept(d) == [folders[n] for n in order[1:6]], label='the sixth in, the oldest out')
print('a sixth: kept', kept(d))

# Back to a kept one: it's the same screen, and a click lands on the row its frame names.
back = order[2]
show_tab(back)
d = until(lambda d: active_name(d) == back and kept(d)[-1] == folders[back] and len(kept(d)) == 5, label='back on a kept tab')
steady()
k('select', '1'); until(lambda d: selection(d).startswith('commit 1 '), label='commit 1 selected'); steady()
f = target_frame('commit', '2')
k('click', '%g' % (f[0] + f[2] / 2), '%g' % (f[1] + f[3] / 2))
d = until(lambda d: selection(d).startswith('commit 2 ') and not d['driver']['pointerBusy'], label='a click on the second commit of a tab that came back')
print('back on', back, '· click:', selection(d)[:16], '· panes', sorted(d['phase5']['layout']['panes']['frames']))
assert {'sidebar', 'panel'} <= set(d['phase5']['layout']['panes']['frames'])

# A commit made in a kept tab's repository while another tab shows: there when the tab comes back.
hidden = order[3]
root = tab(d, hidden)['path']
with open(os.path.join(root, 'made-while-hidden.txt'), 'w') as f: f.write('x\n')
g(root, 'add', 'made-while-hidden.txt'); g(root, 'commit', '-q', '-m', 'Made while the tab was hidden')
tip = g(root, 'rev-parse', '--short=7', 'HEAD').strip()
time.sleep(1.0)
show_tab(hidden)
d = until(lambda d: active_name(d) == hidden and d['active']['head'] == tip, label='the hidden tab caught up')
print(hidden, 'came back at', d['active']['head'], '(the commit made while it was hidden)')

# A tab that closes takes its screen along.
gone = order[4]
k('close', gone)
d = until(lambda d: tab(d, gone) is None and folders[gone] not in kept(d), label='the closed tab\'s screen gone')
print('closed', gone, '· kept', kept(d))
print('KEPTSCREENS OK')
quit_app()
