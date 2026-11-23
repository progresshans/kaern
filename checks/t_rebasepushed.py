"""t_rebasepushed.py — the Interactive Rebase sheet's line about pushed commits, and Push after the rebase.

The base sample's branch (feature/restore-automatic-alpha) has three commits after develop, oldest first: P,
which is on origin, then U1 and U2, which aren't. git keeps a picked commit as it is when its parent is where the
rebase has got to, so P stays as it is only while it comes first, as a Pick, onto its own parent, with nothing
folded into it. A Squash or Fixup right after P (dropped commits in between don't count) folds into P and
rewrites it, and the line under the table must then warn that Push will need Force Push.

The check goes through the actions, moves, the Onto pop-up's items (the upstream, the same commit by name,
another commit, a branch that already has P), and with U1 on origin too: the two pushed commits swapped, and
Squash N into One folding U2 into U1. Then two rebases for real: U1 fixed up into P, after which Push asks to
force-push with lease and names P as what it replaces; and U2 fixed up into U1, after which a normal Push works.
"""
import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *

BRANCH = 'feature/restore-automatic-alpha'


def rb(d):
    return d['active']['phase4'].get('rebase')


def actions(r):
    return [step.split(' ')[0] for step in r['steps']]


def listed(r):
    return [step.split(' ')[1] for step in r['steps']]


def prepare():
    # The branch's reflog as a real one has it: the branch was at P when P was pushed, then got U1 and U2 (the
    # sample sets it to U2 straight away). Push reads the reflog to tell a rewrite of its own from someone
    # else's push.
    for commit in git('rev-list', '--reverse', 'develop..HEAD').split():
        git('update-ref', '-m', 'commit: ' + git('log', '-1', '--format=%s', commit), 'refs/heads/' + BRANCH, commit)


launch_prepared('light', 'base', prepare=prepare)
a = shown()
ids = git('rev-list', '--reverse', 'develop..HEAD').split()
assert a['branch'] == BRANCH and len(ids) == 3 and git('rev-list', 'develop..@{u}').split() == ids[:1], ('the sample changed', a['branch'], ids)
P, U1, U2 = ids
p, u1, u2 = (commit[:7] for commit in ids)
develop, head0, upstream = git('rev-parse', 'develop'), ids[-1], git('rev-parse', '--abbrev-ref', '@{u}')
assert git('rev-parse', P + '^') == develop
assert git('merge-base', P, 'feature/reliability-and-release') == P and git('merge-base', P, 'feature/harden-sparkle-releases') != P
staged0, unstaged0 = sorted(a['staged']), sorted(a['unstaged'])
OK = 'ok %s stays as it is — only unpushed commits change, so a normal Push works afterwards.' % p
WARN = 'warning %s is already on origin. After this rebase, Push will need Force Push (with lease).' % p
NONE = 'ok None of these commits are on origin yet, so a normal Push works afterwards.'
print('P %s (on origin), U1 %s, U2 %s' % (p, u1, u2))


def open_sheet(pushed=(p,)):
    # By hash and with the line in the dump: the app needs feature/rebase-fixup-into-pushed (2026-11-19).
    k('sheet', 'ir', develop[:12])
    d = settle(lambda d: rb(d) and not rb(d)['loading'] and len(rb(d)['steps']) == 3,
               label='the rebase sheet (an app from before 2026-11-19 opens it only by row)')
    r = rb(d)
    assert 'check' in r and 'onto' in r, "this app's rebase dump has no line or Onto (it is from before 2026-11-19)"
    assert listed(r) == [p, u1, u2] and r['pushed'] == sorted(pushed), r
    return r


def close_sheet():
    k('sheetClose')
    settle(lambda d: not rb(d), label='the sheet closed')


def say(label, r):
    print('  %-24s %-4s %-36s %s' % (label, 'WARN' if r['rewritesPushed'] else 'ok', ' | '.join(r['meta']), r['check'][:46] + '…'))


def case(wanted, want):
    """Sets the rows' actions (top row first), waits until the sheet has them and checks the line under the
    table, which is what the sheet shows (`RebaseDraft.check`)."""
    for row, action in enumerate(wanted):
        k('irAction', row, action)
    r = rb(until(lambda d: actions(rb(d)) == list(wanted), label=' '.join(wanted)))
    say(' '.join(wanted), r)
    assert r['rewritesPushed'] == want.startswith('warning') and r['check'] == want, (wanted, r)
    return r


def move(row, offset, order):
    k('irMove', row, offset)
    r = rb(until(lambda d: listed(rb(d)) == order, label='the rows in the order ' + ' '.join(order)))
    say('order ' + ' '.join(order), r)
    return r


