"""Reset Hard goes by what git finds, not by the status the model shows.

Reset Hard puts the uncommitted changes aside first ("Before reset to …" in Stashes) and ⌘Z brings everything back.
It used to decide whether there was anything to put aside from the model's status, which can be older than the
working tree: a refresh still reading (seconds on a big repository), the file watcher switched off in Settings, a
file saved a moment ago. An edit that status didn't list was thrown away with no copy, and ⌘Z couldn't bring it
back (found 2026-11-10). The branch it resets and the commit ⌘Z goes back to came from that status too.

Nothing here depends on timing: the debug driver holds the refresh that would show what changed (`hold status`,
DebugDriver+Holds.swift), so the model still shows the older status when Reset is confirmed. Each step starts
from a fresh instance of the stash-conflict sample (a clean working tree on feature/restore-automatic-alpha).
"""
import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *

PARAGRAPH = 'A paragraph written a moment before Reset Hard.'
README = os.path.join(PL, 'README.md')

def holding(d): return d['driver']['holding']
def stash_list(): return git('stash', 'list', '--format=%s').splitlines()
def readme():
    with open(README) as f: return f.read()

class NoHolds(Exception):
    """The app under test is from before the hold commands: nothing here can run."""

def begin(prepare=None, unstaged=()):
    """A fresh instance on the sample (after prepare()), once it shows `unstaged` as the only changes."""
    d = launch_prepared('light', 'stash-conflict', prepare=prepare)
    if 'holding' not in d['driver']: raise NoHolds()
    return settle(lambda d: len(d['active']['stashes']) == 2 and sorted(d['active']['unstaged']) == sorted(unstaged) and not d['active']['staged'],
                  label='the sample with its two stashes')

def unseen(change, what):
    """Makes `change` with the refresh that would show it held: the model keeps the status from before."""
    k('hold', 'status')
    change()
    return until(lambda d: 'status' in holding(d), label='the refresh to wait with the status after ' + what)

def reset_hard(target):
    """Reset Hard to `target` as the menu does: the question, then Reset."""
    k('reset', target, 'hard')
    until(lambda d: d['active']['confirmation'], label='the question before Reset Hard')
    k('confirm')


# 1. An edit the status doesn't list yet goes to Stashes first, and ⌘Z brings it back.
def an_edit_not_shown_yet():
    begin()
    head, target, before = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD~1'), readme()
    def edit():
        with open(README, 'a') as f: f.write('\n' + PARAGRAPH + '\n')
    d = unseen(edit, 'the edit')
    assert d['active']['unstaged'] == [] and git('status', '--porcelain') == 'M README.md', \
        'the app should still show the clean tree while git sees the edit: %s / %r' % (d['active']['unstaged'], git('status', '--porcelain'))
    reset_hard(target)
    d = until(lambda d: git('rev-parse', 'HEAD') == target and not d['active']['activity'] and toast(d), label='the reset')
    said = toast(d)
    k('release')
    d = settle(lambda d: len(d['active']['stashes']) >= 2, label='the refreshes after the reset')
    print('   reset: toast %r | stashes %s' % (said, stash_list()))
    assert stash_list()[0].endswith('Before reset to ' + target[:7]) and len(stash_list()) == 3, \
        'the edit should be in Stashes first, as "Before reset to %s": %s' % (target[:7], stash_list())
    assert PARAGRAPH in git('stash', 'show', '-p', 'stash@{0}') and PARAGRAPH not in readme()
    assert 'stashed first' in said, said
    k('undo')
    d = settle(lambda d: git('rev-parse', 'HEAD') == head and 'Undid' in toast(d), label='⌘Z')
    assert readme() == before + '\n' + PARAGRAPH + '\n', 'the edit should be back after ⌘Z'
    assert len(stash_list()) == 2 and d['active']['unstaged'] == ['README.md'], (stash_list(), d['active']['unstaged'])
    print('   ⌘Z: the edit is back in README.md, its stash is gone')
    quit_app()


