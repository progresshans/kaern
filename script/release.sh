#!/bin/bash
# script/release.sh — a Kaern release made on this Mac: the app signed with your Developer ID and notarized, in a
# DMG (to download) and a ZIP (for Sparkle), and the appcast entry that offers it as an update.
#
#   script/release.sh keys                    once: the EdDSA key that signs updates (kept in your login keychain;
#                                             its public half goes into Packaging/Info.plist)
#   script/release.sh                         a release of the version in the project (MARKETING_VERSION)
#   script/release.sh --skip-notarization     the same, signed but not sent to Apple and not in the appcast (a try)
#
# Settings: the environment or .env (.env.example lists them). The whole procedure: Packaging/README.md.
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
REPOSITORY="${KAERN_GITHUB_REPOSITORY:-progresshans/kaern}"
NOTARY_PROFILE="${KAERN_NOTARY_PROFILE:-progresshans-notary}"
KEY_ACCOUNT="${KAERN_SPARKLE_KEY_ACCOUNT:-kaern}"
SIGN_IDENTITY="${KAERN_SIGN_IDENTITY:-}"

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
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -v key="$1" '$1 == key && $2 == "=" { print $3; exit }'
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

keys() {
  local tool public
  tool="$(sparkle_tool generate_keys)"
  # The first time it makes the key in your login keychain (macOS may ask to allow that); after that it finds it.
  "$tool" --account "$KEY_ACCOUNT"
  public="$("$tool" --account "$KEY_ACCOUNT" -p)"
  [[ -n "$public" ]] || fail "generate_keys printed no public key"
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $public" "$INFO_PLIST"
  printf '\nPackaging/Info.plist: SUPublicEDKey = %s\nCommit it. The private key stays in your keychain (account "%s"); back it up with\n  %s --account %s -x <file>\n' \
    "$public" "$KEY_ACCOUNT" "$tool" "$KEY_ACCOUNT"
}

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

