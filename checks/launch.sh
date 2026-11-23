#!/bin/bash
# launch.sh <light|dark> [scenario] [extra args…] — fresh samples and a test instance of the Debug app in the
# background (never takes focus), on the run "manual" unless KAERN_RUN names another: its own samples, session,
# global git config and debug channel under <work folder>/runs/<run>/. Send it commands with
#   KAERN_RUN=manual python3 checks/k3.py <command…>
# It is on the screen and the mouse works in it (KAERN_POINTER=1); the checks keep theirs beside the screen and the
# real pointer out of them.
KAERN_RUN="${KAERN_RUN:-manual}" KAERN_POINTER="${KAERN_POINTER-1}" exec python3 "$(dirname "$0")/k4.py" launch "$@"
