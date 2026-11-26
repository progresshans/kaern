"""A refresh that read git before an action ended must not undo what the action showed.

The race this checks (found 2026-11-10): the file watcher starts a refresh up to 0.3 s after a change, also
while an action runs. When a stash pop stopped on a conflict in the meantime, the refresh came back with a
`git status` from before the pop, no conflicted file in it, and the model took that for "resolved outside
Kaern": the conflict bar and the editor went away with the toast "Resolved the conflicts from stash@{0}…"
while the file still had its markers.

Nothing here depends on timing: the debug driver holds the refresh at the point each order needs
(`hold status|decide|statusNow|decideNow`, `release`, `refresh`; DebugDriver+Holds.swift), the pop runs, and the
refresh is let go. Each step starts from a fresh instance, so one that fails doesn't spoil the next.
"""
import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *

ALPHA = 'Sources/PowerLens/Release/AlphaVersion.swift'
RESOLVED = 'Resolved the conflicts'

def p4(d): return d['active']['phase4']
def holding(d): return d['driver']['holding']
def refreshes(d): return tab(d, 'powerlens')['refreshes']
def stale_reads(d): return tab(d, 'powerlens').get('staleReads', 0)   # `git status` answers the model didn't show
def crossed(d): return tab(d, 'powerlens').get('crossedRefreshes', 0)  # refreshes that concluded nothing: Kaern changed the repository while they ran
def unmerged(): return [line[3:] for line in git('status', '--porcelain').splitlines() if line[:2] == 'UU']

def stopped(d):
    """The pop stopped on its conflict and the app shows it: the bar, the editor, the conflicted file."""
    return bool(p4(d)['stashConflict']) and p4(d)['screen'] == 'conflicts' and p4(d)['conflicted'] == [ALPHA]

def state(d):
    return 'bar=%s editor=%s conflicted=%s toast=%r' % (bool(p4(d)['stashConflict']), p4(d)['screen'] == 'conflicts', p4(d)['conflicted'], toast(d)[:40])

def still_stopped(d, what):
    assert unmerged() == [ALPHA], 'the sample should have its conflict: %s' % unmerged()
    assert stopped(d) and RESOLVED not in toast(d), '%s: the conflict is still in the file, but the app shows %s' % (what, state(d))
    print('   ok:', state(d))

class NoHolds(Exception):
    """The app under test is from before the hold commands: nothing here can run."""

def begin():
    d = launch('light', 'stash-conflict')
    if 'holding' not in d['driver']: raise NoHolds()
    d = settle(lambda d: len(d['active']['stashes']) == 2 and not p4(d)['stashConflict'], label='the sample with its two stashes')
    assert unmerged() == [] and holding(d) == []
    return d


# 1 and 2. The race as it happens: a file changes, the watcher's refresh (status only) reads git, the pop
#    stops on its conflict, and then the refresh shows what it read. Then the same with a full refresh.
def read_before_shown_after(start):
    begin()
    hold_at('status')
    start()
    until(lambda d: 'status' in holding(d), label='the refresh to wait with the status it read')
    k('popStash', 0)
    d = until(lambda d: stopped(d) and not d['active']['activity'], label='the pop to stop on its conflict')
    assert 'status' in holding(d), 'the refresh should still wait: %s' % holding(d)
    print('   the pop stopped:', state(d), '| held:', holding(d))
    dropped = stale_reads(d)
    k('release', 'status')
    d = settle(label='the held refresh to end')
    still_stopped(d, 'a status read before the pop and shown after it')
    # Not shown at all, not even for a moment: the model counted it as read too early.
    assert stale_reads(d) == dropped + 1, 'the status read before the pop should have been dropped (%d → %d)' % (dropped, stale_reads(d))
    # The bar still works: Undo Pop takes the conflict back.
    k('undoPop')
    d = settle(lambda d: not p4(d)['stashConflict'] and p4(d)['conflicted'] == [] and 'Undid' in toast(d), label='Undo Pop')
    assert unmerged() == [] and len(d['active']['stashes']) == 2
    quit_app()

def a_file_changes():
    with open(os.path.join(PL, 'README.md'), 'a') as f: f.write('\na line the watcher reports\n')

def a_full_refresh():
    k('refresh')


# 3. The other order: the refresh has shown its status (from before the pop) and is about to conclude
#    from it when the pop stops. The pop's own status read is held too, so the older status is still
#    the one shown when the refresh decides.
def shown_before_decided_after():
    begin()
    hold_at('decide'); k('refresh')
    d = until(lambda d: 'decide' in holding(d), label='the refresh to wait before it decides')
    before = refreshes(d)
    hold_at('statusNow')
    k('popStash', 0)
    d = until(lambda d: p4(d)['stashConflict'] and not d['active']['activity'] and 'statusNow' in holding(d),
              label='the pop to stop, with its own status read waiting')
    assert p4(d)['conflicted'] == [] and holding(d) == ['decide', 'statusNow'], 'the status shown should be the older one: %s %s' % (state(d), holding(d))
    print('   the pop stopped:', state(d), '| held:', holding(d))
    skipped = crossed(d)
    k('release', 'decide')
    # The held refresh has decided once the next one (the pop's) has started.
    d = until(lambda d: refreshes(d) > before, label="the held refresh to end and the pop's refresh to start")
    assert p4(d)['stashConflict'] and RESOLVED not in toast(d), \
        'a refresh shown before the pop concluded from its older status: %s' % state(d)
    assert crossed(d) == skipped + 1, 'the held refresh should have concluded nothing (%d → %d)' % (skipped, crossed(d))
    k('release', 'statusNow')
    d = settle(stopped, label='the conflict editor to open')
    still_stopped(d, 'a refresh that decided after the pop')
    quit_app()


