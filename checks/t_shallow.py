"""t_shallow.py [light|dark] — a shallow clone (git clone --depth 2 of the powerlens sample over file://): the history
ends with the dashed row and Fetch 100 More / Fetch Full History; each fetch brings the older commits in."""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen5 import run
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
SHALLOW = os.path.join(SAMPLES, 'made', 'powerlens-shallow')
def h(d): return d['phase5']['history']

def prepare():
    subprocess.run(['rm', '-rf', SHALLOW], check=True)
    os.makedirs(os.path.dirname(SHALLOW), exist_ok=True)
    run(SAMPLES, 'clone', '-q', '--depth', '2', 'file://' + os.path.join(SAMPLES, 'powerlens'), SHALLOW)

launch_prepared(mode, prepare=prepare)
k('open', SHALLOW)
d = settle(lambda d: active_name(d) == 'powerlens-shallow' and d['phase5']['phase'] == 'ready' and not h(d)['hasMore'], label='shallow ready')
full = int(g(os.path.join(SAMPLES, 'powerlens'), 'rev-list', '--count', 'HEAD'))
x = h(d); print('shallow:', x['shallow'], '| commits', x['commits'], 'of', full)
assert x['shallow'] and x['commits'] < full
k('scroll', str(x['commits'] - 1))
snap('shallow-end', mode)
before = x['commits']
k('deepen', '3')
d = settle(lambda d: h(d)['commits'] > before and not h(d)['loadingMore'], seconds=30, label='deepened')
x = h(d); print('after Fetch 3 More:', x['commits'], '| shallow', x['shallow'])
assert x['commits'] > before
k('deepen', 'all')
d = settle(lambda d: not h(d)['shallow'] and h(d)['commits'] == full, seconds=30, label='unshallow')
x = h(d); print('after Fetch Full History:', x['commits'], '| shallow', x['shallow'])
assert not x['shallow'] and x['commits'] == full
print('SHALLOW OK')
quit_app()
