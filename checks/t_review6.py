"""t_review6.py — the fixes after the phase-6 review, in the app:
1. Remove… names the files git ignores in a worktree; they go to the Trash; ⌘Z brings the worktree, its changes and them back.
2. ⌘Z of Add Worktree… refuses once the new worktree has work of its own.
3. ⌘Z of Ignore refuses after .gitignore was edited.
4. Trust This Key… writes through a linked allowed signers file (the link stays a link); ⌘Z refuses after the file changed.
5. A linked worktree's tab can't remove the main working tree.
6. Pull (rebase) stopped while git runs: the uncommitted changes come back, staged parts staged; nothing in Stashes."""
import os, shutil, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen6 import pull_behind, SIGNED_UNTRUSTED, KEYS, run

REPO = os.path.join(SAMPLES, 'powerlens')
HOTFIX = os.path.join(SAMPLES, 'powerlens-hotfix')
ALLOWED = os.path.join(KEYS, 'allowed_signers')
DOTFILE = os.path.join(KEYS, 'dotfiles', 'allowed_signers')


def p6(d): return d['phase6']


def alert(d):
    return d['active'].get('alert', '')


def prepare():
    # On the signed history (samples.py's kind "signed", copied here).
    with open(os.path.join(REPO, '.git', 'info', 'exclude'), 'a') as f:
        f.write('local.env\nbuild/\n')
    open(os.path.join(HOTFIX, 'local.env'), 'w').write('SECRET=1\n')
    os.makedirs(os.path.join(HOTFIX, 'build'), exist_ok=True)
    open(os.path.join(HOTFIX, 'build', 'out.bin'), 'w').write('artifact\n')
    os.makedirs(os.path.dirname(DOTFILE), exist_ok=True)
    shutil.move(ALLOWED, DOTFILE)
    os.symlink(DOTFILE, ALLOWED)


launch_prepared('light', scenario='signed', prepare=prepare)
show_tab('powerlens', lambda d: len(p6(d)['signatures']) >= 20, seconds=40)

# 1. Remove… with ignored files.
k('worktree', 'powerlens-hotfix')
settle(lambda d: p6(d)['worktreeDetails'] and len(p6(d)['worktreeDetails']['files']) == 2, label='worktree page')
k('worktreeAction', 'remove')
d = until(lambda d: p6(d)['confirmation'].startswith('Remove the worktree powerlens-hotfix'), label='question')
print('1. question:', p6(d)['confirmation'].replace('\n', ' ')[:260])
assert 'Files git ignores there (' in p6(d)['confirmation'] and 'go to the Trash' in p6(d)['confirmation']
k('confirm')
d = settle(lambda d: not os.path.exists(HOTFIX) and p6(d)['toast'].startswith('Removed'), seconds=40, label='removed')
print('   removed:', p6(d)['toast'])
assert 'ignored files are in the Trash' in p6(d)['toast']
k('undo')
d = settle(lambda d: os.path.exists(os.path.join(HOTFIX, 'local.env')) and any('powerlens-hotfix | hotfix/0.9.3.1 | 2' in w for w in p6(d)['worktrees']),
           seconds=40, label='back')
status = run(HOTFIX, 'status', '--short')
print('   ⌘Z: local.env %r, build/out.bin %s, changes %s' % (open(os.path.join(HOTFIX, 'local.env')).read(),
      os.path.exists(os.path.join(HOTFIX, 'build', 'out.bin')), status.split('\n')))
assert open(os.path.join(HOTFIX, 'local.env')).read() == 'SECRET=1\n' and os.path.exists(os.path.join(HOTFIX, 'build', 'out.bin'))
assert len([line for line in status.split('\n') if line.strip()]) == 2 and alert(d) == ''

# 2. ⌘Z of Add Worktree… refuses once the worktree has work of its own.
folder = os.path.join(SAMPLES, 'powerlens-charge')
k('addWorktree', 'feature/charge-limit-awareness', folder)
settle(lambda d: any(w.startswith('powerlens-charge |') for w in p6(d)['worktrees']), seconds=40, label='added')
open(os.path.join(folder, 'notes.txt'), 'w').write('work in progress\n')
# (The sidebar doesn't count a file written in another worktree until something refreshes; ⌘Z looks itself.)
k('undo')
d = settle(lambda d: alert(d) != '', label='refusal')
print('2. ⌘Z after work there:', alert(d)[:160])
assert os.path.exists(os.path.join(folder, 'notes.txt')) and 'Use Remove… instead' in alert(d)
k('dismiss'); sync()

