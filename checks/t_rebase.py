import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
def p4(d): return d['active']['phase4']
launch('light', 'base')
a = shown()
head0 = git('rev-parse', 'HEAD'); develop = git('rev-parse', 'develop')
staged0 = sorted(a['staged']); unstaged0 = sorted(a['unstaged'])
k('sheet', 'ir', 6)
d = settle(lambda d: len(p4(d)['rebase']['steps']) == 3 and not p4(d)['rebase']['loading'], label='the rebase sheet')
r = p4(d)['rebase']; print('sheet:', r)
assert r['steps'][0].startswith('pick') and len(r['steps']) == 3 and r['result'] == 3
k('irAction', 2, 'fixup')
k('irAction', 1, 'reword', 'fix: restore automatic alpha releases after the freeze')
d = until(lambda d: p4(d)['rebase']['steps'][2].startswith('fixup') and p4(d)['rebase']['steps'][1].startswith('reword'), label='the edited steps')
r = p4(d)['rebase']; print('edited:', r['steps'], r['result'], r['canStart'], r['rewritesPushed'])
k('irStart')
d = settle(lambda d: git('log', '-1', '--format=%s', 'HEAD') == 'fix: restore automatic alpha releases after the freeze'
           and d['active']['operation'] == '' and 'Rebased' in toast(d), label='the interactive rebase')
a = d['active']; print('after:', git('log', '--format=%s', develop + '..HEAD').split('\n'), a['toast'])
assert git('rev-parse', 'HEAD~2') == develop
assert git('log', '-1', '--format=%s', 'HEAD') == 'fix: restore automatic alpha releases after the freeze'
assert sorted(a['staged']) == staged0 and sorted(a['unstaged']) == unstaged0, (a['staged'], a['unstaged'])
k('undo')
d = settle(lambda d: git('rev-parse', 'HEAD') == head0 and 'Undid' in toast(d), label='the undo'); a = d['active']; print('undo:', a['toast'])
assert git('rev-parse', 'HEAD') == head0 and sorted(a['staged']) == staged0
# Squash two picked commits (rows 1 and 2) into one.
k('squash', 1, 2)
d = settle(lambda d: [s.split(' ')[0] for s in p4(d)['rebase']['steps']] == ['pick', 'squash'] and not p4(d)['rebase']['loading'], label='the squash sheet')
r = p4(d)['rebase']; print('squash sheet:', r['steps'], r['result'])
assert [s.split(' ')[0] for s in r['steps']] == ['pick', 'squash'] and r['result'] == 1
k('irStart')
d = settle(lambda d: len(git('log', '--format=%s', develop + '..HEAD').split('\n')) == 2 and d['active']['operation'] == ''
           and '2 commits became 1' in toast(d), label='the squash')
subjects = git('log', '--format=%s', develop + '..HEAD').split('\n')
print('squashed:', subjects)
assert len(subjects) == 2 and git('rev-parse', 'HEAD~2') == develop and subjects[0] == 'fix: restore automatic alpha releases'
print('   toast:', d['active']['toast'])
print('REBASE OK')
quit_app()
