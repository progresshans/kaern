"""t_marks6.py [light|dark] — ScreenMarks › 서명 and 워크트리 on powerlens with SSH-signed history (scen6.marks_sample):
the Commit column's shields (verified, signed but not verified, bad, none), the selected commit's card, Trust This
Key… (adds the key to the allowed signers; ⌘Z takes it out), Show Raw Signature; the Worktrees section (this window,
powerlens-hotfix with hotfix/0.9.3.1 and 2 changes), the branch's worktree mark, the worktree page, Remove… (its
changes go to Stashes; ⌘Z puts the worktree back with them) and Add Worktree (⌘Z removes it)."""
import os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen6 import SIGNED_BAD, SIGNED_UNTRUSTED, KEYS
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
HOTFIX = os.path.join(SAMPLES, 'powerlens-hotfix')
def p6(d): return d['phase6']
def sigs(d): return dict(line.rsplit(' | ', 1) for line in d['phase6']['signatures'])

# The signed history is built once (samples.py's kind "signed") and copied here.
launch_prepared(mode, scenario='signed')
d = show_tab('powerlens', lambda d: len(p6(d)['signatures']) >= 26, seconds=40)
s = sigs(d)
print({k[:40]: v for k, v in list(s.items())[:8]})
assert s[SIGNED_UNTRUSTED] == 'U' and s[SIGNED_BAD] == 'B' and s['refactor: centralize power delivery transitions'] == 'N'
assert s['Merge pull request #10 from feature/charge-limit-awareness'] == 'G' and s['fix: reset alpha numbering per version'] == 'G'

# The card for the commit signed with a key nobody listed.
k('selectSubject', SIGNED_UNTRUSTED)
d = settle(lambda d: p6(d)['selectedSignature'].startswith('unverified'), label='card')
print('card:', p6(d)['selectedSignature'])
snap('marks-signature', mode)

# Trust This Key…: the confirmation shows the fingerprint; the key goes into the allowed signers; ⌘Z takes it out.
allowed = os.path.join(KEYS, 'allowed_signers')
before = open(allowed).read()
k('trustKey')
d = until(lambda d: p6(d)['confirmation'].startswith('Trust Minji Park'), label='trust confirmation')
print('confirmation:', p6(d)['confirmation'][:160].replace('\n', ' '))
assert 'SHA256:' in p6(d)['confirmation']
snap('marks-trust', mode, changed=True)
k('confirm')
d = settle(lambda d: sigs(d).get(SIGNED_UNTRUSTED) == 'G' and p6(d)['selectedSignature'].startswith('verified'), label='trusted')
print('trusted:', p6(d)['toast'], '| undo', p6(d)['undo'][-1:])
assert open(allowed).read().startswith(before) and open(allowed).read() != before
k('undo')
d = settle(lambda d: sigs(d).get(SIGNED_UNTRUSTED) == 'U' and len(p6(d)['signatures']) >= 26, label='undo trust')
assert open(allowed).read() == before
# The other rows kept (or got back) their shields without scrolling.
assert len(p6(d)['signatures']) >= 26 and sigs(d)[SIGNED_BAD] == 'B', p6(d)['signatures'][:5]
print('undo: the key is out again')

# Show Raw Signature for the bad one.
k('selectSubject', SIGNED_BAD)
d = settle(lambda d: p6(d)['selectedSignature'].startswith('bad'), label='bad card')
k('rawSignature')
d = until(lambda d: p6(d)['quickLook'].endswith('signed commit.txt'), label='raw signature')
print('raw:', p6(d)['quickLook'])
k('quickLook')
until(lambda d: p6(d)['quickLook'] == '', label='Quick Look closed')

# Worktrees: this window, powerlens-hotfix with its branch and changes; the branch's mark.
d = settle(lambda d: any('powerlens-hotfix | hotfix/0.9.3.1 | 2' in w for w in p6(d)['worktrees']), label='worktree changes')
x = p6(d); print('worktrees:', x['worktrees'], '| marks', x['branchMarks'])
assert x['branchMarks'] == {'hotfix/0.9.3.1': 'powerlens-hotfix'}
k('worktree', 'powerlens-hotfix')
d = settle(lambda d: p6(d)['worktreeDetails'] and len(p6(d)['worktreeDetails']['files']) == 2, label='worktree page')
print('page:', p6(d)['worktreeDetails'])
assert p6(d)['worktreeDetails']['head'] == 'chore: formalize Apple silicon-only distribution'
snap('marks-worktree', mode, changed=True)

# Remove…: asks first; the changes go to Stashes; ⌘Z puts the worktree back with them.
k('worktreeAction', 'remove')
d = until(lambda d: p6(d)['confirmation'].startswith('Remove the worktree powerlens-hotfix'), label='remove confirmation')
print('remove:', p6(d)['confirmation'][:200].replace('\n', ' '))
k('confirm')
d = settle(lambda d: not os.path.exists(HOTFIX) and p6(d)['toast'].startswith('Removed'), seconds=40, label='removed')
x = p6(d); print('removed:', x['toast'], '| stashes', x['stashes'][:2], '| page', x['selectedWorktree'])
assert x['stashes'][0].endswith('Worktree powerlens-hotfix') and x['selectedWorktree'] == ''
k('undo')
d = settle(lambda d: os.path.exists(HOTFIX) and any('powerlens-hotfix | hotfix/0.9.3.1 | 2' in w for w in p6(d)['worktrees']), seconds=40, label='worktree back')
print('undo: back with', g(HOTFIX, 'status', '--short').split('\n'))
assert not [s for s in p6(d)['stashes'] if s.endswith('Worktree powerlens-hotfix')]

# Add Worktree: a branch no worktree has; ⌘Z removes it.
folder = os.path.join(SAMPLES, 'powerlens-charge')
k('worktreeSheet', 'feature/charge-limit-awareness')
until(lambda d: p6(d)['sheet'] == 'worktree', label='the Add Worktree sheet')
snap('marks-add-worktree', mode, changed=True)
k('sheetClose')
until(lambda d: p6(d)['sheet'] == '', label='the sheet closed')
k('addWorktree', 'feature/charge-limit-awareness', folder)
d = settle(lambda d: any(w.startswith('powerlens-charge | feature/charge-limit-awareness') for w in p6(d)['worktrees']), seconds=40, label='added')
print('added:', p6(d)['toast'])
k('undo')
d = settle(lambda d: not os.path.exists(folder) and not any(w.startswith('powerlens-charge') for w in p6(d)['worktrees']), seconds=40, label='add undone')
quit_app()
print('OK t_marks6', mode)
