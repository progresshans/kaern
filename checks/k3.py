"""Helpers for driving a test instance of the Debug app.

Every run (one check in one mode) has its own folder, <work folder>/runs/<run>/, with its samples, session
file, test gitconfig and dump files, and its own debug channel: the app is launched with
-KaernDebugChannel <channel> and takes only the commands posted to com.progresshans.kaern.debug.<channel>,
so several runs can go at the same time. The run is named by KAERN_RUN (the suite runner sets it), else by
the script and its arguments (t_marks-dark).

Nothing here waits a fixed time. k() sends a command and returns; what the command should bring about
is waited for with until() or settle(), which poll the dump:
    k('undo'); d = settle(lambda d: git('rev-parse', 'HEAD') == head0, label='undo')
"""
import ctypes, ctypes.util, hashlib, json, os, re, shutil, signal, subprocess, sys, time

# By hand: python3 k3.py [--run <run>] <command…> posts a command to that run's instance.
if __name__ == '__main__' and len(sys.argv) > 2 and sys.argv[1] == '--run':
    os.environ['KAERN_RUN'] = sys.argv[2]
    del sys.argv[1:3]
elif __name__ == '__main__':
    os.environ.setdefault('KAERN_RUN', 'manual')

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from paths import PATIENCE, TOOLS, WORK


def _run_name():
    name = os.environ.get('KAERN_RUN')
    if not name:
        script = os.path.splitext(os.path.basename(sys.argv[0] or ''))[0]
        if script in ('', '-c', '-'): script = 'manual'
        name = '-'.join([script] + [a for a in sys.argv[1:] if re.fullmatch(r'[A-Za-z0-9_.]+', a)])
    return re.sub(r'[^A-Za-z0-9_.-]', '_', name)


RUN = _run_name()
RUN_DIR = os.path.join(WORK, 'runs', RUN)
SAMPLES = os.path.join(RUN_DIR, 'samples')
PL = os.path.join(SAMPLES, 'powerlens')
SHOTS = os.environ.get('KAERN_SHOTS_DIR') or os.path.join(WORK, 'shots')
REPLIES = os.path.join(RUN_DIR, 'replies')
# The work folder is part of the channel, so two checkouts' suites never hear each other.
CHANNEL = RUN + '-' + hashlib.sha1(WORK.encode()).hexdigest()[:8]
NOTIFICATION = 'com.progresshans.kaern.debug.' + CHANNEL
assert ' ' not in RUN_DIR, 'the driver splits commands at spaces: no spaces in ' + RUN_DIR

GIT = os.environ.get('KAERN_GIT') or subprocess.run(['xcrun', '--find', 'git'], capture_output=True, text=True).stdout.strip() or '/usr/bin/git'
os.environ['KAERN_GIT'] = GIT
ENV = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')

# ---------------------------------------------------------------------------------------------
# Sending commands: a distributed notification posted from this process (no helper to start).

_CF = ctypes.CDLL(ctypes.util.find_library('CoreFoundation'))
_CF.CFNotificationCenterGetDistributedCenter.restype = ctypes.c_void_p
_CF.CFStringCreateWithCString.restype = ctypes.c_void_p
_CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
_CF.CFNotificationCenterPostNotificationWithOptions.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong]
_CF.CFRelease.argtypes = [ctypes.c_void_p]
_UTF8 = 0x08000100
_CENTER = _CF.CFNotificationCenterGetDistributedCenter()
_NAME = _CF.CFStringCreateWithCString(None, NOTIFICATION.encode(), _UTF8)


TRACE = bool(os.environ.get('KAERN_TRACE'))
_t0 = time.time()


def trace(what, since=None):
    """KAERN_TRACE=1: where a check's time goes, on stderr."""
    if TRACE:
        took = ' (%.0f ms)' % ((time.time() - since) * 1000) if since else ''
        print('   [%6.2f s] %s%s' % (time.time() - _t0, what, took), file=sys.stderr, flush=True)


def post(line):
    text = _CF.CFStringCreateWithCString(None, line.encode('utf-8'), _UTF8)
    _CF.CFNotificationCenterPostNotificationWithOptions(_CENTER, _NAME, text, None, 1)  # deliver immediately
    _CF.CFRelease(text)


def k(*cmd, wait=0):
    """Sends a debug command to this run's instance and returns at once. Commands run in the order sent.
    `wait` is only for a pause that is the point of the step; to wait for the app, use until() or settle()."""
    post(' '.join(str(c) for c in cmd))
    trace('k ' + ' '.join(str(c) for c in cmd)[:110])
    if wait: time.sleep(wait)


# ---------------------------------------------------------------------------------------------
# Answers: each request names a file of its own, so a late answer to an earlier request is never
# taken for this one.

_seq = 0


def _reply_path(kind):
    global _seq
    _seq += 1
    os.makedirs(REPLIES, exist_ok=True)
    return os.path.join(REPLIES, '%s-%d-%05d' % (kind, os.getpid(), _seq))


