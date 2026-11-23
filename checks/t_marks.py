"""t_marks.py [light|dark] — ScreenMarks diff extras on the powerlens sample: an LFS picture (2-up / Swipe /
Onion Skin), an LFS video that isn't downloaded (pointer page, Download without git-lfs says so, Always
Download), a plain PNG, a moved submodule (Recorded → Checked out now, commits, Stage / Unstage, Update to
Recorded), file-row marks, Quick Look (Space)."""
import hashlib, os, struct, subprocess, sys, time, zlib
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen5 import run
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
NAME = 'powerlens'
REPO = os.path.join(SAMPLES, NAME)
LIB = os.path.join(SAMPLES, 'remotes', 'Sparkle')

def png(width, height, color, accent):
    """A small PNG: a window-like picture with a bar in `accent`."""
    rows = []
    for y in range(height):
        row = bytearray([0])
        for x in range(width):
            if y < height // 10: c = (233, 234, 238)
            elif height * 0.6 < y < height * 0.75 and width * 0.45 < x < width * 0.65: c = accent
            elif height * 0.25 < y < height * 0.45 and width * 0.1 < x < width * 0.35: c = (52, 199, 89)
            else: c = color
            row += bytes(c)
        rows.append(bytes(row))
    raw = zlib.compress(b''.join(rows), 9)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', raw) + chunk(b'IEND', b'')

def lfs_store(content):
    """Puts content where git-lfs keeps it and returns its pointer."""
    oid = hashlib.sha256(content).hexdigest()
    folder = os.path.join(REPO, '.git', 'lfs', 'objects', oid[:2], oid[2:4])
    os.makedirs(folder, exist_ok=True)
    open(os.path.join(folder, oid), 'wb').write(content)
    return pointer(oid, len(content))

def pointer(oid, size):
    return 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %d\n' % (oid, size)

def write(path, data):
    full = os.path.join(REPO, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, 'wb' if isinstance(data, bytes) else 'w').write(data)

