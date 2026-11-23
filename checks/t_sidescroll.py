"""t_sidescroll.py [light|dark] — Settings › Diff › Wrap long lines off: long lines stay on one line and the text
scrolls sideways under fixed line numbers (trackpad scroll events through the event queue), in Review."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
NAME = 'powerlens'
REPO = os.path.join(SAMPLES, NAME)
LONG = 'README.md'
def side(d): return d['phase5']['sideScroll']

def prepare():
    with open(os.path.join(REPO, LONG), 'a') as f:
        f.write('\n' + 'The quick brown fox jumps over the lazy dog, ' * 9 + 'and that is the end of a very long line.\n')
        f.write('short line\n')

launch_prepared(mode, prepare=prepare)
show_tab(NAME)
k('select', 'wip')
k('review', 'one', LONG)
k('diffWrap', 'off')
d = settle(lambda d: side(d) and side(d)['max'] > 100, label='the long line wider than its column')
x = side(d); print('wrap off:', x)
assert x and x['max'] > 100, 'a long line is wider than the column'
snap('sidescroll-start', mode)
# Swipe left over the diff (dx < 0): the text moves left under the line numbers.
for _ in range(6):
    k('scrollWheel', '900', '420', '-60', '0'); sync()
d = until(lambda d: side(d)['offset'] == 360, label='six swipes of 60 moved the text by 360')
x = side(d); print('after swiping left:', x)
assert 300 <= x['offset'] <= x['max'], 'the text moved sideways'
snap('sidescroll-moved', mode, changed=True)
# Up and down still scroll the diff, not the text.
before = x['offset']
k('scrollWheel', '900', '420', '0', '-80')
d = until(lambda d: 'dx 0.0 dy -80.0' in side(d)['lastSeen'], label='the vertical scroll seen')
x = side(d); assert x['offset'] == before, 'a vertical scroll leaves the text where it is'
# Past the end it stops at the widest line.
for _ in range(30):
    k('scrollWheel', '900', '420', '-200', '0'); sync()
d = until(lambda d: abs(side(d)['offset'] - side(d)['max']) < 0.5, label='the text at its end')
x = side(d); print('at the end:', x)
assert abs(x['offset'] - x['max']) < 0.5
snap('sidescroll-end', mode, changed=True)
k('diffWrap', 'on'); sync()
print('SIDE SCROLL OK')
quit_app()
