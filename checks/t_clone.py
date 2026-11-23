"""t_clone.py [light|dark] — File › Clone Repository (a local sample over file://, never the network), the
existing-folder problem, Create New Repository (kaern site → kaern-site, Node .gitignore, MIT, first commit,
publish banner), and a plain folder tab that offers Create Repository Here (Node detected, node_modules left out)."""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
MADE = os.path.join(SAMPLES, 'made')
SITE = os.path.join(SAMPLES, 'astro-site')
def sheet(d): return d['phase5']['sheet']

def prepare():
    subprocess.run(['rm', '-rf', MADE, SITE], check=True)
    os.makedirs(MADE)
    os.makedirs(os.path.join(SITE, 'src', 'pages'))
    os.makedirs(os.path.join(SITE, 'node_modules', 'astro'))
    open(os.path.join(SITE, 'package.json'), 'w').write('{"name":"astro-site","dependencies":{"astro":"^5.0.0"}}\n')
    open(os.path.join(SITE, 'src', 'pages', 'index.astro'), 'w').write('<h1>Hi</h1>\n')
    open(os.path.join(SITE, 'node_modules', 'astro', 'index.js'), 'w').write('// generated\n')

launch_prepared(mode, prepare=prepare, extra=['-KaernProjectsFolder', MADE])
show_tab('powerlens')

# Clone: a local sample over file://.
source = 'file://' + os.path.join(SAMPLES, 'powerlens')
copy = os.path.join(MADE, 'powerlens-copy')
k('clone', source)
k('cloneField', 'dest', copy)
s = sheet(until(lambda d: sheet(d)['kind'] == 'clone' and sheet(d)['destination'] == copy and not sheet(d)['problem'], label='the clone sheet'))
print('clone sheet:', s['url'], '→', s['destination'], '| problem:', s['problem'] or '-')
snap('clone-sheet', mode)
k('cloneStart')
d = settle(lambda d: os.path.exists(os.path.join(copy, '.git')) and sheet(d) is None and active_name(d) == 'powerlens-copy'
           and d['phase5']['phase'] == 'ready', seconds=40, label='the clone, open in a tab')
print('after clone: tabs', tabs(d)[-2:], '| active', active_name(d))
assert active_name(d) == 'powerlens-copy'
print('activity:', d['phase5']['recentActivity'][:1])
# Cloning into a folder that has files is refused before git runs.
k('clone', source)
k('cloneField', 'dest', copy)
s = sheet(until(lambda d: sheet(d)['kind'] == 'clone' and sheet(d)['problem'], label='the problem with the destination'))
print('existing destination:', s['problem']); assert s['problem']
snap('clone-problem', mode)
k('windowSheetClose')
until(lambda d: sheet(d) is None, label='the clone sheet closed')

# Create New Repository: a new folder with .gitignore, LICENSE, README and a first commit.
k('create')
k('createField', 'name', 'kaern site')
k('createField', 'location', MADE)
k('createField', 'ignore', 'Node'); k('createField', 'license', 'MIT')
s = sheet(settle(lambda d: sheet(d)['kind'] == 'create' and sheet(d)['name'] == 'kaern site' and sheet(d)['ignore'] == 'Node'
                 and sheet(d)['license'] == 'MIT' and sheet(d)['canCreate'], label='the create sheet filled in'))
print('create sheet:', s['name'], '|', s['nameNote'], '|', s['ignoreNote'], '|', s['firstNote'])
snap('create-sheet', mode)
k('createStart')
created = os.path.join(MADE, 'kaern-site')
d = settle(lambda d: sheet(d) is None and d['phase5']['createdNote'] and d['phase5']['phase'] == 'ready', seconds=30, label='the new repository')
x = d['phase5']; print('created note:', x['createdNote'], '| banner:', x['publishBanner'])
assert sorted(os.listdir(created)) == ['.git', '.gitignore', 'LICENSE', 'README.md'], os.listdir(created)
assert x['createdNote'] == 'Created kaern-site · 1 commit · 3 files'
snap('create-done', mode)

# A plain folder opens as a tab that offers Create Repository Here.
k('open', SITE)
d = settle(lambda d: active_name(d) == 'astro-site' and d['phase5']['phase'] == 'notRepository' and d['phase5']['survey'], label='the plain folder tab')
x = d['phase5']; print('plain folder:', x['phase'], x['survey'])
assert x['phase'] == 'notRepository' and x['survey']['template'] == 'Node' and x['survey']['generated'][:1] == ['node_modules/ 1']
snap('notrepo', mode)
k('create', SITE)
# The sheet looked at the folder: Node's .gitignore is chosen.
until(lambda d: sheet(d)['kind'] == 'create' and sheet(d)['ignore'] == 'Node' and sheet(d)['canCreate'], label='the create-here sheet')
k('createStart')
settle(lambda d: d['phase5']['phase'] == 'ready' and sheet(d) is None, seconds=30, label='the repository made in the folder')
tracked = g(SITE, 'ls-files').split('\n'); print('tracked in astro-site:', tracked)
assert '.gitignore' in tracked and not any(t.startswith('node_modules/') for t in tracked)
print('CLONE OK')
quit_app()
