"""t_lifecycle.py — which git processes the history stream leaves behind: first page, tab in the background,
resumed stream, a new commit while streaming, tab closed, app quit, app killed."""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
NAME = 'cluster-config'
REPO = os.path.join(SAMPLES, NAME)


def gits():
    """git processes whose working folder is the big sample, as 'pid ppid stat command'."""
    out = subprocess.run(['lsof', '-a', '-c', 'git', '-d', 'cwd', '-Fpn'], capture_output=True, text=True).stdout
    root = os.path.realpath(REPO)
    pids, pid = [], None
    for line in out.splitlines():
        if line.startswith('p'):
            pid = line[1:]
        elif line.startswith('n') and pid and os.path.realpath(line[1:]).startswith(root):
            pids.append(pid)
    rows = []
    for p in pids:
        r = subprocess.run(['ps', '-o', 'pid=,ppid=,stat=,command=', '-p', p], capture_output=True, text=True).stdout.strip()
        if r:
            rows.append(' '.join(r.split()))
    return rows


def show(label, settle=1.5):
    time.sleep(settle)
    rows = gits()
    print('%-34s %d git  %s' % (label, len(rows), ' || '.join(r[:150] for r in rows)))
    return rows


def hist(d=None):
    x = (d or full_dump())['phase5'].get('history', {})
    return {key: x.get(key) for key in ('commits', 'stream', 'shown', 'topRow')}


def h(d): return d['phase5']['history']


# show()'s pauses are the check itself (which git processes are left a moment after each step), not waits
# for the app; what the app does in between is waited for by its state.
launch_prepared('light', prepare=lambda: big_sample(NAME, 3000))
d = show_tab(NAME, lambda d: h(d)['commits'] >= 400)
print('history:', hist(d))
first = show('first page loaded')

show_tab('powerlens')
show('tab in the background', settle=2.5)

show_tab(NAME)
k('loadMore')
d = settle(lambda d: h(d)['commits'] >= 800, label='second page')
print('history:', hist(d))
show('stream resumed, second page')

# A new commit while the stream is open: the history reloads; the old stream must go, and its rows must not come back.
with open(os.path.join(REPO, 'lifecycle.txt'), 'w') as f:
    f.write('x\n')
g(REPO, 'add', 'lifecycle.txt')
g(REPO, '-c', 'user.name=T', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'test: lifecycle commit')
d = settle(lambda d: d['active']['head'] == g(REPO, 'rev-parse', 'HEAD')[:7], label='the app noticed the commit')
print('history after the new commit:', hist(d))
show('after a new commit')
before = h(d)['commits']
k('loadMore')
d = settle(lambda d: h(d)['commits'] > before, label='another page')
print('history after another page:', hist(d))
show('after another page')

k('close', NAME)
until(lambda d: tab(d, NAME) is None, label='the tab closed')
show('tab closed', settle=3)

# Open it again, read two pages, then quit the app normally.
k('open', REPO)
settle(lambda d: active_name(d) == NAME and h(d)['commits'] >= 400, label='reopened first page')
k('loadMore')
settle(lambda d: h(d)['commits'] >= 800, label='reopened second page')
show('reopened, two pages')
quit_app()
show('after quit', settle=2.5)

# Launch on the same session (the tab is open again), read a page, then kill the app.
relaunch('light')
show_tab(NAME, lambda d: h(d)['commits'] >= 400)
show('relaunched, first page')
kill_app(hard=True)
show('after kill -9', settle=3)
print('done')
