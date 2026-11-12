#!/bin/bash
# script/release.sh — Kaern's release build: the app signed with a Developer ID and notarized, in a DMG (to download)
# and a ZIP (for Sparkle), and the appcast entry that offers it as an update.
#
# Releases are made by GitHub Actions when a version tag is pushed (.github/workflows/release.yml), which runs this
# script: v1.1.0 makes a release, v1.1.0-beta.2 a beta. On a Mac it makes the same build and publishes nothing:
#
#   script/release.sh                      signed and notarized
#   script/release.sh --skip-notarization  the same, not sent to Apple
#   script/release.sh --unsigned           the same without a Developer ID: signed ad hoc, not notarized
#   script/release.sh appcast              the appcast with that build added, signed with the update key
#                                          (release/<version>/appcast.xml; GitHub Actions publishes it on gh-pages)
#   script/release.sh notes [<version>]    the notes the update window and the GitHub release would show
#   script/release.sh keys                 once: the update key (EdDSA, kept in your login keychain; its public half
#                                          goes into Packaging/Info.plist)
#
# The version is KAERN_VERSION (GitHub Actions sets it from the tag), or else the project's MARKETING_VERSION; its build
# number comes from it (build_number). Other settings: the environment or .env (.env.example lists them). GitHub
# Actions also sets KAERN_NOTARY_KEYCHAIN and KAERN_SPARKLE_KEY_FILE. The procedure: Packaging/README.md.
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
CHANGELOG="$ROOT/CHANGELOG.md"
PAGES_BRANCH="gh-pages"
REPOSITORY="${KAERN_GITHUB_REPOSITORY:-progresshans/kaern}"
NOTARY_PROFILE="${KAERN_NOTARY_PROFILE:-progresshans-notary}"
NOTARY_KEYCHAIN="${KAERN_NOTARY_KEYCHAIN:-}"
KEY_ACCOUNT="${KAERN_SPARKLE_KEY_ACCOUNT:-kaern}"
KEY_FILE="${KAERN_SPARKLE_KEY_FILE:-}"
SIGN_IDENTITY="${KAERN_SIGN_IDENTITY:-}"
VERSION="${KAERN_VERSION:-}"
PUBLISHED_APPCAST="${KAERN_PUBLISHED_APPCAST:-}"

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

# A release's version: three numbers (1.1.0), and for a beta its number (1.1.0-beta.2).
VERSION_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.([1-9][0-9]*))?$'

