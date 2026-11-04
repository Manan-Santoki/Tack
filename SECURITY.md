# Security

Tack can see everything you copy, so please report security problems privately through [GitHub's private vulnerability reporting](https://github.com/Manan-Santoki/Tack/security/advisories/new), not in a public issue.

## How clips are protected

- History stays on your Mac. The only network request is a check of this repository's releases at launch.
- Clips are encrypted with AES-256-GCM. The key is in your Keychain.
- Clips that their app marks as sensitive, such as passwords, aren't recorded unless you turn that on in Settings. When it's on, they show in the popup in plain view.
- Encryption protects the files on disk. Clips are decrypted while Tack is running, and other software running as you may still be able to read the clipboard itself.
