"""t_deepselect.py — a commit selected more than 20,000 commits down stays selected when the history is read again
(a commit made in Terminal): the refresh reads as far down as the selection, not only its usual 20,000."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
NAME = 'cluster-config'
REPO = os.path.join(SAMPLES, NAME)


def h(d): return d['phase5']['history']


launch_prepared('light', prepare=lambda: big_sample(NAME, 60000))
show_tab(NAME, lambda d: h(d)['commits'] >= 400, seconds=60)
k('loadMore', 21000)
d = settle(lambda d: h(d)['commits'] >= 21000, seconds=120, label='21,000 commits loaded')
print('loaded:', h(d)['commits'])
k('select', 20600)
d = settle(lambda d: d['active']['selection'].startswith('commit 20600 '), label='commit 20,600 selected')
picked = d['active']['selection'].split()[2]

with open(os.path.join(REPO, 'deep.txt'), 'w') as f: f.write('x\n')
g(REPO, 'add', 'deep.txt')
g(REPO, '-c', 'user.name=T', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'test: a commit on top')
head = g(REPO, 'rev-parse', 'HEAD')[:7]
d = settle(lambda d: d['active']['head'] == head, seconds=120, label='the app noticed the commit')
print('after the refresh: %d commits loaded, selection %r' % (h(d)['commits'], d['active']['selection']))
assert d['active']['selection'] == 'commit 20601 ' + picked, d['active']['selection']
quit_app()
print('t_deepselect ok')
