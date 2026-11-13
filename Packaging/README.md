# Releasing Kaern

Kaern is distributed outside the Mac App Store. Each release has two files:
- a DMG to download (also as `Kaern.dmg` on a release, for the website's download buttons);
- a ZIP that Sparkle installs as an update.

Releases run on Apple silicon Macs (arm64 only) with macOS 26 or later.

The app in both is signed with a Developer ID and notarized by Apple. GitHub Actions makes the releases: pushing a
version tag builds the release on a GitHub Mac and publishes it as a GitHub release. It then adds the release to the
appcast (`appcast.xml` on the `gh-pages` branch, served by GitHub Pages), which Kaern reads to find updates.

There are two kinds of versions:
- **A release**, tagged `v1.1.0`: offered to every copy.
- **A beta**, tagged `v1.1.0-beta.2`: a GitHub pre-release, offered only to copies with Settings › General › Updates ›
  Get beta versions on. A copy that is itself a beta starts with it on.

| Where | What |
|---|---|
| `.github/workflows/release.yml` | On a version tag: build, sign and notarize → GitHub release → appcast on `gh-pages`. |
| `.github/workflows/ci.yml` | On each pull request and each push to `main`: the KaernKit tests, a Debug build, and the release build signed ad hoc. |
| `script/release.sh` | The build the workflow runs: archive → Developer ID export → notarize and staple the app → ZIP and DMG → notarize and staple the DMG. Also the appcast entry, the notes, and tries on your Mac. |
| `CHANGELOG.md` | Each version's notes, shown in the update window and on the GitHub release. |
| `Packaging/Info.plist` | Sparkle's keys, merged into the Info.plist Xcode generates: `SUFeedURL`, `SUPublicEDKey`, a daily check that asks before installing. Also `KaernSourceURL`, shown in About Kaern. |
| `Packaging/DMG/` | The background of the DMG's window, at 1x and 2x (`script/make_dmg_background.swift` draws it). |
| `gh-pages` branch | The appcast, served by GitHub Pages at `https://progresshans.github.io/kaern/appcast.xml`. Only the release workflow commits to it. |
| `.env` (from `.env.example`) | Your settings for tries on your Mac. |

Updates only run in Release builds. Debug builds (`./script/build_and_run.sh`, the flow checks) never start the
updater, and they show no Check for Updates… item.

## Versions and build numbers

The tag is the version: you don't change the project for a release. `script/release.sh` builds the app with the tag's
version (`MARKETING_VERSION`) and a build number made from it (`CURRENT_PROJECT_VERSION`):

| Version | Build number |
|---|---|
| 1.0.0 | 1000099 |
| 1.1.0-beta.1 | 1010001 |
| 1.1.0-beta.2 | 1010002 |
| 1.1.0 | 1010099 |
| 1.1.1 | 1010199 |

Sparkle offers an update when its build number is higher than the installed one's. So a release comes after its betas,
and before the next version and that version's betas. A version's minor and patch numbers go up to 99, its betas to 98.

The project's own `MARKETING_VERSION` is only what Debug builds and tries on your Mac show.

## Once

1. **Signing:** a "Developer ID Application" certificate in your login keychain. You have one; `security
   find-identity -v -p codesigning` lists it.
2. **Notarization on your Mac:** a notarytool keychain profile, `progresshans-notary` (another name:
   `KAERN_NOTARY_PROFILE` in `.env`). It holds your account's credentials, not an app's, so one profile serves every
   app you notarize. Make it once with an App Store Connect API key:
   ```
   xcrun notarytool store-credentials progresshans-notary --key <AuthKey_….p8> --key-id <key ID> --issuer <issuer ID>
   ```
   - The key is a team key with the Developer role, made in App Store Connect › Users and Access › Integrations ›
     App Store Connect API (the Account Holder requests API access once). The issuer ID is above the list of team
     keys; the key ID is in the `.p8` file's name.
   - Once stored, notarytool reads the key from the keychain, not the `.p8` file. Keep the file somewhere safe: GitHub
     needs it too (step 5).
   - Unlike an app-specific password, the key reaches no iCloud data and keeps working when your Apple ID password
     changes. A password works too: `--apple-id <Apple ID> --team-id <team ID>`, and it asks for the password.
3. **The update key:** run `script/release.sh keys`.
   - The first time, it makes the EdDSA key in your login keychain (account `kaern`, separate from PowerLens's).
     macOS may ask you to allow that.
   - It writes the public half into `Packaging/Info.plist`. Commit that.
   - It prints how to put the private key in a file, for GitHub (step 5) and as a backup. Losing it means installed
     copies can't take updates anymore.
4. **The repository:** create `github.com/progresshans/kaern` and push `main`.
5. **The release environment:** in Settings › Environments, add one named `release`.
   - Deployment branches and tags: "Selected branches and tags", with the tag rule `v*`. Only a version tag's run
     can then use its secrets.
   - Required reviewers: none. Alone, an approval adds a click to every release and beta without protecting anything,
     since whoever holds your account can approve too. The tag rule is what keeps the secrets to version tags. Add
     reviewers if others get write access to the repository.
   - Its secrets:

     | Secret | Value |
     |---|---|
     | `DEVELOPER_ID_P12_BASE64` | The certificate with its private key. In Keychain Access › My Certificates, export "Developer ID Application: …" as a `.p12` with a password, then `base64 -i <file>.p12 \| pbcopy`. |
     | `DEVELOPER_ID_P12_PASSWORD` | That `.p12`'s password. |
     | `NOTARY_KEY` | The App Store Connect API key: the `.p8` file's whole content. |
     | `NOTARY_KEY_ID` | Its key ID. |
     | `NOTARY_ISSUER_ID` | The issuer ID. |
     | `SPARKLE_PRIVATE_KEY` | The update key's private half, from step 3. |

   - Delete the exported `.p12` and the key file once they're in.
6. **A build on GitHub:** after pushing `main`, check Actions › CI. Besides the KaernKit tests and a Debug build, it
   makes the release build as a tag would, signed ad hoc and with no secrets, on the same kind of GitHub Mac.
   - Both workflows run on GitHub's `xcode-27` image: macOS 27 with its default Xcode 27. It's a public preview and,
     for now, the only macOS 27 image. When GitHub releases a `macos-27` label, change `runs-on` in both.
   - Mac runners are free for public repositories; a private one spends its Actions minutes at ten times the rate.
7. **GitHub Pages**, after the first release (it makes the `gh-pages` branch): in Settings › Pages, set Source to
   "Deploy from a branch", the branch to `gh-pages` and the folder to `/ (root)`. The appcast is then at
   `https://progresshans.github.io/kaern/appcast.xml`, Kaern's `SUFeedURL`.
   - Until then, copies find no appcast. They're all on the first release anyway.
   - For another place, change `SUFeedURL` and `KaernSourceURL` in `Packaging/Info.plist` and
     `KAERN_GITHUB_REPOSITORY` in `.env`.

## Each release

1. While you work, write what changes for people under `## [Unreleased]` in `CHANGELOG.md`.
2. **A beta:** tag the commit on `main` and push the tag.
   ```
   git tag v1.1.0-beta.1 && git push origin v1.1.0-beta.1
   ```
   Its notes are `[Unreleased]`. When that's empty, they're the subjects of the commits since the last version.
3. **A release:** rename `## [Unreleased]` to the version and the date, as in `## [1.1.0] - 2026-12-01`, and start a
   new empty `## [Unreleased]` above it. `script/release.sh notes 1.1.0` shows what the update window will show.
   Commit, push `main`, then tag and push:
   ```
   git tag v1.1.0 && git push origin v1.1.0
   ```
4. Actions › Release takes about 10 to 20 minutes, most of it waiting for Apple:
   - **Build, sign and notarize** (on a GitHub Mac, with the release environment's secrets): the script's checks, the
     DMG and the ZIP, and the appcast entry.
   - **Publish:** the GitHub release (a pre-release for a beta) with the DMG, the ZIP and `SHA256SUMS` (a release also
     with `Kaern.dmg`, the same DMG under the name the website links to), then the
     appcast, committed to `gh-pages` as "Offer <version> as an update". Pages serves it a minute or two later, and
     installed copies see the update at their next daily check. `main` doesn't change.

If a run fails, fix the cause and re-run it in the Actions tab. Publishing can run again: an existing GitHub release
gets its files replaced, and an appcast that already offers the version isn't committed twice. If `gh-pages` changed
while the release was being built, publishing stops: run the whole workflow again.

**To take a version back** from the appcast, revert the commit on `gh-pages` that offered it (or edit `appcast.xml`
there in GitHub's editor). Pages serves the change in a few minutes, and copies stop being offered that version. Copies
that installed it keep it until a newer one comes.

## The DMG

Opening the DMG shows a window with Kaern and a link to Applications. Stones from Kaern's icon lead from one to the
other, the last one blue, above "Drag Kaern to Applications". The disk itself shows Kaern's icon.
- The background (`Packaging/DMG/background.png` and `background@2x.png`) is light in both appearances. Over a
  background picture, Finder draws the icons' labels in black even in Dark Mode, and a picture's clear parts in white.
  After changing the design, run `swift script/make_dmg_background.swift` and commit the pictures.
- `script/dmg_layout.swift` writes the window's layout (its `.DS_Store`: size, icon size, where the icons are, the
  background) into the mounted image itself, without Finder, so a headless GitHub Mac makes the same DMG.
  `DMG_WINDOW`, `DMG_APP` and `DMG_APPLICATIONS` in `script/release.sh` set the window and where the icons go; the
  background is drawn for them. The window is 432 pt tall: the 400 pt picture and the 32 pt title bar.
- The image is made in a temporary folder: the layout records where it was mounted, and that ships with the DMG.

## On your Mac

`script/release.sh` makes the same build here and publishes nothing:
- `script/release.sh --unsigned`: signed ad hoc, with no certificate (what CI does).
- `script/release.sh --skip-notarization`: signed with your Developer ID, not sent to Apple. A DMG made this way warns
  on other Macs.
- `script/release.sh`: signed and notarized with your profile, as GitHub Actions does it. It needs what a release
  needs: a clean working tree, the update key, and the notes.
- `script/release.sh appcast`: the appcast with that build added (`release/<version>/appcast.xml`), signed with the
  update key in your keychain. It starts from `origin/gh-pages` as you last fetched it.
- `script/release.sh notes [<version>]`: the notes the update window and the GitHub release would show.

They build the project's `MARKETING_VERSION`; `KAERN_VERSION=1.1.0-beta.1` builds another version.

## What the script checks

For a release, it stops, saying why, when:
- the working tree has changes;
- `SUPublicEDKey` is empty;
- the version isn't a release's (`1.1.0`) or a beta's (`1.1.0-beta.2`);
- a release has no section in `CHANGELOG.md`;
- the version isn't newer than everything the appcast offers, in either channel.

For every build, it stops when:
- there's no Developer ID identity (except `--unsigned`);
- the archive or the export fails;
- the app isn't signed with the hardened runtime, a secure timestamp and a Developer ID (except `--unsigned`);
- the app's version, build number or public key isn't the one it built;
- the app isn't built for Apple silicon only (`arm64`). Sparkle's framework stays universal, as it comes.

After notarizing, it staples the app and the DMG, and checks the app with `spctl`. The appcast step stops when the new
entry isn't signed, which means the update key isn't the one whose public half is in the app, or isn't in its channel.
