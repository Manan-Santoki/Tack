# Security

Tack can see everything you copy, so please report security problems privately through [GitHub's private vulnerability reporting](https://github.com/Manan-Santoki/Tack/security/advisories/new), not in a public issue.

## How clips are protected

- History stays on your Mac. The only network requests are to this repository's GitHub releases, to check for and download updates. They never include your clips.
- Updates are installed only if they're signed with the same certificate as the installed app. You can turn automatic updates off in Settings.
- Clips and their searchable text, including text read from images on your Mac, are encrypted with AES-256-GCM. The key is in your Keychain.
- Clips that their app marks as sensitive, such as passwords, aren't recorded unless you turn that on in Settings. When it's on, they show in the popup in plain view.
- Encryption protects the files on disk. Clips are decrypted while Tack is running, and other software running as you may still be able to read the clipboard itself.
