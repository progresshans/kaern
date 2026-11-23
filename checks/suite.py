#!/usr/bin/env python3
"""suite.py — runs Kaern's app flow checks, several at a time.

    python3 suite.py                        every check, 3 at a time; the ones that measure run alone at the end
    python3 suite.py --jobs 1               one at a time (-j N: N at a time)
    python3 suite.py t_stash t_marks6       only these
    python3 suite.py --area sidebar,undo    the checks for those areas
    python3 suite.py --changed [<base>]     the checks for the files changed since <base> (default: develop),
                                            uncommitted changes included; anything in the core runs them all
    python3 suite.py --list [--changed …]   what would run, with areas and lanes; nothing is started

    --no-dark         skip the dark pictures (they are taken in the same run, see below)
    --dark-runs       the old way instead: the picture checks run a second time, launched in dark
    --reuse-samples   keep the sample cache when it is still good (default: build it again, once, at the start)
    --repeat N        the whole selection N times (to look for a check that fails now and then)
    --timeout S       seconds before a check is stopped (default 600, times KAERN_PATIENCE)
    --log FILE        also one log of everything

Each check is a run of its own: its samples, session, gitconfig and debug channel are under
<work folder>/runs/<check>/, so runs don't see each other (paths.py says where the work folder is). The output goes
to <work folder>/suite/<time>/: <check>.log per check, summary.txt, times.tsv; <work folder>/suite/latest points at
it. Exit status 0: all passed.

Dark pictures: a check that has them (KAERN_SHOTS=light,dark) takes each picture in light, switches the
appearance, takes it in dark and switches back, so its logic runs once.
"""
import concurrent.futures, fcntl, json, os, re, shutil, signal, subprocess, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from paths import APP, PATIENCE, REPO, TOOLS, WORK
import preferences


class Check:
    def __init__(self, name, areas, dark=False, alone=False, samples=('base',), seconds=8):
        self.name, self.areas, self.dark, self.alone = name, areas.split(), dark, alone
        self.samples, self.seconds = samples, seconds


# dark: its pictures are taken in dark too.
# alone: it measures speed or memory, so nothing else runs beside it. seconds: about how long it takes
# (the long ones start first).
CHECKS = [
    Check('t_settings', 'settings launch tabs'),
    Check('t_conflict', 'conflicts rebase undo', samples=('conflict',)),
    Check('t_stash', 'stash conflicts undo', samples=('stash-conflict',)),
    Check('t_rebase', 'rebase sheets undo'),
    Check('t_rebasepushed', 'rebase sheets undo', seconds=12),
    Check('t_sheets', 'sheets sidebar undo menus'),
    Check('t_explore', 'explore'),
    Check('t_activity', 'activity fetch statusbar commandlog'),
    Check('t_quickopen', 'quickopen explore'),
    Check('t_popstaged', 'stash conflicts changes'),
    Check('t_stalerefresh', 'stash conflicts', samples=('stash-conflict',), seconds=20),
    Check('t_resethard', 'undo changes', samples=('stash-conflict',), seconds=14),
    Check('t_stalestate', 'stash undo rebase sheets', samples=('stash-conflict',), seconds=20),
    Check('t_isolation', 'settings launch changes'),
    Check('t_clone', 'start sheets activity', dark=True, seconds=20),
    Check('t_repos', 'repositories pull fetch activity', dark=True),
    Check('t_modes', 'layout settings sidebar launch', dark=True, seconds=28),
    Check('t_narrow760', 'layout statusbar settings', dark=True, seconds=10),
    Check('t_bigrepo', 'history', dark=True, samples=('base', 'big-3000'), seconds=38),
    Check('t_sidescroll', 'review'),
    Check('t_marks', 'marks review changes sidebar', dark=True, seconds=26),
    Check('t_small', 'history review menus tabs', samples=('base', 'big-600'), seconds=14),
    Check('t_shallow', 'history fetch'),
    Check('t_review5', 'marks repositories history pull undo', samples=('base', 'big-60000'), seconds=10),
    Check('t_preload', 'history launch', samples=('base', 'big-3000'), seconds=34),
    Check('t_lifecycle', 'history launch', samples=('base', 'big-3000'), seconds=29),
    Check('t_historyfail', 'history statusbar commandlog start', dark=True),
    Check('t_pullrebase', 'pull rebase conflicts stash undo', dark=True, seconds=12),
    Check('t_scope', 'history sidebar menus settings', dark=True, samples=('base', 'remotes-3000'), seconds=18),
    Check('t_bigchanges', 'changes undo settings', dark=True, alone=True, samples=('base', 'changes-3000'), seconds=13),
    Check('t_marks6', 'signatures worktrees sidebar sheets stash undo', dark=True, samples=('signed',), seconds=14),
    Check('t_review6', 'worktrees signatures pull stash undo', samples=('signed', 'base'), seconds=12),
    Check('t_review7', 'undo conflicts stash changes', seconds=24),
    Check('t_knownbugs', 'history sidebar changes worktrees tabs', samples=('base', 'remotes-3000', 'signed'), seconds=30),
    Check('t_welcome', 'start launch tabs settings', seconds=12),
    Check('t_panes', 'layout sidebar review launch', seconds=42),
    Check('t_arrows', 'review changes history explore', seconds=10),
    Check('t_labels', 'history', seconds=10),
    Check('t_labelswitch', 'history', seconds=15),
    Check('t_worktreemenu', 'sidebar history', seconds=20),
    Check('t_sidebar', 'sidebar history', seconds=10),
    Check('t_wholenames', 'sidebar history', seconds=15),
    Check('t_stacks', 'sidebar changes layout', seconds=12),
    Check('t_tabs', 'tabs', seconds=8),
    Check('t_keptscreens', 'tabs layout', seconds=20),
    Check('t_zoom', 'layout menus settings', seconds=35),
    Check('t_nestedworktree', 'worktrees sidebar', seconds=8),
    Check('t_publishfail', 'start sheets', seconds=12),
    Check('t_finish', 'sheets menus undo conflicts rebase', seconds=30),
    Check('t_deepselect', 'history', samples=('base', 'big-60000'), seconds=20),
    Check('t_firstload', 'launch history changes', seconds=8),
    Check('t_remotemore', 'sidebar', samples=('base', 'remotes-3000'), seconds=12),
]
BY_NAME = {c.name: c for c in CHECKS}

