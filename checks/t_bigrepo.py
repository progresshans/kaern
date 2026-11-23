"""t_bigrepo.py [light|dark] — big-repository behavior on a 3,000-commit sample (bigsample.py) in place of
cluster-config: one streaming git log, a stream that resumes where it stopped, Search paging into older
history, bot folding (collapse / expand / hide / show), the fsmonitor suggestion, and the windowed list
(jumping to the oldest commit, coming back to the top)."""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
NAME = 'cluster-config'
REPO = os.path.join(SAMPLES, NAME)
def h(d): return d['phase5']['history']

launch_prepared(mode, prepare=lambda: big_sample(NAME, 3000), extra=['-KaernSlowStatusSeconds', '0.001'])
d = show_tab(NAME, lambda d: h(d)['commits'] >= 400)
x = h(d); print('first page:', x['commits'], '|', x['stream'], '| runs', len(x['runs']), '| folded', x['folded'])
# Preloaded in the background, the tab let go of git after its first page (none); loaded while shown, it keeps it.
assert x['commits'] == 400 and x['stream'] in ('none', 'skip 0 read 400 finished false')
assert x['hasBots'] and x['folded'] > 0 and x['runs'], 'bot runs fold'
print('first run row:', x['runs'][0])

# The next page comes from the same git log, or from one that starts where the preload stopped.
k('loadMore')
d = settle(lambda d: h(d)['commits'] >= 800, label='second page')
x = h(d); print('second page:', x['commits'], '|', x['stream'])
assert x['stream'] in ('skip 0 read 800 finished false', 'skip 400 read 400 finished false')

# A tab in the background stops git; the next page starts a new stream where the old one stopped.
show_tab('powerlens')
show_tab(NAME)
k('loadMore')
d = settle(lambda d: h(d)['commits'] >= 1200, label='third page')
x = h(d); print('after the tab came back:', x['commits'], '|', x['stream'])
assert x['stream'] == 'skip 800 read 400 finished false'

# Search finds a commit that isn't loaded yet and pages to it.
k('search', 'the needle commit to find')
d = settle(lambda d: h(d)['searchMatches'] == 0 and h(d)['searchOlder'] == 1, label='the search counted older matches')
x = h(d); print('search:', x['searchMatches'], 'loaded,', x['searchOlder'], 'older')
assert x['searchMatches'] == 0 and x['searchOlder'] == 1
k('searchStep', '1')
# Selected, and the list has scrolled down to it (rows are folded, so it is near the end).
d = settle(lambda d: h(d)['selection'] == 'feat: the needle commit to find' and h(d)['topRow'] > h(d)['shown'] * 0.8, seconds=40, label='needle selected and in view')
x = h(d); print('stepped to:', x['selection'], '| commits', x['commits'], '| top row', x['topRow'], 'of', x['shown'])
assert x['topRow'] > x['shown'] * 0.8, 'the list scrolled down to the match (rows are folded, so it is near the end)'
snap('bigrepo-needle', mode)
k('search', 'off')
until(lambda d: not d['active']['search']['open'], label='the find bar closed')

# Expand the first folded run, then Hide and Show.
before = h(full_dump())
k('expandRun', before['runs'][0].split(':')[0])
d = until(lambda d: h(d)['shown'] > before['shown'] and h(d)['folded'] < before['folded'], label='the run expanded')
x = h(d); print('expanded: shown', before['shown'], '->', x['shown'], '| folded', before['folded'], '->', x['folded'])
assert x['shown'] > before['shown'] and x['folded'] < before['folded']
k('botMode', 'hide'); d = until(lambda d: h(d)['hidden'] > 0 and not h(d)['runs'], label='bot commits hidden')
x = h(d); print('hide: shown', x['shown'], '| hidden', x['hidden'])
assert x['hidden'] > 0 and not x['runs']
k('botMode', 'show'); d = until(lambda d: h(d)['shown'] == h(d)['commits'] and h(d)['hidden'] == 0, label='bot commits shown')
x = h(d); print('show: shown', x['shown'], '| commits', x['commits'])
assert x['shown'] == x['commits'] and x['hidden'] == 0
k('botMode', 'collapse'); until(lambda d: h(d)['runs'] and h(d)['folded'] > 0, label='bot commits folded again')

# Every commit, then the oldest one and back to the top: the list keeps only the rows in view.
k('loadMore', '5000')
d = settle(lambda d: not h(d)['hasMore'], seconds=40, label='all history')
x = h(d); last = x['shown'] - 1
k('scroll', str(x['commits'] - 1))
d = until(lambda d: h(d)['topRow'] > h(d)['shown'] - 40, label='scrolled to the oldest')
x = h(d); print('scrolled to the oldest: top row', x['topRow'], 'of', x['shown'])
assert x['topRow'] > x['shown'] - 40
snap('bigrepo-oldest', mode)
k('scroll', '0')
d = until(lambda d: h(d)['topRow'] < 5, label='back at the newest')
x = h(d); print('back to the newest: top row', x['topRow'])
assert x['topRow'] < 5

# The status took longer than the (lowered) threshold: the details panel suggests fsmonitor.
d = settle(lambda d: h(d)['suggestsFSMonitor'], label='the fsmonitor suggestion')
x = h(d); print('status %.3fs · suggests fsmonitor: %s · fsmonitor %s' % (x['statusSeconds'], x['suggestsFSMonitor'], x['fsmonitorOn']))
assert x['suggestsFSMonitor']
snap('bigrepo-fsmonitor', mode)
k('fsmonitorOn')
d = settle(lambda d: g(REPO, 'config', '--local', 'core.fsmonitor') == 'true' and not h(d)['suggestsFSMonitor'], label='fsmonitor turned on')
print('core.fsmonitor =', g(REPO, 'config', '--local', 'core.fsmonitor'), '| core.untrackedCache =', g(REPO, 'config', '--local', 'core.untrackedCache'))
assert g(REPO, 'config', '--local', 'core.fsmonitor') == 'true'
assert not h(d)['suggestsFSMonitor']
print('BIG REPO OK')
quit_app()