release() {
  local skip_notarization="$1"
  if [[ -n "$(git status --porcelain)" ]]; then
    [[ "$skip_notarization" == 1 ]] || fail "commit or put aside your changes first: a release is built from a commit"
    printf 'release: a try with uncommitted changes\n'
  fi

  local version build public_key
  version="$(build_setting MARKETING_VERSION)"
  build="$(build_setting CURRENT_PROJECT_VERSION)"
  [[ -n "$version" && -n "$build" ]] || fail "couldn't read MARKETING_VERSION and CURRENT_PROJECT_VERSION"
  public_key="$(plist_value SUPublicEDKey "$INFO_PLIST")"
  if [[ -z "$public_key" ]]; then
    [[ "$skip_notarization" == 1 ]] || fail "Packaging/Info.plist has no SUPublicEDKey: run script/release.sh keys first"
    printf 'release: a try without SUPublicEDKey (that app won\x27t take updates)\n'
  fi
  if [[ "$skip_notarization" == 0 ]]; then
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "MARKETING_VERSION is $version: use three numbers, as in 1.0.1"
    [[ "$build" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION is $build: use a whole number"
    if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
      fail "v$version is tagged already: raise MARKETING_VERSION (and CURRENT_PROJECT_VERSION) first"
    fi
    # Sparkle offers an update only when its build number (CFBundleVersion) is higher than the installed one's.
    local published
    published="$(published_build docs/appcast.xml)"
    if [[ -n "$published" ]] && (( build <= published )); then
      fail "build $build isn't higher than the newest in docs/appcast.xml ($published): raise CURRENT_PROJECT_VERSION"
    fi
  fi

  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
  fi
  [[ -n "$SIGN_IDENTITY" ]] || fail "no Developer ID Application certificate in your keychain"
  local team
  team="$(sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p' <<<"$SIGN_IDENTITY")"
  [[ -n "$team" ]] || fail "couldn't read the team ID from \"$SIGN_IDENTITY\""

  local out="$ROOT/release/$version" notes=""
  rm -rf "$out"
  mkdir -p "$out"
  local app="$out/export/$APP_NAME.app" zip="$out/$APP_NAME-$version.zip" dmg="$out/$APP_NAME-$version.dmg"

  say "Archiving $APP_NAME $version ($build) at $(git rev-parse --short HEAD), signed by $SIGN_IDENTITY"
  if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -derivedDataPath "$DERIVED" \
      -archivePath "$out/$APP_NAME.xcarchive" archive \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp \
      >"$out/archive.log" 2>&1; then
    tail -30 "$out/archive.log"
    fail "the archive failed (release/$version/archive.log)"
  fi

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
  if ! xcodebuild -exportArchive -archivePath "$out/$APP_NAME.xcarchive" -exportPath "$out/export" \
      -exportOptionsPlist "$out/ExportOptions.plist" >"$out/export.log" 2>&1; then
    tail -30 "$out/export.log"
    fail "the export failed (release/$version/export.log)"
  fi

  say "Checking the app"
  codesign --verify --deep --strict --verbose=2 "$app"
  local details
  details="$(codesign -dv --verbose=4 "$app" 2>&1)"
  grep -q 'flags=.*runtime' <<<"$details" || fail "the app isn't signed with the hardened runtime"
  grep -q '^Timestamp=' <<<"$details" || fail "the app's signature has no secure timestamp"
  grep -q "Authority=Developer ID Application" <<<"$details" || fail "the app isn't signed with a Developer ID"
  [[ "$(plist_value CFBundleShortVersionString "$app/Contents/Info.plist")" == "$version" ]] || fail "the app's version isn't $version"
  [[ "$(plist_value SUPublicEDKey "$app/Contents/Info.plist")" == "$public_key" ]] || fail "the app's SUPublicEDKey isn't the one in Packaging/Info.plist"

  if [[ "$skip_notarization" == 0 ]]; then
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
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
  codesign --verify --verbose=2 "$dmg"
  if [[ "$skip_notarization" == 0 ]]; then
    say "Notarizing the DMG"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
  fi
  (cd "$out" && shasum -a 256 "$(basename "$dmg")" "$(basename "$zip")" >SHA256SUMS)

  if [[ "$skip_notarization" == 0 ]]; then
    say "Adding $version to the appcast (docs/appcast.xml)"
    local work="$ROOT/release/appcast"
    rm -rf "$work"
    mkdir -p "$work"
    if [[ -f docs/appcast.xml ]]; then cp docs/appcast.xml "$work/appcast.xml"; fi
    cp "$zip" "$work/"
    notes="$ROOT/release/notes/$version.md"
    if [[ -f "$notes" ]]; then cp "$notes" "$work/$APP_NAME-$version.md"; else notes=""; fi
    "$(sparkle_tool generate_appcast)" --account "$KEY_ACCOUNT" --embed-release-notes \
      --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$version/" "$work"
    signed_in_appcast "$work/appcast.xml" "$(basename "$zip")" \
      || fail "the appcast's entry for $version isn't signed: is the key in your keychain (account \"$KEY_ACCOUNT\") the one in Packaging/Info.plist?"
    [[ "$(published_build "$work/appcast.xml")" == "$build" ]] || fail "the appcast doesn't offer build $build"
    mkdir -p docs
    cp "$work/appcast.xml" docs/appcast.xml
  else
    say "Appcast: left alone (a build that isn't notarized isn't offered as an update)"
  fi

  say "Done: release/$version"
  ls -lh "$dmg" "$zip"
  cat "$out/SHA256SUMS"
  if [[ "$skip_notarization" == 0 ]]; then
    cat <<NEXT

Next, in this order (the appcast must not point at files that aren't up yet):
  git tag v$version && git push origin main v$version
  gh release create v$version "$dmg" "$zip" --title "$APP_NAME $version" ${notes:+--notes-file "$notes"}
  git add docs/appcast.xml && git commit -m "Offer $version as an update" && git push origin main
NEXT
  fi
}

case "${1:-}" in
  keys) keys ;;
  --skip-notarization) release 1 ;;
  "") release 0 ;;
  *) fail "usage: script/release.sh [keys | --skip-notarization]" ;;
esac