# Source paths → areas. A path that matches CORE, or a Swift file that matches nothing, runs every check.
CORE = r'''(?x) ^Kaern/App/(AppModel|AppDelegate|main|DebugDriver.*)\.swift$ | ^Kaern/Repository/RepositoryModel(\+Actions)?\.swift$
    | ^Kaern/Window/(MainWindowController|WindowModel)\.swift$ | ^Kaern/Views/WindowRootView\.swift$ | ^Kaern/Design/ | ^Kaern/Session/
    | KaernKit/Git/(GitRunner|GitRepository|GitRepository\+Indicators)\.swift$ | KaernKit/Parsing/RecordParsing | KaernKit/Watch/
    | \.xcodeproj/ | Package\.swift$ | \.entitlements$ | Info\.plist$'''
NONE = r'(?x) /Tests/ | \.md$ | ^script/ | ^\.gitignore$ | ^\.github/ | ^Kaern/Resources/Licenses/'
# A check's own file runs that check; any other file of the checks (a helper, a sample) runs them all.
OWN = r'^checks/(t_\w+)\.py$'
AREAS = [
    (r'Views/Conflicts/|RepositoryModel\+Conflicts|GitRepository\+Conflicts|Parsing/ConflictDocument', 'conflicts'),
    (r'Views/Stash/|RepositoryModel\+Stashes|GitRepository\+Stash', 'stash'),
    (r'RepositoryModel\+Rebase|Sheets/RebaseSheet|GitRepository\+InteractiveRebase', 'rebase'),
    (r'GitRepository\+Operations|Models/Operation', 'rebase conflicts pull'),
    (r'Sheets/Sheets\.swift|Sheets/FinishSheet|RepositoryModel\+Sheets|RepositoryModel\+Finish|Common/FlowViews|Models/TagNaming', 'sheets'),
    (r'Sheets/RepositorySettingsSheet|GitRepository\+Settings', 'sheets pull'),
    (r'Views/Explore/|RepositoryModel\+Explore|Models/FileHistory|GitRepository\+Files', 'explore'),
    (r'Views/QuickOpen/|Models/FuzzyMatch', 'quickopen'),
    (r'App/Activity\.swift|RepositoryModel\+Fetch|App/FailureHelp|Git/GitFailure|Models/GitProgress|GitRepository\+Remotes|KaernKit/Hosting/',
     'activity fetch repositories pull'),
    (r'Kaern/Settings/|UserDefaults\+Kaern|App/TestSession|Engine/GitLocator', 'settings launch'),
    (r'AppModel\+Start|Views/Start/|Views/Welcome/|Window/WindowSheet|GitRepository\+Create|Models/FolderSurvey|Models/RemoteURL', 'start'),
    (r'Views/Repositories/', 'repositories'),
    (r'Views/RepositoryList/|Sidebar/SidebarRail|Views/Toolbar/|Common/ToolbarControls|Common/PaneResize|Models/PaneLayout', 'layout'),
    (r'Common/ArrowKeySteps', 'review changes history explore'),
    (r'Views/TabBar/', 'tabs layout'),
    (r'Views/History/|Git/CommitStream|GitRepository\+History|GitRepository\+Search|KaernKit/Graph/|Models/(BotFolding|Commit|CommitSearch|HistoryScope)\.swift'
     r'|RepositoryModel\+Scope|Parsing/LogParser', 'history'),
    (r'Views/Review/(DiffSideScroll|DiffViews|FocusDrawer|ReviewView)|Parsing/DiffParser|Models/(Diff|InlineDiff)\.swift|GitRepository\+(Review|Lines|Content)',
     'review marks'),
    (r'RepositoryModel\+Marks|Review/MarkViews|Panel/MarksPanels|GitRepository\+LFS', 'marks'),
    (r'RepositoryModel\+(BigChanges|Changes)|Panel/(BigChangesPanel|DetailsPanel)|GitRepository\+Discard|Parsing/(StatusParser|ChangeListParser)|Models/Status',
     'changes'),
    (r'Panel/ComparePanels|GitRepository\+Compare', 'changes undo'),
    (r'Sidebar/SidebarView|Models/Ref\.swift|Parsing/RefParser|GitRepository\+Branches', 'sidebar sheets'),
    (r'Common/StackedLists', 'sidebar changes'),
    (r'RepositoryModel\+Signatures', 'signatures'),
    (r'RepositoryModel\+Worktrees', 'worktrees'),
    (r'RepositoryModel\+Undo|GitRepository\+Undo', 'undo'),
    (r'Views/Menus/|App/MainMenu', 'menus'),
    (r'Views/StatusBar/', 'statusbar'),
    (r'Views/CommandLog/|App/CommandLog|Git/GitCommandLog', 'commandlog'),
]


