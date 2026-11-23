"""Phase-5 helpers on top of k4: the dump's phase5 block, pictures, typing, big samples."""
import json, os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k4 import *
import samples


def p5():
    return full_dump().get('phase5', {})


def wait_for(check, seconds=20, step=None, label=''):
    """until() under its older name: polls the dump until check(dump) holds."""
    return until(check, seconds, label)


def tabs(d):
    return [t['name'] for w in d['windows'] for t in w['tabs']]


def tab(d, name):
    return next((t for w in d['windows'] for t in w['tabs'] if t['name'] == name), None)


def active_name(d):
    return d['active'].get('name', '')


def show_tab(name, check=None, seconds=30):
    """Switches to the tab and returns the dump once it shows and everything it loads has come in."""
    k('activateName', name)
    return settle(lambda d: active_name(d) == name and d['phase5']['phase'] == 'ready' and _ok(check, d), seconds, label='the %s tab' % name)


def _ok(check, d):
    return check is None or check(d)


# ---------------------------------------------------------------------------------------------
# Pictures. A picture is taken again until two in a row are the same (an animation or a late
# layout has ended), not after a fixed pause. With KAERN_SHOTS=light,dark each one is also taken
# in the other appearance, in the same state, so a check doesn't run a second time for dark.

def shot_modes():
    wanted = [m for m in os.environ.get('KAERN_SHOTS', '').split(',') if m in ('light', 'dark')]
    return [mode()] + [m for m in wanted if m != mode()]


def shot_path(name, appearance):
    os.makedirs(SHOTS, exist_ok=True)
    return os.path.join(SHOTS, 'app-%s-%s.png' % (name, appearance))


def _file(path, seconds=15):
    end = time.time() + seconds * PATIENCE
    while not os.path.exists(path):
        if time.time() >= end: raise SystemExit('no picture at %s after %d s' % (path, seconds))
        time.sleep(0.005)
    sync(60)  # the command that wrote it has finished: the file is whole
    with open(path, 'rb') as f: return f.read()


# A picture taken in the middle of a transition (a sheet fades in for 0.15 s, the list folds for 0.3 s) is
# drawn through transparency layers on the CPU and costs about a second; taken after it, a third of that.
# So the first picture waits the transition out. This pause is for speed only: what decides is still two
# pictures alike.
TRANSITION = 0.3


def _alike(a, b):
    """Two pictures (PNG bytes) are the same, or differ only in a spot the size of a text cursor (the
    cursor of a focused field fades in and out for ever). Any other difference, however faint, counts:
    the end of an animation moves things by less than a pixel, which only softens the text.
    Without Pillow: the same bytes only."""
    if a == b: return True
    try:
        import io
        from PIL import Image, ImageChops
    except ImportError:
        return False
    x, y = Image.open(io.BytesIO(a)).convert('RGB'), Image.open(io.BytesIO(b)).convert('RGB')
    if x.size != y.size: return False
    box = ImageChops.difference(x, y).getbbox()
    return box is None or ((box[2] - box[0]) <= 12 and (box[3] - box[1]) <= 80)


def _steady(take, path, unlike=(), seconds=6.0):
    """Runs take() (a command that writes `path`) until two pictures in a row are alike (see _alike) and
    are none of `unlike`. It gives up after `seconds`, or four times what one picture takes when that is
    longer (with Search's find bar open the dimmed rows take seconds to draw off screen), and keeps the
    last one."""
    time.sleep(TRANSITION)
    started = time.time()
    end = started + seconds
    last = None
    while True:
        if os.path.exists(path): os.remove(path)
        began = time.time()
        take()
        data = _file(path, seconds=60)
        trace('picture ' + os.path.basename(path), began)
        if last is not None and data not in unlike and _alike(data, last): return data
        if last is None: end = max(end, started + 4 * (time.time() - began) + 1)
        if time.time() >= end:
            # The last two are kept next to the run, to see what moves.
            base = os.path.join(RUN_DIR, 'changing-' + os.path.basename(path)[:-4])
            for suffix, picture in (('-a.png', last), ('-b.png', data)):
                if picture:
                    with open(base + suffix, 'wb') as f: f.write(picture)
            print('   (the picture %s kept changing for %.0f s; kept the last one — the last two are %s-a.png and -b.png)' % (
                os.path.basename(path), time.time() - started, base))
            return data
        last = data
        time.sleep(0.03)


def steady():
    """Waits until the window's picture has stopped changing (nothing is kept)."""
    scratch = os.path.join(RUN_DIR, 'steady.png')
    _steady(lambda: k('snapshot', scratch), scratch)
    os.remove(scratch)


_last = {'other': None, 'shot': None}


