"""t_nestedworktree.py — a working tree inside the shown repository's folder (as `.claude/worktrees/x` is): a file
saved there updates that tree's count in the sidebar without a refresh of the shown tab, and a commit made there
(which changes no file in its folder) brings the count back down."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
NAME = 'powerlens'
REPO = os.path.join(SAMPLES, NAME)
INNER = os.path.join(REPO, '.worktrees', 'inner')


def prepare():
    with open(os.path.join(REPO, '.git', 'info', 'exclude'), 'a') as f: f.write('.worktrees/\n')
    g(REPO, 'worktree', 'add', '-q', '-b', 'inner', INNER)


def count(d):
    line = next((w for w in d['phase6']['worktrees'] if w.startswith('inner |')), '')
    return line.split(' | ')[2] if line else None


launch_prepared('light', prepare=prepare)
d = show_tab(NAME)
d = settle(lambda d: count(d) == '0', label='the inner worktree, clean')
refreshes = tab(d, NAME)['refreshes']

with open(os.path.join(INNER, 'new.txt'), 'w') as f: f.write('x\n')
d = until(lambda d: count(d) == '1', seconds=10, label="the inner worktree's count after a file was saved in it")
d = settle(label='quiet after the save')
print('1. a file saved in the inner worktree: count %s | refreshes of %s: %d -> %d' % (count(d), NAME, refreshes, tab(d, NAME)['refreshes']))
assert tab(d, NAME)['refreshes'] == refreshes, 'the shown tab refreshed for a file in another working tree'

g(INNER, 'add', 'new.txt')
g(INNER, '-c', 'user.name=T', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'test: in the inner worktree')
d = until(lambda d: count(d) == '0', seconds=10, label="the inner worktree's count after a commit there")
print('2. a commit made in the inner worktree: count %s' % count(d))
quit_app()
print('t_nestedworktree ok')
