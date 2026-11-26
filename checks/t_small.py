"""t_small.py [light|dark] — phase-5 small items: ⇧↑/⇧↓ ranges in the graph (keyboard through the window, the
list scrolling with the range's moving end), clicks that pick with their own ⌘ and ⇧, the file menu on Review's file chips and file headers, and
right-click menus with two windows open (each menu is for its own window's repository)."""
import os, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'

def h(d): return d['phase5']['history']
def picked(d): return d['active']['picked']
def selection(d): return d['active']['selection']

launch_prepared(mode, prepare=lambda: big_sample('cluster-config', 600))
show_tab('powerlens')

def graph_has_keys(d):
    """The graph has the keyboard: not the window itself, and not a text field."""
    return d['driver']['firstResponder'] not in ('', 'KaernWindow') and not d['driver']['typing']

# ⇧↓ ⇧↓ from commit 3: 3 4 5 picked; ⇧↑ shrinks; past the anchor the range flips.
k('select', '3')
k('focusGraph')
settle(lambda d: selection(d).startswith('commit 3') and graph_has_keys(d), label='commit 3 selected, the graph with the keyboard')
k('press', 'down', 'shift'); k('press', 'down', 'shift')
d = until(lambda d: picked(d) == [3, 4, 5], label='⇧↓ ⇧↓')
p, sel = picked(d), selection(d); print('⇧↓ ⇧↓:', p, '|', sel[:40])
assert p == [3, 4, 5], p
k('press', 'up', 'shift')
d = until(lambda d: picked(d) == [3, 4], label='⇧↑'); p = picked(d); print('⇧↑:', p); assert p == [3, 4], p
k('press', 'up', 'shift'); k('press', 'up', 'shift')
d = until(lambda d: picked(d) == [2, 3], label='⇧↑ ⇧↑')
p, sel = picked(d), selection(d); print('⇧↑ ⇧↑ (past the anchor):', p, '|', sel[:40]); assert p == [2, 3], p
k('press', 'down')
d = until(lambda d: picked(d) == [] and selection(d).startswith('commit 4'), label='↓ without ⇧')
p, sel = picked(d), selection(d); print('↓ without ⇧:', p, '|', sel[:40]); assert p == [] and sel.startswith('commit 4'), (p, sel)

# Clicks pick with the ⌘ and ⇧ of their own events, not with the keyboard as it is then (a key held on the real
# keyboard while a check runs would turn its plain click into a pick): plain selects, ⌘ adds, ⇧ picks a range.
def click_row(index, *keys):
    f = target_frame('commit', str(index))
    k('click', '%g' % (f[0] + f[2] * 0.6), '%g' % (f[1] + f[3] / 2), '1', *keys)
click_row(2)
d = until(lambda d: not d['driver']['pointerBusy'] and selection(d).startswith('commit 2'), label='a click on commit 2')
assert picked(d) == [], picked(d)
click_row(4, 'cmd')
d = until(lambda d: not d['driver']['pointerBusy'] and (picked(d) or selection(d).startswith('commit 4')), label='⌘-click on commit 4')
p = picked(d); print('click 2, ⌘-click 4:', p); assert p == [2, 4], 'the ⌘ of the click picks: %s' % p
click_row(6, 'shift')
d = until(lambda d: not d['driver']['pointerBusy'] and picked(d) != [2, 4], label='⇧-click on commit 6')
p = picked(d); print('⇧-click 6:', p); assert p == [4, 5, 6], 'the ⇧ of the click picks a range: %s' % p
k('clearPicks')

# A long range in a bigger history: the list follows the moving end.
show_tab('cluster-config', lambda d: h(d)['commits'] >= 400)
k('select', '0'); k('focusGraph')
settle(lambda d: selection(d).startswith('commit 0') and graph_has_keys(d), label='the big sample\'s graph with the keyboard')
for _ in range(45):
    k('press', 'down', 'shift')
d = until(lambda d: len(picked(d)) > 45 and h(d)['topRow'] > 5, label='the range of 45 ⇧↓ and the list scrolled with it')
p = picked(d); top = h(d)['topRow']; print('45 x ⇧↓: %d picked, top row %d' % (len(p), top))
assert len(p) > 45 and top > 5, 'the list scrolled with the range (folded bot commits are in the range too)'
snap('small-range', mode)
k('clearPicks')
show_tab('powerlens')

# Review › All Files: a file chip and a file header open the file's menu.
k('select', 'wip')
k('review', 'all')
settle(lambda d: d['active']['reviewFiles'], label='Review › All Files')
path = 'CONTRIBUTING.md'
frame = target_frame('file', path); print('chip frame:', frame)
assert frame, 'the chip registered for right-clicks'
x, y = frame[0] + frame[2] / 2, frame[1] + frame[3] / 2
menu_snap('small-chipmenu', 'rightClick', str(x), str(y))
w = p5()['windows'][0]; print('chip right-click:', w['lastTarget'])
assert w['lastTarget'].startswith('file(path: "%s"' % path), w
k('review', 'off')

# Two windows: each right-click menu is for its own window's repository.
# New Window shows the start window; what opens there becomes the second window.
k('newWindow')
until(lambda d: d['welcome']['open'] and len(d['windows']) == 1, label='the start window')
k('open', os.path.join(SAMPLES, 'orders-api'))
until(lambda d: len(d['windows']) == 2 and not d['welcome']['open'], label='the second window')
k('useWindow', '1')
settle(lambda d: active_name(d) == 'orders-api' and d['phase5']['phase'] == 'ready', label='second window ready')
f1 = target_frame('commit', '2')
menu_snap('small-window2', 'rightClick', str(f1[0] + f1[2] * 0.6), str(f1[1] + f1[3] / 2))
k('useWindow', '0')
f0 = target_frame('commit', '2')
menu_snap('small-window1', 'rightClick', str(f0[0] + f0[2] * 0.6), str(f0[1] + f0[3] / 2))
windows = p5()['windows']
for w in windows: print('window %d: %s · %s · in its repository: %s' % (w['index'], w['tab'], w['lastTarget'][:60], w['targetInRepo']))
assert len(windows) == 2 and windows[0]['tab'] == 'powerlens' and windows[1]['tab'] == 'orders-api'
assert all(w['lastTarget'].startswith('commit(') and w['targetInRepo'] for w in windows)
assert windows[0]['lastTarget'] != windows[1]['lastTarget']
k('useWindow', '1'); k('closeWindow')
until(lambda d: len(d['windows']) == 1, label='the second window closed')
k('useWindow', 'off')
print('SMALL ITEMS OK')
quit_app()
