import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
def p4(d): return d['active']['phase4']
# Repro: staged work in a file + a pop of a stash touching that file stops on a conflict → Undo Pop.
launch('light', 'base')
a = shown()
changed = {line[3:] for line in git('status', '--porcelain').splitlines()}
F = next(p for p in git('ls-files').splitlines() if p.endswith('.md') and p not in changed)
path = os.path.join(PL, F)
lines = open(path).read().split('\n')
def write_first(text):
    open(path, 'w').write('\n'.join([text] + lines[1:]))
ID = ['-c', 'user.name=Repro', '-c', 'user.email=repro@example.com']
write_first('STASHED LINE'); git(*ID, 'stash', 'push', '-q', '-m', 'repro: touches ' + F, '--', F)
write_first('MY STAGED WORK'); git('add', F)
print('file:', F, '| staged before pop has my work:', 'MY STAGED WORK' in git('diff', '--cached', '--', F))
# The app notices the stash and the staged file.
d = settle(lambda d: len(d['active']['stashes']) == 2 and F in d['active']['staged'], label='the stash and the staged file')
print('stashes:', d['active']['stashes'])
k('popStash', 0)
d = settle(lambda d: p4(d)['stashConflict'] and p4(d)['conflicted'], label='the pop stopped')
print('pop stopped:', p4(d)['stashConflict'], p4(d)['conflicted'])
k('undoPop')
d = settle(lambda d: not p4(d)['stashConflict'] and 'Undid' in toast(d), label='Undo Pop')
a = d['active']; print('undo pop toast:', a['toast'])
print('staged after Undo Pop has my work:', 'MY STAGED WORK' in git('diff', '--cached', '--', F),
      '| first line in the file:', repr(open(path).read().split('\n')[0]), '| stashes:', a['stashes'])
assert 'MY STAGED WORK' in git('diff', '--cached', '--', F) and open(path).read().split('\n')[0] == 'MY STAGED WORK'
quit_app()
print('POPSTAGED OK')
