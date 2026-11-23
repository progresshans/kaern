#!/bin/bash
# checks/build.sh [xcodebuild settings…] — the Debug build of Kaern that the flow checks start, into the checks' work
# folder (paths.py). It is apart from the build you run yourself: script/build_and_run.sh builds into build/, and a
# build there would replace the app you have open.
#
# Signed to run locally, which needs no certificate. The checks keep their samples in the temporary folder, where
# macOS asks nothing before an app reads them.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(python3 checks/paths.py work)"
echo "Building Kaern (Debug) into $WORK/DerivedData…"
xcodebuild build -project Kaern.xcodeproj -scheme Kaern -configuration Debug \
  -destination "platform=macOS,arch=arm64" -derivedDataPath "$WORK/DerivedData" -quiet "$@"
echo "Built $WORK/DerivedData/Build/Products/Debug/Kaern.app"
