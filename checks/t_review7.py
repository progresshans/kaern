"""t_review7.py — the fixes after the review of the stale-status branch (2026-11-10), in the app:
1. Reset Hard with a git repository of its own in the way (a clone kept in the folder, where the target has
   a file): nothing changes, and the alert names it. git would delete it, and git stash can't hold it.
2. A cherry-pick that stops on a conflict, then Skip of its only commit: the uncommitted changes Kaern put
   aside before it come back (they used to stay in Stashes without a word).
3. The same, resolved and continued, when those changes touch the lines the pick changed: they stay in
   Stashes and the file has no conflict markers (the pop used to write them, with no conflict bar).
4. A hidden tab's light refresh doesn't land in the tab once it's shown (it replaced the full status with
   the folded one: `drafts/` instead of its two files, until something changed).
KAERN_STEPS=2,4 runs some of the steps (each starts its own instance)."""
import os, sys, time; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen6 import run

README = os.path.join(PL, 'README.md')


def p4(d): return d['active']['phase4']
def alert(d): return d['active'].get('alert', '')
def stash_subjects(): return git('stash', 'list', '--format=%gs').splitlines()
def kept(): return [s for s in stash_subjects() if 'Before Cherry-pick' in s]


def prepare_nested():
    """HEAD~1 has vendor/lib.txt, HEAD dropped it, and vendor/ is now a repository of its own with work in it."""
    vendor = os.path.join(PL, 'vendor')
    os.makedirs(vendor)
    with open(os.path.join(vendor, 'lib.txt'), 'w') as f: f.write('vendored\n')
    run(PL, 'add', 'vendor'); run(PL, 'commit', '-q', '-m', 'Vendor the parser')
    run(PL, 'rm', '-q', '-r', 'vendor'); run(PL, 'commit', '-q', '-m', 'Drop the vendored parser')
    os.makedirs(vendor)
    run(vendor, 'init', '-q')
    with open(os.path.join(vendor, 'lib.txt'), 'w') as f: f.write('its own\n')
    run(vendor, 'add', 'lib.txt'); run(vendor, 'commit', '-q', '-m', 'Its own parser')
    with open(os.path.join(vendor, 'wip.txt'), 'w') as f: f.write('work in progress\n')


def step1():
    """Reset Hard over a repository of its own."""
    launch_prepared('light', 'base', prepare=prepare_nested)
    show_tab('powerlens')
    head, target, stashes = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD~1'), stash_subjects()
    k('reset', target, 'hard')
    until(lambda d: d['active']['confirmation'], label='the question before Reset Hard')
    k('confirm')
    d = settle(lambda d: alert(d) != '' or git('rev-parse', 'HEAD') != head, label='the alert (or the reset)')
    print('1. alert:', alert(d)[:230] or '(none)', '| HEAD moved:', git('rev-parse', 'HEAD') != head)
    assert 'vendor is a git repository of its own' in alert(d), 'Reset Hard should refuse: %r' % alert(d)
    assert git('rev-parse', 'HEAD') == head and stash_subjects() == stashes, 'nothing should have changed'
    with open(os.path.join(PL, 'vendor', 'wip.txt')) as f: wip = f.read()
    assert wip == 'work in progress\n' and os.path.isdir(os.path.join(PL, 'vendor', '.git'))
    k('dismiss')
    quit_app()


def prepare_pick(clash):
    """`side` and the branch both retitle README.md (a cherry-pick of side's commit stops on that), and
    something is left uncommitted: the same line again (`clash`), or another file."""
    def prepare():
        branch = run(PL, 'rev-parse', '--abbrev-ref', 'HEAD')
        with open(README) as f: text = f.read()
        run(PL, 'switch', '-q', '-c', 'side')
        with open(README, 'w') as f: f.write('Side title\n' + text)
        run(PL, 'commit', '-q', '-am', 'Retitle the README on side')
        run(PL, 'switch', '-q', branch)
        with open(README, 'w') as f: f.write('Main title\n' + text)
        run(PL, 'commit', '-q', '-am', 'Retitle the README on main')
        if clash:
            with open(README, 'w') as f: f.write('My title\n' + text)
        else:
            other = next(p for p in run(PL, 'ls-files').splitlines() if p != 'README.md')
            with open(os.path.join(PL, other), 'a') as f: f.write('\n// a line of mine\n')
    return prepare


