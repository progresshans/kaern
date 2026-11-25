"""t_knownbugs.py — the known bugs fixed after the release check (2026-11-10), in the app:
1. A remote branch picked in the sidebar while a refresh reads history with the graph's scope from before the
   pick: once the branch is drawn, its commit is selected (the refresh under way used to take the selection and
   look for the commit in a history without that branch, and the selection stayed on WIP).
2. Line counts never go back to an older read: a read waits after git answered, a line is added and a file staged
   meanwhile (that asks for the counts again), then the waiting read goes on. The counts shown only move forward
   and end with the newest.
3. A new tab joins the same group every time when groups tie: the leftmost in the strip (a dictionary's order
   used to pick one at random).
4. A file saved in another worktree updates that worktree's count in the sidebar, with no refresh of the shown
   repository (its watcher doesn't see that folder; the count used to wait for something else to refresh).
KAERN_STEPS=2,4 runs some of the steps (each starts its own instance)."""
import os, subprocess, sys, time; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen6 import big_remotes, REMOTE_ONLY


def p6(d): return d['phase6']
def holding(d): return d['driver']['holding']


def step1():
    name, expo = 'cluster-config', REMOTE_ONLY['env/expo-preview']
    launch_prepared('light', prepare=lambda: big_remotes(name))
    d = show_tab(name, lambda d: p6(d)['commits'] >= 400 and p6(d)['total'] >= 0, seconds=40)
    assert p6(d)['graphScope'] == 'local' and expo not in p6(d)['subjects']
    # A refresh that has read git (history with the scope from before the pick) and waits.
    hold_at('status'); k('refresh')
    until(lambda d: 'status' in holding(d), label='the refresh to wait with what it read')
    k('showRemote', 'origin/env/expo-preview')
    sync()
    k('release', 'status')
    d = settle(lambda d: expo in p6(d)['subjects'] and p6(d)['total'] >= 0, label='the branch drawn')
    print('1. picked while a refresh read history: selection %r' % p6(d)['selection'])
    assert p6(d)['selection'] == expo, 'the picked branch should be selected, not %r' % p6(d)['selection']
    quit_app()


def step2():
    launch('light', 'base')
    show_tab('powerlens')
    readme = os.path.join(PL, 'README.md')
    other = next(p for p in git('ls-files').splitlines() if p != 'README.md')
    def stat(d): return d['driver']['lineStats'].get('README.md', '')
    def append(path, text):
        with open(path, 'a') as f: f.write(text + '\n')
    append(readme, 'one')
    settle(lambda d: stat(d) == '+1 −0', label='README.md +1')
    hold_at('lineStats')
    append(readme, 'two')
    until(lambda d: 'lineStats' in holding(d), label='a line-count read to wait (it has +2)')
    # Meanwhile: a third line, and a file staged (its status read asks for the counts again).
    append(readme, 'three')
    append(os.path.join(PL, other), '# staged meanwhile')
    k('stage', other)
    until(lambda d: other in d['active']['staged'], label='the file staged')
    seen = [stat(full_dump())]
    k('release', 'lineStats')
    end = time.time() + 6
    while time.time() < end:
        d = full_dump()
        if seen[-1] != stat(d): seen.append(stat(d))
        if stat(d) == '+3 −0' and not d['driver']['busy']: break
        time.sleep(0.005)
    d = settle(lambda d: stat(d) == '+3 −0', label='README.md +3')
    print('2. README.md counts shown from the release on:', seen)
    order = ['+1 −0', '+2 −0', '+3 −0']
    steps = [order.index(s) for s in seen if s in order]
    assert steps == sorted(steps), 'the counts went back to an older read: %s' % seen
    quit_app()


def step3():
    launch('light', 'base')
    tabs = full_dump()['windows'][0]['tabs']
    counts = {}
    for t in tabs:
        if t['group']: counts[t['group']] = counts.get(t['group'], 0) + 1
    most = max(counts.values())
    tied = [t['group'] for t in tabs if t['group'] and counts[t['group']] == most]
    expected = 'samples' if 'samples' in tied else tied[0]
    folder = os.path.join(SAMPLES, 'newrepo')
    os.makedirs(folder)
    subprocess.run([GIT, 'init', '-q'], cwd=folder, env=ENV)
    k('open', folder)
    d = settle(lambda d: any(t['name'] == 'newrepo' for t in d['windows'][0]['tabs']), label='the newrepo tab')
    joined = next(t['group'] for t in d['windows'][0]['tabs'] if t['name'] == 'newrepo')
    print('3. groups %s | tied %s | joined %r' % (counts, sorted(set(tied)), joined))
    assert joined == expected, 'the new tab should join %r, the leftmost of the tied groups' % expected
    quit_app()


def step4():
    launch_prepared('light', scenario='signed')
    show_tab('powerlens')
    hotfix = os.path.join(SAMPLES, 'powerlens-hotfix')
    def count(d):
        line = next((w for w in p6(d)['worktrees'] if w.startswith('powerlens-hotfix |')), '')
        return line.split(' | ')[2] if line else ''
    d = settle(lambda d: count(d) == '2', label='the hotfix worktree with its 2 changes')
    refreshes = tab(d, 'powerlens')['refreshes']
    with open(os.path.join(hotfix, 'a-note-from-the-other-tree.md'), 'w') as f: f.write('a note\n')
    d = until(lambda d: count(d) == '3', seconds=10, label="the hotfix worktree's count to follow")
    print("4. hotfix worktree's count: 2 → %s | refreshes of powerlens: %d → %d" % (count(d), refreshes, tab(d, 'powerlens')['refreshes']))
    assert tab(d, 'powerlens')['refreshes'] == refreshes, 'the count should follow without a refresh of powerlens'
    quit_app()


STEPS = {'1': step1, '2': step2, '3': step3, '4': step4}
for name in (os.environ.get('KAERN_STEPS') or '1,2,3,4').split(','):
    STEPS[name.strip()]()
print('KNOWNBUGS OK')
