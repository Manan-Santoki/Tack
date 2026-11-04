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

The script runs the tests, then tags and pushes the version. The release workflow then tests again, builds the DMG, and publishes a GitHub release with the changelog section as its notes. Tack checks for that release at launch and offers the update.

### Notarized releases

Releases are ad-hoc signed by default, so people have to clear the quarantine flag by hand. To notarize them, add these repository secrets. This needs a paid Apple Developer membership.

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | Your Developer ID Application certificate as a `.p12`, base64 encoded |
| `DEVELOPER_ID_P12_PASSWORD` | The password of that `.p12` |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | Your team ID |
| `APPLE_APP_PASSWORD` | An [app-specific password](https://support.apple.com/102654) |
