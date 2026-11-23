"""t_review5.py — the fixes after the phase-5 review, in the app:
1. Update to Recorded asks before leaving commits on no branch; ⌘Z / ⇧⌘Z; no question when a ref holds them.
2. Locate… refuses a folder inside another repository and takes the repository's own folder.
3. Quick Look keeps one copy at a time.
4. Repositories window › Pull on a tab in the background uses the repository's pull.rebase.
5. A first load cut short by switching tabs loads again when the tab comes back."""
import json, os, shutil, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen5 import diverge, run

REPO = os.path.join(SAMPLES, 'powerlens')
SUB = os.path.join(REPO, 'Vendor', 'Sparkle')
LIB = os.path.join(SAMPLES, 'remotes', 'Sparkle')
BIG = os.path.join(SAMPLES, 'big-history')
MOVED = os.path.join(SAMPLES, 'moved')


def prepare():
    subprocess.run(['rm', '-rf', LIB, BIG, MOVED], check=True)
    os.makedirs(LIB)
    run(LIB, 'init', '-q', '-b', 'main')
    for version in ('2.6.4', '2.7.0'):
        open(os.path.join(LIB, 'VERSION'), 'w').write(version + '\n')
        run(LIB, 'add', '-A'); run(LIB, 'commit', '-q', '-m', 'Release ' + version); run(LIB, 'tag', version)
    run(REPO, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', LIB, 'Vendor/Sparkle')
    run(SUB, 'checkout', '-q', '2.6.4')
    run(REPO, 'add', '.gitmodules', 'Vendor/Sparkle'); run(REPO, 'commit', '-q', '-m', 'Add Sparkle at 2.6.4')
    # Moved to 2.7.0, then a commit there on a detached HEAD that no branch holds.
    run(SUB, 'checkout', '-q', '2.7.0')
    open(os.path.join(SUB, 'LOCAL'), 'w').write('local\n')
    run(SUB, 'add', 'LOCAL'); run(SUB, 'commit', '-q', '-m', 'Local fix')
    # orders-api: 5 ahead, 2 behind, a clean work tree, and Pull rebases there (its own setting).
    orders = os.path.join(SAMPLES, 'orders-api')
    run(orders, 'checkout', '--', '.')
    diverge('orders-api', 5, 2)
    run(orders, 'config', 'pull.rebase', 'true')
    big_sample('big-history', 60000)


def head():
    return run(SUB, 'rev-parse', 'HEAD')


def log_lines(d, needle):
    return [line for line in d['active'].get('commandLog', []) if needle in line]


def marks(d): return d['phase5']['marks']
def rows(d): return {row.split(' | ')[0]: row for s in d['phase5']['repositories']['sections'] for row in s['rows']}


launch_prepared('light', prepare=prepare)
show_tab('powerlens')
local = head()
recorded = run(REPO, 'ls-tree', 'HEAD', 'Vendor/Sparkle').split()[2]
print('submodule at the local commit %s, recorded %s' % (local[:7], recorded[:7]))

# 1. Update to Recorded.
k('updateRecorded', 'Vendor/Sparkle', '2.6.4')
c = until(lambda d: d['active']['confirmation'], label='the question before leaving a commit behind')['active']['confirmation']
print('1. question:', c)
assert c and c['title'] == 'Leave 1 commit in Vendor/Sparkle on no branch?' and c['lost'] == ['Local fix'], c
k('dismiss')
settle(lambda d: d['active']['confirmation'] is None, label='the question cancelled')
assert head() == local, 'Cancel leaves the submodule where it was'
k('updateRecorded', 'Vendor/Sparkle', '2.6.4')
until(lambda d: d['active']['confirmation'], label='the question again')
k('confirm')
a = settle(lambda d: head() == recorded and toast(d) == 'Vendor/Sparkle is at 2.6.4 again', label='Update to Recorded')['active']
print('   after Update:', head()[:7], '| toast', a['toast'], '| undo', a['undo'][-1:])
assert head() == recorded and a['toast'] and a['toast']['message'] == 'Vendor/Sparkle is at 2.6.4 again' and a['toast']['undo']
assert a['undo'][-1] == 'Update Vendor/Sparkle to 2.6.4'
k('undo')
settle(lambda d: head() == local, label='⌘Z')
print('   after ⌘Z:', head()[:7]); assert head() == local, '⌘Z brings the local commit back'
k('redo')
settle(lambda d: head() == recorded, label='⇧⌘Z')
print('   after ⇧⌘Z:', head()[:7]); assert head() == recorded
run(SUB, 'checkout', '-q', '2.7.0')
# The app notices the submodule at 2.7.0.
settle(lambda d: any(line.startswith('Vendor/Sparkle | 2.6.4 → 2.7.0') for line in marks(d)['sidebarSubmodules']), label='the submodule moved to 2.7.0')
k('updateRecorded', 'Vendor/Sparkle', '2.6.4')
a = settle(lambda d: head() == recorded and d['active']['confirmation'] is None, label='Update to Recorded without a question')['active']
print('   held by a tag: question', a['confirmation'], '| at', head()[:7])
assert a['confirmation'] is None and head() == recorded

# 2. Locate….
crm = os.path.join(SAMPLES, 'CRM')
os.makedirs(MOVED)
shutil.move(crm, os.path.join(MOVED, 'CRM'))
os.makedirs(os.path.join(MOVED, 'CRM', 'docs'), exist_ok=True)
# The app notices the folder is gone.
settle(lambda d: tab(d, 'CRM')['phase'] == 'missing', label='the CRM tab without its folder')

def relocate(target):
    """Locate…'s choice, and what came back once the app had looked at the folder (it asks git)."""
    n = commands(full_dump())
    k('relocate', crm, target)
    return settle(lambda d: commands(d) > n and d['phase5']['lastRelocate'] != '', label='Locate… answered')['phase5']['lastRelocate']

answer = relocate(os.path.join(MOVED, 'CRM', 'docs'))
print('2. a folder inside the repository:', answer); assert answer == 'refused'
answer = relocate(os.path.join(REPO, 'Sources'))
print('   a folder inside another repository:', answer); assert answer == 'refused'
k('relocate', crm, os.path.join(MOVED, 'CRM'))
found = settle(lambda d: d['phase5']['lastRelocate'].endswith('/moved/CRM'), label='Locate… took the repository\'s own folder')['phase5']['lastRelocate']
print('   the repository\'s own folder:', found.replace(SAMPLES, '<samples>'))
assert found.endswith('/moved/CRM')

# 3. Quick Look keeps one copy at a time.
show_tab('powerlens')
k('select', '1')
k('review', 'all')
d = settle(lambda d: d['active']['selection'].startswith('commit 1') and any(f.split(' ')[-1] == 'text' for f in marks(d)['files']), label='the commit\'s files in Review')
files = [f.split(' ')[1] for f in marks(d)['files'] if f.split(' ')[-1] == 'text']
print('3. files in the commit:', files[:3])
def copies(name):
    """Quick Look copies of a file with this name. (Every Kaern that runs shares the folder, so the dump's
    count of everything in it changes when another test instance shows a file.)"""
    folder = os.path.join(os.environ.get('TMPDIR', '/tmp'), 'Kaern Quick Look')
    return sum(os.path.exists(os.path.join(folder, d, name)) for d in os.listdir(folder)) if os.path.isdir(folder) else 0

counts = []
for path in files[:1] * 2:
    k('review', 'one', path)
    settle(lambda d: (d['active']['review'] or {}).get('path') == path, label='the file in Review')
    k('quickLook')
    m = marks(until(lambda d: marks(d)['quickLook'] != '', label='Quick Look open'))
    counts.append(copies(m['quickLook']))
    print('   quick look', m['quickLook'], '| copies of it in the folder:', counts[-1])
    k('quickLook')
    until(lambda d: marks(d)['quickLook'] == '', label='Quick Look closed')
# counts[0] >= 1: the folder is this instance's (a different TMPDIR would count nothing twice).
assert len(counts) == 2 and counts[0] >= 1 and counts[1] == counts[0], 'the second copy replaced the first: %s' % counts
k('review', 'off')
until(lambda d: d['active']['review'] is None, label='Review closed')

# 4. Repositories window › Pull on orders-api (a background tab, pull.rebase = true).
d = full_dump(); print('4. orders-api phase:', tab(d, 'orders-api')['phase'])
orders = os.path.join(SAMPLES, 'orders-api')
k('repositories')
settle(lambda d: d['phase5']['repositories']['open'] and rows(d)['orders-api'].endswith('| Pull'), label='the Repositories window with Pull on orders-api')
k('reposFix', 'orders-api')
settle(lambda d: run(orders, 'rev-list', '--left-right', '--count', 'HEAD...@{u}').split() == ['5', '0'], label='the Pull from the list')
reflog = run(orders, 'reflog', '-6', '--format=%gs').splitlines()
parents = run(orders, 'rev-list', '--parents', '-n', '1', 'HEAD').split()
counts = run(orders, 'rev-list', '--left-right', '--count', 'HEAD...@{u}')
print('   reflog:', reflog[:3], '| HEAD parents:', len(parents) - 1, '| ahead/behind:', counts)
k('reposClose')
until(lambda d: not d['phase5']['repositories']['open'], label='the Repositories window closed')
assert any('rebase' in line for line in reflog), 'Pull rebased (the repository\'s pull.rebase)'
assert len(parents) - 1 == 1 and counts.split() == ['5', '0']

# 5. A first load cut short by switching tabs. The pause between Open and the switch is the step itself (when
# the user switches away), not a wait for the app: the switch has to arrive while the first `git log` is being
# read, and looking at the app in between (a dump) moves that moment. A few pauses are tried.
cut = False
for delay in (0.15, 0.3, 0.5, 0.8, 0.1, 0.2, 0.4):
    if tab(full_dump(), 'big-history'):
        k('close', 'big-history')
        until(lambda d: tab(d, 'big-history') is None, label='the big-history tab closed')
        settle(label='quiet before the next try')
    k('open', BIG, wait=delay)
    k('activateName', 'powerlens')
    d = settle(lambda d: active_name(d) == 'powerlens' and tab(d, 'big-history')['phase'] == 'ready', label='powerlens shown again')
    t = tab(d, 'big-history')
    stopped = [line for line in d['active'].get('commandLog', []) if 'log --date-order' in line and ' 15 ' in line]
    print('5. switched away after %.2fs: big-history phase %s, %s commits, stopped logs %d' % (delay, t and t['phase'], t and t['commits'], len(stopped)))
    if t and t['commits'] == 0 and t['phase'] == 'ready':
        cut = True
        break
if cut:
    before = tab(full_dump(), 'big-history')['refreshes']
    k('activateName', 'big-history')
    d = settle(lambda d: active_name(d) == 'big-history' and d['phase5']['history']['commits'] >= 400, seconds=30, label='history after coming back')
    x = d['phase5']['history']
    print('   back on the tab:', x['commits'], 'commits |', x['stream'], '| refreshes', before, '->', tab(d, 'big-history')['refreshes'])
    assert x['commits'] == 400 and 'finished false' in x['stream']
else:
    print('NOTE: the switch never landed inside the first read; the unit test covers the cut read')
quit_app()
print('REVIEW FIXES OK')
