#!/usr/bin/env bash
# Kill, build and launch Kaern.
#
#   ./script/build_and_run.sh                      build + launch
#   ./script/build_and_run.sh run -KaernOpen ~/src/repo   launch with a repository open
#   ./script/build_and_run.sh --verify             launch and check the process is running
#   ./script/build_and_run.sh --logs               launch and stream the app's logs
#   ./script/build_and_run.sh --telemetry          launch and stream the app's subsystem logs
#   ./script/build_and_run.sh --debug              run under lldb
#   ./script/build_and_run.sh --test               run the KaernKit tests (swift test)
#
# Debug builds also accept -KaernSelectCommit <sha prefix>, -KaernSelectFile <path> and
# -KaernAppearance dark|light, e.g. `run -KaernOpen ~/src/repo -KaernAppearance dark`.
set -euo pipefail

MODE="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi

APP_NAME="Kaern"
BUNDLE_ID="com.progresshans.kaern"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"

if [[ "$MODE" == "--test" || "$MODE" == "test" ]]; then
  cd "$ROOT_DIR/Packages/KaernKit"
  exec swift test
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

xcodebuild \
  -project "$ROOT_DIR/Kaern.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  build

open_app() {
  if [[ $# -gt 0 ]]; then
    /usr/bin/open -n "$APP_BUNDLE" --args "$@"
  else
    /usr/bin/open -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  run)
    open_app "$@"
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$@"
    ;;
  --logs|logs)
    open_app "$@"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app "$@"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app "$@"
    sleep 2
    if pgrep -x "$APP_NAME" >/dev/null; then
      echo "$APP_NAME is running"
    else
      echo "$APP_NAME did not start" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--test] [app arguments…]" >&2
    exit 2
    ;;
esac
