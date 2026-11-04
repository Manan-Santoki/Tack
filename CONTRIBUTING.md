# Contributing

Issues and pull requests are welcome. Please open an issue before starting a large change.

## Setup

You need macOS 26 and Xcode 26 or later. The Command Line Tools alone can't build Tack, so if `xcode-select -p` points at them, either run `sudo xcode-select -s /Applications/Xcode.app` or prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
swift build
swift test
bash scripts/build-dmg.sh   # creates dist/Tack.app and dist/Tack.dmg
```

## Signing while developing

macOS ties Accessibility and Keychain approvals to an app's signature. With an ad-hoc signature, every rebuild looks like a new app and has to be approved again.

To avoid that, add your Apple ID under Xcode → Settings → Accounts and create an Apple Development certificate. `build-dmg.sh` uses it automatically.

Local builds aren't signed with the release certificate, so they can't update a released copy, and a released copy won't update them.

If Accessibility shows Tack as on but Tack can't paste or find the cursor, macOS may have recorded a different build. Delete any extra copies, such as `dist/Tack.app`, then remove Tack from the Accessibility list and add `/Applications/Tack.app` again.

## Pull requests

- Add a test for anything that can be tested without the UI.
- Add a line under `[Unreleased]` in `CHANGELOG.md` for anything users would notice.
- CI must pass.

## Releasing

1. Set the new version in `VERSION`.
2. In `CHANGELOG.md`, rename `[Unreleased]` to the version and date, add a new empty `[Unreleased]` above it, and update the links at the bottom.
3. Commit to `main` and push.
4. Run `scripts/release.sh`.

The script runs the tests, then tags and pushes the version. The release workflow then tests again, builds and signs the DMG, and publishes a GitHub release with the changelog section as its notes. Installed copies of Tack pick it up within six hours, or at their next launch.

### Signing

Every release is signed with one self-made certificate, stored in the `TACK_SIGNING_P12_BASE64` and `TACK_SIGNING_P12_PASSWORD` repository secrets. It doesn't need an Apple Developer account.

Keeping the same certificate is what makes updates work. macOS keeps Accessibility and Keychain approvals across versions, and Tack refuses any update signed with a different certificate. The release fails if the app isn't signed with the certificate recorded in `release.yml`.

Don't lose or replace it. A new certificate would mean every user has to reinstall Tack by hand and approve it again.

Because the certificate isn't from Apple, a first install still needs the quarantine step in the README. Updates don't.
