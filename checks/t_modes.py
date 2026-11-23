"""t_modes.py [light|dark] — Settings › General › Switch repositories: Sidebar (list, folded rail, a missing folder)
and Toolbar (repository button and its popover), Icon and Text, and the narrow-window folding at 1,040 / 920 pt."""
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'

def layout(d): return d['phase5']['layout']

for switching in ('sidebar', 'toolbar'):
    launch_prepared(mode, extra=['-KaernRepositorySwitching', switching])
    d = show_tab('powerlens')
    x = layout(d); print(switching, 'mode:', x)
    assert x['switching'] == switching
    snap('mode-%s' % switching, mode)
    if switching == 'sidebar':
        k('listFold', 'on'); until(lambda d: layout(d)['listFolded'], label='the folded list')
        snap('mode-sidebar-rail', mode, changed=True)
        k('listFold', 'off'); until(lambda d: not layout(d)['listFolded'], label='the list again')
    else:
        k('repoPopover', 'on'); until(lambda d: layout(d)['repoPopover'] and window_open(d, 'Popover'), label='the repository popover')
        snap('mode-toolbar-popover', mode, composite=True, changed=True)
        k('repoPopover', 'off'); until(lambda d: not layout(d)['repoPopover'], label='the popover closed')
    quit_app()

# Tabs mode, narrow: the sidebar becomes a section rail with a flyout, the panel an overlay.
launch_prepared(mode)
show_tab('powerlens')
for width in (1040, 920):
    k('resize', str(width), '800')
    d = until(lambda d: layout(d)['width'] == width, label='the window %d wide' % width)
    print('width', layout(d)['width'])
    snap('narrow-%d' % width, mode, changed=True)
k('resize', '1040', '800'); k('flyout', 'local')
d = until(lambda d: layout(d)['width'] == 1040 and layout(d)['flyout'] == 'local', label='the Local flyout'); assert layout(d)['flyout'] == 'local'
snap('narrow-1040-flyout', mode, changed=True)
k('flyout', 'off'); until(lambda d: layout(d)['flyout'] == '', label='the flyout closed')
k('resize', '920', '800'); k('overlayPanel', 'on')
d = until(lambda d: layout(d)['width'] == 920 and layout(d)['overlayPanel'], label='the overlay panel'); assert layout(d)['overlayPanel']
snap('narrow-920-panel', mode, changed=True)
k('overlayPanel', 'off'); until(lambda d: not layout(d)['overlayPanel'], label='the panel closed')
print('MODES OK')
quit_app()