# 4. The stash view moves on to the next stash when its own is gone — but not from what a refresh reads
#    while an action runs (a rename takes its stash out of the list and puts it back; a pop closes the
#    view itself). Here a checkout is kept running by a post-checkout hook, and the shown stash is dropped
#    outside Kaern meanwhile: the view waits, and moves on when the checkout has ended.
def stash_view_waits_for_the_action():
    begin()
    go = os.path.join(RUN_DIR, 'hook-go')
    if os.path.exists(go): os.remove(go)
    hook = os.path.join(PL, '.git', 'hooks', 'post-checkout')
    with open(hook, 'w') as f: f.write('#!/bin/sh\nwhile [ ! -e "%s" ]; do sleep 0.05; done\n' % go)
    os.chmod(hook, 0o755)
    try:
        k('openStash', 0)
        d = settle(lambda d: (p4(d)['stashDetails'] or {}).get('stash') == 'stash@{0}', label='the stash view')
        shown = p4(d)['screen']
        assert shown.startswith('stash('), shown
        k('checkout', 'develop')
        d = until(lambda d: d['active']['activity'].startswith('Switching') and git('rev-parse', '--abbrev-ref', 'HEAD') == 'develop',
                  label='the checkout to wait in its hook')
        git('stash', 'drop', '-q', 'stash@{0}')
        d = until(lambda d: len(d['active']['stashes']) == 1, label='the refresh that reads the shorter stash list')
        # That refresh has decided once a later one has started.
        started = refreshes(d)
        k('refresh')
        d = until(lambda d: refreshes(d) > started, label='the refresh that read the list to end')
        assert d['active']['activity'].startswith('Switching'), 'the checkout should still be running: %r' % d['active']['activity']
        assert p4(d)['screen'] == shown, 'the stash view moved on while the checkout was still running: %s → %s' % (shown, p4(d)['screen'])
        print('   while the checkout runs: the view stays on', shown, '| stashes:', d['active']['stashes'])
    finally:
        with open(go, 'w'): pass
    d = settle(lambda d: not d['active']['activity'] and d['active']['branch'] == 'develop'
               and p4(d)['screen'].startswith('stash(') and p4(d)['screen'] != shown, label='the view to move on once the checkout ended')
    assert (p4(d)['stashDetails'] or {}).get('stash') == 'stash@{0}' and len(d['active']['stashes']) == 1, \
        'after the checkout the view shows %r with %r of %r' % (p4(d)['screen'], p4(d)['stashDetails'], d['active']['stashes'])
    print('   after it:', p4(d)['screen'], p4(d)['stashDetails']['stash'], d['active']['stashes'])
    quit_app()


# 5. After a stop on conflicts the editor opens once the status is in and the line counts are read. Undo
#    Pop in between takes the conflict back, so the editor must not open on the status from before it.
#    The refresh after Undo Pop is held too, so that older status is still the one shown.
def editor_stays_closed_after_undo_pop():
    begin()
    hold_at('decideNow')
    k('popStash', 0)
    d = until(lambda d: p4(d)['stashConflict'] and not d['active']['activity'] and p4(d)['conflicted'] == [ALPHA] and 'decideNow' in holding(d),
              label='the pop to stop with its status shown and the editor still to open')
    assert p4(d)['screen'] == '', 'the editor should not be open yet: %s' % state(d)
    hold_at('status')
    k('undoPop')
    d = until(lambda d: not p4(d)['stashConflict'] and not d['active']['activity'] and 'Undid' in toast(d) and 'status' in holding(d),
              label='Undo Pop to end, with the refresh after it waiting')
    assert unmerged() == [] and p4(d)['conflicted'] == [ALPHA], 'git has no conflict left and the status shown is still the older one: %s %s' % (unmerged(), state(d))
    print('   Undo Pop ended:', state(d), '| held:', holding(d))
    k('release', 'decideNow')
    # The held read goes on: it reads again and shows that nothing is in conflict (or, before the fix,
    # the editor opens on the older status).
    d = until(lambda d: p4(d)['conflicted'] == [] or p4(d)['screen'] == 'conflicts', label='the held status read to go on')
    assert p4(d)['screen'] == '', 'the conflict editor opened on a conflict Undo Pop had taken back: %s' % state(d)
    k('release', 'status')
    d = settle(lambda d: p4(d)['conflicted'] == [] and p4(d)['screen'] == '' and not p4(d)['stashConflict'], label='the refresh after Undo Pop to end')
    assert unmerged() == [] and len(d['active']['stashes']) == 2
    print('   ok:', state(d))
    quit_app()


steps = [
    ('1. a status read before the pop, shown after it (the watcher, status only)', lambda: read_before_shown_after(a_file_changes)),
    ('2. the same with a full refresh (refs, history, stashes)', lambda: read_before_shown_after(a_full_refresh)),
    ('3. a refresh shown before the pop that decides after it', shown_before_decided_after),
    ('4. the stash view waits for a running action before it moves on', stash_view_waits_for_the_action),
    ('5. the conflict editor stays closed when Undo Pop comes before it opens', editor_stays_closed_after_undo_pop),
]
failed = []
for name, run in steps:
    print('--', name)
    try:
        run()
    except NoHolds:
        kill_app()
        raise SystemExit('STALEREFRESH: this build of the app has no hold commands (Kaern/App/DebugDriver+Holds.swift)')
    except (AssertionError, SystemExit) as problem:
        failed.append(name)
        print('   FAILED:', problem)
kill_app()
if failed:
    raise SystemExit('STALEREFRESH FAILED: %d of %d steps\n   %s' % (len(failed), len(steps), '\n   '.join(failed)))
print('STALEREFRESH OK')
