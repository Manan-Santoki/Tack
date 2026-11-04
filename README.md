# ClipHistory

A minimal, native macOS clipboard manager in the spirit of Windows + V. Press a shortcut and your history opens at your text cursor. Pick a clip and it pastes exactly as you copied it.

This is a fork of [weiykong/ClipHistory](https://github.com/weiykong/ClipHistory), rebuilt with native macOS controls and full-fidelity clips.

## What's different in this fork

- **Original formats:** every format on the clipboard is saved byte for byte, so images keep full resolution, and rich text and multiple files stay intact.
- **Opens at the text cursor:** falls back to the focused input field, then the mouse pointer, for apps that don't report their cursor.
- **Native UI:** Liquid Glass popup, grouped settings form, `MenuBarExtra`, and a standard search field.
- **No keyboard interception:** the popup takes focus directly, so there's no global event tap.
- **Pins are permanent:** they never get evicted by newer clips.
- **Knows what you copied:** links, email addresses and code are detected and shown differently, and searching "link" or "code" finds them. What gets pasted is never changed.
- **List or grid:** list favours text, grid favours image previews.
- **Your choice on other devices:** record or ignore clips arriving from your iPhone through Universal Clipboard.

## Requirements

- macOS 26 or later
- Xcode 26 or later to build (the Command Line Tools alone aren't enough)

## Build and install

```bash
git clone https://github.com/Manan-Santoki/ClipHistory.git
cd ClipHistory
bash scripts/build-dmg.sh
cp -R dist/ClipHistory.app /Applications/
open /Applications/ClipHistory.app
```

Then allow ClipHistory under System Settings → Privacy & Security → Accessibility. It's needed to paste for you and to find the text cursor.

Without a signing certificate the app gets an ad-hoc signature, so macOS treats each rebuild as a new app and asks for Keychain and Accessibility approval again. To avoid that, add your Apple ID under Xcode → Settings → Accounts and create an Apple Development certificate. The build script uses it automatically.

## Usage

| Action | Shortcut |
|---|---|
| Open or close | `⌘⇧V` (change it in Settings) |
| Search | Just type |
| Move | `↑` `↓` (and `←` `→` in grid) |
| Switch list and grid | `⌘L` |
| Paste | `↵` |
| Paste as plain text | `⇧↵` |
| Paste by position | `⌘1` to `⌘9` |
| Pin or unpin | `⌘P` |
| Delete | `⌘⌫` |
| Close | `Esc` or click away |

Right-click a clip for the same actions.

## Privacy

- History stays on your Mac, encrypted with AES-256-GCM. The key is in your Keychain.
- Clips marked as sensitive by their app, such as passwords from a password manager, aren't recorded unless you turn on **Record passwords and sensitive clips** in Settings. When it's on, they appear in the popup in plain view.
- You can turn off recording per app in Settings.
- The only network request is a check of this repo's GitHub releases at launch.

Copied files are stored as references, so a file clip stops working if the original is moved or deleted. A single clip is limited to 200 MB; above that, its largest formats aren't kept.

## Development

```bash
swift build
swift test
```

Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select` points at the Command Line Tools.

## License

[MIT](LICENSE), © 2026 weiykong.
