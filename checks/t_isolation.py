import json, os, re, subprocess, sys, time; sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
# A launcher that forgets GIT_CONFIG_GLOBAL (no `open --env`): the test instance must still keep
# git's global config and credentials next to its own session file, never ~/.gitconfig or the Keychain.
SESSION = fresh_run()
STEM = SESSION[:-len('.json')]
samples.install('base', SAMPLES)
write_session(SESSION)
real = os.path.expanduser('~/.gitconfig'); real_before = os.stat(real).st_mtime
start_app('light', columns=False, git_config=False)
d = wait_launched()
genv = d['gitConfigEnvironment']; print('git config environment:', genv)
assert genv.get('GIT_CONFIG_GLOBAL') == STEM + '.gitconfig'
assert '' in genv.values() and any(v.startswith('store --file=') for v in genv.values())
print('session gitconfig:', open(STEM + '.gitconfig').read().replace('\n', ' | '))
k('summary', 'Isolation check commit'); k('commit')
settle(lambda d: git('log', '-1', '--format=%s') == 'Isolation check commit', label='the commit')
last = git('log', '-1', '--format=%an <%ae> · %s'); print('last commit:', last)
assert last.startswith('Kaern Test <test@kaern.invalid>')
k('settings', 'Git')
until(lambda d: window_open(d, ' Git'), label='the Settings window on Git')
snap('isolation-settings-git', window='Git')
k('settings', 'close')
until(lambda d: not window_open(d, ' Git'), label='the Settings window closed')
kill_app()
assert os.stat(real).st_mtime == real_before
print('ISOLATION OK')
