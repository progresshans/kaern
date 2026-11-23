"""t_narrow760.py [light|dark] — the narrowest window (760 pt, and 800) in both toolbar styles: nothing spills out
of the toolbar or the status bar (Icon and Text folds into » More)."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from k5 import *
mode = sys.argv[1] if len(sys.argv) > 1 else 'light'
for style in ('iconOnly', 'iconAndText'):
    launch_prepared(mode, extra=['-KaernToolbarStyle', style])
    show_tab('powerlens')
    for width in (760, 800):
        k('resize', str(width), '700')
        d = until(lambda d: abs(d['phase5']['layout']['width'] - width) < 1, label='the window %d wide' % width)
        w = d['phase5']['layout']['width']; print(style, 'at', width, '→ window', w)
        assert abs(w - width) < 1, 'the window can be that narrow'
        snap('narrow760-%s-%d' % (style, width), mode, changed=True)
    quit_app()
print('NARROW 760 OK')
