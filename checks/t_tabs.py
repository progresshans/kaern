"""t_tabs.py — the tab strip's bookkeeping: a group's only tab leaves the group in place, closing several tabs
makes the next one that stays the active tab, and tabs reopened after their group went come back into one group."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *

failures = []


def expect(label, got, want):
    ok = got == want
    print('%s %s: %s' % ('ok  ' if ok else 'FAIL', label, got if ok else '%s, expected %s' % (got, want)))
    if not ok: failures.append(label)


def strip(d):
    return [(t['name'], t['group']) for t in d['windows'][0]['tabs']]


d = launch_prepared('light')
start = strip(d)
names = [n for n, _ in start]
print('tabs:', start)

# 1. A group of one tab; taking the tab out of it leaves the tab where it is.
k('newGroup', 'Solo', 'powerlens')
d = until(lambda d: tab(d, 'powerlens')['group'] == 'Solo', label='powerlens in a group of its own')
expect('order with the new group', [n for n, _ in strip(d)], names)
k('removeFromGroup', 'powerlens')
d = until(lambda d: tab(d, 'powerlens')['group'] == '', label='powerlens out of the group')
expect('order after leaving the group', strip(d), start)
expect('the empty group is gone', [g['name'] for g in d['windows'][0]['groups'] if g['name'] == 'Solo'], [])

# 2. Closing the active tab together with one before it: the tab after the active one takes over.
show_tab('CRM')
k('close', 'powerlens', 'CRM')
d = settle(lambda d: tab(d, 'CRM') is None and tab(d, 'powerlens') is None, label='two tabs closed')
expect('active after closing powerlens + CRM', active_name(d), names[names.index('CRM') + 1])
# The active tab and everything after it: the last one that stays.
last = [n for n, _ in strip(d)]
show_tab(last[-2])
k('close', last[-2], last[-1])
d = settle(lambda d: tab(d, last[-1]) is None, label='the last two closed')
expect('active after closing the last two', active_name(d), last[-3])

# 3. Both tabs of a group closed one by one (the group goes with the second), then reopened.
group = tab(d, 'travel-notes')['group']
k('close', 'travel-notes')
until(lambda d: tab(d, 'travel-notes') is None, label='travel-notes closed')
k('close', 'travel-blog')
d = until(lambda d: tab(d, 'travel-blog') is None, label='travel-blog closed')
expect('the group went with its last tab', [g['name'] for g in d['windows'][0]['groups'] if g['name'] == group], [])
k('reopenClosedTab')
until(lambda d: tab(d, 'travel-blog') is not None, label='travel-blog back')
k('reopenClosedTab')
d = settle(lambda d: tab(d, 'travel-notes') is not None, label='travel-notes back')
expect('one group again', [g['name'] for g in d['windows'][0]['groups'] if g['name'] == group], [group])
expect('both tabs in it', sorted(n for n, g in strip(d) if g == group), ['travel-blog', 'travel-notes'])

quit_app()
if failures: raise SystemExit('failed: ' + ', '.join(failures))
print('t_tabs ok')
