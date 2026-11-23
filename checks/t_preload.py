"""t_preload.py — does a background tab that was preloaded but never shown keep a paused git log?"""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
NAME = 'cluster-config'
REPO = os.path.join(SAMPLES, NAME)


def gits():
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
        r = subprocess.run(['ps', '-o', 'pid=,stat=,etime=,command=', '-p', p], capture_output=True, text=True).stdout.strip()
        if r:
            rows.append(' '.join(r.split())[:120])
    return rows


launch_prepared('light', prepare=lambda: big_sample(NAME, 3000))
start = time.time()
# Leave the big tab alone: the preload after launch went through the background tabs before launch_prepared
# returned. These pauses are the check itself (what is left some time later), not waits for the app.
for until_seconds in (8, 15, 30):
    time.sleep(max(0, until_seconds - (time.time() - start)))
    d = full_dump()
    rows = gits()
    print('t=%2ds  active tab: %-12s  git in the big background tab: %d  %s' % (until_seconds, d['active'].get('name'), len(rows),
                                                                             ' || '.join(rows)))
kill_app()
print('done')
