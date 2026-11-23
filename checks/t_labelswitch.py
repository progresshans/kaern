"""t_labelswitch.py [light|dark] — a double-click on a branch's label in the history switches to it, as in the
sidebar: the row's label and a label in its "+N" list (which lies over other rows). A remote branch's label checks out
a local branch that tracks it, a branch checked out in another worktree opens that worktree in a tab of its own, and a
tag's does nothing. A single click on a label only picks its commit. Test instances get no hover: `labels <hash>` opens a list."""
import os, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
CHECKED_OUT = 'feature/restore-automatic-alpha'   # the sample's checked-out branch


def refs():
    """HEAD: the checked-out branch, release/1.2 and origin/review/ui (a remote branch with no local one): "+2".
    HEAD~1: qa and the tag v1.3.0 ("qa +1"). HEAD~2: wt/side, checked out in a worktree of its own, and
    origin/feature/restore-automatic-alpha. The local changes touch none of the files these commits change."""
    root = os.path.join(SAMPLES, 'powerlens')
    g(root, 'branch', 'release/1.2')
    g(root, 'update-ref', 'refs/remotes/origin/review/ui', g(root, 'rev-parse', 'HEAD'))
    g(root, 'branch', 'qa', 'HEAD~1')
    g(root, 'tag', 'v1.3.0', 'HEAD~1')
    g(root, 'worktree', 'add', '-q', '-b', 'wt/side', os.path.join(SAMPLES, 'powerlens-side'), 'HEAD~2')


def frame_now(kind, name):
    k('targetFrame', kind, name)
    return full_dump()['phase5']['targetFrame']


def row_of(sha, count):
    """The history row of a commit: select rows until the selection is that commit."""
    for index in range(count):
        k('select', str(index))
        d = until(lambda d: d['active']['selection'].startswith('commit %d ' % index), label='row %d selected' % index)
        if d['active']['selection'].split()[2] == sha[:7]: return index
    raise SystemExit('no row for %s' % sha[:7])


def branch(d):
    return tab(d, 'powerlens')['branch']


launch_prepared(mode, prepare=refs)
try:
    show_tab('powerlens')
    k('resize', '1440', '900')
    d = until(lambda d: d['phase5']['layout']['width'] == 1440 and branch(d) == CHECKED_OUT
              and d['phase5']['history']['commits'] >= 20, label='powerlens at 1,440')
    frames = d['phase5']['layout']['panes']['frames']
    edge = frames['sidebar'][0] + frames['sidebar'][2]
    count = d['phase5']['history']['commits']
    root = os.path.join(SAMPLES, 'powerlens')
    head, parent, grand = (g(root, 'rev-parse', spec) for spec in ('HEAD', 'HEAD~1', 'HEAD~2'))
    top, below, further = row_of(head, count), row_of(parent, count), row_of(grand, count)
    k('select', 'wip')
    steady()

    def label(kind, name):
        """Where the history shows that label (in a row or an open list, not the sidebar)."""
        f = target_frame(kind, name)
        assert f[0] > edge, '%s %s is drawn in the history (found at %s)' % (kind, name, f)
        return f

    def press(f, clicks):
        """Clicks (1) or double-clicks (2) the middle of `f` and returns the dump once the clicks are sent."""
        k('click', '%g' % (f[0] + f[2] / 2), '%g' % (f[1] + f[3] / 2), str(clicks))
        return until(lambda d: not d['driver']['pointerBusy'], label='the clicks sent')

    def picks(index, sha, since):
        """The selection became row `index` (`sha`)."""
        d = until(lambda d: d['active']['selection'] != since, label='the click picking a commit')
        assert d['active']['selection'].split()[1:3] == [str(index), sha[:7]], d['active']['selection']
        return d

    def timed_click(x, y, index, sha):
        """Seconds from a click to the selection of row `index`."""
        before = full_dump()['active']['selection']
        began = time.time()
        k('click', '%g' % x, '%g' % y)
        picks(index, sha, before)
        return time.time() - began

    # A single click on qa's label picks its commit as soon as a click beside the labels does (it doesn't wait
    # to see whether a second click follows), and switches nothing.
    plain_row = target_frame('commit', str(further))
    plain = timed_click(plain_row[0] + plain_row[2] * 0.6, plain_row[1] + plain_row[3] / 2, further, grand)
    qa = label('branch', 'qa')
    on_label = timed_click(qa[0] + qa[2] / 2, qa[1] + qa[3] / 2, below, parent)
    print('a click picks its commit in %.2f s beside the labels, %.2f s on qa\'s label' % (plain, on_label))
    assert on_label < plain + 0.3, 'a click on a label picks the commit at once'
    time.sleep(0.8)
    assert branch(settle()) == CHECKED_OUT, 'a single click switches nothing'

    # Double-clicking it switches to qa (the local changes come along).
    press(qa, 2)
    settle(lambda d: branch(d) == 'qa', label='qa checked out by a double-click on its label')
    print('double-click on qa: on qa')

    # HEAD's commit: its list lies over the rows below; a double-click on release/1.2 there switches to it.
    k('labels', head[:12])
    until(lambda d: (lambda f: f and f[0] > edge)(frame_now('branch', 'release/1.2')), label='the list of HEAD\'s commit open')
    release = label('branch', 'release/1.2')
    row = target_frame('commit', str(top))
    assert release[1] + release[3] / 2 > row[1] + row[3], 'release/1.2 lies over a row below its own'
    press(release, 2)
    settle(lambda d: branch(d) == 'release/1.2', label='release/1.2 checked out from the list')
    print('double-click on release/1.2 in the list: on release/1.2')

    # origin/review/ui in the same list: a local review/ui that tracks it, checked out.
    remote = label('remote', 'origin/review/ui')
    press(remote, 2)
    settle(lambda d: branch(d) == 'review/ui', label='review/ui made from origin/review/ui and checked out')
    upstream = g(root, 'rev-parse', '--abbrev-ref', 'review/ui@{upstream}')
    print('double-click on origin/review/ui: on review/ui, tracking', upstream)
    assert upstream == 'origin/review/ui'
    k('labels', 'off')

    # A tag's double-click (in HEAD~1's list) picks its commit and switches nothing (no detached HEAD).
    k('labels', parent[:12])
    until(lambda d: (lambda f: f and f[0] > edge)(frame_now('tag', 'v1.3.0')), label='the list of HEAD~1 open')
    tag_frame = label('tag', 'v1.3.0')
    before = full_dump()['active']['selection']
    press(tag_frame, 2)
    picks(below, parent, before)
    time.sleep(0.8)
    assert branch(settle()) == 'review/ui', 'a tag\'s double-click switches nothing'
    print('double-click on v1.3.0: still on review/ui')
    k('labels', 'off')

    # wt/side is checked out in another worktree: its double-click opens that worktree in a tab of its own.
    side = label('branch', 'wt/side')
    press(side, 2)
    d = settle(lambda d: active_name(d) == 'powerlens-side', label='the worktree that has wt/side, in its own tab')
    assert branch(d) == 'review/ui'
    print('double-click on wt/side: the powerlens-side tab, powerlens still on review/ui')
    print('ok')
finally:
    quit_app()