def onto(choice, order):
    """Picks `choice` in the Onto pop-up and waits for the list it gives."""
    assert choice in rb(full_dump())['choices'], (choice, rb(full_dump())['choices'])
    k('irBase', choice)
    r = rb(settle(lambda d: rb(d) and rb(d)['onto'] == choice and not rb(d)['loading'] and listed(rb(d)) == order,
                  label='the list onto ' + choice))
    say('onto ' + choice[:20], r)
    return r


# The line under the table, for each kind of change.
r = open_sheet()
assert r['check'] == OK and not r['rewritesPushed'] and r['meta'] == ['on origin', '', ''], r
print('only unpushed commits change:')
for wanted in [('pick', 'pick', 'pick'),
               ('pick', 'pick', 'fixup'),    # U2 into U1
               ('pick', 'pick', 'squash'),
               ('pick', 'reword', 'pick'),
               ('pick', 'drop', 'pick'),
               ('pick', 'pick', 'drop'),
               ('pick', 'drop', 'drop'),
               ('pick', 'edit', 'fixup')]:   # U2 into U1, which stops to be edited
    case(wanted, OK)
print('P changes:')
r = case(('pick', 'fixup', 'pick'), WARN)    # U1 into P: the row says so, and so must the line
assert r['meta'] == ['on origin', 'into ' + p, ''], r
case(('pick', 'squash', 'pick'), WARN)
r = case(('pick', 'drop', 'fixup'), WARN)    # a dropped commit in between doesn't count
assert r['meta'] == ['on origin', 'removed', 'into ' + p], r
case(('pick', 'drop', 'squash'), WARN)
case(('pick', 'fixup', 'fixup'), WARN)
case(('pick', 'squash', 'fixup'), WARN)
case(('reword', 'pick', 'pick'), WARN)
case(('drop', 'pick', 'pick'), WARN)
case(('edit', 'pick', 'pick'), WARN)
case(('pick', 'pick', 'pick'), OK)
r = move(1, -1, [u1, p, u2])                 # U1 above P: P is replayed onto U1
assert r['rewritesPushed'] and r['check'] == WARN, r
r = move(0, 1, [p, u1, u2])
assert not r['rewritesPushed'] and r['check'] == OK, r

# Onto: what is on origin is read again with each list, and P stays only when the list starts at its parent.
print('Onto:')
assert rb(full_dump())['onto'] == develop
r = onto(upstream, [u1, u2])                 # the branch's own upstream: only the unpushed commits
assert r['pushed'] == [] and not r['rewritesPushed'] and r['check'] == NONE, r
r = onto('develop', [p, u1, u2])             # by name, the commit the sheet opened on
assert r['pushed'] == [p] and not r['rewritesPushed'] and r['check'] == OK, r
r = onto('feature/harden-sparkle-releases', [p, u1, u2])    # another commit: P is replayed onto it
assert r['pushed'] == [p] and r['rewritesPushed'] and r['check'] == WARN, r
r = onto('feature/reliability-and-release', [u1, u2])       # a branch that already has P
assert r['pushed'] == [] and not r['rewritesPushed'] and r['check'] == NONE, r
r = onto(develop, [p, u1, u2])               # the first item again
assert r['pushed'] == [p] and r['check'] == OK, r
close_sheet()

# U1 on origin too (pushed from here, as from another clone of the branch).
git('push', '-q', 'origin', U1 + ':refs/heads/' + BRANCH)
settle(lambda d: (d['active']['ahead'], d['active']['behind']) == (1, 0), label='U1 on origin')
OK2 = 'ok %s, %s stay as they are — only unpushed commits change, so a normal Push works afterwards.' % (p, u1)
WARN2 = 'warning 2 of these commits are already on origin. After this rebase, Push will need Force Push (with lease).'
print('P and U1 on origin:')
open_sheet(pushed=(p, u1))
case(('pick', 'pick', 'pick'), OK2)
case(('pick', 'pick', 'drop'), OK2)
case(('pick', 'pick', 'fixup'), WARN2)       # U2 into U1
case(('pick', 'pick', 'pick'), OK2)
r = move(0, 1, [u1, p, u2])                  # P and U1 swapped: both are replayed
assert r['rewritesPushed'] and r['check'] == WARN2, r
r = move(0, 1, [p, u1, u2])
assert r['check'] == OK2, r
close_sheet()
# Squash N into One (the commit menu) on U1 and U2, which are next to each other in the history (P isn't: two
# commits of other branches come between by date): U2 folds into U1.
k('squash', u1, u2)
r = rb(settle(lambda d: rb(d) and not rb(d)['loading'] and len(rb(d)['steps']) == 2, label='Squash U1 and U2'))
say('squash U1 U2', r)
assert actions(r) == ['pick', 'squash'] and r['pushed'] == [u1] and r['meta'] == ['on origin', 'into ' + u1], r
assert r['rewritesPushed'] and r['check'] == 'warning %s is already on origin. After this rebase, Push will need Force Push (with lease).' % u1, r
close_sheet()
git('push', '-q', '--force', 'origin', P + ':refs/heads/' + BRANCH)    # origin as the sample had it
settle(lambda d: (d['active']['ahead'], d['active']['behind']) == (2, 0) and git('rev-parse', '@{u}') == P, label='origin back at P')
k('squash', u1, u2)
r = rb(settle(lambda d: rb(d) and not rb(d)['loading'] and len(rb(d)['steps']) == 2, label='Squash U1 and U2, none on origin'))
say('squash U1 U2', r)
assert actions(r) == ['pick', 'squash'] and r['pushed'] == [] and not r['rewritesPushed'] and r['check'] == NONE, r
close_sheet()

