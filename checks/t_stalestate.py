"""Actions go by what git has when they run, not by what the model last read.

The stash list, the branches' tips and where HEAD is come from the last refresh, which can be older than the
repository: a refresh still reading, the file watcher off, something done in Terminal a moment ago. Actions used
them to name what they act on and where ⌘Z goes back to (found 2026-11-10, the sweep after the Reset Hard fix):
- Drop, Pop, Apply and Create Branch from Stash named the stash by its number in that list (stash@{0}); a stash
  made since takes that number, so Drop deleted a different stash than the one picked.
- ⌘Z of Delete Branch made the branch again at the tip the model had read: commits made on it since were lost.
- ⌘Z of a cherry-pick (merge, revert, rebase, pull, commit) went back to the HEAD the model had read: a commit made
  in Terminal just before fell off the branch. ⌘Z of a checkout went back to the branch the model showed.
- Interactive Rebase gave git the commits it had listed when its sheet opened; git drops what a list leaves out,
  so a commit made on the branch while the sheet was open was lost.

Nothing here depends on timing: the debug driver holds the refresh that would show what changed in Terminal
(`hold status`, DebugDriver+Holds.swift). Each step starts from a fresh instance of the stash-conflict sample
(a clean working tree on feature/restore-automatic-alpha, two stashes).
"""
import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *

BRANCH = 'feature/restore-automatic-alpha'
ID = ['-c', 'user.name=Terminal', '-c', 'user.email=terminal@example.com']

def holding(d): return d['driver']['holding']
def stash_objects(): return git('stash', 'list', '--format=%H').splitlines()

class NoHolds(Exception):
    """The app under test is from before the hold commands: nothing here can run."""

def side_branch():
    """A branch `side` with one commit on top of HEAD that adds a file of its own (it cherry-picks cleanly)."""
    git('switch', '-q', '-c', 'side')
    with open(os.path.join(PL, 'SIDE.md'), 'w') as f: f.write('from the side branch\n')
    git('add', 'SIDE.md'); git(*ID, 'commit', '-q', '-m', 'a commit on the side branch')
    git('switch', '-q', BRANCH)

def begin(prepare=None):
    d = launch_prepared('light', 'stash-conflict', prepare=prepare)
    if 'holding' not in d['driver']: raise NoHolds()
    return settle(lambda d: len(d['active']['stashes']) == 2 and d['active']['branch'] == BRANCH and not d['active']['unstaged'],
                  label='the clean sample with its two stashes')

def unseen(change, what):
    """Does `change` (git, as in Terminal) with the refresh that would show it held."""
    k('hold', 'status')
    change()
    return until(lambda d: 'status' in holding(d), label='the refresh to wait with what git has after ' + what)

def let_go(check=None, what='the held refresh and the ones after it'):
    k('release')
    return settle(check, label=what)

def commit_in_terminal():
    with open(os.path.join(PL, 'TERMINAL.md'), 'w') as f: f.write('made in Terminal\n')
    git('add', 'TERMINAL.md'); git(*ID, 'commit', '-q', '-m', 'a commit made in Terminal')


# 1. Drop with a stash made since the list was read: the stash picked goes, not the one now at its number.
def drop_with_an_older_list():
    begin()
    picked = git('rev-parse', 'stash@{0}')
    def stash_in_terminal():
        with open(os.path.join(PL, 'README.md'), 'a') as f: f.write('\nwork stashed in Terminal\n')
        git(*ID, 'stash', 'push', '-q', '-m', 'made in Terminal')
    d = unseen(stash_in_terminal, 'a stash made in Terminal')
    made = git('rev-parse', 'stash@{0}')
    assert len(d['active']['stashes']) == 2 and len(stash_objects()) == 3, 'the app should still show the two stashes'
    k('drop', 0)      # the first row of the list the app shows: the stash `picked`
    d = until(lambda d: not d['active']['activity'] and (len(stash_objects()) == 2 or d['active']['alert']), label='the drop')
    left = stash_objects()
    print('   after Drop: %s' % git('stash', 'list', '--format=%gd %s').splitlines())
    assert made in left, 'the stash made in Terminal was dropped instead of the one picked'
    assert picked not in left and not d['active']['alert'], (left, d['active']['alert'])
    let_go(lambda d: len(d['active']['stashes']) == 2)
    quit_app()


# 2. Delete Branch while the branch has a commit the model hasn't read: ⌘Z makes it again with that commit.
def delete_branch_with_an_older_tip():
    begin()
    def commit_on_develop():
        new = git(*ID, 'commit-tree', 'develop^{tree}', '-p', 'develop', '-m', 'a commit on develop made in Terminal')
        git('update-ref', 'refs/heads/develop', new)
    shown = git('rev-parse', 'develop')
    unseen(commit_on_develop, 'a commit on develop')
    made = git('rev-parse', 'develop')
    assert made != shown
    k('deleteBranch', 'develop')
    until(lambda d: not d['active']['activity'] and git('rev-parse', '--verify', '-q', 'refs/heads/develop') == '', label='the delete')
    let_go(lambda d: 'develop' not in [r for r in d['phase6'].get('subjects', [])] or True)
    k('undo')
    d = settle(lambda d: not d['active']['activity'] and ('Undid' in toast(d) or d['active']['alert']), label='⌘Z')
    now = git('rev-parse', '--verify', '-q', 'refs/heads/develop')
    print('   ⌘Z: develop at %s (made in Terminal: %s, the tip the app had read: %s)' % (now[:7], made[:7], shown[:7]))
    assert now == made, '⌘Z should make develop again at %s, with the commit made in Terminal; it is at %s' % (made[:7], now[:7])
    quit_app()


