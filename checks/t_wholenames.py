"""t_wholenames.py [light|dark] — a branch name that is cut short ("…") shows whole when the pointer rests on it.

In the history, a commit's only label, cut by the label column, unfolds in the list that several labels unfold in,
and a label with room for its name unfolds nothing. In the sidebar, a row whose name is cut is drawn again as wide as
it needs, on over what lies right of the sidebar; that is a picture, so a press on it goes to what is under it (the
history beside the sidebar, the row inside it), and a row with room for its name unfolds nothing.

A test window in the background gets no hover: `labels <hash>` and `wholeName <row title>` unfold them the way the
pointer would."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
LONE = 'feature/a-long-name-the-label-column-cuts'            # the only label of its commit
SIDE = 'feature/another-rather-long-name-only-the-sidebar-shows'   # on HEAD's commit: behind its "+1" in the history
SIDE_TITLE = SIDE.split('/', 1)[1]


def refs():
    """LONE on the newest commit without a ref, SIDE on the checked-out commit."""
    root = os.path.join(SAMPLES, 'powerlens')
    taken = set(g(root, 'for-each-ref', '--format=%(objectname) %(*objectname)').split())
    lone = next(sha for sha in g(root, 'rev-list', 'HEAD').split() if sha not in taken)
    g(root, 'branch', LONE, lone)
    g(root, 'branch', SIDE)


def frame_now(*spec):
    k('targetFrame', *spec)
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


def sidebar(d):
    f = d['phase5']['layout']['panes']['frames']['sidebar']
    return f, f[0] + f[2]


# The check sets the label column's width: a launch argument for it would win over that.
launch_prepared(mode, prepare=refs, drop=['-KaernColumnRef'])
try:
    show_tab('powerlens')
    k('resize', '1440', '900')
    d = until(lambda d: d['phase5']['layout']['width'] == 1440 and d['phase5']['history']['commits'] >= 20, label='powerlens at 1,440')
    side, edge = sidebar(d)
    count = d['phase5']['history']['commits']
    root = os.path.join(SAMPLES, 'powerlens')
    lone = g(root, 'rev-parse', LONE)

    # --- The history: a lone label the column cuts short.
    index = row_of(lone, count)
    k('select', 'wip')
    k('column', 'ref', '150')
    until(lambda d: str(d['settings'].get('KaernColumnRef')) in ('150', '150.0'), label='the label column at 150')
    steady()
    shown = target_frame('branch', LONE)
    print('row', index, 'shows the label at', shown)
    assert edge <= shown[0] and shown[0] + shown[2] <= edge + 150, 'the label is inside the label column'
    k('labels', lone[:12])
    until(lambda d: frame_now('labels', 'list') is not None, label='the cut label unfolded')
    whole, at_row = target_frame('labels', 'list'), target_frame('labels', 'row')
    print('unfolded at', whole, '· the row shows it at', at_row)
    assert covers(whole, at_row), 'the unfolded label covers the cut one'
    assert whole[0] + whole[2] > edge + 150 + 20, 'the whole label reaches over the graph'
    assert whole[3] < 40, 'one label, one line'
    snap('wholename-label', mode, changed=True)
    # A press on the part over the graph belongs to the label's commit.
    before = full_dump()['active']['selection']
    k('click', '%g' % (whole[0] + whole[2] - 14), '%g' % (whole[1] + whole[3] / 2))
    d = until(lambda d: not d['driver']['pointerBusy'] and d['active']['selection'] != before, label='the press on the unfolded label')
    print('a press on it selects:', d['active']['selection'])
    assert d['active']['selection'].split()[1:3] == [str(index), lone[:7]], 'a press on the unfolded label belongs to its commit'
    k('labels', 'off')
    until(lambda d: frame_now('labels', 'list') is None, label='folded again')

    # With room for the name, nothing unfolds.
    k('select', 'wip')
    k('column', 'ref', '420')
    until(lambda d: str(d['settings'].get('KaernColumnRef')) in ('420', '420.0'), label='the label column at 420')
    steady()
    roomy = target_frame('branch', LONE)
    print('with room the label is', roomy)
    assert roomy[2] > shown[2] + 20, 'the label has its whole name'
    k('labels', lone[:12])
    steady()
    assert frame_now('labels', 'list') is None, 'a label with room for its name unfolds nothing'
    k('labels', 'off')
    k('column', 'ref', '176')
    until(lambda d: str(d['settings'].get('KaernColumnRef')) in ('176', '176.0'), label='the label column back')

    # --- The sidebar: a row whose name is cut short.
    steady()
    row = target_frame('branch', SIDE)
    print('the sidebar row is at', row)
    assert row[0] + row[2] <= edge, 'the row is in the sidebar'
    k('wholeName', SIDE_TITLE)
    until(lambda d: frame_now('wholeName', 'row') is not None, label='the cut name unfolded')
    plate = target_frame('wholeName', 'row')
    print('unfolded at', plate)
    assert abs(plate[0] - row[0]) <= 0.5 and abs(plate[1] - row[1]) <= 0.5 and abs(plate[3] - row[3]) <= 0.5, 'it lies on its row'
    assert plate[0] + plate[2] > edge + 40, 'the whole name reaches over what is right of the sidebar'
    snap('wholename-sidebar', mode, changed=True)
    # It's a picture. A press on the part over the history goes to the history…
    before = full_dump()['active']['selection']
    k('click', '%g' % (edge + 14), '%g' % (plate[1] + plate[3] / 2))
    d = until(lambda d: not d['driver']['pointerBusy'] and d['active']['selection'] != before, label='the press beside the sidebar')
    print('a press on it beside the sidebar selects:', d['active']['selection'])
    assert d['active']['selection'].startswith('commit '), 'the history under the picture takes the press'
    # …and a double-click on the part in the sidebar switches to the branch, as on the row.
    k('click', '%g' % (row[0] + 70), '%g' % (row[1] + row[3] / 2), '2')
    settle(lambda d: not d['driver']['pointerBusy'] and tab(d, 'powerlens')['branch'] == SIDE, label='switched by a double-click through the picture')
    print('a double-click on it in the sidebar switched to', SIDE)
    k('wholeName', 'off')
    until(lambda d: frame_now('wholeName', 'row') is None, label='the name folded again')

    # With room for the name, nothing unfolds.
    k('pane', 'sidebar', '520')
    d = until(lambda d: sidebar(d)[0][2] == 520, label='the sidebar at 520')
    steady()
    k('wholeName', SIDE_TITLE)
    steady()
    assert frame_now('wholeName', 'row') is None, 'a row with room for its name unfolds nothing'
    k('wholeName', 'off')
    print('WHOLE NAMES OK')
finally:
    quit_app()
