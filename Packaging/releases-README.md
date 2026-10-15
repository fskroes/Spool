# Spool releases

Builds of Spool, a scrolling window manager for macOS. Windows sit side by side on a strip that scrolls.

- **Updates:** Spool updates itself. It reads `appcast.xml` from the newest release here. Each archive has an EdDSA signature that the app checks before it installs the update.
- **Checksums:** each release has `SHA256SUMS.txt`.
- **Signature:** the builds are signed with a personal certificate. They are not notarized, so they are for the owner's own Macs.

This repository holds release files only. The source code is private.
