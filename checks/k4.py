"""Launching a test instance for this run, quitting it, and starting it again on the same session.

launch_prepared() gives the run fresh samples (a copy from the sample cache, see samples.py), a session
file and settings of its own and a new instance, and returns once the instance answers and every tab
has loaded (the preload after launch goes through the background tabs)."""
import itertools, json, os, re, shutil, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k3 import *
import samples
import preferences
from paths import APP

GITCONFIG = os.path.join(RUN_DIR, 'test-gitconfig')
# What the board comparisons were taken with.
COLUMNS = ['-KaernColumnRef', '176', '-KaernColumnGraph', '0', '-KaernColumnDate', '104', '-KaernColumnSHA', '72', '-KaernFileTree', 'NO']
# How far to the right of the screen a run's windows are (the app's -KaernDebugWindowsAside): they cover nothing of
# yours while the checks run, and they are the same on every Mac, whatever its screen. KAERN_ON_SCREEN=1, or an
# instance started by hand (KAERN_POINTER=1), keeps them on the screen to look at.
ASIDE = 12000
_state = {'session': None, 'mode': 'light', 'cleaned': False}
_launches = itertools.count(1)


def session():
    """The session file of this run's current instance (each fresh launch gets a new one, so its
    settings, credentials and gitconfig next to it start empty)."""
    if _state['session'] is None:
        found = sorted((f for f in os.listdir(RUN_DIR) if re.fullmatch(r'session-\d+-\d+\.json', f)),
                       key=lambda f: os.path.getmtime(os.path.join(RUN_DIR, f))) if os.path.isdir(RUN_DIR) else []
        if not found: raise SystemExit('no instance was launched for the run %s' % RUN)
        _state['session'] = os.path.join(RUN_DIR, found[-1])
    return _state['session']


def mode():
    """The appearance the current instance was launched with."""
    return _state['mode']


def write_session(path, samples_dir=SAMPLES):
    with open(os.path.join(TOOLS, 'session-test.json')) as f: template = f.read()
    with open(path, 'w') as f: f.write(template.replace('{SAMPLES}', samples_dir))


def start_app(appearance='light', extra=(), columns=True, drop=(), session_file=None, git_config=True):
    """Starts the Debug app in the background (it never takes focus) on a session file, listening on this
    run's channel, with the run's own global git config."""
    path = session_file or session()
    args = ['-KaernSessionFile', path, '-KaernCheckPreferencesID', preferences.open_session(path),
            '-KaernDebugChannel', CHANNEL, '-KaernAppearance', appearance]
    # The real mouse stays out of it (a hovered row changes pictures and what Return picks in Quick Open);
    # KAERN_POINTER=1 lets it in, to click around in an instance started by hand.
    if not os.environ.get('KAERN_POINTER'): args += ['-KaernDebugIgnorePointer', 'YES']
    if not (os.environ.get('KAERN_POINTER') or os.environ.get('KAERN_ON_SCREEN')): args += ['-KaernDebugWindowsAside', str(ASIDE)]
    args += (COLUMNS if columns else []) + [str(a) for a in extra]
    # KAERN_ZOOM=1.25 starts the app zoomed (View › Zoom In): for pictures of every screen at that size.
    if os.environ.get('KAERN_ZOOM'): args += ['-KaernZoom', os.environ['KAERN_ZOOM']]
    for key in drop:
        if key in args:
            i = args.index(key); del args[i:i + 2]
    command = ['/usr/bin/open', '-n', '-g'] + (['--env', 'GIT_CONFIG_GLOBAL=' + GITCONFIG] if git_config else []) + [APP, '--args'] + args
    subprocess.run(command, check=True)
    _state['mode'] = appearance


def loaded(d):
    """git was found and every tab is past its first load."""
    tabs = [t for w in d['windows'] for t in w['tabs']]
    return d['git'] != '' and all(t['phase'] not in ('waiting', 'opening', 'light', 'loading') and not t['busy'] for t in tabs)


def wait_launched(seconds=60):
    began = time.time()
    end = began + seconds * PATIENCE
    while not answers(0.3):
        if time.time() >= end:
            raise SystemExit('the app did not start taking commands on %s in %g s (%s)'
                             % (NOTIFICATION, seconds * PATIENCE, 'it is running' if app_pids() else 'it is not running'))
    trace('the app answers', began)
    return settle(loaded, seconds=seconds, label='the launch: every tab loaded')


def fresh_run():
    """Ends the run's earlier instances and, the first time in this process, clears what an earlier run left."""
    kill_app()
    if not _state['cleaned']:
        _state['cleaned'] = True
        for name in os.listdir(RUN_DIR) if os.path.isdir(RUN_DIR) else []:
            if name != 'samples': samples._discard(os.path.join(RUN_DIR, name))
    os.makedirs(RUN_DIR, exist_ok=True)
    shutil.copyfile(os.path.join(TOOLS, 'test-gitconfig'), GITCONFIG)
    _state['session'] = os.path.join(RUN_DIR, 'session-%d-%d.json' % (os.getpid(), next(_launches)))
    return _state['session']


def launch_prepared(appearance='light', scenario='base', prepare=None, extra=(), drop=()):
    """Fresh samples (`scenario` from the cache, then prepare()), a fresh session and a new instance."""
    began = time.time()
    path = fresh_run()
    samples.install(scenario, SAMPLES)
    trace('samples ' + scenario, began)
    if prepare:
        began = time.time(); prepare(); trace('prepare', began)
    write_session(path)
    began = time.time()
    start_app(appearance, extra, drop=drop)
    trace('open', began)
    return wait_launched()


def launch(appearance='light', scenario='base', *extra):
    return launch_prepared(appearance, scenario, extra=extra)


def stored_setting(key):
    """The setting saved for this session, independent of the live app's view of it."""
    return preferences.saved_settings(session()).get(key)


def wait_saved_settings(expected, seconds=10):
    def saved(_):
        settings = preferences.saved_settings(session())
        return all(settings.get(key) == value for key, value in expected.items())
    until(saved, seconds=seconds, label='saved settings ' + str(expected))


def set_setting(key, value, seconds=10):
    """Apply a setting (None removes it) and wait for the session's persistent domain to reflect it."""
    k('setting', key, '-' if value is None else value)
    wait_saved_settings({key: value}, seconds)
    sync()


def quit_app():
    """Quits the instance (it saves its session first) and waits until its process is gone."""
    began = time.time()
    pids = app_pids()
    k('quit')
    if not wait_gone(pids, 8): kill_app()
    else: preferences.archive_in(RUN_DIR)
    trace('quit', began)


def relaunch(appearance='light', *extra):
    """Starts the app again on the same session and settings files."""
    start_app(appearance, extra, columns=False)
    return wait_launched()


if __name__ == '__main__':
    # k4.py launch <light|dark> [scenario] [extra args…] — what launch.sh runs.
    if len(sys.argv) > 1 and sys.argv[1] == 'launch':
        launch(*(sys.argv[2:] or ['light']))
        print('launched: run %s, channel %s, session %s' % (RUN, CHANNEL, session()))
