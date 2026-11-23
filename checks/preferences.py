"""A native macOS preferences domain for each flow-check session, archived beside its session file."""
import fcntl
import os
import plistlib
import subprocess
import uuid
from pathlib import Path


def _id(session):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, os.path.realpath(session)))


def _defaults(action, session, *args, data=None, check=True):
    domain = 'com.progresshans.kaern.check.' + _id(session)
    return subprocess.run(['/usr/bin/defaults', action, domain, *args], input=data, capture_output=True, check=check)


def open_session(session):
    session = Path(session)
    marker = session.with_suffix('.check-prefs')
    if not marker.exists():
        snapshot = session.with_suffix('.settings.plist')
        data = snapshot.read_bytes() if snapshot.exists() else plistlib.dumps({})
        _defaults('import', session, '-', data=data)
        marker.touch()
    return _id(session)


def saved_settings(session):
    """Read the persistent domain independently of the app's cached values and launch arguments."""
    session = Path(session)
    if session.with_suffix('.check-prefs').exists():
        return plistlib.loads(_defaults('export', session, '-').stdout)
    snapshot = session.with_suffix('.settings.plist')
    return plistlib.loads(snapshot.read_bytes()) if snapshot.exists() else {}


def archive_session(session):
    """Called after the session's last process exits. Keep the marker if export or cleanup fails."""
    session = Path(session)
    marker = session.with_suffix('.check-prefs')
    try:
        lock = marker.open('rb')
    except FileNotFoundError:
        return
    # Interrupting the suite can start cleanup in both the worker and the suite itself.
    with lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not marker.exists(): return
        data = _defaults('export', session, '-').stdout
        values = plistlib.loads(data)
        snapshot = session.with_suffix('.settings.plist')
        temporary = snapshot.with_suffix('.plist.tmp')
        temporary.write_bytes(data)
        os.replace(temporary, snapshot)
        # macOS can already have removed an empty domain.
        _defaults('delete', session, check=bool(values))
        marker.unlink()


def archive_in(folder, pattern='*.check-prefs'):
    for marker in Path(folder).glob(pattern):
        archive_session(marker.with_suffix('.json'))
