"""Sample repositories for a run, without building them again each time.

Building the samples takes seconds (the base set runs ~700 git commands; the big histories and the signed
one more), and every launch used to build them again. Each kind is now built once into
<work folder>/sample-cache/<key>/ and a run gets its own copy as APFS clones (cp -c): no data is copied
until a file changes, so a copy takes a moment whatever its size.

A copy is made like a fresh build: the few absolute paths git keeps (a remote's folder, a worktree's two
links, the allowed signers file) are pointed at the run's folder, and each index is refreshed (a clone
has new inodes, and the app runs git with GIT_OPTIONAL_LOCKS=0, so its status would never save that).

    python3 samples.py build [key…]     build what's missing (every kind when no key is given)
    python3 samples.py fresh [key…]     build again
    python3 samples.py list             the kinds, and which are built
    python3 samples.py check            exit 1 if something wrote into the cache since it was built

Kinds: base, conflict, stash-conflict (make_samples.py scenarios; any other scenario name works too),
big-600, big-3000, big-60000 (bigsample.py), remotes-3000 (1,243 remote branches), changes-3000 (12,409
changed files), signed (the SSH-signed powerlens with the hotfix worktree).
"""
import fcntl, hashlib, json, os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from paths import WORK
CACHE = os.environ.get('KAERN_SAMPLE_CACHE') or os.path.join(WORK, 'sample-cache')
GIT = os.environ.get('KAERN_GIT') or subprocess.run(['xcrun', '--find', 'git'], capture_output=True, text=True).stdout.strip() or '/usr/bin/git'
ENV = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
# A cache older than this is built again: the samples' dates are relative to when they were made.
MAX_AGE = float(os.environ.get('KAERN_SAMPLE_HOURS', '3')) * 3600
ALL = ['base', 'conflict', 'stash-conflict', 'big-600', 'big-3000', 'big-60000', 'remotes-3000', 'changes-3000', 'signed']
BIG_NAME = 'cluster-config'


def _source_stamp():
    """Changes when a generator changes, so its cache is built again."""
    h = hashlib.sha1()
    for name in ('make_samples.py', 'bigsample.py', 'scen6.py', 'samples.py'):
        try:
            with open(os.path.join(HERE, name), 'rb') as f: h.update(f.read())
        except OSError:
            pass  # set up without the later phases' tools
    return h.hexdigest()[:12]


def _entry(key):
    return os.path.join(CACHE, key.replace('/', '_'))


def _meta(key):
    try:
        with open(os.path.join(_entry(key), 'meta.json')) as f: return json.load(f)
    except (OSError, ValueError):
        return None


def _usable(key):
    meta = _meta(key)
    return bool(meta) and meta['source'] == _source_stamp() and time.time() - meta['built'] < MAX_AGE


def _py(script, *args):
    r = subprocess.run([sys.executable, '-I', os.path.join(HERE, script)] + list(args), capture_output=True, text=True)
    if r.returncode != 0: raise SystemExit('%s %s failed:\n%s%s' % (script, ' '.join(args), r.stdout, r.stderr))


def _build(key, root):
    """Builds the kind into `root` (a samples folder of its own) and returns the paths in it a run takes
    (None: the whole folder)."""
    if key.startswith('big-'):
        _py('bigsample.py', root, 'big', key.split('-')[1])
        return ['big']
    if key in ('remotes-3000', 'changes-3000'):
        install('big-3000', root, {'big': BIG_NAME})
        import scen6
        if key == 'remotes-3000':
            scen6.many_remotes(BIG_NAME, root=root)
            return [BIG_NAME, 'remotes/%s.git' % BIG_NAME]
        scen6.many_changes(BIG_NAME, root=root)
        return [BIG_NAME]
    if key == 'signed':
        install('base', root)
        import scen6
        scen6.marks_sample('powerlens', root=root)
        return None
    _py('make_samples.py', '--scenario', key, '--root', root)
    return None