# U1 fixed up into P for real: P is rewritten, so Push asks to force-push, and what it replaces is P.
open_sheet()
case(('pick', 'fixup', 'pick'), WARN)
k('irStart')
d = settle(lambda d: d['active']['operation'] == '' and 'Rebased' in toast(d) and git('rev-parse', 'HEAD') != head0
           and d['active']['behind'] == 1, label='the rebase that folds U1 into P')
a = d['active']
print('after U1 into P:', git('log', '--format=%h %s', develop + '..HEAD').split('\n'), 'ahead', a['ahead'], 'behind', a['behind'])
assert git('rev-list', '--count', develop + '..HEAD') == '2' and git('rev-parse', 'HEAD~2') == develop
assert git('rev-parse', 'HEAD~1') != P and git('log', '-1', '--format=%s', 'HEAD~1') == git('log', '-1', '--format=%s', P)
assert git('rev-list', '--count', 'HEAD..@{u}') == '1', 'origin has a commit the branch no longer has, so a plain push is refused'
assert (a['ahead'], a['behind']) == (2, 1), (a['ahead'], a['behind'])
assert sorted(a['staged']) == staged0 and sorted(a['unstaged']) == unstaged0, (a['staged'], a['unstaged'])
k('push')
d = settle(lambda d: d['active']['confirmation'] is not None, label='Push asking to force-push')
c = d['active']['confirmation']
print('push asks:', c)
assert c['title'] == 'Force push “%s”?' % BRANCH and c['lost'] == [git('log', '-1', '--format=%s', P)], c
k('dismiss')
settle(lambda d: d['active']['confirmation'] is None, label='the question put away')
assert git('rev-parse', '@{u}') == P, 'nothing was pushed'
k('undo')
d = settle(lambda d: git('rev-parse', 'HEAD') == head0 and 'Undid' in toast(d) and d['active']['behind'] == 0, label='the undo')
a = d['active']
assert sorted(a['staged']) == staged0 and sorted(a['unstaged']) == unstaged0, (a['staged'], a['unstaged'])

# U2 fixed up into U1 for real: P stays as it is, and a normal Push works.
open_sheet()
case(('pick', 'pick', 'fixup'), OK)
k('irStart')
d = settle(lambda d: d['active']['operation'] == '' and 'Rebased' in toast(d) and git('rev-parse', 'HEAD') != head0
           and d['active']['ahead'] == 1, label='the rebase that folds U2 into U1')
a = d['active']
print('after U2 into U1:', git('log', '--format=%h %s', develop + '..HEAD').split('\n'), 'ahead', a['ahead'], 'behind', a['behind'])
assert git('rev-parse', 'HEAD~1') == P and git('rev-list', '--count', 'HEAD..@{u}') == '0'
assert (a['ahead'], a['behind']) == (1, 0), (a['ahead'], a['behind'])
assert sorted(a['staged']) == staged0 and sorted(a['unstaged']) == unstaged0, (a['staged'], a['unstaged'])
head1 = git('rev-parse', 'HEAD')
k('push')
d = settle(lambda d: git('rev-parse', '@{u}') == head1 and 'Pushed' in toast(d), label='the normal push')
print('push:', toast(d))
assert d['active']['confirmation'] is None and toast(d) == 'Pushed 1 commit to origin/' + BRANCH, (d['active']['confirmation'], toast(d))
print('REBASE PUSHED OK')
quit_app()
