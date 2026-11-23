"""t_arrows.py [light|dark] — ↑ ↓ in the panel's file lists: a click on one of a commit's files gives the list the
arrow keys and Review follows them; back from Review the graph has them again without a click; Unstaged and Staged
step as one list, from the end of Unstaged on into Staged (a partly staged file has a row in each); Focus's drawer
steps through its files. In each, a key held down keeps going: a held key sends repeats, which a press doesn't."""
import os, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'


def review(d): return d['active']['review']
def files(d): return [f['path'] for f in d['active']['reviewFiles']]
def selection(d): return d['active']['selection']
def reviewing(path): return lambda d: review(d) and not review(d)['all'] and review(d)['path'] == path


def click_row(*spec):
    f = target_frame(*spec)
    k('click', '%g' % (f[0] + f[2] / 2), '%g' % (f[1] + f[3] / 2))


def press(key, check, label):
    k('press', key)
    return until(check, label=label)


def hold(key, rows, check, label):
    """The key held down for more repeats than the `rows` it has to cross (a repeat that comes before the list is
    drawn again steps from the same row, so some may not count): it ends where `check` says, and stays there."""
    k('press', key, 'hold', str(rows + 6), 'every', '60')
    return until(lambda d: check(d) and not d['driver']['pointerBusy'], seconds=30, label=label)


def changes():
    """More uncommitted changes in powerlens (it has some): two files changed, one staged, one partly staged."""
    root = os.path.join(SAMPLES, 'powerlens')
    paths = [p for p in g(root, 'ls-files').splitlines() if p.endswith(('.md', '.txt', '.swift', '.py', '.json', '.yml'))][:4]
    assert len(paths) == 4, paths
    for p in paths:
        with open(os.path.join(root, p), 'a') as f: f.write('\nchanged for t_arrows\n')
    g(root, 'add', paths[2], paths[3])
    with open(os.path.join(root, paths[3]), 'a') as f: f.write('and again, not staged\n')


launch_prepared(mode, prepare=changes)
show_tab('powerlens')

# A commit with three files or more.
for index in range(1, 60):
    k('select', str(index)); k('review', 'all')
    d = maybe(lambda d: selection(d).startswith('commit %d ' % index) and review(d) and len(files(d)) > 0, seconds=6)
    if d and len(files(d)) >= 3: break
else:
    raise SystemExit('no commit with three files in the first 60')
paths = files(d)
print('commit', index, paths)
k('review', 'off')
until(lambda d: review(d) is None and not d['active']['reviewFiles'] or review(d) is None, label='Review closed')
steady()

# A click on the first file: Review shows it, and ↓ ↓ ↑ step through the list.
click_row('commitFile', paths[0])
d = until(lambda d: reviewing(paths[0])(d) and not d['driver']['pointerBusy'], label='the first file after a click')
print('clicked:', review(d), '· first responder', d['driver']['firstResponder'])
d = press('down', reviewing(paths[1]), '↓: the second file')
d = press('down', reviewing(paths[2]), '↓ ↓: the third file')
d = press('up', reviewing(paths[1]), '↑: the second file again')
print('↓ ↓ ↑ in the commit\'s files:', review(d))
d = hold('down', len(paths), reviewing(paths[-1]), 'held ↓: the commit\'s last file')
d = hold('up', len(paths), reviewing(paths[0]), 'held ↑: the commit\'s first file')
print('held ↓ then ↑ through the commit\'s %d files:' % len(paths), review(d)['path'])
press('down', reviewing(paths[1]), '↓: the second file')
snap('arrows-commit-files', mode, changed=True)

# Back from Review the graph takes ↑ without a click (the commit may be the oldest).
k('press', 'escape')
if not maybe(lambda d: review(d) is None, seconds=3):
    print('(Esc through the window did not close Review; closing it from the driver)')
    k('review', 'off')
until(lambda d: review(d) is None, label='Review closed')
time.sleep(0.3)
d = press('up', lambda d: selection(d).startswith('commit %d ' % (index - 1)), '↑ in the graph after Review')
print('graph after Review:', selection(d)[:40])
if index >= 6:      # room above: four rows up (the graph steps once a repeat, whether or not it was drawn in between)
    k('press', 'up', 'hold', '3', 'every', '60')
    d = until(lambda d: selection(d).startswith('commit %d ' % (index - 5)) and not d['driver']['pointerBusy'], label='held ↑ in the graph')
    print('held ↑ in the graph:', selection(d)[:40])

# The working copy: Unstaged, then Staged, as one list.
k('select', 'wip')
d = until(lambda d: selection(d) == 'wip' and d['active']['unstaged'] and d['active']['staged']
          and set(d['active']['unstaged']) & set(d['active']['staged']), label='the working copy with a partly staged file')
unstaged, staged = d['active']['unstaged'], d['active']['staged']
print('unstaged', unstaged, '· staged', staged)
steady()
click_row('file', unstaged[0])
d = until(lambda d: reviewing(unstaged[0])(d) and not d['driver']['pointerBusy'], label='the first unstaged file after a click')
for path in unstaged[1:] + staged:
    d = press('down', reviewing(path), '↓ to %s' % path)
    print('↓', review(d)['path'])
d = press('down', reviewing(staged[-1]), '↓ at the end stays')
for path in reversed(unstaged + staged[:-1]):
    d = press('up', reviewing(path), '↑ to %s' % path)
print('↑ back to', review(d)['path'])
everything = unstaged + staged
d = hold('down', len(everything), reviewing(staged[-1]), 'held ↓: from Unstaged on to the last staged file')
d = hold('up', len(everything), reviewing(unstaged[0]), 'held ↑: back to the first unstaged file')
print('held ↓ then ↑ through Unstaged and Staged:', review(d)['path'])
snap('arrows-working-files', mode, changed=True)

# Focus's drawer: a click on a file gives its list the keys.
def drawer_path(path): return lambda d: d['active']['drawerPath'] == path
k('review', 'off'); k('select', str(index)); k('focus', 'on')
d = until(lambda d: selection(d).startswith('commit %d ' % index) and d['active']['drawer'] and files(d) == paths
          and d['phase5']['layout']['panes']['frames'].get('drawer'), label='Focus with the commit\'s files in its drawer')
steady()
x, y, w, h = full_dump()['phase5']['layout']['panes']['frames']['drawer']
k('click', '%g' % (x + 120), '%g' % (y + 40 + 4 + 13))     # under the 40 pt header and 4 pt of padding, the first 26 pt row
d = until(lambda d: drawer_path(paths[0])(d) and not d['driver']['pointerBusy'], label='the drawer\'s first file after a click')
d = press('down', drawer_path(paths[1]), '↓ in the drawer')
d = hold('down', len(paths), drawer_path(paths[-1]), 'held ↓: the drawer\'s last file')
d = hold('up', len(paths), drawer_path(paths[0]), 'held ↑: the drawer\'s first file')
print('held ↓ then ↑ through the drawer\'s %d files:' % len(paths), d['active']['drawerPath'])
k('focus', 'off')
quit_app()
print('ok')