def areas_for(path):
    """The areas a changed path touches: None for every check, [] for none."""
    if re.search(NONE, path): return []
    if re.search(CORE, path) or path.startswith('checks/'): return None
    found = []
    for pattern, names in AREAS:
        if re.search(pattern, path): found += names.split()
    if found: return sorted(set(found))
    return None if path.endswith('.swift') else []


def app_lacks(app):
    """What the checks need that this build of the app doesn't have (its launch arguments and marker are
    plain strings in the binary)."""
    needed = {b'KaernDebugChannel': 'the debug channel', b'KaernDebugIgnorePointer': 'the pointer switch',
              b'KaernCheckPreferencesID': 'the private preferences domain', b'kaern-debug-sync-': "the file watcher's marker"}
    found = set()
    folder = os.path.join(app, 'Contents', 'MacOS')
    for name in os.listdir(folder) if os.path.isdir(folder) else []:
        try:
            with open(os.path.join(folder, name), 'rb') as f: data = f.read()
        except OSError:
            continue
        found |= {key for key in needed if key in data}
    return [what for key, what in needed.items() if key not in found]


def changed_paths(base):
    def lines(*args):
        r = subprocess.run(['git', '-C', REPO] + list(args), capture_output=True, text=True)
        if r.returncode != 0: raise SystemExit('git %s: %s' % (' '.join(args), r.stderr.strip()))
        return [line for line in r.stdout.split('\n') if line]
    committed = lines('diff', '--name-only', base + '...HEAD')
    uncommitted = [line[3:].split(' -> ')[-1] for line in lines('status', '--porcelain')]
    return sorted(set(committed + uncommitted))


