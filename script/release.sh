#!/bin/bash
# script/release.sh — Kaern's release build: the app signed with a Developer ID and notarized, in a DMG (to download)
# and a ZIP (for Sparkle), and the appcast entry that offers it as an update.
#
# Releases are made by GitHub Actions when a version tag (v1.0.1) is pushed (.github/workflows/release.yml), which
# runs this script. On a Mac it makes the same build and publishes nothing:
#
#   script/release.sh                      the version in the project (MARKETING_VERSION), signed and notarized
#   script/release.sh --skip-notarization  the same, not sent to Apple
#   script/release.sh --unsigned           the same without a Developer ID: signed ad hoc, not notarized
#   script/release.sh appcast              the appcast with that build added, signed with the update key
#                                          (release/<version>/appcast.xml; GitHub Actions puts it in docs/)
#   script/release.sh keys                 once: the update key (EdDSA, kept in your login keychain; its public half
#                                          goes into Packaging/Info.plist)
#
# Settings: the environment or .env (.env.example lists them). GitHub Actions also sets KAERN_RELEASE_TAG,
# KAERN_PUBLISHED_APPCAST, KAERN_NOTARY_KEYCHAIN and KAERN_SPARKLE_KEY_FILE. The procedure: Packaging/README.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PROJECT="Kaern.xcodeproj"
SCHEME="Kaern"
APP_NAME="Kaern"
DERIVED="$ROOT/release/DerivedData"
INFO_PLIST="$ROOT/Packaging/Info.plist"
NOTES_DIR="$ROOT/Packaging/ReleaseNotes"
REPOSITORY="${KAERN_GITHUB_REPOSITORY:-progresshans/kaern}"
NOTARY_PROFILE="${KAERN_NOTARY_PROFILE:-progresshans-notary}"
NOTARY_KEYCHAIN="${KAERN_NOTARY_KEYCHAIN:-}"
KEY_ACCOUNT="${KAERN_SPARKLE_KEY_ACCOUNT:-kaern}"
KEY_FILE="${KAERN_SPARKLE_KEY_FILE:-}"
SIGN_IDENTITY="${KAERN_SIGN_IDENTITY:-}"
RELEASE_TAG="${KAERN_RELEASE_TAG:-}"
PUBLISHED_APPCAST="${KAERN_PUBLISHED_APPCAST:-$ROOT/docs/appcast.xml}"

say() { printf '\n== %s\n' "$*"; }
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }

# Sparkle's tools come with its package (resolved into the release's own DerivedData).
sparkle_tool() {
  local tool="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/$1"
  if [[ ! -x "$tool" ]]; then
    xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$DERIVED" >/dev/null
  fi
  [[ -x "$tool" ]] || fail "Sparkle's $1 isn't at $tool"
  printf '%s\n' "$tool"
}

build_setting() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -derivedDataPath "$DERIVED" \
    -showBuildSettings 2>/dev/null | awk -v key="$1" '$1 == key && $2 == "=" { print $3; exit }'
}

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true; }

# The highest build number (sparkle:version) an appcast offers; nothing when it offers none.
published_build() {
  [[ -f "$1" ]] || return 0
  grep -oE 'sparkle:version(>|=")[0-9]+' "$1" | grep -oE '[0-9]+$' | sort -n | tail -1 || true
}

# Whether an appcast's entry for an archive carries its EdDSA signature. generate_appcast leaves it out, with only
# a warning, when the app's SUPublicEDKey isn't the signing key's; Sparkle refuses such an update when installing.
signed_in_appcast() {
  local entry
  entry="$(grep -F "/$2\"" "$1" || true)"
  [[ "$entry" == *'sparkle:edSignature="'* ]]
}

notarize() {
  local args=(submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait)
  if [[ -n "$NOTARY_KEYCHAIN" ]]; then args+=(--keychain "$NOTARY_KEYCHAIN"); fi
  xcrun notarytool "${args[@]}"
}

keys() {
  local tool public
  tool="$(sparkle_tool generate_keys)"
  # The first time it makes the key in your login keychain (macOS may ask to allow that); after that it finds it.
  "$tool" --account "$KEY_ACCOUNT"
  public="$("$tool" --account "$KEY_ACCOUNT" -p)"
  [[ -n "$public" ]] || fail "generate_keys printed no public key"
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $public" "$INFO_PLIST"
  cat <<DONE

Packaging/Info.plist: SUPublicEDKey = $public
Commit it. The private key stays in your keychain (account "$KEY_ACCOUNT"). To put it in a file:
  $tool --account $KEY_ACCOUNT -x <file>
Paste the file's content into the release environment's SPARKLE_PRIVATE_KEY secret on GitHub, keep a copy somewhere
safe, and delete the file. Losing the key means installed copies can't take updates anymore.
DONE
}

