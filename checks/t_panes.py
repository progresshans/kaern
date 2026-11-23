"""t_panes.py [light|dark] — the sidebar, the right panel, Focus's drawer and (Sidebar switching) the repository
list resize by dragging their edges with the mouse: from their least as far as the window allows (the middle keeps
400 pt, the repository beside the list its panes' least), a double-click puts a pane back to the board's size, a
narrower window narrows them without forgetting their sizes, and the sizes are there again after a relaunch.
Narrow windows: the rail's sidebar and the panel over the graph too."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'


def panes(d): return d['phase5']['layout']['panes']
def frame(d, name): return panes(d)['frames'].get(name)
def near(a, b): return abs(a - b) < 0.6


def sized(**sizes):
    """Each named pane is that wide (that tall for the drawer); None: not on screen."""
    def check(d):
        for name, size in sizes.items():
            f = frame(d, name)
            if size is None:
                if f is not None: return False
            elif f is None or not near(f[3] if name == 'drawer' else f[2], size):
                return False
        return True
    return check


def at_width(width, **sizes):
    k('resize', str(width), '900')
    return until(lambda d: near(d['phase5']['layout']['width'], width) and sized(**sizes)(d),
                 label='a %d pt window with %s' % (width, sizes))


def pointer_done(check):
    """The drag or click has been sent to its end (its release too), and check(dump) holds."""
    return lambda d: not d['driver']['pointerBusy'] and check(d)


def drag(handle, x1, y1, x2, y2, check=None, **sizes):
    """Require this drag to reach its resize handle, even when the pane is already at its limit."""
    sequence = send_drag(x1, y1, x2, y2)
    expected = check or sized(**sizes)
    def resized(d):
        event = d['driver']['drag']
        return event['sequence'] == sequence and event['handle'] == handle and expected(d)
    return until(pointer_done(resized), label='%s drag %d (%g,%g → %g,%g) %s' % (handle, sequence, x1, y1, x2, y2, sizes))


def double_click(x, y, **sizes):
    k('click', '%g' % x, '%g' % y, '2')
    return until(pointer_done(sized(**sizes)), label='after a double-click at %g,%g: %s' % (x, y, sizes))


def edges(d):
    s, p = frame(d, 'sidebar'), frame(d, 'panel')
    return (s[0] + s[2], s[1] + s[3] / 2) if s else None, (p[0], p[1] + p[3] / 2) if p else None


launch_prepared(mode)
show_tab('powerlens')
d = at_width(1440, sidebar=230, panel=316)
assert panes(d)['sidebar'] == 0 and panes(d)['panel'] == 0, 'nothing kept yet: the boards’ sizes'
(sx, sy), (px, py) = edges(d)
print('sidebar edge', sx, sy, '· panel edge', px, py)

def middle(d):
    s, p = frame(d, 'sidebar'), frame(d, 'panel')
    return p[0] - (s[0] + s[2])


# The sidebar: wider, then as wide as the window allows (1,440 − 316 − 400 = 724) and its least (180).
d = drag('Sidebar width', sx, sy, sx + 100, sy, sidebar=330, panel=316)
assert panes(d)['sidebar'] == 330, panes(d)
(sx, sy), _ = edges(d)
d = drag('Sidebar width', sx, sy, 1300, sy, sidebar=724, panel=316)
print('sidebar at its most:', frame(d, 'sidebar'), 'middle', middle(d))
assert panes(d)['sidebar'] == 724 and near(middle(d), 400), 'the middle keeps 400 pt: %s' % panes(d)
(sx, sy), _ = edges(d)
d = drag('Sidebar width', sx, sy, 40, sy, sidebar=180)
assert panes(d)['sidebar'] == 180, panes(d)
(sx, sy), _ = edges(d)
d = drag('Sidebar width', sx, sy, 300, sy, sidebar=300)
s, p = frame(d, 'sidebar'), frame(d, 'panel')
print('sidebar 300:', s, 'panel', p)
snap('panes-sidebar300', mode, changed=True)

# The panel grows to the left as far as the middle keeps 400 pt (1,440 − 300 − 400 = 740).
(_, _), (px, py) = edges(d)
d = drag('Panel width', px, py, px - 150, py, panel=466, sidebar=300)
assert panes(d)['panel'] == 466, panes(d)
(_, _), (px, py) = edges(d)
d = drag('Panel width', px, py, 100, py, panel=740, sidebar=300)
assert panes(d)['panel'] == 740, panes(d)
# Now the sidebar has no room left: a drag doesn't take any from the middle.
(sx, sy), _ = edges(d)
d = drag('Sidebar width', sx, sy, 1200, sy, sidebar=300, panel=740)
s, p = frame(d, 'sidebar'), frame(d, 'panel')
print('the panel at its most:', s, p, 'middle', middle(d))
assert panes(d)['sidebar'] == 300 and near(middle(d), 400), 'the middle keeps 400 pt: %s' % panes(d)
snap('panes-widest', mode, changed=True)

# A narrower window narrows both together, each by what it has above its least (300 − 180 : 740 − 280 of the
# 240 over); a wider one gives them their sizes back.
d = at_width(1200, sidebar=250, panel=550)
print('at 1,200:', frame(d, 'sidebar'), frame(d, 'panel'), 'middle', middle(d))
assert panes(d)['sidebar'] == 300 and panes(d)['panel'] == 740, 'the sizes are kept: %s' % panes(d)
d = at_width(1440, sidebar=300, panel=740)            # a wider window gives them their sizes back
d = at_width(1200, sidebar=250, panel=550)
# Dragging one of them then keeps what both show (no room to grow: the middle has its least).
(sx, sy), _ = edges(d)
d = drag('Sidebar width', sx, sy, sx + 80, sy, sidebar=250, panel=550)
assert panes(d)['sidebar'] == 250 and panes(d)['panel'] == 550, 'what they show is kept: %s' % panes(d)
(sx, sy), _ = edges(d)
d = drag('Sidebar width', sx, sy, sx - 60, sy, sidebar=190, panel=550)
d = at_width(1440, sidebar=190, panel=550)

# Double-clicks put them back to the boards' sizes.
(sx, sy), (px, py) = edges(d)
d = double_click(sx, sy, sidebar=230, panel=550)
assert panes(d)['sidebar'] == 0, panes(d)
(sx, sy), (px, py) = edges(d)
d = double_click(px, py, sidebar=230, panel=316)
assert panes(d)['panel'] == 0, panes(d)

# Focus's drawer: its top edge, up to where the graph keeps 150 pt, and down to 180.
row_top = frame(d, 'sidebar')[1]
k('focus', 'on')
d = until(sized(drawer=330, sidebar=None, panel=None), label='Focus with its drawer')
steady()   # the drawer has slid in: its edge is where its frame says
f = frame(full_dump(), 'drawer')
top, mx = f[1], f[0] + f[2] / 2 + 200
d = drag('Drawer height', mx, top, mx, top - 120, drawer=450)
assert panes(d)['drawer'] == 450, panes(d)
snap('panes-drawer450', mode, changed=True)
f = frame(d, 'drawer')
d = drag('Drawer height', mx, f[1], mx, 10,
         check=lambda d: frame(d, 'drawer') and panes(d)['drawer'] > 450 and near(frame(d, 'drawer')[3], panes(d)['drawer']))
f = frame(d, 'drawer')
print('drawer at its most:', f, 'stored', panes(d)['drawer'], '· the graph keeps', f[1] - row_top)
assert near(f[1] - row_top, 150), 'the graph keeps 150 pt above the drawer'
d = drag('Drawer height', mx, f[1], mx, 890, drawer=180)
f = frame(d, 'drawer')
d = double_click(mx, f[1], drawer=330)
assert panes(d)['drawer'] == 0, panes(d)
k('focus', 'off')
d = until(sized(drawer=None, sidebar=230, panel=316), label='Focus off')

# Kept for the next launch.
(sx, sy), (px, py) = edges(d)
d = drag('Sidebar width', sx, sy, sx + 70, sy, sidebar=300)
(sx, sy), (px, py) = edges(d)
d = drag('Panel width', px, py, px - 84, py, panel=400)
k('focus', 'on')
d = until(sized(drawer=330), label='Focus again')
steady()
f = frame(full_dump(), 'drawer')
d = drag('Drawer height', mx, f[1], mx, f[1] - 70, drawer=400)
k('focus', 'off')
until(sized(drawer=None), label='Focus off again')
wait_saved_settings({'KaernSidebarWidth': 300, 'KaernPanelWidth': 400, 'KaernDrawerHeight': 400})
quit_app()
relaunch(mode)
show_tab('powerlens')
d = at_width(1440, sidebar=300, panel=400)
k('focus', 'on')
d = until(sized(drawer=400), label='the drawer’s size after the relaunch')
k('focus', 'off')

# A narrow window: the sidebar's rail opens it over the graph at its size; the panel over the graph too.
d = at_width(1000, sidebar=None, panel=400)
k('flyout', 'local')
d = until(sized(sidebar=300), label='the sidebar over the graph from the rail')
steady()
s = frame(full_dump(), 'sidebar')
d = drag('Sidebar width', s[0] + s[2], s[1] + s[3] / 2, s[0] + s[2] - 60, s[1] + s[3] / 2, sidebar=240)
snap('panes-flyout240', mode, changed=True)
k('flyout', 'off')
d = at_width(900, sidebar=None, panel=None)
k('overlayPanel', 'on')
d = until(sized(panel=400), label='the panel over the graph')
steady()
p = frame(full_dump(), 'panel')
# The 9 pt handle straddles the leading edge. Press inside its overlap with the panel.
x, y = p[0] + 2, p[1] + p[3] / 2
d = drag('Panel width', x, y, x + 60, y, panel=340)
assert d['driver']['drag']['storedAfterMouseUp']['panel'] == 340, d['driver']['drag']
wait_saved_settings({'KaernPanelWidth': 340})
snap('panes-overlay340', mode, changed=True)
k('overlayPanel', 'off')
assert panes(until(sized(panel=None)))['sidebar'] == 240
quit_app()
relaunch(mode)
show_tab('powerlens')
d = at_width(1440, sidebar=240, panel=340)
assert panes(d)['panel'] == 340 and stored_setting('KaernPanelWidth') == 340, panes(d)
quit_app()

# Sidebar switching: the repository list too.
launch_prepared(mode, extra=['-KaernRepositorySwitching', 'sidebar'])
show_tab('powerlens')
d = at_width(1440, list=228, sidebar=230, panel=316)
l, s = frame(d, 'list'), frame(d, 'sidebar')
assert near(s[0], l[0] + l[2]), 'the sidebar starts where the list ends'
d = drag('Repository list width', l[0] + l[2], l[1] + l[3] / 2, l[0] + l[2] + 90, l[1] + l[3] / 2, list=318, sidebar=230)
s = frame(d, 'sidebar')
assert near(s[0], 318), 'the sidebar moved with it: %s' % s
# As wide as the repository beside it allows: its sidebar, panel and middle at their least (1,440 − 860 = 580).
d = drag('Repository list width', 318, l[1] + l[3] / 2, 1100, l[1] + l[3] / 2, list=580, sidebar=180, panel=280)
s, p = frame(d, 'sidebar'), frame(d, 'panel')
print('the list at its most:', frame(d, 'list'), s, p, 'middle', middle(d))
assert panes(d)['list'] == 580 and near(middle(d), 400), panes(d)
assert panes(d)['sidebar'] == 0 and panes(d)['panel'] == 0, 'the sizes beside it are kept: %s' % panes(d)
snap('panes-list580', mode, changed=True)
d = double_click(580, l[1] + l[3] / 2, list=228, sidebar=230, panel=316)
assert panes(d)['list'] == 0, panes(d)
quit_app()
print('PANES OK')