# 3. Cherry-pick right after a commit made in Terminal: ⌘Z goes back to that commit, not to the HEAD shown.
def cherry_pick_with_an_older_head():
    begin(prepare=side_branch)
    side = git('rev-parse', 'side')
    shown = git('rev-parse', 'HEAD')
    d = unseen(commit_in_terminal, 'the commit')
    made = git('rev-parse', 'HEAD')
    assert d['active']['head'] == shown[:7] and made != shown
    k('cherryPick', side)
    until(lambda d: not d['active']['activity'] and git('rev-parse', 'HEAD') not in (shown, made), label='the cherry-pick')
    let_go()
    k('undo')
    d = settle(lambda d: not d['active']['activity'] and ('Undid' in toast(d) or d['active']['alert']), label='⌘Z')
    now = git('rev-parse', 'HEAD')
    print('   ⌘Z: HEAD at %s (made in Terminal: %s, the HEAD the app had read: %s)' % (now[:7], made[:7], shown[:7]))
    assert now == made and os.path.exists(os.path.join(PL, 'TERMINAL.md')), \
        '⌘Z should go back to the commit made in Terminal (%s), not to %s: HEAD is %s' % (made[:7], shown[:7], now[:7])
    quit_app()


# 4. Checkout right after switching branches in Terminal: ⌘Z goes back to where HEAD really was.
def checkout_with_an_older_branch():
    begin()
    d = unseen(lambda: git('switch', '-q', 'develop'), 'the switch')
    assert d['active']['branch'] == BRANCH
    k('checkout', 'main')
    until(lambda d: not d['active']['activity'] and git('rev-parse', '--abbrev-ref', 'HEAD') == 'main', label='the checkout')
    let_go()
    k('undo')
    d = settle(lambda d: not d['active']['activity'] and ('Undid' in toast(d) or d['active']['alert']), label='⌘Z')
    now = git('rev-parse', '--abbrev-ref', 'HEAD')
    print('   ⌘Z: on %s (switched to in Terminal: develop, the branch the app showed: %s)' % (now, BRANCH))
    assert now == 'develop', '⌘Z should go back to develop, where HEAD was; it went to %s' % now
    quit_app()


# 5. Interactive Rebase while a commit is made in Terminal: nothing is rebased, the commit stays.
def interactive_rebase_with_an_older_list():
    begin()
    subject = git('log', '-1', '--format=%s', 'HEAD~2')
    subjects = full_dump()['phase6']['subjects']
    assert subjects.count(subject) == 1, 'HEAD~2 should be one row: %r' % subject
    k('sheet', 'ir', subjects.index(subject))
    d = until(lambda d: (d['active']['phase4'].get('rebase') or {}).get('loading') is False, label='the rebase sheet with its commits')
    print('   the sheet lists: %s' % d['active']['phase4']['rebase']['steps'])
    shown = git('rev-parse', 'HEAD')
    commit_in_terminal()
    made = git('rev-parse', 'HEAD')
    k('irStart')
    d = until(lambda d: not d['active']['activity'] and (d['active']['alert'] or git('rev-parse', 'HEAD') != made), label='the rebase to be refused')
    print('   alert: %r' % d['active']['alert'][:120])
    now = git('rev-parse', 'HEAD')
    assert now == made and os.path.exists(os.path.join(PL, 'TERMINAL.md')), \
        'the commit made in Terminal while the sheet was open was dropped: HEAD %s (it was %s, and %s before)' % (now[:7], made[:7], shown[:7])
    assert d['active']['alert'] and git('status', '--porcelain') == '', (d['active']['alert'], git('status', '--porcelain'))
    settle(lambda d: d['active']['head'] == made[:7], label='the refresh')
    quit_app()


steps = [
    ('1. Drop with a stash made since the list was read', drop_with_an_older_list),
    ('2. Delete Branch with a commit on it the app hasn\'t read', delete_branch_with_an_older_tip),
    ('3. Cherry-pick right after a commit made in Terminal', cherry_pick_with_an_older_head),
    ('4. Checkout right after switching branches in Terminal', checkout_with_an_older_branch),
    ('5. Interactive Rebase while a commit is made in Terminal', interactive_rebase_with_an_older_list),
]
failed = []
for name, run in steps:
    print('--', name)
    try:
        run()
    except NoHolds:
        kill_app()
        raise SystemExit('STALESTATE: this build of the app has no hold commands (Kaern/App/DebugDriver+Holds.swift)')
    except (AssertionError, SystemExit) as problem:
        failed.append(name)
        print('   FAILED:', problem)
kill_app()
if failed:
    raise SystemExit('STALESTATE FAILED: %d of %d steps\n   %s' % (len(failed), len(steps), '\n   '.join(failed)))
print('STALESTATE OK')
