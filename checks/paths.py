"""Where the checks work, and which app they start.

The work folder holds everything the checks make: each run's samples and session (runs/), the sample cache
(sample-cache/), the pictures (shots/), the suite's logs (suite/) and the app `build.sh` builds (DerivedData/).
It is in the temporary folder, one per checkout, unless KAERN_CHECKS_WORK names another. Not in the repository:
macOS asks before an app reads a folder such as Documents, and a test instance has nobody to answer. Its path
can't have a space (the driver splits a command at spaces).

The app is the Debug build in the work folder, unless KAERN_APP names another Kaern.app.

    python3 paths.py [work|app]     prints them
"""
import hashlib, os, sys, tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
WORK = os.path.realpath(os.environ.get('KAERN_CHECKS_WORK')
                        or os.path.join(tempfile.gettempdir(), 'kaern-checks-' + hashlib.sha1(REPO.encode()).hexdigest()[:8]))
APP = os.environ.get('KAERN_APP') or os.path.join(WORK, 'DerivedData', 'Build', 'Products', 'Debug', 'Kaern.app')

# How long a check waits before it gives up, times this: KAERN_PATIENCE=3 on a slow Mac, such as GitHub's. The checks
# wait for a state, not for a time, so only a check that fails takes longer.
PATIENCE = float(os.environ.get('KAERN_PATIENCE') or 1)

if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else ''
    print({'work': WORK, 'app': APP}.get(what) or 'work  %s\napp   %s' % (WORK, APP))
