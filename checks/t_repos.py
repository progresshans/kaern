"""t_repos.py [light|dark] — Window › Repositories: sections by group and Recent, Needs Attention (behind,
sign-in trouble, conflicts, missing folder), the inline fix (Pull), and opening a repository from the list."""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
from scen5 import diverge, run
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
ORDERS = os.path.join(SAMPLES, 'orders-api')

def prepare():
    diverge('orders-api', 5, 2)
    diverge('weather-dashboard-app', 0, 1)
    # recipe-app's folder goes away: the list says so and offers Locate….
    subprocess.run(['mv', os.path.join(SAMPLES, 'recipe-app'), os.path.join(SAMPLES, 'recipe-app-moved')], check=True)

def rows(d): return {row.split(' | ')[0]: row for s in d['phase5']['repositories']['sections'] for row in s['rows']}

launch_prepared(mode, prepare=prepare)
k('fakeFetchProblem', 'CRM', 'signIn', 'gitlab.com')
k('repositories')
# The window is up and each row says what its repository needs.
d = settle(lambda d: d['phase5']['repositories']['open'] and 'Diverged' in rows(d)['orders-api'] and '1 commit to pull' in rows(d)['weather-dashboard-app']
           and 'Sign in to gitlab.com' in rows(d)['CRM'] and 'Folder not found' in rows(d)['recipe-app'], label='the Repositories window')
r = d['phase5']['repositories']; print('sections:', [(s['name'], len(s['rows'])) for s in r['sections']])
for name in ('orders-api', 'weather-dashboard-app', 'CRM', 'recipe-app'):
    print('  ', rows(d).get(name, name + ' — missing'))
snap('repos', mode, composite=True)
k('reposAttention', 'on')
d = until(lambda d: {'orders-api', 'CRM', 'recipe-app'} <= set(rows(d)) and 'travel-notes' not in rows(d), label='Needs Attention only')
attention = sorted(rows(d)); print('needs attention:', attention)
assert {'orders-api', 'CRM', 'recipe-app'} <= set(attention)
snap('repos-attention', mode, composite=True, changed=True)
k('reposAttention', 'off')
until(lambda d: 'travel-notes' in rows(d), label='every repository again')
# orders-api went apart from origin: its row's fix is Pull, which merges the 2 commits in.
k('reposFix', 'orders-api')
settle(lambda d: g(ORDERS, 'rev-list', '--left-right', '--count', 'HEAD...@{u}').split()[1] == '0', label='the Pull from the list')
counts = g(ORDERS, 'rev-list', '--left-right', '--count', 'HEAD...@{u}').split()
print('after Pull (ahead, behind):', counts)
assert counts[1] == '0', 'nothing left to pull'
k('reposOpen', 'orders-api')
d = settle(lambda d: active_name(d) == 'orders-api' and d['phase5']['phase'] == 'ready', label='orders-api opened from the list')
print('opened:', active_name(d)); assert active_name(d) == 'orders-api'
k('reposClose')
until(lambda d: not d['phase5']['repositories']['open'], label='the Repositories window closed')
subprocess.run(['mv', os.path.join(SAMPLES, 'recipe-app-moved'), os.path.join(SAMPLES, 'recipe-app')])
print('REPOS OK')
quit_app()
