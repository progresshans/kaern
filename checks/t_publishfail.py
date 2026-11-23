"""t_publishfail.py [light|dark] — Create New Repository with Publish to GitHub on, where publishing fails.
(1) Before anything is made on GitHub (the account's token can't be read): the repository opens and Publish
    comes up saying so, with Not Now / Try Again; Not Now leaves the repository and its banner.
(2) origin is another repository: Publish refuses before it asks GitHub for anything.
(3) Made on GitHub, the push failed (origin is that repository already): the sheet says only the push is
    left, and Try Again pushes without asking GitHub for the repository again.
Never the network: the run's git config rewrites https://github.com/ to a folder of bare repositories."""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
MADE = os.path.join(SAMPLES, 'made')
HUB = os.path.join(RUN_DIR, 'hub')
REPO = os.path.join(MADE, 'notes-app')
BARE = os.path.join(HUB, 'sample-user', 'notes-app.git')
def sheet(d): return d['phase5']['sheet']
def publish(d): return sheet(d) if sheet(d) and sheet(d)['kind'] == 'publish' else None

def prepare():
    subprocess.run(['rm', '-rf', MADE, HUB], check=True)
    os.makedirs(MADE); os.makedirs(HUB)
    with open(GITCONFIG, 'a') as f: f.write('[url "file://%s/"]\n\tinsteadOf = https://github.com/\n' % HUB)

launch_prepared(mode, prepare=prepare, extra=['-KaernProjectsFolder', MADE])
show_tab('powerlens')
k('fakeAccount', 'sample-user', 'github.com', 'Sample', 'User')

# (1) Create with publishing on; the token can't be read, so nothing is asked of GitHub.
k('create')
k('createField', 'name', 'notes app'); k('createField', 'location', MADE)
k('createField', 'publish', 'on'); k('createField', 'private', 'on')
settle(lambda d: sheet(d)['kind'] == 'create' and sheet(d)['name'] == 'notes app' and sheet(d)['canCreate'], label='the create sheet filled in')
k('createStart')
d = settle(lambda d: publish(d) and publish(d)['error'] and d['phase5']['phase'] == 'ready', seconds=40, label='Publish coming up after the failure')
s = publish(d); x = d['phase5']
print('(1) sheet:', s, '\n    tab:', active_name(d), '| note:', x['createdNote'], '| banner:', x['publishBanner'], '| remotes:', x['remotes'])
assert active_name(d) == 'notes-app' and s['followsCreate'] and s['made'] == '' and 'token' in s['error'], s
assert x['createdNote'].startswith('Created notes-app') and x['publishBanner'] and x['remotes'] == []
assert sorted(os.listdir(REPO)) == ['.git', 'README.md'] or '.git' in os.listdir(REPO)
snap('publishfail-created', mode)
k('windowSheetClose')
d = until(lambda d: sheet(d) is None, label='Not Now closing the sheet')
assert d['phase5']['publishBanner'] and os.path.isdir(os.path.join(REPO, '.git'))
print('    Not Now: the repository stays, banner', d['phase5']['publishBanner'])

# (2) Another origin: refused before GitHub hears of it.
g(REPO, 'remote', 'add', 'origin', 'https://github.com/someone-else/other.git')
settle(lambda d: d['phase5']['remotes'] == ['origin'], label='origin in the app')
k('publishSheet'); until(lambda d: publish(d), label='the Publish sheet')
k('publishStart')
s = publish(until(lambda d: publish(d) and publish(d)['error'] and not publish(d)['running'], label='the refusal'))
print('(2) other origin:', s['error']); assert 'already a remote named origin' in s['error'] and s['made'] == '', s
k('windowSheetClose'); until(lambda d: sheet(d) is None, label='the sheet closed')

# (3) What a first try leaves when its push fails: the repository on GitHub and origin pointing at it.
g(REPO, 'remote', 'set-url', 'origin', 'https://github.com/sample-user/notes-app.git')
k('publishSheet'); until(lambda d: publish(d), label='the Publish sheet')
k('publishStart')
s = publish(until(lambda d: publish(d) and publish(d)['error'] and not publish(d)['running'], label='the push failing'))
print('(3) push failed:', s['made'], '|', s['error'].split('\n')[0]); assert s['made'] == 'sample-user/notes-app', s
snap('publishfail-push', mode)
subprocess.run([GIT, 'init', '--bare', '-q', BARE], check=True, env=ENV)
k('publishStart')
d = settle(lambda d: sheet(d) is None and not d['phase5']['publishBanner'], seconds=30, label='Try Again pushing')
upstream = g(REPO, 'rev-parse', '--abbrev-ref', '@{u}'); there = subprocess.run([GIT, '-C', BARE, 'rev-parse', 'main'], capture_output=True, text=True, env=ENV).stdout.strip()
print('    Try Again: upstream', upstream, '| pushed', there[:7], '| toast:', toast(d))
assert upstream == 'origin/main' and there == g(REPO, 'rev-parse', 'HEAD')
print('PUBLISHFAIL OK')
quit_app()