def prepare():
    # The submodule's own repository: three releases.
    subprocess.run(['rm', '-rf', LIB], check=True)
    os.makedirs(LIB)
    run(LIB, 'init', '-q', '-b', 'main')
    for version, subject in (('2.6.4', 'Release 2.6.4'), ('2.6.5-dev', 'Add an EdDSA signature fallback for old appcasts'),
                             ('2.6.9-dev', 'Fix appcast parsing for alpha channels'), ('2.7.0', 'Bump version to 2.7.0')):
        open(os.path.join(LIB, 'VERSION'), 'w').write(version + '\n')
        run(LIB, 'add', '-A'); run(LIB, 'commit', '-q', '-m', subject)
        if '-dev' not in version: run(LIB, 'tag', version)
    # Pictures, LFS files and the submodule in powerlens.
    write('.gitattributes', 'docs/screenshots/*.png filter=lfs diff=lfs merge=lfs -text\n*.mov filter=lfs diff=lfs merge=lfs -text\n')
    before = png(240, 150, (244, 245, 248), (10, 124, 255))
    after = png(240, 150, (244, 245, 248), (124, 77, 232))
    write('docs/screenshots/onboarding.png', lfs_store(before))
    write('Assets/demo.mov', pointer('4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393', 50541312))
    write('Resources/badge.png', png(64, 64, (255, 255, 255), (255, 159, 10)))
    run(REPO, 'add', '-A'); run(REPO, 'commit', '-q', '-m', 'Add onboarding screenshot and demo video')
    run(REPO, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', LIB, 'Vendor/Sparkle')
    run(os.path.join(REPO, 'Vendor/Sparkle'), 'checkout', '-q', '2.6.4')
    # A second submodule that isn't initialized here (its clone stays in .git/modules).
    fmt = os.path.join(SAMPLES, 'remotes', 'SwiftFormat')
    subprocess.run(['rm', '-rf', fmt], check=True); os.makedirs(fmt)
    run(fmt, 'init', '-q', '-b', 'main')
    open(os.path.join(fmt, 'VERSION'), 'w').write('0.54.6\n'); run(fmt, 'add', '-A'); run(fmt, 'commit', '-q', '-m', 'Release 0.54.6')
    run(fmt, 'tag', '0.54.6')
    run(REPO, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', fmt, 'Vendor/SwiftFormat')
    run(REPO, 'add', '-A'); run(REPO, 'commit', '-q', '-m', 'Add Sparkle at 2.6.4')
    run(REPO, 'submodule', 'deinit', '-q', '-f', 'Vendor/SwiftFormat')
    # Uncommitted: the screenshot changed, the badge changed, Sparkle checked out at 2.7.0.
    write('docs/screenshots/onboarding.png', lfs_store(after))
    write('Resources/badge.png', png(64, 64, (255, 255, 255), (52, 199, 89)))
    run(os.path.join(REPO, 'Vendor/Sparkle'), 'checkout', '-q', '2.7.0')

def marks(d): return d['phase5']['marks']
def review_path(d): return (d['active']['review'] or {}).get('path')

launch_prepared(mode, prepare=prepare)
show_tab(NAME, lambda d: marks(d)['submodules'])
k('select', 'wip')
EXPECTED = ['Vendor/Sparkle | 2.6.4 → 2.7.0 · 3 new commits | moved', 'Vendor/SwiftFormat | Not initialized | notInitialized']
d = settle(lambda d: marks(d)['sidebarSubmodules'] == EXPECTED and 'docs/screenshots/onboarding.png' in marks(d)['lfs']
           and marks(d)['submodules'].get('Vendor/Sparkle') == '3 commits', label='the working copy\'s marks')
side = marks(d)['sidebarSubmodules']; print('sidebar submodules:', side)
assert side == EXPECTED, side
m = marks(d); print('working marks:', m['lfs'], '| pointers', m['pointers'], '| submodules', m['submodules'])
assert 'docs/screenshots/onboarding.png' in m['lfs'] and m['submodules'].get('Vendor/Sparkle') == '3 commits'
assert m['pointers'] == ['Assets/demo.mov'], 'only the video is really not downloaded (the screenshot is in .git/lfs/objects)'
snap('marks-panel', mode)
k('review', 'all')
d = settle(lambda d: any(f.startswith('M docs/screenshots/onboarding.png image lfs') for f in marks(d)['files'])
           and any(f.startswith('S Vendor/Sparkle submodule unstaged') for f in marks(d)['files']), label='Review › All Files')
files = marks(d)['files']; print('review files:', files)
assert any(f.startswith('M docs/screenshots/onboarding.png image lfs') for f in files)
assert any(f.startswith('M Resources/badge.png image') for f in files)
assert any(f.startswith('S Vendor/Sparkle submodule unstaged') for f in files)
snap('marks-allfiles', mode, changed=True)

# The LFS picture: Swipe (the default), 2-up, Onion Skin.
k('review', 'one', 'docs/screenshots/onboarding.png')
settle(lambda d: review_path(d) == 'docs/screenshots/onboarding.png', label='the LFS picture')
snap('marks-image-swipe', mode, changed=True)
for image_mode in ('2up', 'onion'):
    k('imageMode', image_mode); sync()
    snap('marks-image-' + image_mode, mode, changed=True)
k('imageMode', 'swipe'); sync()
k('press', 'space')
d = until(lambda d: marks(d)['quickLook'] == 'onboarding.png', label='Quick Look on the picture')
m = marks(d); print('quick look (space):', m['quickLook'], '| file', m['quickLookFile'])
assert m['quickLook'] == 'onboarding.png'
ql = subprocess.run(['find', os.path.join(os.environ.get('TMPDIR', '/tmp'), 'Kaern Quick Look'), '-name', 'onboarding.png', '-newer', os.path.join(REPO, '.gitattributes')],
                    capture_output=True, text=True).stdout.splitlines()
print('quick look copy:', ql[-1:] if ql else ql)
assert ql and open(ql[-1], 'rb').read(4) == b'\x89PNG', 'Quick Look shows the picture, not its LFS pointer'
k('press', 'space')
until(lambda d: marks(d)['quickLook'] == '', label='space again closes Quick Look')

# The plain PNG.
k('review', 'one', 'Resources/badge.png')
settle(lambda d: review_path(d) == 'Resources/badge.png', label='the plain picture')
snap('marks-image-plain', mode, changed=True)

# The submodule: Recorded 2.6.4 → Checked out 2.7.0, three new commits.
k('review', 'one', 'Vendor/Sparkle')
settle(lambda d: review_path(d) == 'Vendor/Sparkle', label='the submodule page')
snap('marks-submodule', mode, changed=True)
k('stage', 'Vendor/Sparkle')
d = settle(lambda d: any('submodule staged' in f for f in marks(d)['files'] if 'Sparkle' in f), label='the submodule change staged')
m = marks(d); print('after staging:', [f for f in m['files'] if 'Sparkle' in f])
assert any('submodule staged' in f for f in m['files'] if 'Sparkle' in f)
k('unstage', 'Vendor/Sparkle')
d = settle(lambda d: any('submodule unstaged' in f for f in marks(d)['files'] if 'Sparkle' in f), label='the submodule change unstaged')
assert any('submodule unstaged' in f for f in marks(d)['files'] if 'Sparkle' in f)

# The commit with the video: not downloaded, and Download says git-lfs isn't installed.
k('review', 'off')
k('selectSubject', 'Add onboarding screenshot and demo video')
d = settle(lambda d: marks(d)['commit'] and 'Assets/demo.mov' in marks(d)['commit']['missing'], label='the commit\'s LFS marks')
m = marks(d); print('commit marks:', m['commit'])
assert m['commit'] and 'Assets/demo.mov' in m['commit']['missing'] and 'docs/screenshots/onboarding.png' not in m['commit']['missing']
snap('marks-commit', mode, changed=True)
k('review', 'one', 'Assets/demo.mov')
settle(lambda d: review_path(d) == 'Assets/demo.mov', label='the LFS page of the video')
snap('marks-lfs-missing', mode, changed=True)
installed = subprocess.run(['which', 'git-lfs'], capture_output=True).returncode == 0
print('git-lfs installed:', installed)
if not installed:
    k('downloadLFS', 'Assets/demo.mov')
    d = settle(lambda d: 'Git LFS isn' in marks(d)['alert'], label='the alert about git-lfs')
    m = marks(d); print('download without git-lfs:', m['alert'])
    assert "Git LFS isn’t installed" in m['alert'] or "Git LFS isn't installed" in m['alert']
    k('dismiss'); sync()
k('alwaysLFS', 'on'); assert until(lambda d: marks(d)['alwaysLFS'] is True, label='Always Download on')
k('alwaysLFS', 'off'); assert until(lambda d: marks(d)['alwaysLFS'] is False, label='Always Download off')
k('review', 'off'); k('select', 'wip')
settle(lambda d: d['active']['selection'] == 'wip' and d['active']['review'] is None, label='the working copy again')
k('initSubmodule', 'Vendor/SwiftFormat')
d = settle(lambda d: 'Vendor/SwiftFormat | 0.54.6 · up to date | upToDate' in marks(d)['sidebarSubmodules'], seconds=40, label='SwiftFormat initialized')
side = marks(d)['sidebarSubmodules']; print('after Initialize:', side)
assert 'Vendor/SwiftFormat | 0.54.6 · up to date | upToDate' in side, side
snap('marks-sidebar', mode, changed=True)
print('LFS MARKS OK')
quit_app()
