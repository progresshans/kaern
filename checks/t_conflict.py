import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
def p4(d): return d['active']['phase4']
def session_of(d): return p4(d)['conflictSession']
launch(mode, 'conflict')
a = shown(); show('start', a, ('head', 'branch', 'unstaged'))
head0 = git('rev-parse', 'HEAD')
k('rebase', 'develop')
# Stopped on the conflicts, with the first file's blocks read into the editor.
d = settle(lambda d: d['active']['operation'] == 'rebase' and p4(d)['screen'] == 'conflicts' and session_of(d)['blocks'] > 0, label='the rebase stopped on conflicts')
a = d['active']; x = p4(d); print('after rebase:', a['operation'], x['screen'], x['conflicted'], x['mergedAutomatically'])
print('session:', {k_: x['conflictSession'][k_] for k_ in ('files', 'path', 'blocks', 'open', 'ours', 'theirs')})
assert a['operation'] == 'rebase' and x['screen'] == 'conflicts' and len(x['conflicted']) == 2
snap('conflicts', mode)
k('conflictPick', 0, 'ours')
d = until(lambda d: session_of(d)['choices'] == ['0:ours'], label='the first block picked')
print('picked 0:', session_of(d)['choices'], 'open', session_of(d)['open'])
snap('conflicts-picked', mode)
first = session_of(d)['path']
k('conflictKeep', 'theirs')
k('markResolved')
# The editor moved on to the second file, with its blocks read.
d = settle(lambda d: len(p4(d)['conflicted']) == 1 and session_of(d)['path'] != first and session_of(d)['blocks'] > 0, label='the first file resolved')
print('after mark 1:', p4(d)['conflicted'], session_of(d)['path'])
k('conflictKeep', 'both')
k('markResolved')
d = settle(lambda d: p4(d)['conflicted'] == [] and d['active']['toast'], label='the second file resolved')
print('after mark 2:', p4(d)['conflicted'], d['active']['toast'])
assert p4(d)['conflicted'] == []
k('continueOp')
d = settle(lambda d: d['active']['operation'] == '' and p4(d)['operationFinish'].startswith('Rebase finished'), label='the rebase finished')
print('after continue:', d['active']['operation'], p4(d)['screen'], p4(d)['operationFinish'])
assert d['active']['operation'] == '' and p4(d)['operationFinish'].startswith('Rebase finished')
snap('conflicts-finished', mode)
print('   log:', git('log', '--oneline', '-5'))
assert git('rev-parse', 'HEAD~4') == git('rev-parse', 'develop')
k('undo')
d = settle(lambda d: git('rev-parse', 'HEAD') == head0, label='the undo'); show('undo', d['active'], ('head', 'toast'))
assert git('rev-parse', 'HEAD') == head0
# Abort path: rebase again, abort.
k('rebase', 'develop')
d = settle(lambda d: d['active']['operation'] == 'rebase' and p4(d)['screen'] == 'conflicts', label='the second rebase stopped')
assert d['active']['operation'] == 'rebase'
k('abortOp')
d = settle(lambda d: d['active']['operation'] == '' and git('rev-parse', 'HEAD') == head0 and p4(d)['screen'] == '', label='the abort')
a = d['active']; show('abort', a, ('head', 'toast', 'operation'))
assert a['operation'] == '' and git('rev-parse', 'HEAD') == head0 and a['phase4']['screen'] == ''
quit_app()
print('CONFLICT OK')