def pick_stopped(clash):
    launch_prepared('light', 'base', prepare=prepare_pick(clash))
    show_tab('powerlens')
    head, before = git('rev-parse', 'HEAD'), git('status', '--porcelain')
    k('cherryPick', git('rev-parse', 'side'))
    settle(lambda d: d['active']['operation'] == 'cherryPick' and p4(d)['screen'] == 'conflicts', label='the pick to stop on its conflict')
    assert len(kept()) == 1, 'the uncommitted changes should wait in Stashes: %s' % stash_subjects()
    return head, before


def step2():
    """Skip of the only commit: the changes come back."""
    head, before = pick_stopped(clash=False)
    k('skipOp')
    d = settle(lambda d: d['active']['operation'] == '' and p4(d)['screen'] == '', label='Skip')
    print('2. after Skip: HEAD same %s | changes %r | kept %s | toast %r' % (git('rev-parse', 'HEAD') == head, git('status', '--porcelain'), kept(), toast(d)))
    assert git('rev-parse', 'HEAD') == head
    assert not kept() and git('status', '--porcelain') == before, 'the changes put aside should be back'
    quit_app()


def step3():
    """Continue after resolving, with changes on the same lines: they stay in Stashes, no markers."""
    pick_stopped(clash=True)
    k('conflictKeep', 'theirs')
    k('markResolved')
    settle(lambda d: p4(d)['conflicted'] == [], label='the conflict resolved')
    k('continueOp')
    d = settle(lambda d: d['active']['operation'] == '' and p4(d)['screen'] == '' and toast(d), label='the pick to finish')
    with open(README) as f: text = f.read()
    print('3. after Continue: toast %r | first line %r | markers %s | kept %s' % (toast(d), text.split('\n')[0], '<<<<<<<' in text, kept()))
    assert '<<<<<<<' not in text and text.startswith('Side title\n') and git('status', '--porcelain', '--untracked-files=no') == '', 'no conflict markers'
    assert len(kept()) == 1 and 'touch the same files' in toast(d)
    quit_app()


def step4():
    """A hidden tab's light refresh, after the tab was shown."""
    launch('light', 'base')
    show_tab('powerlens')
    folder = os.path.join(SAMPLES, 'travel-notes', 'drafts')
    os.makedirs(folder)
    for name in ('one.md', 'two.md'):
        with open(os.path.join(folder, name), 'w') as f: f.write('a draft\n')
    time.sleep(0.5)   # the step itself: the hidden tab has heard of the change, and its light refresh waits (1.5 s)
    k('activateName', 'travel-notes')
    both = ['drafts/one.md', 'drafts/two.md']
    def drafts(d): return sorted(p for p in d['active']['unstaged'] if p.startswith('drafts'))
    until(lambda d: active_name(d) == 'travel-notes' and drafts(d) == both, label='travel-notes shown with the two drafts')
    time.sleep(2.5)   # the step itself: past the light refresh's 1.5 s
    d = settle(label='quiet')
    print('4. 2.5 s after showing the tab:', drafts(d), '| light refreshes', tab(d, 'travel-notes')['lightRefreshes'])
    assert drafts(d) == both, 'the folded status replaced the full one: %s' % drafts(d)
    quit_app()


STEPS = {'1': step1, '2': step2, '3': step3, '4': step4}
for name in (os.environ.get('KAERN_STEPS') or '1,2,3,4').split(','):
    STEPS[name.strip()]()
print('REVIEW7 OK')