def select(args):
    """The checks to run and why."""
    if args['names']:
        unknown = [n for n in args['names'] if n not in BY_NAME]
        if unknown: raise SystemExit('no such check: %s (see --list)' % ', '.join(unknown))
        return [BY_NAME[n] for n in args['names']], 'named'
    if args['area']:
        known = {a for c in CHECKS for a in c.areas}
        unknown = [a for a in args['area'] if a not in known]
        if unknown: raise SystemExit('no such area: %s (areas: %s)' % (', '.join(unknown), ' '.join(sorted(known))))
        return [c for c in CHECKS if set(c.areas) & set(args['area'])], 'areas ' + ', '.join(args['area'])
    if args['changed'] is not None:
        paths = changed_paths(args['changed'])
        wanted, own, everything, notes = set(), set(), False, []
        for path in paths:
            check = re.match(OWN, path)
            if check and (check.group(1) in BY_NAME or not os.path.exists(os.path.join(REPO, path))):
                own.add(check.group(1))
                notes.append('  %-62s %s' % (path, 'that check'))
                continue
            areas = areas_for(path)
            notes.append('  %-62s %s' % (path, 'every check' if areas is None else ' '.join(areas) or '—'))
            if areas is None: everything = True
            else: wanted |= set(areas)
        print('changed since %s:' % args['changed']); print('\n'.join(notes) or '  nothing')
        if everything: return list(CHECKS), 'a core file changed'
        return ([c for c in CHECKS if set(c.areas) & wanted or c.name in own],
                ', '.join(filter(None, ['areas ' + ', '.join(sorted(wanted)) if wanted else '', 'changed checks' if own else ''])) or 'nothing that a check covers')
    return list(CHECKS), 'all'


class Run:
    def __init__(self, check, mode, shots, round_):
        self.check, self.mode, self.shots, self.round = check, mode, shots, round_
        self.id = check.name + ('-dark' if mode == 'dark' else '') + ('.%d' % round_ if round_ > 1 else '')
        self.label = check.name + '.py' + (' ' + mode if check.dark and (mode == 'dark' or shots is None) else '')
        self.seconds = self.status = self.log = None

    @property
    def ok(self): return self.status == 0


def end_instances(run_id=None):
    """Ends the test instances of one run, or of every run in this work folder."""
    folder = os.path.join(WORK, 'runs', run_id) + '/' if run_id else os.path.join(WORK, 'runs') + '/'
    pattern = '-KaernSessionFile ' + re.sub(r'([.+*?()\[\]{}|^$\\])', r'\\\1', folder)
    pids = subprocess.run(['pgrep', '-f', '--', pattern], capture_output=True, text=True).stdout.split()
    if pids:
        from k3 import stop_processes
        stop_processes([int(pid) for pid in pids])
    preferences.archive_in(folder, '*.check-prefs' if run_id else '*/*.check-prefs')
    return len(pids)


LIVE = set()
LOCK = None


