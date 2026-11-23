"""The start window (WelcomeWindowController): the only window while no repository is open — at launch with
nothing to reopen, after the last tab closes, from New Window — and what opens in it becomes a main window."""
import os, sys; sys.path.insert(0, os.path.dirname(__file__))
from k4 import *


def welcome_picture(name):
    """The start window, by its title (it isn't a main window, so `snapshot` doesn't take it)."""
    path = os.path.join(SHOTS, 'app-%s-%s.png' % (name, mode()))
    os.makedirs(SHOTS, exist_ok=True)
    if os.path.exists(path): os.remove(path)
    end = time.time() + 15
    while time.time() < end:
        k('snapshotWindow', path, 'Welcome', 'to', 'Kaern')
        start = time.time()
        while time.time() - start < 0.5:
            if os.path.exists(path) and os.path.getsize(path) > 0: return path
            time.sleep(0.02)
    raise SystemExit('no picture of the start window')


launch('light', 'base')
# On launch › Show the welcome window: last time's 11 tabs wait behind Reopen, and no main window opens.
set_setting('KaernOnLaunch', 'welcome')
quit_app()
d = relaunch()
print('relaunch:', len(d['windows']), 'main windows, welcome', d['welcome'], 'lastClosedTabs', d['lastClosedTabs'])
assert not d['windows'] and d['welcome']['open'] and d['lastClosedTabs'] == 11
print('picture:', welcome_picture('welcome-reopen'))

# A repository opened there makes a main window with it, and the start window goes.
k('open', os.path.join(SAMPLES, 'powerlens'))
d = settle(lambda d: [[t['name'] for t in w['tabs']] for w in d['windows']] == [['powerlens']] and not d['welcome']['open'],
           label='powerlens in a main window')
print('opened:', [[t['name'] for t in w['tabs']] for w in d['windows']])

# Its last tab closes: the window goes, and the start window comes back with that tab behind Reopen.
k('close', 'powerlens')
d = until(lambda d: not d['windows'] and d['welcome']['open'] and d['lastClosedTabs'] == 1, label='the start window after the last tab')
print('last tab closed:', d['welcome'], 'lastClosedTabs', d['lastClosedTabs'])

# Clone from the start window: the sheet is the start window's.
k('clone', 'https://github.com/example/demo.git')
until(lambda d: d['welcome']['sheet'] == 'clone', label='the Clone sheet in the start window')
print('picture:', welcome_picture('welcome-clone'))
k('windowSheetClose')
until(lambda d: d['welcome']['sheet'] == '', label='the Clone sheet closed')

# Reopen: the tab in a main window again.
k('reopenLastSession')
d = settle(lambda d: [[t['name'] for t in w['tabs']] for w in d['windows']] == [['powerlens']] and not d['welcome']['open'],
           label='Reopen')

# New Window: the start window; what opens there is a second main window.
k('newWindow')
until(lambda d: d['welcome']['open'] and len(d['windows']) == 1, label='the start window from New Window')
k('open', os.path.join(SAMPLES, 'orders-api'))
d = settle(lambda d: len(d['windows']) == 2 and not d['welcome']['open'], label='a second main window')
print('two windows:', [[t['name'] for t in w['tabs']] for w in d['windows']])

# Reopen at launch (the default again): both windows, and no start window.
set_setting('KaernOnLaunch', None)
quit_app()
d = relaunch()
assert len(d['windows']) == 2 and not d['welcome']['open'], d['welcome']
quit_app()
print('WELCOME OK')
