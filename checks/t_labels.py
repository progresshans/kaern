"""t_labels.py [light|dark] — several refs on one commit show as one label and "+N"; with the pointer on it, every
label unfolds in a list over the rows below (up, the other way round, near the bottom of the history), each with its
right-click target. A test window in the background gets no hover, and the real pointer is kept out of test
instances: `labels <hash>` opens a row's list the way the pointer would.

The list is the list wherever it lies, so the pointer can go from the label into it: a press on one of its labels,
over another row, belongs to the list's commit (a press finds its view the way the pointer's hover does), and the list
covers the first label and "+N" it unfolded from (`targetFrame labels list|row`)."""
import os, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'


def refs():
    """Two more branches and a tag on powerlens's HEAD commit, and a branch and a tag on its first commit."""
    root = os.path.join(SAMPLES, 'powerlens')
    g(root, 'branch', 'release/1.2')
    g(root, 'branch', 'hotfix/battery-serial')
    g(root, 'tag', 'v1.2.0')
    first = g(root, 'rev-list', '--max-parents=0', 'HEAD').splitlines()[0]
    g(root, 'branch', 'archive/first-light', first)
    g(root, 'tag', 'v0.1.0', first)


def frame_of(kind, name):
    k('targetFrame', kind, name)
    return full_dump()['phase5']['targetFrame']


def row_of(sha, count):
    """The history row of a commit: select rows until the selection is that commit."""
    for index in range(count):
        k('select', str(index))
        d = until(lambda d: d['active']['selection'].startswith('commit %d ' % index), label='row %d selected' % index)
        if d['active']['selection'].split()[2] == sha[:7]: return index
    raise SystemExit('no row for %s' % sha[:7])


def covers(outer, inner):
    return (outer[0] <= inner[0] + 0.5 and outer[1] <= inner[1] + 0.5
            and outer[0] + outer[2] >= inner[0] + inner[2] - 0.5 and outer[1] + outer[3] >= inner[1] + inner[3] - 0.5)


def reachable(label, index, sha):
    """A press on `label` (a label in the open list, over another row) selects the list's commit, row `index`, not
    the row under the press; and the list covers the first label and "+N" the pointer opened it from."""
    before = full_dump()['active']['selection']
    k('click', '%g' % (label[0] + label[2] / 2), '%g' % (label[1] + label[3] / 2))
    d = until(lambda d: not d['driver']['pointerBusy'] and d['active']['selection'] != before, label='the press on the list')
    print('a press on the list selects:', d['active']['selection'])
    assert d['active']['selection'].split()[1:3] == [str(index), sha[:7]], 'a press on the list belongs to its commit'
    shown, whole = target_frame('labels', 'row'), target_frame('labels', 'list')
    print('the row shows its label and "+N" at', shown, '· the list is at', whole)
    assert covers(whole, shown), 'the list covers the label and "+N" it unfolded from'


launch_prepared(mode, prepare=refs)
try:
    show_tab('powerlens')
    k('resize', '1440', '900')
    d = until(lambda d: d['phase5']['layout']['width'] == 1440 and d['phase5']['history']['commits'] >= 20, label='powerlens at 1,440')
    frames = d['phase5']['layout']['panes']['frames']
    edge = frames['sidebar'][0] + frames['sidebar'][2]
    count = d['phase5']['history']['commits']
    root = os.path.join(SAMPLES, 'powerlens')
    head = g(root, 'rev-parse', 'HEAD')
    first = g(root, 'rev-list', '--max-parents=0', 'HEAD').splitlines()[0]

    # HEAD's commit: its branch, two more branches and a tag.
    top = row_of(head, count)
    k('select', 'wip')
    steady()
    row = target_frame('commit', str(top))
    print('HEAD is row', top, row)
    k('labels', head[:12])
    d = until(lambda d: (lambda f: f and f[0] > edge)(frame_of('branch', 'release/1.2')),
              label='the list open: release/1.2 drawn in the history')
    f = frame_of('branch', 'release/1.2')
    print('release/1.2 in the list at', f, '(row at y %g)' % row[1])
    assert f[1] > row[1], 'the list unfolds downward from the row'
    snap('labels-list-down', mode, changed=True)
    assert f[1] + f[3] / 2 > row[1] + row[3], 'release/1.2 lies over a row below'
    reachable(f, top, head)
    k('labels', 'off')
    until(lambda d: (lambda f: f is None or f[0] < edge)(frame_of('branch', 'release/1.2')), label='the list closed')
    print('closed')

    # The first commit, at the bottom of the history: the list unfolds upward.
    last = row_of(first, count)
    k('select', 'wip')
    k('scroll', str(last))   # as far down as it goes: the last row at the bottom
    time.sleep(0.5)
    steady()
    low = target_frame('commit', str(last))
    print('first commit is row', last, low)
    k('labels', first[:12])
    # The tag is only in the list (the row shows the branch and "+1").
    until(lambda d: (lambda f: f and f[0] > edge)(frame_of('tag', 'v0.1.0')), label='the bottom row\'s list open')
    f = frame_of('tag', 'v0.1.0')
    print('v0.1.0 in the list at', f, '(row at y %g)' % low[1])
    assert f[1] < low[1], 'near the bottom the list unfolds upward'
    snap('labels-list-up', mode, changed=True)
    assert f[1] + f[3] / 2 < low[1], 'v0.1.0 lies over a row above'
    reachable(f, last, first)
    print('ok')
finally:
    quit_app()