def execute(run, out, timeout, lock, counter, total):
    run.log = os.path.join(out, run.id + '.log')
    env = dict(os.environ, KAERN_RUN=run.id, PYTHONUNBUFFERED='1')
    env.pop('KAERN_SHOTS', None)
    # A repeated round's pictures go to a folder of their own (the rounds run side by side).
    if run.round > 1: env['KAERN_SHOTS_DIR'] = os.path.join(WORK, 'shots-round%d' % run.round)
    if run.shots: env['KAERN_SHOTS'] = run.shots
    args = [sys.executable, os.path.join(TOOLS, run.check.name + '.py')] + ([run.mode] if run.check.dark or run.mode == 'dark' else [])
    started = time.time()
    with open(run.log, 'w') as log:
        process = subprocess.Popen(args, cwd=TOOLS, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        LIVE.add(process.pid)
        try:
            run.status = process.wait(timeout=timeout * PATIENCE)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()
            run.status = 'timeout'
            log.write('\n=== stopped after %d s\n' % (timeout * PATIENCE))
        LIVE.discard(process.pid)
    run.seconds = time.time() - started
    end_instances(run.id)
    with lock:
        counter[0] += 1
        print('[%2d/%d] %-7s %-22s %6.1f s' % (counter[0], total, 'ok' if run.ok else 'FAILED', run.label, run.seconds), flush=True)


def main(argv):
    args = {'names': [], 'jobs': 3, 'area': None, 'changed': None, 'list': False, 'dark': 'shots', 'reuse': False,
            'repeat': 1, 'timeout': 600, 'log': None}
    i = 0
    while i < len(argv):
        a = argv[i]
        def value():
            nonlocal i
            i += 1
            if i >= len(argv): raise SystemExit('%s needs a value' % a)
            return argv[i]
        if a in ('-j', '--jobs'): args['jobs'] = max(1, int(value()))
        elif a == '--serial': args['jobs'] = 1
        elif a == '--area': args['area'] = [x for x in value().split(',') if x]
        elif a == '--changed':
            args['changed'] = 'develop'
            if i + 1 < len(argv) and not argv[i + 1].startswith('-') and not argv[i + 1].startswith('t_'): args['changed'] = value()
        elif a == '--list': args['list'] = True
        elif a == '--no-dark': args['dark'] = 'none'
        elif a == '--dark-runs': args['dark'] = 'runs'
        elif a == '--reuse-samples': args['reuse'] = True
        elif a == '--repeat': args['repeat'] = max(1, int(value()))
        elif a == '--timeout': args['timeout'] = int(value())
        elif a == '--log': args['log'] = os.path.abspath(value())
        elif a in ('-h', '--help'): print(__doc__); return 0
        elif a.startswith('-'): raise SystemExit('unknown option %s (see --help)' % a)
        else: args['names'].append(a[:-3] if a.endswith('.py') else a)
        i += 1

    checks, why = select(args)
    if args['list']:
        print('%d of %d checks (%s):' % (len(checks), len(CHECKS), why))
        for c in checks:
            print('  %-14s %-6s %-6s %s' % (c.name, 'dark' if c.dark else '', 'alone' if c.alone else '', ' '.join(c.areas)))
        print('areas: ' + ' '.join(sorted({a for c in CHECKS for a in c.areas})))
        return 0
    if not checks:
        print('nothing to run (%s)' % why)
        return 0
    if not os.path.isdir(APP):
        raise SystemExit('no app at %s — build it first (checks/build.sh), or name one with KAERN_APP' % APP)
    missing = app_lacks(APP)
    if missing:
        raise SystemExit('the app at %s has no debug driver (%s is missing): the checks need a Debug build of this '
                         'checkout (checks/build.sh)' % (APP, ' and '.join(missing)))

    runs = []
    for round_ in range(1, args['repeat'] + 1):
        for c in checks:
            if args['dark'] == 'runs':
                runs.append(Run(c, 'light', None, round_))
                if c.dark: runs.append(Run(c, 'dark', None, round_))
            else:
                runs.append(Run(c, 'light', 'light,dark' if c.dark and args['dark'] == 'shots' else 'light', round_))

    # One suite at a time in a work folder: two would use the same run folders and channels, and each ends
    # the other's instances.
    os.makedirs(os.path.join(WORK, 'suite'), exist_ok=True)
    global LOCK
    LOCK = open(os.path.join(WORK, 'suite', '.lock'), 'a+')
    try:
        fcntl.flock(LOCK, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        LOCK.seek(0)
        raise SystemExit('another suite is running in this work folder (%s); wait for it or stop it' % (LOCK.read().strip() or 'pid unknown'))
    LOCK.seek(0); LOCK.truncate(); LOCK.write('pid %d, started %s' % (os.getpid(), time.strftime('%H:%M:%S'))); LOCK.flush()

    out = os.path.join(WORK, 'suite', time.strftime('%Y%m%d-%H%M%S'))
    os.makedirs(out)
    latest = os.path.join(WORK, 'suite', 'latest')
    if os.path.lexists(latest): os.remove(latest)
    os.symlink(out, latest)
    began = time.time()
    stale = end_instances()
    if stale: print('ended %d test instance(s) left from before' % stale)

    # The samples: built once for the whole suite, each run copies what it needs.
    kinds = sorted({k for c in checks for k in c.samples})
    r = subprocess.run([sys.executable, os.path.join(TOOLS, 'samples.py'), 'build' if args['reuse'] else 'fresh'] + kinds,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        raise SystemExit('the samples could not be built')
    samples_seconds = time.time() - began
    print('samples (%s) %s in %.1f s; %d runs, %d at a time%s' % (
        ', '.join(kinds), 'ready' if args['reuse'] else 'built', samples_seconds, len(runs), args['jobs'],
        '' if args['jobs'] == 1 or not any(run.check.alone for run in runs) else ', then %d alone' % sum(run.check.alone for run in runs)), flush=True)

    lock, counter = threading.Lock(), [0]
    together = [run for run in runs if not run.check.alone or args['jobs'] == 1]
    alone = [run for run in runs if run.check.alone and args['jobs'] > 1]
    if args['jobs'] > 1:
        together.sort(key=lambda run: -run.check.seconds)  # the long ones first, so none is left running at the end
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=args['jobs'])
    try:
        for f in [pool.submit(execute, run, out, args['timeout'], lock, counter, len(runs)) for run in together]: f.result()
    except KeyboardInterrupt:
        # Stopped by hand: nothing more starts, and the checks under way end (main() ends their instances).
        pool.shutdown(wait=False, cancel_futures=True)
        for pid in list(LIVE):
            try: os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError: pass
        raise
    pool.shutdown()
    lane_seconds = time.time() - began - samples_seconds
    for run in alone:
        execute(run, out, args['timeout'], lock, counter, len(runs))
    wall = time.time() - began

    left = end_instances()
    cache = subprocess.run([sys.executable, os.path.join(TOOLS, 'samples.py'), 'check'], capture_output=True, text=True)
    failed = [run for run in runs if not run.ok]
    lines = []
    lines.append('%d runs: %d passed, %d failed — %s' % (len(runs), len(runs) - len(failed), len(failed), why))
    lines.append('wall time %s (samples %.1f s, %d at a time %.1f s%s); the runs add up to %s' % (
        clock(wall), samples_seconds, args['jobs'], lane_seconds, ', alone %.1f s' % (wall - samples_seconds - lane_seconds) if alone else '',
        clock(sum(run.seconds for run in runs))))
    lines.append('')
    for run in runs:
        lines.append('%-7s %-24s %6.1f s%s%s' % ('ok' if run.ok else 'FAILED', run.label + ('' if run.round == 1 else ' #%d' % run.round), run.seconds,
                                             '  alone' if run in alone else '', '' if run.ok else '  exit %s  %s' % (run.status, run.log)))
    notes = []
    for run in runs:
        with open(run.log, errors='replace') as f:
            notes += ['%s: %s' % (run.id, line.strip()) for line in f if line.startswith('NOTE:') or 'kept changing' in line]
    if notes: lines += ['', 'notes from the checks:'] + ['  ' + n for n in notes]
    if cache.returncode != 0:
        lines += ['', 'THE SAMPLE CACHE WAS WRITTEN TO during the run (a run used the cache instead of its own copy):', cache.stdout.strip()]
    if left: lines += ['', '%d test instance(s) were still running at the end and were ended' % left]
    for run in failed:
        lines += ['', '--- %s (%s), the end of its log:' % (run.label, run.log)]
        with open(run.log, errors='replace') as f: lines += ['    ' + line.rstrip()[:400] for line in f.readlines()[-14:]]
    summary = '\n'.join(lines)
    print('\n' + summary)
    with open(os.path.join(out, 'summary.txt'), 'w') as f: f.write(summary + '\n')
    with open(os.path.join(out, 'times.tsv'), 'w') as f:
        for run in runs: f.write('%.1f\t%s\t%s\n' % (run.seconds, run.status, run.label))
        f.write('%.1f\t-\tTOTAL\n' % wall)
    if args['log']:
        with open(args['log'], 'w') as combined:
            for run in runs:
                combined.write('=== %s\n' % run.label)
                with open(run.log, errors='replace') as f: combined.write(f.read())
                combined.write('=== %s exit %s\n' % (run.label, run.status))
            combined.write('=== done\n')
    print('\nlogs: %s' % out)
    return 0 if not failed and cache.returncode == 0 else 1


def clock(seconds):
    return '%d min %02d s' % (seconds // 60, seconds % 60) if seconds >= 60 else '%.1f s' % seconds


def _stop(signum, frame):
    raise KeyboardInterrupt


if __name__ == '__main__':
    # Ctrl-C, or a kill (a suite started in the background ignores SIGINT unless it is asked not to).
    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        # Stopped by hand: the checks under way and their instances go too.
        for pid in list(LIVE):
            try: os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError: pass
        end_instances()
        print('\nstopped')
        sys.exit(130)