def _await(command, kind, seconds, read):
    """Sends `command <file>` and returns read(file) once the app wrote it; asks again when no answer comes
    for a while (a notification can get lost while the app starts or tracks a menu). None after `seconds`
    (times PATIENCE, like every limit here)."""
    end = time.time() + seconds * PATIENCE
    asked, again = [], 1.0
    try:
        while True:
            path = _reply_path(kind)
            post('%s %s' % (command, path)); asked.append(path)
            until_time = min(end, time.time() + again)
            while True:
                for p in asked:
                    if os.path.exists(p):
                        try:
                            return read(p)
                        except ValueError:
                            pass  # an older app writes the file in place: read it again when it's whole
                if time.time() >= until_time: break
                time.sleep(0.002)
            if time.time() >= end: return None
            again = min(again * 2, 8.0)
    finally:
        for p in asked:
            try: os.remove(p)
            except OSError: pass


def sync(seconds=20):
    """Returns once the app has run every command sent before this call (a ping the app answers)."""
    if _await('ping', 'ping', seconds, lambda p: True) is None:
        raise SystemExit('the app did not answer in %d s (%s)' % (seconds, _alive_note()))


def answers(seconds=0.3):
    return _await('ping', 'ping', seconds, lambda p: True) is not None


def full_dump(seconds=30):
    def read(path):
        with open(path) as f: return json.load(f)
    d = _await('dump', 'dump', seconds, read)
    if d is None: raise SystemExit('no dump: the app did not answer in %d s (%s)' % (seconds, _alive_note()))
    return d


def dump():
    """The shown tab's part of the dump."""
    return full_dump()['active']


# ---------------------------------------------------------------------------------------------
# Waiting for a state.

def _holds(check, d):
    if check is None: return True
    try:
        return bool(check(d))
    except (KeyError, IndexError, TypeError, AttributeError, ValueError):
        return False  # that part of the state isn't there yet


def is_quiet(d):
    """Nothing under way: no action, load or refresh in the shown repository, no task in Activity, no
    Fetch All round, and no git command running (the paused `git log` a shown history reads more from
    doesn't count)."""
    driver = d.get('driver') or {}
    running = [c for c in driver.get('running', []) if not c.startswith('git log --date-order')]
    return (not driver.get('busy') and not running and not driver.get('fetchingAll')
            and not d['active'].get('activity') and not d['phase5'].get('activity'))


def _give_up(what, label, seconds, d):
    lines = ['timed out after %g s waiting for %s' % (seconds * PATIENCE, label or what)]
    if d:
        a = d.get('active', {})
        lines.append('  shown: %s' % {key: a.get(key) for key in ('name', 'head', 'branch', 'activity', 'operation', 'alert', 'toast', 'selection')})
        lines.append('  driver: %s' % json.dumps(d.get('driver'), ensure_ascii=False)[:600])
        lines.append('  tabs: %s' % ['%s:%s%s' % (t['name'], t['phase'], '*' if t.get('busy') else '') for w in d.get('windows', []) for t in w['tabs']])
        for part in ('phase4', 'phase5', 'phase6'):
            source = a if part == 'phase4' else d
            lines.append('  %s: %s' % (part, json.dumps(source.get(part), ensure_ascii=False)[:1200]))
        try:
            os.makedirs(RUN_DIR, exist_ok=True)
            with open(os.path.join(RUN_DIR, 'failed-dump.json'), 'w') as f: json.dump(d, f, indent=1, ensure_ascii=False)
            post('snapshotAll ' + os.path.join(RUN_DIR, 'failed.png'))
            lines.append('  the whole dump and a picture: %s/failed-dump.json, failed.png' % RUN_DIR)
        except OSError:
            pass
    raise SystemExit('\n'.join(lines))


def until(check, seconds=20, label=''):
    """Polls the dump until check(dump) holds and returns that dump. For a state to catch while the app is
    still working; to go on with the next step, use settle()."""
    began = time.time()
    end = began + seconds * PATIENCE
    pause = 0.01
    while True:
        d = full_dump()
        if _holds(check, d):
            trace('until ' + label, began)
            return d
        if time.time() >= end: _give_up('a state', label, seconds, d)
        time.sleep(pause)
        pause = min(pause * 1.5, 0.15)


CALM = 0.05
_markers = [0]


def _quiet(check, end, label, seconds):
    """Polls until the app is quiet and check(dump) holds in two dumps in a row with no git command
    started in between; returns the dump."""
    pause = 0.01
    last = None
    while True:
        d = full_dump()
        ok = is_quiet(d) and _holds(check, d)
        mark = (d['driver'].get('lastCommand'), len(d['driver'].get('running', []))) if ok else None
        if ok and mark == last: return d
        if time.time() >= end:
            _give_up('the app to be quiet' + ('' if _holds(check, d) else ' in the expected state'), label, seconds, d)
        last = mark
        if ok:
            time.sleep(CALM)
        else:
            time.sleep(pause)
            pause = min(pause * 1.5, 0.15)


