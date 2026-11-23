"""t_stacks.py [light|dark] — the sidebar's sections and the panel's Unstaged and Staged files are stacked lists: every
header stays in view and each open list scrolls on its own. While all the rows fit, a list is as tall as its rows;
when they don't, the lists share the column, a list that needs less than its share has just its rows, and the line
between two lists can be dragged with the mouse (the heights are kept as weights for every window). A double-click on
the line shares the column out again. Scrolling one list moves no other.

Both columns are measured from the dump's `phase6.stacks` (heights, rows' heights, frames of the scroll views and
edges, the kept weights)."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
LOCAL = ['feature/bulk-%02d' % n for n in range(1, 61)]
REMOTE = ['origin/bulk-%02d' % n for n in range(1, 41)]
UNSTAGED = ['notes/draft-%02d.md' % n for n in range(1, 41)]
STAGED = ['notes/ready-%02d.md' % n for n in range(1, 31)]


def prepare():
    """60 more local branches and 40 more remote branches; 40 new files and 30 staged ones. (The sample's tags already
    fill Tags's first rows.)"""
    root = os.path.join(SAMPLES, 'powerlens')
    head = g(root, 'rev-parse', 'HEAD')
    for name in LOCAL: g(root, 'branch', name)
    for name in REMOTE: g(root, 'update-ref', 'refs/remotes/' + name, head)
    os.makedirs(os.path.join(root, 'notes'), exist_ok=True)
    for path in UNSTAGED + STAGED:
        with open(os.path.join(root, path), 'w') as f: f.write('# %s\n' % path)
    g(root, 'add', '--', *STAGED)


def stacks(d): return d['phase6']['stacks']
def column(d, name): return {s['name']: s for s in stacks(d)[name]}
def frame(d, key): return stacks(d)['frames'].get(key)
def near(a, b, slack=1.0): return abs(a - b) <= slack
def total(col): return sum(s['height'] for s in col.values() if s['open'])


def pointer_done(check):
    return lambda d: not d['driver']['pointerBusy'] and check(d)


def drag(x1, y1, x2, y2, check, label):
    """A drag the app has acknowledged (`send_drag`: a lost notification is sent again, never dragged twice), sent
    to its end (its release too), and then check(dump)."""
    sequence = send_drag(x1, y1, x2, y2)
    return until(pointer_done(lambda d: d['driver']['drag']['sequence'] == sequence and check(d)), label=label)


def laid_out(d, name, opened):
    """The column has measured its lists: each open one's rows have a height."""
    col = column(d, name)
    return all(col.get(n, {}).get('open') and col[n]['content'] > 0 for n in opened)


def edge_center(d, label):
    f = frame(d, 'edge ' + label)
    assert f, 'no edge %s in %s' % (label, sorted(stacks(d)['frames']))
    return f[0] + f[2] / 2, f[1] + f[3] / 2


def check_column(d, name, scrolling, fitting):
    """The lists in `scrolling` have fewer rows shown than they have and the ones in `fitting` show all of theirs; the
    open lists fill the column's room."""
    col = column(d, name)
    for n in scrolling:
        assert col[n]['height'] < col[n]['content'] - 1, '%s scrolls: %s' % (n, col[n])
    for n in fitting:
        assert near(col[n]['height'], col[n]['content']), '%s shows all its rows: %s' % (n, col[n])
    room = next(iter(col.values()))['room']
    assert near(total(col), room, 2), 'the lists fill the room (%g of %g): %s' % (total(col), room, col)
    return col


launch_prepared(mode, prepare=prepare)
try:
    show_tab('powerlens')
    k('resize', '1440', '900')
    k('remoteOpen', 'origin', 'on')
    d = until(lambda d: d['phase5']['layout']['width'] == 1440
              and laid_out(d, 'sidebar', ('local', 'remote', 'tags', 'stashes', 'worktrees')),
              label='the sidebar laid out at 1,440')
    d = settle(lambda d: column(d, 'sidebar')['local']['content'] > 1500 and column(d, 'sidebar')['remote']['content'] > 1000,
               label='every branch in the sidebar')
    side = d['phase5']['layout']['panes']['frames']['sidebar']

    # --- The sidebar: Local and Remote scroll, the others show all their rows, every section is in view.
    col = check_column(d, 'sidebar', ('local', 'remote'), ('stashes', 'worktrees'))
    print('sidebar:', {n: (round(s['height']), round(s['content'])) for n, s in col.items()})
    assert near(col['local']['height'], col['remote']['height'], 2), 'with nothing kept, the two share equally'
    last = frame(d, 'sidebar Worktrees')
    assert last and last[1] + last[3] <= side[1] + side[3] - 40, 'the last section is in view, above the filter: %s' % last
    assert stacks(d)['weights']['sidebar'] == '', 'nothing kept yet'
    snap('stacks-sidebar', mode, changed=True)

    # Scrolling Local moves Local only.
    remote_before, first_before = frame(d, 'sidebar Remote'), target_frame('branch', LOCAL[0])
    body = frame(d, 'sidebar Local')
    k('scrollRun', '%g' % (body[0] + 60), '%g' % (body[1] + body[3] / 2), '-28', '20', '120')
    d = until(lambda d: (lambda f: f is None or f[1] < first_before[1] - 100)(
        (k('targetFrame', 'branch', LOCAL[0]), full_dump()['phase5']['targetFrame'])[1]), label='Local scrolled')
    assert frame(d, 'sidebar Remote') == remote_before, 'Remote stayed where it was'
    print('Local scrolled; Remote stayed at', remote_before)

    # Dragging the line above Remote up 80: Local gives Remote 80.
    x, y = edge_center(d, 'Height of Remote')
    d = drag(x, y, x, y - 80, lambda d: near(column(d, 'sidebar')['remote']['height'], col['remote']['height'] + 80),
             label='Remote 80 taller')
    dragged = check_column(d, 'sidebar', ('local', 'remote'), ('stashes', 'worktrees'))
    print('after the drag:', {n: round(s['height']) for n, s in dragged.items()}, 'kept:', stacks(d)['weights']['sidebar'])
    assert near(dragged['local']['height'], col['local']['height'] - 80), 'Local gave it'
    assert stacks(d)['weights']['sidebar'], 'the heights are kept'
    snap('stacks-sidebar-dragged', mode, changed=True)

    # Back on the tab after another one: the same heights.
    show_tab('travel-blog')
    d = show_tab('powerlens')
    d = until(lambda d: near(column(d, 'sidebar')['remote']['height'], dragged['remote']['height']), label='the same heights back on the tab')

    # The line can't go further than Local's least.
    x, y = edge_center(d, 'Height of Remote')
    d = drag(x, y, x, side[1] - 50, lambda d: column(d, 'sidebar')['local']['height'] <= 29, label='Local down to a row')
    print('Local at its least:', round(column(d, 'sidebar')['local']['height']))

    # A double-click on the line: shared out again.
    x, y = edge_center(d, 'Height of Remote')
    k('click', '%g' % x, '%g' % y, '2')
    d = until(pointer_done(lambda d: stacks(d)['weights']['sidebar'] == ''), label='the kept heights forgotten')
    again = check_column(d, 'sidebar', ('local', 'remote'), ('stashes', 'worktrees'))
    assert near(again['local']['height'], col['local']['height'], 2), 'shared as at first: %s' % again

    # Folding Local: its header stays, Remote takes the room (it can't show all its rows).
    k('click', '%g' % (side[0] + 60), '%g' % (frame(d, 'sidebar Local')[1] - 16))
    d = until(pointer_done(lambda d: not column(d, 'sidebar')['local']['open']), label='Local folded')
    folded = check_column(d, 'sidebar', ('remote',), ('stashes', 'worktrees'))
    print('Local folded:', {n: round(s['height']) for n, s in folded.items()})
    k('click', '%g' % (side[0] + 60), '%g' % (side[1] + 6 + 16))
    d = until(pointer_done(lambda d: column(d, 'sidebar')['local']['open']), label='Local open again')

    # --- The panel: Unstaged and Staged both scroll and share it.
    k('select', 'wip')
    d = until(lambda d: laid_out(d, 'changes', ('unstaged', 'staged')) and set(STAGED) <= set(d['phase6']['staged']),
              label='the working copy\'s lists')
    lists = check_column(d, 'changes', ('unstaged', 'staged'), ())
    print('panel:', {n: (round(s['height']), round(s['content'])) for n, s in lists.items()})
    assert near(lists['unstaged']['height'], lists['staged']['height'], 2), 'with nothing kept, the lists share equally'
    snap('stacks-panel', mode, changed=True)

    x, y = edge_center(d, 'Height of Unstaged Files')
    d = drag(x, y, x, y + 80, lambda d: near(column(d, 'changes')['unstaged']['height'], lists['unstaged']['height'] + 80),
             label='Unstaged 80 taller')
    print('after the drag:', {n: round(s['height']) for n, s in column(d, 'changes').items()}, 'kept:', stacks(d)['weights']['changes'])
    assert near(column(d, 'changes')['staged']['height'], lists['staged']['height'] - 80), 'Staged gave it'
    snap('stacks-panel-dragged', mode, changed=True)

    # A file staged: one list fewer rows, the other more; the split still fills the panel.
    k('stage', UNSTAGED[0])
    d = settle(lambda d: UNSTAGED[0] in d['phase6']['staged'], label='a file staged')
    check_column(d, 'changes', ('unstaged', 'staged'), ())

    x, y = edge_center(d, 'Height of Unstaged Files')
    k('click', '%g' % x, '%g' % y, '2')
    d = until(pointer_done(lambda d: stacks(d)['weights']['changes'] == ''), label='the panel shared out again')
    print('STACKS OK')
finally:
    quit_app()