# The build number (CFBundleVersion) of a release's version. Sparkle offers an update when its build number is higher
# than the installed one's, so the numbers follow the versions: 1.1.0-beta.2 is 1010002 and 1.1.0 is 1010099, after
# its betas and before 1.1.1 (1010199) and 1.2.0's betas (1020001). Fails for a version that isn't a release's, or
# that has a minor or patch number over 99 or a beta number over 98.
build_number() {
  [[ "$1" =~ $VERSION_PATTERN ]] || return 1
  local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}" patch="${BASH_REMATCH[3]}" beta="${BASH_REMATCH[5]}"
  (( ${#major} <= 4 && ${#minor} <= 2 && ${#patch} <= 2 )) || return 1
  if [[ -n "$beta" ]]; then
    (( ${#beta} <= 2 && beta <= 98 )) || return 1
  else
    beta=99
  fi
  printf '%s\n' "$(( major * 1000000 + minor * 10000 + patch * 100 + beta ))"
}

# The version a build number stands for (build_number's reverse), to name it in messages.
version_of_build() {
  local version="$(( $1 / 1000000 )).$(( $1 / 10000 % 100 )).$(( $1 / 100 % 100 ))"
  if (( $1 % 100 == 99 )); then
    printf '%s\n' "$version"
  else
    printf '%s-beta.%s\n' "$version" "$(( $1 % 100 ))"
  fi
}

is_beta() { [[ "$1" == *-beta.* ]]; }

# The version to build: KAERN_VERSION, or the project's MARKETING_VERSION.
release_version() {
  local version="$VERSION"
  if [[ -z "$version" ]]; then version="$(build_setting MARKETING_VERSION)"; fi
  [[ -n "$version" ]] || fail "couldn't read MARKETING_VERSION"
  printf '%s\n' "$version"
}

# The lines under a heading of CHANGELOG.md, without the blank lines around them: "## [1.1.0] - 2026-12-01" (or
# "## 1.1.0") for 1.1.0, "## [Unreleased]" for Unreleased.
changelog_section() {
  [[ -f "$CHANGELOG" ]] || return 0
  awk -v want="$1" '
    /^## / {
      if (found) exit
      name = $0
      sub(/^##[ \t]+\[?/, "", name)
      sub(/[] \t].*$/, "", name)
      found = (name == want)
      next
    }
    found { lines[++n] = $0 }
    END {
      first = 1
      while (first <= n && lines[first] ~ /^[ \t]*$/) first++
      last = n
      while (last >= first && lines[last] ~ /^[ \t]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "$CHANGELOG"
}

# The subjects of the commits since the last version tag (at most 30), for a beta with no notes of its own.
commits_since_last_tag() {
  local last range="HEAD" count
  last="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD^ 2>/dev/null || true)"
  if [[ -n "$last" ]]; then range="$last..HEAD"; fi
  count="$(git rev-list --no-merges --count "$range")"
  (( count > 0 )) || return 0
  if [[ -n "$last" ]]; then printf 'Changes since %s:\n\n' "${last#v}"; fi
  git log --no-merges -n 30 --format='- %s' "$range"
  if (( count > 30 )); then printf -- '- and %s more\n' "$(( count - 30 ))"; fi
}

# A release's notes, which the update window and the GitHub release show: its section of CHANGELOG.md. A beta without
# one shows [Unreleased], or else the commits since the last version tag.
release_notes() {
  local notes
  notes="$(changelog_section "$1")"
  if [[ -z "$notes" ]] && is_beta "$1"; then notes="$(changelog_section Unreleased)"; fi
  if [[ -z "$notes" ]] && is_beta "$1"; then notes="$(commits_since_last_tag)"; fi
  [[ -n "$notes" ]] || return 1
  printf '%s\n' "$notes"
}

# The appcast as published, in a file: KAERN_PUBLISHED_APPCAST, or the gh-pages branch as last fetched. Nothing before
# the first release (no gh-pages branch yet).
published_appcast() {
  if [[ -n "$PUBLISHED_APPCAST" ]]; then
    printf '%s\n' "$PUBLISHED_APPCAST"
    return 0
  fi
  git rev-parse -q --verify "refs/remotes/origin/$PAGES_BRANCH" >/dev/null || return 0
  local file="$ROOT/release/published-appcast.xml"
  mkdir -p "$ROOT/release"
  git show "origin/$PAGES_BRANCH:appcast.xml" >"$file" 2>/dev/null || fail "origin/$PAGES_BRANCH has no appcast.xml"
  printf '%s\n' "$file"
}

# The highest build number (sparkle:version) an appcast offers, in any channel; nothing when it offers none.
published_build() {
  [[ -f "$1" ]] || return 0
  grep -oE 'sparkle:version(>|=")[0-9]+' "$1" | grep -oE '[0-9]+$' | sort -n | tail -1 || true
}

# The channel of an appcast's item with a build number: "beta", or nothing for a release.
appcast_channel() {
  xmllint --xpath "string(//item[*[local-name()='version' and normalize-space()='$2']]/*[local-name()='channel'])" "$1"
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

# The DMG to download: the app and a link to Applications.
make_dmg() {
  local app="$1" dmg="$2" stage="$3"
  mkdir -p "$stage"
  ditto "$app" "$stage/$APP_NAME.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
  rm -rf "$stage"
}

# A release build. mode: release (Developer ID, notarized), try (Developer ID, not notarized), unsigned (ad hoc).
build() {
  local mode="$1"
  if [[ -n "$(git status --porcelain)" ]]; then
    [[ "$mode" != release ]] || fail "commit or put aside your changes first: a release is built from a commit"
    printf 'release: a try with uncommitted changes\n'
  fi

  local version build public_key notes
  version="$(release_version)"
  if ! build="$(build_number "$version")"; then
    [[ "$mode" != release ]] || fail "the version is $version: a release is 1.1.0 and a beta 1.1.0-beta.2 (minor and patch up to 99, betas up to 98)"
    build="$(build_setting CURRENT_PROJECT_VERSION)"
    printf 'release: a try of %s, which isn\x27t a release version: build %s\n' "$version" "$build"
  fi
  public_key="$(plist_value SUPublicEDKey "$INFO_PLIST")"
  if [[ -z "$public_key" ]]; then
    [[ "$mode" != release ]] || fail "Packaging/Info.plist has no SUPublicEDKey: run script/release.sh keys first"
    printf 'release: a try without SUPublicEDKey (that app won\x27t take updates)\n'
  fi
  notes="$(release_notes "$version" || true)"
  if [[ "$mode" == release ]]; then
    [[ -n "$notes" ]] || fail "CHANGELOG.md has no notes for $version: write them under \"## [$version] - <date>\" (the update window and the GitHub release show them)"
    # Sparkle offers an update only when its build number is higher than the installed one's.
    local published newest
    published="$(published_appcast)"
    newest="$(published_build "$published")"
    if [[ -n "$newest" ]] && (( build < newest )); then
      fail "$version isn't newer than $(version_of_build "$newest"), which the appcast already offers"
    elif [[ -n "$newest" ]] && (( build == newest )); then
      printf 'release: the appcast already offers %s: making it again\n' "$version"
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
  local settings=(MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build")
  if [[ "$mode" == unsigned ]]; then
    say "Archiving $APP_NAME $version ($build) at $(git rev-parse --short HEAD), signed ad hoc"
  else
    say "Archiving $APP_NAME $version ($build) at $(git rev-parse --short HEAD), signed by $SIGN_IDENTITY"
    settings+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$team" OTHER_CODE_SIGN_FLAGS=--timestamp)
  fi
  if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -derivedDataPath "$DERIVED" \
      -archivePath "$archive" archive "${settings[@]}" >"$out/archive.log" 2>&1; then
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
  # Apple silicon only (ARCHS in the project). Sparkle's framework stays universal, as it comes.
  local archs
  archs="$(lipo -archs "$app/Contents/MacOS/$APP_NAME")"
  [[ "$archs" == arm64 ]] || fail "the app is built for $archs: Kaern is built for Apple silicon (arm64) only"
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
  make_dmg "$app" "$dmg" "$out/dmg"
  if [[ "$mode" != unsigned ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
    codesign --verify --verbose=2 "$dmg"
  fi
  if [[ "$mode" == release ]]; then
    say "Notarizing the DMG"
    notarize "$dmg"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
  fi
  if [[ -n "$notes" ]]; then printf '%s\n' "$notes" >"$out/notes.md"; fi
  (cd "$out" && shasum -a 256 "$(basename "$dmg")" "$(basename "$zip")" >SHA256SUMS)

  say "Done: release/$version"
  ls -lh "$dmg" "$zip"
  cat "$out/SHA256SUMS"
  if [[ "$mode" == release && -z "${GITHUB_ACTIONS:-}" ]]; then
    printf '\nNothing is published from here: GitHub Actions releases %s when the tag v%s is pushed.\n' "$version" "$version"
  fi
}

# The published appcast with the built version added, its entry signed with the update key. A beta's entry is in the
# beta channel, which only copies with Settings › General › Updates › Get beta versions look at.
appcast() {
  local version build
  version="$(release_version)"
  build="$(build_number "$version")" || fail "the version is $version: only a release (1.1.0) or a beta (1.1.0-beta.2) goes in the appcast"
  local out="$ROOT/release/$version"
  local zip="$out/$APP_NAME-$version.zip"
  [[ -f "$zip" ]] || fail "there's no release/$version/$APP_NAME-$version.zip: build it first (script/release.sh)"

  local channel=""
  if is_beta "$version"; then channel=beta; fi
  say "Adding $version ($build) to the appcast${channel:+, in the beta channel}"
  local work="$out/appcast-work" published
  rm -rf "$work"
  mkdir -p "$work"
  published="$(published_appcast)"
  if [[ -n "$published" && -f "$published" ]]; then cp "$published" "$work/appcast.xml"; fi
  cp "$zip" "$work/"
  if [[ -f "$out/notes.md" ]]; then cp "$out/notes.md" "$work/$APP_NAME-$version.md"; fi
  local options=(--embed-release-notes --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$version/")
  if [[ -n "$channel" ]]; then options+=(--channel "$channel"); fi
  local signing=(--account "$KEY_ACCOUNT")
  local key_name="the keychain's \"$KEY_ACCOUNT\" key"
  if [[ -n "$KEY_FILE" ]]; then
    signing=(--ed-key-file "$KEY_FILE")
    key_name="the key in $KEY_FILE"
  fi
  "$(sparkle_tool generate_appcast)" "${signing[@]}" "${options[@]}" "$work"
  signed_in_appcast "$work/appcast.xml" "$(basename "$zip")" \
    || fail "the appcast's entry for $version isn't signed: $key_name isn't the one whose public half is in the app"
  [[ "$(published_build "$work/appcast.xml")" == "$build" ]] || fail "the appcast's newest build isn't $build"
  [[ "$(appcast_channel "$work/appcast.xml" "$build")" == "$channel" ]] || fail "the appcast's entry for $version isn't in the ${channel:-default} channel"
  cp "$work/appcast.xml" "$out/appcast.xml"
  say "Done: release/$version/appcast.xml"
}

# What the update window and the GitHub release would show for a version (the project's by default).
notes() {
  local version="${1:-}"
  if [[ -z "$version" ]]; then version="$(release_version)"; fi
  release_notes "$version" || fail "CHANGELOG.md has no notes for $version"
}

case "${1:-}" in
  "") build release ;;
  --skip-notarization) build try ;;
  --unsigned) build unsigned ;;
  appcast) appcast ;;
  notes) notes "${2:-}" ;;
  keys) keys ;;
  *) fail "usage: script/release.sh [--skip-notarization | --unsigned | appcast | notes [<version>] | keys]" ;;
esac