# 3. ⌘Z of Ignore refuses after .gitignore was edited.
ignore_file = os.path.join(REPO, '.gitignore')
k('ignore', 'scratch-notes/')
settle(lambda d: 'scratch-notes/' in p6(d)['gitignore'] and p6(d)['undo'][-1:] != [] and 'gnore' in p6(d)['undo'][-1], label='ignored')
with open(ignore_file, 'a') as f:
    f.write('.idea/\n')
settle(lambda d: '.idea/' in p6(d)['gitignore'], label='the edit to .gitignore')
k('undo')
d = settle(lambda d: '.gitignore changed since' in alert(d), label='the refusal to undo Ignore')
text = open(ignore_file).read()
print('3. ⌘Z after an edit:', alert(d)[:120], '| .gitignore keeps both:', 'scratch-notes/' in text and '.idea/' in text)
assert '.gitignore changed since' in alert(d) and 'scratch-notes/' in text and '.idea/' in text

# 4. Trust This Key… through a link.
k('selectSubject', SIGNED_UNTRUSTED)
settle(lambda d: p6(d)['selectedSignature'].startswith('unverified'), label='card')
before = open(DOTFILE).read()
k('trustKey')
until(lambda d: p6(d)['confirmation'].startswith('Trust Minji Park'), label='trust question')
k('confirm')
settle(lambda d: p6(d)['selectedSignature'].startswith('verified'), label='trusted')
print('4. link still a link:', os.path.islink(ALLOWED), '| key added to the target:', open(DOTFILE).read() != before)
assert os.path.islink(ALLOWED) and open(DOTFILE).read().startswith(before) and open(DOTFILE).read() != before
with open(DOTFILE, 'a') as f:
    f.write('# added by hand\n')
k('undo')
d = settle(lambda d: 'changed since “Trust Key”' in alert(d), label='the refusal to undo Trust Key')
print('   ⌘Z after an edit:', alert(d)[:120])
assert 'changed since “Trust Key”' in alert(d) and open(DOTFILE).read().endswith('# added by hand\n')

# 5. From the hotfix worktree's tab, the main working tree can't be removed.
k('worktree', 'powerlens-hotfix')
settle(lambda d: p6(d)['selectedWorktree'] == 'powerlens-hotfix' and p6(d)['worktreeDetails'], label='the hotfix page')
k('worktreeAction', 'open')
d = settle(lambda d: d['active'].get('name') == 'powerlens-hotfix' and d['phase5']['phase'] == 'ready', label='hotfix tab')
k('worktree', 'powerlens')
settle(lambda d: p6(d)['selectedWorktree'] == 'powerlens', label='the main tree\'s page in the hotfix tab')
k('worktreeAction', 'remove'); sync()
d = settle(label='nothing after Remove… on the main tree')
print('5. main tree from the linked tab: question', repr(p6(d)['confirmation'][:60]), '| folder still there:', os.path.exists(REPO))
assert p6(d)['confirmation'] == '' and os.path.exists(os.path.join(REPO, '.git'))
quit_app()

# 6. Pull (rebase) stopped while git runs (a pre-rebase hook that sleeps).
def prepare_pull():
    pull_behind('powerlens')
    hook = os.path.join(REPO, '.git', 'hooks', 'pre-rebase')
    open(hook, 'w').write('#!/bin/sh\nsleep 30\n')
    os.chmod(hook, 0o755)

launch_prepared('light', prepare=prepare_pull)
show_tab('powerlens')
staged_before = run(REPO, 'diff', '--cached', '--name-only')
unstaged_before = run(REPO, 'diff', '--name-only')
k('pullWith', 'rebase')
# The pull is in the hook: git stashed the changes and the pull command is still running.
until(lambda d: any('pull' in c for c in d['driver']['running']) and os.path.exists(os.path.join(REPO, '.git', 'refs', 'stash')),
      label='the pull waiting in its hook')
d = maybe(lambda d: [s for s in p6(d)['stashes'] if 'Before Pull' in s], seconds=3) or full_dump()
print('6. during the pull, Stashes:', [s for s in p6(d)['stashes'] if 'Before Pull' in s])
k('cancelActivity')
d = settle(lambda d: p6(d)['activity'] == '', label='stopped')
x = p6(d)
staged_after = run(REPO, 'diff', '--cached', '--name-only')
unstaged_after = run(REPO, 'diff', '--name-only')
print('   after Cancel: stashes', [s for s in x['stashes'] if 'Before Pull' in s], '| alert', repr(alert(d)[:80]),
      '| staged same', staged_after == staged_before, '| unstaged same', unstaged_after == unstaged_before,
      '| rebase in progress', os.path.exists(os.path.join(REPO, '.git', 'rebase-merge')))
assert not [s for s in x['stashes'] if 'Before Pull' in s]
assert staged_after == staged_before and unstaged_after == unstaged_before
quit_app()
print('REVIEW6 OK')
