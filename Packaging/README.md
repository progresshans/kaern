# Releasing Kaern

Kaern is distributed outside the Mac App Store. Each release has two files:
- a DMG to download;
- a ZIP that Sparkle installs as an update.

The app in both is signed with a Developer ID and notarized by Apple. GitHub Actions makes the releases: pushing a
version tag (`v1.0.1`) builds the release on a GitHub Mac and publishes it as a GitHub release. It then adds the release
to the appcast (`docs/appcast.xml`, served by GitHub Pages), which Kaern reads to find updates.

| Where | What |
|---|---|
| `.github/workflows/release.yml` | On a `v` tag: build, sign and notarize → GitHub release → appcast on `main`. Run by hand: a dry run that builds without signing. |
| `script/release.sh` | The build the workflow runs: archive → Developer ID export → notarize and staple the app → ZIP and DMG → notarize and staple the DMG. Also the appcast entry, and tries on your Mac. |
| `Packaging/ReleaseNotes/<version>.md` | Each release's notes, shown in the update window and on the GitHub release. |
| `Packaging/Info.plist` | Sparkle's keys, merged into the Info.plist Xcode generates: `SUFeedURL`, `SUPublicEDKey`, a daily check that asks before installing. Also `KaernSourceURL`, shown in About Kaern. |
| `docs/appcast.xml` | The appcast, served by GitHub Pages at `https://progresshans.github.io/kaern/appcast.xml`. |
| `.env` (from `.env.example`) | Your settings for tries on your Mac. |

Updates only run in Release builds. Debug builds (`./script/build_and_run.sh`, the flow checks) never start the
updater, and they show no Check for Updates… item.

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
     needs it too (step 6).
   - Unlike an app-specific password, the key reaches no iCloud data and keeps working when your Apple ID password
     changes. A password works too: `--apple-id <Apple ID> --team-id <team ID>`, and it asks for the password.
3. **The update key:** run `script/release.sh keys`.
   - The first time, it makes the EdDSA key in your login keychain (account `kaern`, separate from PowerLens's).
     macOS may ask you to allow that.
   - It writes the public half into `Packaging/Info.plist`. Commit that.
   - It prints how to put the private key in a file, for GitHub (step 6) and as a backup. Losing it means installed
     copies can't take updates anymore.
4. **The repository:** create `github.com/progresshans/kaern` and push `main`.
5. **GitHub Pages:** in the repository's Settings › Pages, set Source to "Deploy from a branch", the branch to `main`
   and the folder to `/docs`. GitHub then serves the `docs/` folder as a website, so `docs/appcast.xml` is at
   `https://progresshans.github.io/kaern/appcast.xml`, Kaern's `SUFeedURL`.
   - Pages serves a branch's root or its `docs/`; `docs/` keeps the site to the appcast.
   - Until the first release, the appcast offers no version.
   - For another place, change `SUFeedURL` and `KaernSourceURL` in `Packaging/Info.plist` and
     `KAERN_GITHUB_REPOSITORY` in `.env`.
6. **The release environment:** in Settings › Environments, add one named `release`.
   - Deployment branches and tags: "Selected branches and tags", with the tag rule `v*`. Only a version tag's run
     can then use its secrets.
   - Required reviewers: you, if each release should wait for your approval.
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
7. **A dry run:** Actions › Release › Run workflow. It builds and packages on a GitHub Mac, signed ad hoc and with no
   secrets, and keeps the DMG as the run's artifact for a week.
   - It runs on GitHub's `xcode-27` image, the Xcode the project is built with. If GitHub renames it, change `runs-on`
     in the workflow.
   - The release commits the appcast to `main`. If `main` gets branch protection, let GitHub Actions push to it.

## Each release

1. Raise the version in the project:
   - `MARKETING_VERSION`, the version people see: three numbers, as in 1.0.1 for fixes and 1.1.0 for new features.
   - `CURRENT_PROJECT_VERSION`, the build number: one more each release (2, 3, 4…). Sparkle compares this one, so a
     release whose build number isn't higher isn't offered as an update.
2. Write the notes in `Packaging/ReleaseNotes/<version>.md` (Markdown).
3. Commit both to `main` and push.
4. Tag that commit and push the tag:
   ```
   git tag v<version> && git push origin v<version>
   ```
5. In Actions › Release, approve the run if you added yourself as a reviewer. It takes about 10 to 20 minutes, most of
   it waiting for Apple:
   - **Build, sign and notarize** (on a GitHub Mac, with the release environment's secrets): the script's checks, the
     DMG and the ZIP, and the appcast entry.
   - **Publish:** the GitHub release with the DMG, the ZIP and `SHA256SUMS`, then the appcast, committed to `main` as
     "Offer <version> as an update". Pages serves it a minute or two later, and installed copies see the update at
     their next daily check.
6. `git pull` to get the appcast commit.

If a run fails, fix the cause and re-run it in the Actions tab. Publishing can run again: an existing GitHub release
gets its files replaced, and an appcast already on `main` isn't committed twice.

## On your Mac

`script/release.sh` makes the same build here and publishes nothing:
- `script/release.sh --unsigned`: signed ad hoc, with no certificate (what the dry run does).
- `script/release.sh --skip-notarization`: signed with your Developer ID, not sent to Apple. A DMG made this way warns
  on other Macs.
- `script/release.sh`: signed and notarized with your profile, as GitHub Actions does it. It needs what a release
  needs: a clean working tree, the update key and the release notes.
- `script/release.sh appcast`: the appcast with that build added (`release/<version>/appcast.xml`), signed with the
  update key in your keychain.

## What the script checks

For a release, it stops, saying why, when:
- the working tree has changes;
- `SUPublicEDKey` is empty;
- the version isn't three numbers, or the tag isn't `v` and the version;
- there are no release notes;
- the build number isn't higher than the newest in the appcast.

For every build, it stops when:
- there's no Developer ID identity (except `--unsigned`);
- the archive or the export fails;
- the app isn't signed with the hardened runtime, a secure timestamp and a Developer ID (except `--unsigned`);
- the app's version, build number or public key isn't the project's.

After notarizing, it staples the app and the DMG, and checks the app with `spctl`. The appcast step stops when the new
entry isn't signed, which means the update key isn't the one whose public half is in the app.
