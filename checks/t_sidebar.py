"""t_sidebar.py [light|dark] — the Local section lists branches by name and the checked-out one stays in its place
(a check and a tint, no move to the top): checking out another branch moves no row, and a folded folder that holds
the checked-out branch shows a check (in the picture). Branches hidden behind a history row's "+N" are drawn only in
the sidebar, so `targetFrame branch <name>` gives their sidebar rows."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
CHECKED_OUT = 'feature/restore-automatic-alpha'   # the sample's checked-out branch
EXTRA = ('feature/quiet-mode', 'feature/sleep-guard', 'feature/standby-log')


def branches():
    """Three more branches in the feature folder, on the checked-out commit (the history shows them behind "+3").
    By name: charge-limit-awareness, harden-sparkle-releases, quiet-mode, reliability-and-release,
    restore-automatic-alpha (checked out), sleep-guard, standby-log."""
    root = os.path.join(SAMPLES, 'powerlens')
    for name in EXTRA: g(root, 'branch', name)


def frame_now(name):
    k('targetFrame', 'branch', name)
    return full_dump()['phase5']['targetFrame']


def sidebar_y(name, edge):
    f = target_frame('branch', name)
    assert f[0] < edge, '%s is drawn only in the sidebar (found at %s)' % (name, f)
    return f[1]


launch_prepared(mode, prepare=branches)
show_tab('powerlens')
k('resize', '1440', '900')
d = until(lambda d: d['phase5']['layout']['width'] == 1440 and tab(d, 'powerlens')['branch'] == CHECKED_OUT,
          label='powerlens at 1,440 on %s' % CHECKED_OUT)
side = d['phase5']['layout']['panes']['frames']['sidebar']
edge = side[0] + side[2]
before = {name: sidebar_y(name, edge) for name in EXTRA}
step = before['feature/standby-log'] - before['feature/sleep-guard']
print('rows:', before, '· a row is', step)
assert step > 0
# quiet-mode, reliability-and-release, restore-automatic-alpha, sleep-guard: three rows apart.
assert before['feature/sleep-guard'] - before['feature/quiet-mode'] == 3 * step, 'the checked-out branch is in its place'
snap('sidebar-current-in-place', mode)

# Checking out quiet-mode moves no row; restore-automatic-alpha (now behind "+3") is where it sorts.
k('checkout', 'feature/quiet-mode')
settle(lambda d: tab(d, 'powerlens')['branch'] == 'feature/quiet-mode', label='quiet-mode checked out')
after = {name: sidebar_y(name, edge) for name in ('feature/sleep-guard', 'feature/standby-log', CHECKED_OUT)}
print('after the checkout:', after)
assert after['feature/sleep-guard'] == before['feature/sleep-guard'], 'no row moved'
assert after['feature/standby-log'] == before['feature/standby-log'], 'no row moved'
assert after[CHECKED_OUT] == before['feature/quiet-mode'] + 2 * step, 'restore-automatic-alpha is in its place'
snap('sidebar-after-checkout', mode, changed=True)

# Folding the feature folder (its row is three above quiet-mode's): its branches go, and its row shows a check.
x, y = side[0] + 60, before['feature/quiet-mode'] - 3 * step + step / 2
k('click', '%g' % x, '%g' % y)
until(lambda d: not d['driver']['pointerBusy'] and frame_now('feature/sleep-guard') is None, label='the feature folder folded')
snap('sidebar-folded-current', mode, changed=True)
k('click', '%g' % x, '%g' % y)
until(lambda d: not d['driver']['pointerBusy'] and (frame_now('feature/sleep-guard') or [0, 0])[1] == before['feature/sleep-guard'],
      label='the feature folder open again')
quit_app()
print('SIDEBAR OK')