def _in_each_mode(name, take, changed=False):
    """take(path) in the launch appearance, then in each other appearance asked for, then back."""
    first = None
    for appearance in shot_modes():
        path = shot_path(name, appearance)
        if appearance == mode():
            # Not the dark picture taken just before (the switch back to light has been drawn), and
            # for `changed`, not the picture the last snap() took.
            first = _steady(lambda: take(path), path, unlike=(_last['other'], _last['shot'] if changed else None))
            _last['shot'] = first
        else:
            k('appearance', appearance)
            until(lambda d: d['driver']['appearance'] == appearance, label='the %s appearance' % appearance)
            _last['other'] = _steady(lambda: take(path), path, unlike=(first,))
    if len(shot_modes()) > 1:
        k('appearance', mode())
        until(lambda d: d['driver']['appearance'] == mode(), label='the %s appearance again' % mode())


def snap(name, appearance=None, composite=False, window=None, changed=False, toast=False):
    """shots/app-<name>-<light|dark>.png: the window; composite: with the menus, popovers and other Kaern
    windows over it; window: another window, by its title (Command Log, a Settings pane). changed: what
    the step before changed shows only in the picture (no dump field to wait on), so the picture must
    differ from the one snap() took last. toast: the toast on screen belongs in the picture (the step
    just raised it); otherwise one still up from an earlier step is put away first, as the slower checks
    used to outlast it."""
    if not toast and full_dump()['active'].get('toast'):
        k('toast')
        until(lambda d: not d['active'].get('toast'), label='the earlier toast put away')
    if window:
        _in_each_mode(name, lambda path: k('snapshotWindow', path, window), changed)
    else:
        _in_each_mode(name, lambda path: k('snapshotAll' if composite else 'snapshot', path), changed)


def menu_snap(name, *command):
    """A picture with a menu open: `command` is a menu or rightClick command without its `snap <png>` end
    (the driver opens the menu, takes the picture after a moment and closes it again). A menu opened
    while the window is still redrawing (after the appearance changed) closes at once, so the window is
    steady first, and the command is sent again when no picture came."""
    for appearance in shot_modes():
        if appearance != mode():
            k('appearance', appearance)
            until(lambda d: d['driver']['appearance'] == appearance, label='the %s appearance' % appearance)
        path = shot_path(name, appearance)
        for attempt in range(4):
            steady()
            if os.path.exists(path): os.remove(path)
            k(*command, 'snap', path)
            try:
                _file(path, seconds=4)
                break
            except SystemExit:
                if attempt == 3: raise
                print('   (no picture of the menu for %s; opening it again)' % os.path.basename(path))
    if len(shot_modes()) > 1:
        k('appearance', mode())
        until(lambda d: d['driver']['appearance'] == mode(), label='the %s appearance again' % mode())
    sync()


# ---------------------------------------------------------------------------------------------
# Keys.

def field_ready(d, into=None, holding=None):
    """A text field has the keyboard (`into`: its placeholder has this; `holding`: it holds this text)."""
    driver = d['driver']
    return (driver['typing'] and (into is None or into in driver['fieldPlaceholder'])
            and (holding is None or driver['fieldText'] == holding))


def type_text(text, into=None, seconds=15):
    """Types into the field that has the keyboard, once one has it (`into`: the one whose placeholder has
    this), and returns the dump when the text is in."""
    before = until(lambda d: field_ready(d, into), seconds, label='a text field with the keyboard')['driver']['fieldText']
    k('type', text)
    return until(lambda d: field_ready(d, into) and d['driver']['fieldText'] != before, seconds, label='the typed text %r in the field' % text)


def target_frame(*spec, seconds=15):
    """Where a row is in the window (`targetFrame file <path>`, `commit <index>`…), once the view has put
    it there: asked until two answers in a row are the same."""
    end = time.time() + seconds * PATIENCE
    last = None
    while True:
        k('targetFrame', *spec)
        frame = full_dump()['phase5']['targetFrame']
        if frame and frame == last: return frame
        if time.time() >= end: raise SystemExit('no steady frame for %s after %g s (last %s)' % (' '.join(str(x) for x in spec), seconds, frame))
        last = frame
        time.sleep(0.03)


def maybe(check, seconds=3):
    """until() that gives up quietly: the dump when check(dump) came to hold within `seconds`, else None."""
    end = time.time() + seconds * PATIENCE
    while True:
        d = full_dump()
        try:
            if check(d): return d
        except (KeyError, IndexError, TypeError, AttributeError, ValueError):
            pass
        if time.time() >= end: return None
        time.sleep(0.03)


# ---------------------------------------------------------------------------------------------
# Big samples (bigsample.py, built once per suite, see samples.py).

def big_sample(name, commits):
    """samples/<name>: the history of a deployment repository, `commits` commits with bot runs."""
    samples.install('big-%d' % commits, SAMPLES, {'big': name})


# ---------------------------------------------------------------------------------------------
# Work done, whatever core it ran on.

def instructions(pid=None):
    """Instructions the app's process has executed so far, in millions (proc_pid_rusage, RUSAGE_INFO_V4). Wall
    time on the main thread doubles when macOS runs a background app on efficiency cores or the Mac is busy;
    the number of instructions for the same work doesn't."""
    import ctypes
    if pid is None:
        pids = app_pids()
        if not pids: return 0.0
        pid = pids[0]
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    buffer = (ctypes.c_uint64 * 64)()
    if libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(buffer)) != 0: return 0.0
    return buffer[2 + 29] / 1e6
