"""t_worktreemenu.py [light|dark] — worktrees open in a tab of their own: a double-click on one in the sidebar, or on
the history label of a branch checked out in one, opens it there (its open tab the second time). A worktree's
right-click menu opens it, shows or copies its folder, locks it (⌘Z unlocks) and removes it, or it and its branch (one
⌘Z brings both back). A branch checked out in another worktree offers Open Worktree instead of Checkout, and no Delete
while its worktree is there. Menus are read and chosen through `menuItems` and `menuRun`."""
import json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from k5 import _file
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
SIDE, GONE = 'powerlens-side', 'powerlens-gone'


def prepare():
    """Two more worktrees: powerlens-side on wt/side (HEAD~2) and powerlens-gone on wt/gone (HEAD~3). The sample
    already has powerlens-hotfix, detached at a release tag."""
    root = os.path.join(SAMPLES, 'powerlens')
    g(root, 'worktree', 'add', '-q', '-b', 'wt/side', os.path.join(SAMPLES, SIDE), 'HEAD~2')
    g(root, 'worktree', 'add', '-q', '-b', 'wt/gone', os.path.join(SAMPLES, GONE), 'HEAD~3')


_menus = [0]


def menu(*spec):
    """The right-click menu for `spec` ('worktree', name / 'branch', name): its header, {title: (hint, enabled)}."""
    _menus[0] += 1
    os.makedirs(REPLIES, exist_ok=True)
    path = os.path.join(REPLIES, 'menu-%d-%d.json' % (os.getpid(), _menus[0]))
    k('menuItems', path, *spec)
    items = json.loads(_file(path))
    header = next((i['header'] for i in items if 'header' in i), None)
    return header, {i['title']: (i['hint'], i['enabled']) for i in items if 'title' in i}


def menu_until(spec, check, label, seconds=10):
    end = time.time() + seconds
    while True:
        items = menu(*spec)[1]
        if check(items): return items
        if time.time() >= end: raise SystemExit('timed out waiting for %s: %s' % (label, items))
        time.sleep(0.1)


def git_ok(*args):
    return subprocess.run(['git', '-C', os.path.join(SAMPLES, 'powerlens')] + list(args), capture_output=True).returncode == 0


def locked(name):
    blocks = g(os.path.join(SAMPLES, 'powerlens'), 'worktree', 'list', '--porcelain').split('\n\n')
    return any(b.splitlines()[0].endswith('/' + name) and '\nlocked' in b for b in blocks if b.startswith('worktree '))