# 2. A commit made in Terminal that the status doesn't show yet: ⌘Z goes back to it, not to the HEAD shown.
def a_commit_not_shown_yet():
    begin()
    shown, target = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD~1')
    def commit():
        with open(os.path.join(PL, 'TERMINAL.md'), 'w') as f: f.write('made in Terminal\n')
        git('add', 'TERMINAL.md')
        git('-c', 'user.name=Terminal', '-c', 'user.email=terminal@example.com', 'commit', '-q', '-m', 'a commit made in Terminal')
    d = unseen(commit, 'the commit')
    made = git('rev-parse', 'HEAD')
    assert made != shown and d['active']['head'] == shown[:7], 'the app should still show HEAD at %s: %s' % (shown[:7], d['active']['head'])
    reset_hard(target)
    d = until(lambda d: git('rev-parse', 'HEAD') == target and not d['active']['activity'], label='the reset')
    k('release')
    settle(lambda d: d['active']['head'] == target[:7], label='the refreshes after the reset')
    k('undo')
    d = settle(lambda d: not d['active']['activity'] and ('Undid' in toast(d) or d['active']['alert']), label='⌘Z')
    now = git('rev-parse', 'HEAD')
    print('   ⌘Z: HEAD at %s (the commit made in Terminal: %s, the HEAD shown before: %s)' % (now[:7], made[:7], shown[:7]))
    assert now == made and os.path.exists(os.path.join(PL, 'TERMINAL.md')), \
        '⌘Z should go back to the commit made in Terminal (%s), not to the HEAD the app showed (%s): HEAD is %s' % (made[:7], shown[:7], now[:7])
    quit_app()


# 3. A branch switched in Terminal that the status doesn't show yet: nothing is reset (the question named the
#    other branch), and the branch checked out now keeps its commits.
def a_switch_not_shown_yet():
    d = begin()
    asked, develop, target = d['active']['branch'], git('rev-parse', 'develop'), git('rev-parse', 'HEAD~1')
    d = unseen(lambda: git('switch', '-q', 'develop'), 'the switch')
    assert d['active']['branch'] == asked and git('rev-parse', '--abbrev-ref', 'HEAD') == 'develop'
    reset_hard(target)
    d = until(lambda d: not d['active']['activity'] and (d['active']['alert'] or git('rev-parse', 'develop') != develop),
              label='the reset to be refused')
    print('   alert: %r' % d['active']['alert'][:110])
    assert git('rev-parse', 'develop') == develop, \
        'develop was reset to %s: the question was about %s' % (git('rev-parse', 'develop')[:7], asked)
    assert git('rev-parse', asked) != target and len(stash_list()) == 2 and d['active']['alert'], (stash_list(), d['active']['alert'])
    k('release')
    settle(lambda d: d['active']['branch'] == 'develop', label='the refresh to show develop')
    quit_app()


# 4. A tag with the branch's name: git then shortens the branch to "heads/<name>", while the status (and the
#    question) call it <name>. Reset Hard must still reset it, and ⌘Z take it back.
def a_tag_with_the_branchs_name():
    d = begin()
    branch, head, target = d['active']['branch'], git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD~1')
    git('tag', branch)
    settle(lambda d: d['active']['branch'] == branch, label='the tag')
    reset_hard(target)
    d = until(lambda d: not d['active']['activity'] and (git('rev-parse', 'HEAD') == target or d['active']['alert']), label='the reset')
    print('   reset: HEAD %s | alert %r' % (git('rev-parse', 'HEAD')[:7], d['active']['alert'][:90]))
    assert git('rev-parse', 'HEAD') == target and not d['active']['alert'], 'Reset Hard should reset %s: %r' % (branch, d['active']['alert'])
    settle(lambda d: d['active']['head'] == target[:7], label='the refresh after the reset')
    k('undo')
    d = settle(lambda d: not d['active']['activity'] and ('Undid' in toast(d) or d['active']['alert']), label='⌘Z')
    print('   ⌘Z: HEAD %s | alert %r' % (git('rev-parse', 'HEAD')[:7], d['active']['alert'][:90]))
    assert git('rev-parse', 'HEAD') == head and not d['active']['alert'], '⌘Z should take the reset back: %r' % d['active']['alert']
    quit_app()


