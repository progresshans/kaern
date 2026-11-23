"""t_zoom.py [light|dark] — View › Zoom In, Zoom Out, Actual Size: Kaern's text, rows and spacing larger or smaller.
⌘= and ⌘+ go up a step, ⌘− down, ⌘0 back to actual size, and the ends hold. At each step the sidebar and the panel
are their design widths times the zoom, the window's buttons sit in the middle of the tab row as it's drawn, and a
click lands on the row its frame names. A pane dragged while zoomed keeps its design width for actual size, and a
window narrower than the narrowest at the new zoom grows to it."""
import os, re, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'


def zoom(d): return float(d['settings'].get('KaernZoom', 1))
def frames(d): return d['phase5']['layout']['panes']['frames']
def window(d): return d['windows'][0]
def size(d): return [float(v) for v in re.findall(r'[-\d.]+', window(d)['frame'])][2:]
def review(d): return d['active']['review']
def files(d): return [f['path'] for f in d['active']['reviewFiles']]
def near(a, b): return abs(a - b) <= 1


def at(factor, sidebar=230, panel=316):
    """Zoomed to `factor`: the setting, the panes at their design widths × the zoom (None: not beside the middle
    at this width), and the close button in the middle of the 36 pt tab row as it's drawn."""
    def check(d):
        f = frames(d)
        for name, width in (('sidebar', sidebar), ('panel', panel)):
            if width is None:
                if name in f: return False
            elif name not in f or not near(f[name][2], width * factor): return False
        return abs(zoom(d) - factor) < 0.001 and near(window(d)['closeButtonFromTop'], 18 * factor)
    return check


def key(character, label, factor, **panes):
    k('key', character, 'cmd')
    d = until(at(factor, **panes), label=label)
    print('%-12s zoom %.2f · panes %s · close button %.1f pt down' % (label, zoom(d), {n: round(f[2]) for n, f in frames(d).items()}, window(d)['closeButtonFromTop']))
    return d


launch_prepared(mode)
show_tab('powerlens')
for index in range(1, 60):
    k('select', str(index)); k('review', 'all')
    d = maybe(lambda d: d['active']['selection'].startswith('commit %d ' % index) and review(d) and len(files(d)) > 0, seconds=6)
    if d and len(files(d)) >= 2: break
else:
    raise SystemExit('no commit with two files')
paths = files(d)
k('review', 'off'); until(lambda d: review(d) is None, label='Review closed'); steady()
d = until(at(1), label='actual size')
width, height = size(d)

key('=', '⌘=', 1.1)
key('+', '⌘+', 1.25)
snap('zoom-125', mode)
# A click goes by the frame the app reports.
k('select', str(index)); until(lambda d: d['active']['selection'].startswith('commit %d ' % index), label='the commit again'); steady()
f = target_frame('commitFile', paths[1])
k('click', '%g' % (f[0] + f[2] / 2), '%g' % (f[1] + f[3] / 2))
d = until(lambda d: review(d) and review(d)['path'] == paths[1] and not d['driver']['pointerBusy'], label='a click on the second file at 125 %')
print('click at 125 %:', review(d)['path'])
k('review', 'off'); until(lambda d: review(d) is None, label='Review closed'); steady()

# The sidebar dragged 50 pt wider at 125 %: 40 pt of the design, kept for actual size.
s = frames(full_dump())['sidebar']
k('drag', '%g' % (s[0] + s[2]), '%g' % (s[1] + s[3] / 2), '%g' % (s[0] + s[2] + 50), '%g' % (s[1] + s[3] / 2))
d = until(lambda d: near(frames(d)['sidebar'][2], s[2] + 50) and not d['driver']['pointerBusy'], label='the sidebar dragged wider')
kept = float(d['settings']['KaernSidebarWidth'])
print('sidebar dragged to', round(frames(d)['sidebar'][2]), '· kept as', kept)
assert near(kept, 270), kept

# 150 %: this window is 960 pt of the design wide, so the sidebar is its rail (as in a window that narrow).
key('=', '⌘= again', 1.5, sidebar=None)
k('key', '=', 'cmd'); time.sleep(0.5); until(at(1.5, sidebar=None), label='150 % is the most')
snap('zoom-150', mode)
d = key('0', '⌘0', 1, sidebar=270)
assert size(d) == [width, height], (size(d), width, height)
k('pane', 'sidebar', '0'); until(at(1), label='the sidebar back at the board\'s width')
key('-', '⌘−', 0.9)
key('-', '⌘− again', 0.8)
snap('zoom-80', mode)
k('key', '-', 'cmd'); time.sleep(0.5); until(at(0.8), label='80 % is the least')

# A window as narrow as it goes at actual size is too narrow for 150 %: it grows to that zoom's narrowest.
key('0', '⌘0', 1)
k('resize', '760', '520'); until(lambda d: size(d) == [760, 520], label='the narrowest window')
k('zoom', '1.5')
d = until(lambda d: abs(zoom(d) - 1.5) < 0.001 and size(d) == [1140, 780], label='the window grown for 150 %')
print('narrowest window at 150 %:', size(d))
k('zoom', '1'); until(lambda d: abs(zoom(d) - 1) < 0.001, label='actual size again')
print('ZOOM OK')
quit_app()