launch_prepared(mode, prepare=prepare)
try:
    show_tab('powerlens')
    k('resize', '1440', '900')
    d = settle(lambda d: d['phase5']['layout']['width'] == 1440
               and all(any(w.startswith(name + ' |') for w in d['phase6']['worktrees']) for name in (SIDE, GONE)),
               label='powerlens with its worktrees')
    side = d['phase5']['layout']['panes']['frames']['sidebar']
    edge = side[0] + side[2]

    def middle(f):
        return '%g' % (f[0] + f[2] / 2), '%g' % (f[1] + f[3] / 2)

    def in_sidebar(kind, name):
        """Where the sidebar shows it, clear of the filter field at its bottom."""
        f = target_frame(kind, name)
        assert f[0] < edge and side[1] <= f[1] and f[1] + f[3] <= side[1] + side[3] - 40, \
            '%s %s is in view in the sidebar (found at %s)' % (kind, name, f)
        return f

    # The menus.
    header, items = menu('worktree', SIDE)
    print('menu of', header, '->', items)
    assert header == SIDE
    for title in ('Open in New Tab', 'Show in Finder', 'Copy Path', 'Lock', 'Remove Worktree…', 'Remove Worktree and Delete Branch…'):
        assert items[title][1], '%s is on for %s' % (title, SIDE)
    items = menu('worktree', 'powerlens-hotfix')[1]
    assert items['Remove Worktree and Delete Branch…'] == ('No branch', False), items['Remove Worktree and Delete Branch…']
    items = menu('worktree', 'powerlens')[1]
    assert items['Open in New Tab'] == ('This tab', False) and items['Lock'] == ('Main worktree', False), items
    assert items['Remove Worktree…'] == ('Main worktree', False), items
    items = menu('branch', 'wt/side')[1]
    print('menu of wt/side ->', items)
    assert 'Checkout' not in items and items['Open Worktree “%s”' % SIDE][1]
    assert items['Delete'] == ('Checked out in %s' % SIDE, False), items['Delete']
    assert items['Remove Worktree…'][1] and items['Remove Worktree and Delete Branch…'][1]
    items = menu('branch', 'develop')[1]
    assert items['Checkout'][1] and items['Delete'][1] and 'Remove Worktree…' not in items

    # Lock: git has it locked, the menu says Unlock and won't remove it; ⌘Z unlocks it.
    k('menuRun', 'worktree', SIDE, '|', 'Lock')
    settle(lambda d: locked(SIDE), label='%s locked' % SIDE)
    items = menu_until(('worktree', SIDE), lambda items: 'Unlock' in items, 'the menu saying Unlock')
    assert items['Remove Worktree…'] == ('Locked', False), items['Remove Worktree…']
    k('undo')
    settle(lambda d: not locked(SIDE), label='⌘Z unlocking it')
    menu_until(('worktree', SIDE), lambda items: 'Lock' in items, 'the menu saying Lock again')
    print('lock, ⌘Z: unlocked')

    # Remove and Delete Branch… on powerlens-gone: one question, both go, one ⌘Z brings both back.
    gone = os.path.join(SAMPLES, GONE)
    k('menuRun', 'worktree', GONE, '|', 'Remove Worktree and Delete Branch…')
    d = until(lambda d: d['phase6']['confirmation'].startswith('Remove the worktree %s and delete wt/gone' % GONE), label='the question')
    print('asked:', d['phase6']['confirmation'])
    k('confirm')
    settle(lambda d: not os.path.exists(gone) and not git_ok('rev-parse', '--verify', '-q', 'refs/heads/wt/gone'),
           label='the worktree and its branch gone')
    k('undo')
    settle(lambda d: os.path.exists(gone) and git_ok('rev-parse', '--verify', '-q', 'refs/heads/wt/gone')
           and any(w.startswith(GONE + ' |') for w in d['phase6']['worktrees']), label='⌘Z bringing both back')
    assert g(gone, 'branch', '--show-current') == 'wt/gone'
    print('remove and delete branch, ⌘Z: both back')

    # A double-click on powerlens-gone in the sidebar (a row in view) opens it in a tab of its own; the second
    # time goes to that tab.
    before = len(tabs(full_dump()))
    for attempt in range(2):
        show_tab('powerlens')
        k('click', *middle(in_sidebar('worktree', GONE)), '2')
        d = settle(lambda d: active_name(d) == GONE, label='%s in a tab of its own' % GONE)
        assert len(tabs(d)) == before + 1, 'one tab for it (%d tabs, %d before)' % (len(tabs(d)), before)
    print('double-click in the sidebar, twice: the %s tab' % GONE)

    # The history label of wt/side: a double-click opens its worktree's tab, and the second time goes to it.
    for attempt in range(2):
        show_tab('powerlens')
        label = target_frame('branch', 'wt/side')
        assert label[0] > edge, 'wt/side is drawn in the history (found at %s)' % label
        k('click', *middle(label), '2')
        d = settle(lambda d: active_name(d) == SIDE, label='the wt/side label taking me to %s' % SIDE)
        assert len(tabs(d)) == before + 2, 'one tab for it (%d tabs, %d before)' % (len(tabs(d)), before)
    print('double-click on the wt/side label, twice: the %s tab' % SIDE)
    print('ok')
finally:
    quit_app()