# A release build. mode: release (Developer ID, notarized), try (Developer ID, not notarized), unsigned (ad hoc).
build() {
  local mode="$1"
  if [[ -n "$(git status --porcelain)" ]]; then
    [[ "$mode" != release ]] || fail "commit or put aside your changes first: a release is built from a commit"
    printf 'release: a try with uncommitted changes\n'
  fi

  local version build public_key notes
  version="$(build_setting MARKETING_VERSION)"
  build="$(build_setting CURRENT_PROJECT_VERSION)"
  [[ -n "$version" && -n "$build" ]] || fail "couldn't read MARKETING_VERSION and CURRENT_PROJECT_VERSION"
  public_key="$(plist_value SUPublicEDKey "$INFO_PLIST")"
  if [[ -z "$public_key" ]]; then
    [[ "$mode" != release ]] || fail "Packaging/Info.plist has no SUPublicEDKey: run script/release.sh keys first"
    printf 'release: a try without SUPublicEDKey (that app won\x27t take updates)\n'
  fi
  notes="$NOTES_DIR/$version.md"
  if [[ "$mode" == release ]]; then
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "MARKETING_VERSION is $version: use three numbers, as in 1.0.1"
    [[ "$build" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION is $build: use a whole number"
    if [[ -n "$RELEASE_TAG" && "$RELEASE_TAG" != "v$version" ]]; then
      fail "the tag is $RELEASE_TAG but MARKETING_VERSION is $version: tag v$version, or change the version"
    fi
    [[ -s "$notes" ]] || fail "no release notes: write Packaging/ReleaseNotes/$version.md (the update window and the GitHub release show it)"
    # Sparkle offers an update only when its build number (CFBundleVersion) is higher than the installed one's.
    local published
    published="$(published_build "$PUBLISHED_APPCAST")"
    if [[ -n "$published" ]] && (( build <= published )); then
      fail "build $build isn't higher than the newest in the appcast ($published): raise CURRENT_PROJECT_VERSION"
    fi
  fi

  local team=""
  if [[ "$mode" != unsigned ]]; then
    if [[ -z "$SIGN_IDENTITY" ]]; then
      SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
    fi
    [[ -n "$SIGN_IDENTITY" ]] || fail "no Developer ID Application certificate in your keychain (--unsigned builds without one)"
    team="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$SIGN_IDENTITY")"
    [[ -n "$team" ]] || fail "couldn't read the team ID from \"$SIGN_IDENTITY\""
  fi

  local out="$ROOT/release/$version"
  rm -rf "$out"
  mkdir -p "$out"
  local archive="$out/$APP_NAME.xcarchive" app zip="$out/$APP_NAME-$version.zip" dmg="$out/$APP_NAME-$version.dmg"
  local signing=()
  if [[ "$mode" == unsigned ]]; then
    say "Archiving $APP_NAME $version ($build) at $(git rev-parse --short HEAD), signed ad hoc"
  else
    say "Archiving $APP_NAME $version ($build) at $(git rev-parse --short HEAD), signed by $SIGN_IDENTITY"
    signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp)
  fi
  if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -derivedDataPath "$DERIVED" \
      -archivePath "$archive" archive ${signing[@]+"${signing[@]}"} >"$out/archive.log" 2>&1; then
    tail -30 "$out/archive.log"
    fail "the archive failed (release/$version/archive.log)"
  fi

  if [[ "$mode" == unsigned ]]; then
    app="$archive/Products/Applications/$APP_NAME.app"
    [[ -d "$app" ]] || fail "the archive has no $APP_NAME.app"
  else
    say "Exporting for Developer ID"
    cat >"$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>teamID</key>
	<string>$team</string>
</dict>
</plist>
PLIST
    if ! xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out/export" \
        -exportOptionsPlist "$out/ExportOptions.plist" >"$out/export.log" 2>&1; then
      tail -30 "$out/export.log"
      fail "the export failed (release/$version/export.log)"
    fi
    app="$out/export/$APP_NAME.app"
  fi

  say "Checking the app"
  codesign --verify --deep --strict --verbose=2 "$app"
  [[ "$(plist_value CFBundleShortVersionString "$app/Contents/Info.plist")" == "$version" ]] || fail "the app's version isn't $version"
  [[ "$(plist_value CFBundleVersion "$app/Contents/Info.plist")" == "$build" ]] || fail "the app's build number isn't $build"
  [[ "$(plist_value SUPublicEDKey "$app/Contents/Info.plist")" == "$public_key" ]] || fail "the app's SUPublicEDKey isn't the one in Packaging/Info.plist"
  if [[ "$mode" != unsigned ]]; then
    local details
    details="$(codesign -dv --verbose=4 "$app" 2>&1)"
    grep -q 'flags=.*runtime' <<<"$details" || fail "the app isn't signed with the hardened runtime"
    grep -q '^Timestamp=' <<<"$details" || fail "the app's signature has no secure timestamp"
    grep -q "Authority=Developer ID Application" <<<"$details" || fail "the app isn't signed with a Developer ID"
  fi

  if [[ "$mode" == release ]]; then
    say "Notarizing the app (profile \"$NOTARY_PROFILE\")"
    ditto -c -k --keepParent "$app" "$out/notarize.zip"
    notarize "$out/notarize.zip"
    rm -f "$out/notarize.zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
  fi

  say "Packaging"
  # For Sparkle: the app (stapled) in a ZIP.
  ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
  # To download: a DMG with the app and a link to Applications.
  local stage="$out/dmg"
  mkdir -p "$stage"
  ditto "$app" "$stage/$APP_NAME.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "$APP_NAME $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
  rm -rf "$stage"
  if [[ "$mode" != unsigned ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
    codesign --verify --verbose=2 "$dmg"
  fi
  if [[ "$mode" == release ]]; then
    say "Notarizing the DMG"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    cp "$notes" "$out/notes.md"
  fi
  (cd "$out" && shasum -a 256 "$(basename "$dmg")" "$(basename "$zip")" >SHA256SUMS)

  say "Done: release/$version"
  ls -lh "$dmg" "$zip"
  cat "$out/SHA256SUMS"
  if [[ "$mode" == release && -z "$RELEASE_TAG" ]]; then
    printf '\nNothing is published from here: GitHub Actions releases %s when the tag v%s is pushed.\n' "$version" "$version"
  fi
}

# The published appcast with the built version added, its entry signed with the update key.
appcast() {
  local version build
  version="$(build_setting MARKETING_VERSION)"
  build="$(build_setting CURRENT_PROJECT_VERSION)"
  [[ -n "$version" && -n "$build" ]] || fail "couldn't read MARKETING_VERSION and CURRENT_PROJECT_VERSION"
  local out="$ROOT/release/$version"
  local zip="$out/$APP_NAME-$version.zip"
  [[ -f "$zip" ]] || fail "there's no release/$version/$APP_NAME-$version.zip: build it first (script/release.sh)"

  say "Adding $version ($build) to the appcast"
  local work="$out/appcast-work"
  rm -rf "$work"
  mkdir -p "$work"
  if [[ -f "$PUBLISHED_APPCAST" ]]; then cp "$PUBLISHED_APPCAST" "$work/appcast.xml"; fi
  cp "$zip" "$work/"
  if [[ -f "$NOTES_DIR/$version.md" ]]; then cp "$NOTES_DIR/$version.md" "$work/$APP_NAME-$version.md"; fi
  local signing=(--account "$KEY_ACCOUNT")
  local key_name="the keychain's \"$KEY_ACCOUNT\" key"
  if [[ -n "$KEY_FILE" ]]; then
    signing=(--ed-key-file "$KEY_FILE")
    key_name="the key in $KEY_FILE"
  fi
  "$(sparkle_tool generate_appcast)" "${signing[@]}" --embed-release-notes \
    --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$version/" "$work"
  signed_in_appcast "$work/appcast.xml" "$(basename "$zip")" \
    || fail "the appcast's entry for $version isn't signed: $key_name isn't the one whose public half is in the app"
  [[ "$(published_build "$work/appcast.xml")" == "$build" ]] || fail "the appcast's newest build isn't $build"
  cp "$work/appcast.xml" "$out/appcast.xml"
  say "Done: release/$version/appcast.xml"
}

case "${1:-}" in
  "") build release ;;
  --skip-notarization) build try ;;
  --unsigned) build unsigned ;;
  appcast) appcast ;;
  keys) keys ;;
  *) fail "usage: script/release.sh [--skip-notarization | --unsigned | appcast | keys]" ;;
esac
