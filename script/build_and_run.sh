#!/usr/bin/env bash
# Kill, build and launch Kaern.
#
#   ./script/build_and_run.sh                      build + launch
#   ./script/build_and_run.sh --verify             launch and check the process is running
#   ./script/build_and_run.sh --logs               launch and stream the app's logs
#   ./script/build_and_run.sh --telemetry          launch and stream the app's subsystem logs
#   ./script/build_and_run.sh --debug              run under lldb
#   ./script/build_and_run.sh --test [options]     run the KaernKit tests (swift test)
#
# The app is signed with the Developer ID Application certificate in your keychain when there is one, as
# script/release.sh does, or with KAERN_SIGN_IDENTITY ("-" signs to run locally). macOS knows an app by its
# signature: signed to run locally, each build is a new app to it, so it asks again for Documents and other
# protected folders; signed with the certificate, every build is the same app as the Kaern you installed.
#
# Debug builds also accept -KaernSessionFile <path> (use a test session instead of
# ~/Library/Application Support/Kaern/Session.json) and -KaernAppearance dark|light, e.g.
# `run -KaernSessionFile /tmp/test-session.json -KaernAppearance dark`. Launched with a test
# session (and only then), they listen for debug commands (see Kaern/App/DebugDriver.swift),
# posted as the distributed notification com.progresshans.kaern.debug, e.g.
# `snapshot /tmp/window.png` renders the window to a PNG.
set -euo pipefail

MODE="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi

APP_NAME="Kaern"
BUNDLE_ID="com.progresshans.kaern"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/build"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"

if [[ "$MODE" == "--test" || "$MODE" == "test" ]]; then
  # The integration tests run Apple's git. Its behavior and the active toolchain matter in CI failures.
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    sw_vers
    uname -m
    xcodebuild -version
    swift --version
    /usr/bin/git --version
  fi
  cd "$ROOT_DIR/Packages/KaernKit"
  export NSUnbufferedIO=YES
  exec swift test "$@"
fi

if pkill -x "$APP_NAME" >/dev/null 2>&1; then
  echo "Quit the running $APP_NAME."
fi

SIGN_IDENTITY="${KAERN_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; exit }')" || true
fi
SIGNING=()
if [[ -n "$SIGN_IDENTITY" && "$SIGN_IDENTITY" != "-" ]]; then
  TEAM="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$SIGN_IDENTITY")"
  if [[ -z "$TEAM" ]]; then
    echo "Couldn't read the team ID from \"$SIGN_IDENTITY\"" >&2
    exit 1
  fi
  SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM")
  echo "Signing with your ${SIGN_IDENTITY%%:*} certificate (team $TEAM), so macOS remembers the folders you let $APP_NAME open."
else
  echo "Signing to run locally, so macOS asks again for Documents and other protected folders after each build."
fi

# -quiet keeps xcodebuild silent until it's done, so say what's going on.
echo "Building $APP_NAME (Debug)… This can take a minute or two, and only warnings and errors print until it's done."
SECONDS=0
xcodebuild \
  -project "$ROOT_DIR/Kaern.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_DATA" \
  -quiet \
  ${SIGNING[@]+"${SIGNING[@]}"} \
  build
echo "Built in ${SECONDS}s."

open_app() {
  echo "Opening $APP_NAME."
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