def _files_seen(d, end, label, seconds):
    """Returns once the shown repository's file watcher has delivered every change made so far. The
    watcher batches changes for 0.3 s, and the refresh a late batch starts would run into the next
    command (it can even undo what that command shows: a stash pop that stops on a conflict). So a
    marker file goes into the git folder — a path the app's refresh ignores — and its name is waited for
    in the dump: file events arrive in order, so everything before it has arrived too."""
    folder = d['driver'].get('gitDirectory')
    if not folder or not os.path.isdir(folder): return False  # not a repository, or the watcher is off
    _markers[0] += 1
    name = 'kaern-debug-sync-%d-%d' % (os.getpid(), _markers[0])
    path = os.path.join(folder, name)
    began = time.time()
    with open(path, 'w'): pass
    try:
        pause = 0.005
        while True:
            now = full_dump()
            if now['driver'].get('watchMarker') == name: break
            if now['driver'].get('gitDirectory') != folder: return False  # another tab is shown now
            if time.time() >= end:
                _give_up('the file watcher to report the marker %s' % name, label, seconds, now)
            time.sleep(pause)
            pause = min(pause * 1.5, 0.05)
    finally:
        try: os.remove(path)
        except OSError: pass
    trace('file events in', began)
    return True


def settle(check=None, seconds=30, label=''):
    """Waits until the app is quiet (see is_quiet) and check(dump) holds — in two dumps in a row with no
    git command started in between — and its file watcher has caught up with every change made so far,
    and returns the dump. This is what follows a command: the action it starts, the refresh after it,
    the loads that follow and the refresh the watcher starts a moment later are done, so the next command
    isn't dropped as 'busy' and nothing still running can cross it."""
    began = time.time()
    end = began + seconds * PATIENCE
    d = _quiet(check, end, label, seconds)
    if _files_seen(d, end, label, seconds):
        d = _quiet(check, end, label, seconds)
    trace('settle ' + label, began)
    return d


def shown(seconds=30, label=''):
    """settle() for scripts that read the shown tab's part: returns dump()['active'] once the app is quiet."""
    return settle(None, seconds, label)['active']


# ---------------------------------------------------------------------------------------------
# The app's process (found by its session file under this run's folder).

def _pattern(session=None):
    path = session or (RUN_DIR + '/')
    return '-KaernSessionFile ' + re.sub(r'([.+*?()\[\]{}|^$\\])', r'\\\1', path) + ('( |$)' if session else '')


def app_pids(session=None):
    out = subprocess.run(['pgrep', '-f', '--', _pattern(session)], capture_output=True, text=True).stdout.split()
    return [int(p) for p in out]


def _alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _alive_note():
    pids = app_pids()
    return 'the app is running, pid %s, channel %s' % (pids, CHANNEL) if pids else 'no app is running on this run\'s session — did it crash?'


def wait_gone(pids, seconds=8):
    end = time.time() + seconds * PATIENCE
    while any(_alive(p) for p in pids):
        if time.time() >= end: return False
        time.sleep(0.01)
    return True


def kill_app(session=None, hard=False):
    """Ends this run's instances (all of them, or the one on `session`) and waits until they're gone."""
    pids = app_pids(session)
    for pid in pids:
        try: os.kill(pid, signal.SIGKILL if hard else signal.SIGTERM)
        except ProcessLookupError: pass
    if not wait_gone(pids, 5):
        for pid in pids:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
        wait_gone(pids, 5)


def rss_mb(session=None):
    """The instance's resident memory in MB."""
    pids = app_pids(session)
    out = subprocess.run(['ps', '-o', 'rss=', '-p', str(pids[-1])], capture_output=True, text=True).stdout.strip()
    return int(out) // 1024


# ---------------------------------------------------------------------------------------------
# git in the samples (your own config switched off).

def git(*args):
    return subprocess.run([GIT] + list(args), cwd=PL, env=ENV, capture_output=True, text=True).stdout.strip()


def g(path, *args):
    return subprocess.run([GIT] + list(args), cwd=path, env=ENV, capture_output=True, text=True).stdout.strip()


def show(label, a, keys=('head', 'branch', 'toast', 'undo', 'redo')):
    print('--', label, {key: a.get(key) for key in keys})


def toast(d):
    """The toast's text ('' when none shows)."""
    t = d['active'].get('toast')
    return t['message'] if t else ''


def commands(d):
    """How many git commands the app has started. A load that runs git is over once this went up and the
    app is quiet: n = commands(full_dump()); k(…); settle(lambda d: commands(d) > n)."""
    return d['driver']['commandCount']


def window_open(d, text):
    """A window, popover or menu whose class or title has `text` is on screen (Popover, Command Log)."""
    return any(text in w for w in d['driver']['visibleWindows'])


if __name__ == '__main__':
    if len(sys.argv) < 2: raise SystemExit('usage: k3.py [--run <run>] <command…>   (run %s, channel %s)' % (RUN, CHANNEL))
    k(*sys.argv[1:])
    if sys.argv[1] != 'quit': sync()  # the command has run