# 5. Files git doesn't track where the target commit has files. git writes over them without a word (an ignored
#    .env too) and the stash of changes didn't hold them. They go into the same stash first now, and ⌘Z brings
#    them back. Other untracked and ignored files stay where they are, as git leaves them.
SECRET, NOTES = 'TOKEN=my real secret\n', 'my own notes, never committed\n'
def untracked_files_in_the_way():
    def prepare():
        def write(name, text):
            with open(os.path.join(PL, name), 'w') as f: f.write(text)
        ID = ['-c', 'user.name=Terminal', '-c', 'user.email=terminal@example.com']
        # A commit that tracked .env and NOTES.md, and the next one that stops tracking .env (and ignores
        # it) and deletes NOTES.md. Then both are written again by hand, and a file nobody tracks sits next to them.
        write('.env', 'TOKEN=committed by mistake\n'); write('NOTES.md', 'notes that were committed\n')
        git('add', '-f', '.env', 'NOTES.md'); git(*ID, 'commit', '-q', '-m', 'add .env and notes')
        git('rm', '-q', '--cached', '.env'); git('rm', '-q', 'NOTES.md')
        with open(os.path.join(PL, '.gitignore'), 'a') as f: f.write('\n.env\n')
        git('add', '.gitignore'); git(*ID, 'commit', '-q', '-m', 'stop tracking .env, remove the notes')
        write('.env', SECRET); write('NOTES.md', NOTES); write('scratch.txt', 'not in the way\n')
    begin(prepare, unstaged=('NOTES.md', 'scratch.txt'))     # .env is ignored now: not a change
    head, target = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD~1')
    reset_hard(target)
    d = until(lambda d: git('rev-parse', 'HEAD') == target and not d['active']['activity'] and toast(d), label='the reset')
    said = toast(d)
    def read(name):
        with open(os.path.join(PL, name)) as f: return f.read()
    print('   reset: toast %r | .env %r | NOTES.md %r | stashes %s' % (said, read('.env'), read('NOTES.md'), stash_list()[:1]))
    assert len(stash_list()) == 3 and stash_list()[0].endswith('Before reset to ' + target[:7]), \
        '.env and NOTES.md should be in Stashes first: %s' % stash_list()
    shown = git('stash', 'show', '--include-untracked', '--name-only', 'stash@{0}').splitlines()
    assert {'.env', 'NOTES.md'} <= set(shown) and 'scratch.txt' not in shown, shown
    assert read('scratch.txt') == 'not in the way\n', 'a file not in the way should stay'
    settle(lambda d: d['active']['head'] == target[:7], label='the refresh after the reset')
    k('undo')
    d = settle(lambda d: not d['active']['activity'] and ('Undid' in toast(d) or d['active']['alert']), label='⌘Z')
    print('   ⌘Z: HEAD %s | .env %r | NOTES.md %r | alert %r' % (git('rev-parse', 'HEAD')[:7], read('.env'), read('NOTES.md'), d['active']['alert'][:80]))
    assert git('rev-parse', 'HEAD') == head and read('.env') == SECRET and read('NOTES.md') == NOTES, \
        '⌘Z should bring back the files Reset Hard wrote over'
    assert len(stash_list()) == 2 and not d['active']['alert'], (stash_list(), d['active']['alert'])
    quit_app()


steps = [
    ('1. an edit the status doesn\'t list yet', an_edit_not_shown_yet),
    ('2. a commit made in Terminal the status doesn\'t show yet', a_commit_not_shown_yet),
    ('3. a branch switched in Terminal the status doesn\'t show yet', a_switch_not_shown_yet),
    ('4. a tag with the branch\'s name', a_tag_with_the_branchs_name),
    ('5. untracked and ignored files where the target has files', untracked_files_in_the_way),
]
failed = []
for name, run in steps:
    print('--', name)
    try:
        run()
    except NoHolds:
        kill_app()
        raise SystemExit('RESETHARD: this build of the app has no hold commands (Kaern/App/DebugDriver+Holds.swift)')
    except (AssertionError, SystemExit) as problem:
        failed.append(name)
        print('   FAILED:', problem)
kill_app()
if failed:
    raise SystemExit('RESETHARD FAILED: %d of %d steps\n   %s' % (len(failed), len(steps), '\n   '.join(failed)))
print('RESETHARD OK')
