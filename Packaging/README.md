# Releasing Kaern

Kaern is distributed outside the Mac App Store. Each release has two files:
- a DMG to download;
- a ZIP that Sparkle installs as an update.

The app in both is signed with a Developer ID and notarized by Apple. `script/release.sh` makes both on this Mac and
adds the release to the appcast (`docs/appcast.xml`), which Kaern reads to find updates.

| Where | What |
|---|---|
| `Packaging/Info.plist` | Sparkle's keys, merged into the Info.plist Xcode generates: `SUFeedURL`, `SUPublicEDKey`, a daily check that asks before installing. Also `KaernSourceURL`, shown in About Kaern. |
| `script/release.sh` | archive → Developer ID export → notarize and staple the app → ZIP and DMG → notarize and staple the DMG → appcast |
| `docs/appcast.xml` | the appcast, served by GitHub Pages at `https://progresshans.github.io/kaern/appcast.xml` |
| `.env` (from `.env.example`) | your local settings: signing identity, notary profile, key account, repository |

Updates only run in Release builds. Debug builds (`./script/build_and_run.sh`, the flow checks) never start the
updater, and they show no Check for Updates… item.

## Once

1. **Signing:** a "Developer ID Application" certificate in your login keychain. You have one; `security
   find-identity -v -p codesigning` lists it. The script picks it up, or set `KAERN_SIGN_IDENTITY`.
2. **Notarization:** a notarytool keychain profile, `progresshans-notary` (another name: `KAERN_NOTARY_PROFILE` in
   `.env`). It holds your Apple ID's credentials, not an app's, so one profile serves every app you notarize. Make
   it once:
   ```
   xcrun notarytool store-credentials progresshans-notary --apple-id <Apple ID> --team-id <team ID>
   ```
   It asks for an app-specific password made at account.apple.com.
3. **The update key:** run `script/release.sh keys`.
   - The first time, it makes the EdDSA key in your login keychain (account `kaern`, separate from PowerLens's).
     macOS may ask you to allow that.
   - It writes the public half into `Packaging/Info.plist`. Commit that.
   - Back up the private key (`… generate_keys --account kaern -x <file>`, the command is printed). Losing it means
     existing installs can't take updates anymore.
4. **The repository:** create `github.com/progresshans/kaern` and push `main`.
5. **GitHub Pages:** in the repository's Settings › Pages, set Source to "Deploy from a branch", the branch to
   `main` and the folder to `/docs`. GitHub then serves the `docs/` folder as a website, so `docs/appcast.xml` is at
   `https://progresshans.github.io/kaern/appcast.xml`, Kaern's `SUFeedURL`.
   - Pages serves a branch's root or its `docs/`; `docs/` keeps the site to the appcast.
   - Until the first release, the appcast offers no version.
   - For another place, change `SUFeedURL` and `KaernSourceURL` in `Packaging/Info.plist` and
     `KAERN_GITHUB_REPOSITORY` in `.env`.

## Each release

1. Raise the version in the project, and commit:
   - `MARKETING_VERSION`, the version people see: three numbers, as in 1.0.1 for fixes and 1.1.0 for new features.
   - `CURRENT_PROJECT_VERSION`, the build number: one more each release (2, 3, 4…). Sparkle compares this one, so a
     release whose build number isn't higher isn't offered as an update.
2. Optional: write release notes in `release/notes/<version>.md`. The appcast shows them in the update window.
3. Run `script/release.sh`. It takes a few minutes, most of it waiting for Apple, and leaves in `release/<version>/`:
   - `Kaern-<version>.dmg` and `Kaern-<version>.zip`;
   - `SHA256SUMS`;
   - the archive and its logs.
4. It prints the next steps. Keep their order: the appcast must not point at files that aren't up yet.
   ```
   git tag v<version> && git push origin main v<version>
   gh release create v<version> release/<version>/Kaern-<version>.dmg release/<version>/Kaern-<version>.zip …
   git add docs/appcast.xml && git commit -m "Offer <version> as an update" && git push origin main
   ```

`script/release.sh --skip-notarization` does everything but Apple's part. It signs and packages, and leaves the
appcast alone. It also runs with uncommitted changes and without the update key. Use it to try the build: a DMG
made that way warns on other Macs.

## What the script checks

It stops, saying why, when:
- the working tree has changes;
- `SUPublicEDKey` is empty;
- the version isn't three numbers, or it's tagged already;
- the build number isn't higher than the newest in the appcast;
- there's no Developer ID identity;
- the archive or the export fails;
- the app isn't signed with the hardened runtime, a secure timestamp and a Developer ID;
- the app's version or public key isn't the project's;
- the new appcast entry isn't signed: the update key in your keychain isn't the one in `Packaging/Info.plist`.

After notarizing, it staples the app and the DMG, and checks the app with `spctl`.