def ensure(key, fresh=False):
    """The cache entry for `key`, built first when it's missing, stale or `fresh`. One builder at a time
    per kind, so runs that start together share the one build."""
    if not fresh and _usable(key): return _entry(key)
    os.makedirs(CACHE, exist_ok=True)
    with open(_entry(key) + '.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if fresh or not _usable(key):
            entry = _entry(key)
            _discard(entry)
            root = os.path.join(entry, 'root')
            os.makedirs(root)
            started = time.time()
            items = _build(key, root)
            # Written last: an entry without it is a build that didn't finish.
            with open(os.path.join(entry, 'meta.json'), 'w') as f:
                json.dump({'key': key, 'root': root, 'items': items, 'built': time.time(), 'source': _source_stamp(),
                           'seconds': round(time.time() - started, 2)}, f)
    return _entry(key)


def _discard(path):
    """Removes a folder without waiting for it: moved aside, deleted in the background."""
    if not os.path.lexists(path): return
    aside = os.path.join(os.path.dirname(path), '.trash-%d-%d' % (os.getpid(), time.time_ns()))
    os.rename(path, aside)
    subprocess.Popen(['rm', '-rf', aside], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _clone(source, target):
    os.makedirs(os.path.dirname(target), exist_ok=True)
    # -c: clonefile(2) per file (cp copies when the volume can't clone); -p keeps modes and times.
    subprocess.run(['cp', '-c', '-R', '-p', source, target], check=True)


def install(key, samples, rename=None):
    """Copies the kind into the samples folder `samples` as clones: the whole folder (replacing it) or, for
    a kind that is part of one, its paths, replacing what is there. `rename` maps a path in the cache to
    another in `samples` ({'big': 'cluster-config'})."""
    entry = ensure(key)
    # Shared with other copies; a rebuild of this kind waits until none is being made.
    with open(entry + '.lock') as lock:
        fcntl.flock(lock, fcntl.LOCK_SH)
        meta = _meta(key)
        root = meta['root']
        if meta['items'] is None:
            if os.path.lexists(samples): _discard(samples)
            _clone(root, samples)
            tops = [samples]
        else:
            tops = []
            for item in meta['items']:
                target = os.path.join(samples, (rename or {}).get(item, item))
                if os.path.lexists(target): _discard(target)
                _clone(os.path.join(root, item), target)
                tops.append(target)
    trees = []
    for top in tops:
        trees += relocate(top, root, samples)
    refresh(trees)
    return entry


def _is_git_dir(path):
    return os.path.isfile(os.path.join(path, 'HEAD')) and os.path.isdir(os.path.join(path, 'objects'))


def _rewrite(path, old, new):
    try:
        if os.path.islink(path) or os.path.getsize(path) > 1 << 20: return
        with open(path, 'rb') as f: data = f.read()
    except OSError:
        return
    if old in data:
        with open(path, 'wb') as f: f.write(data.replace(old, new))


def relocate(top, old_root, new_root):
    """Points git's absolute paths under `top` from old_root to new_root (config, a worktree's gitdir and
    .git files, FETCH_HEAD, reflogs; never a file in a working tree) and returns the working trees found."""
    old, new = old_root.encode(), new_root.encode()
    trees = []

    def inside(git_dir):
        for folder, dirs, files in os.walk(git_dir):
            # Objects and refs hold no paths.
            dirs[:] = [d for d in dirs if d not in ('objects', 'lfs') and not (d == 'refs' and os.path.basename(folder) != 'logs')]
            for name in files:
                if name not in ('index', 'packed-refs'): _rewrite(os.path.join(folder, name), old, new)

    if _is_git_dir(top):
        inside(top)
        return trees
    for folder, dirs, files in os.walk(top):
        if '.git' in files:
            _rewrite(os.path.join(folder, '.git'), old, new)
            trees.append(folder)
        if '.git' in dirs:
            inside(os.path.join(folder, '.git'))
            dirs.remove('.git')
            trees.append(folder)
        for d in list(dirs):
            if _is_git_dir(os.path.join(folder, d)):
                inside(os.path.join(folder, d))
                dirs.remove(d)
    return trees


def refresh(trees):
    """Brings each working tree's index up to date with its files' new inodes, as a fresh build has it."""
    running = [subprocess.Popen([GIT, 'update-index', '-q', '--refresh'], cwd=tree, env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
               for tree in trees if os.path.exists(os.path.join(tree, '.git'))]
    for p in running: p.wait()


def changed_since_built():
    """Files in the cache that changed after their kind was built: a run wrote into the cache instead of
    its own copy (a path that wasn't pointed at the run's folder)."""
    found = []
    for name in sorted(os.listdir(CACHE)) if os.path.isdir(CACHE) else []:
        marker = os.path.join(CACHE, name, 'meta.json')
        if not os.path.isfile(marker): continue
        out = subprocess.run(['find', os.path.join(CACHE, name, 'root'), '-newer', marker, '-not', '-type', 'd'], capture_output=True, text=True).stdout
        found += out.splitlines()
    return found


def main(args):
    command = args[0] if args else 'list'
    keys = args[1:] or ALL
    if command in ('build', 'fresh'):
        # Kinds made from another kind come after it; the rest build side by side.
        first = [key for key in keys if key not in ('remotes-3000', 'changes-3000', 'signed')]
        for key in ('big-3000', 'base'):
            if key not in first and any(k in keys for k in {'big-3000': ('remotes-3000', 'changes-3000'), 'base': ('signed',)}[key]):
                first.append(key)
        second = [key for key in keys if key not in first]
        for group in (first, second):
            running = [(key, subprocess.Popen([sys.executable, os.path.abspath(__file__), 'one', command, key])) for key in group]
            failed = [key for key, p in running if p.wait() != 0]
            if failed: raise SystemExit('could not build: %s' % ', '.join(failed))
    elif command == 'one':
        started = time.time()
        fresh = args[1] == 'fresh'
        was = _usable(args[2]) and not fresh
        ensure(args[2], fresh=fresh)
        print('%-16s %s' % (args[2], 'already built' if was else 'built in %.1f s' % (time.time() - started)), flush=True)
    elif command == 'list':
        for key in ALL:
            meta = _meta(key)
            print('%-16s %s' % (key, 'built %d min ago in %.1f s%s' % ((time.time() - meta['built']) / 60, meta['seconds'], '' if _usable(key) else ' (stale)')
                                if meta else 'not built'))
    elif command == 'check':
        found = changed_since_built()
        for path in found[:40]: print('changed after the build:', path)
        if found: raise SystemExit('%d files in the sample cache changed after it was built' % len(found))
        print('the sample cache is as it was built')
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
