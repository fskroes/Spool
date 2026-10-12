# Release Striple

Striple publishes its builds on GitHub, in the public repository [fskroes/striple-releases](https://github.com/fskroes/striple-releases). The source stays private. The installed app finds new versions through the Sparkle feed in that repository and installs them itself.

```
 this Mac (private source)                      github.com/fskroes/striple-releases (public)
┌──────────────────────────────┐               ┌──────────────────────────────────────────┐
│ make publish                 │  gh release   │ release v0.1.1                           │
│  build + sign (local identity)├─────────────►│   Striple-0.1.1.zip   (Sparkle archive)  │
│  zip + dmg + appcast (EdDSA) │               │   Striple.dmg                            │
│  SHA256SUMS.txt              │               │   appcast.xml         (one item)         │
└──────────────────────────────┘               │   SHA256SUMS.txt                         │
                                               └───────────────────┬──────────────────────┘
 installed Striple.app                                             │
┌──────────────────────────────┐   releases/latest/download/       │
│ Sparkle: check every 24 h,   │◄──────── appcast.xml ─────────────┘
│ or "Check for Updates…"      │   checks the EdDSA signature and the code signature, then installs
└──────────────────────────────┘
```

## What is where

| Thing | Where | Secret? |
|---|---|---|
| Feed URL, public EdDSA key, releases repo, key account, signing certificate SHA-1 | `Packaging/updates.env` (committed) | No |
| Sparkle private EdDSA key | login keychain, account `com.fskroes.Striple`; backup in your password manager | **Yes** |
| Code signing identity "Striple Local Signing" | `~/Library/Keychains/striple-signing.keychain-db`; backup `.p12` and passphrase in your password manager | **Yes** |
| Release notes | `CHANGELOG.md`, one `## <version>` section per release | No |
| GitHub login | `gh auth login` (keyring) | Yes |

Every `make app` reads `Packaging/updates.env`, so every build checks for updates. `STRIPLE_UPDATES=off make app` builds without updates.

The feed URL is `https://github.com/fskroes/striple-releases/releases/latest/download/appcast.xml`. GitHub sends it to the `appcast.xml` of the newest published release. Each release has an appcast with one item: its own version.

## One time

1. Install and log in to the GitHub CLI:

   ```sh
   brew install gh
   gh auth login        # GitHub.com, HTTPS, log in with a web browser
   ```

2. Make the code signing identity: `./scripts/make-signing-cert.sh` (see [INSTALL.md](INSTALL.md#keep-the-accessibility-permission-after-a-rebuild)). **Put the backup file and the passphrase it prints in your password manager**, then delete the file. Set `STRIPLE_SIGNING_CERT_SHA1` in `Packaging/updates.env` to the SHA-1 it prints. On a new Mac, restore it with `./scripts/make-signing-cert.sh --import <file>`.
3. The Sparkle key pair exists already. Its public key is in `Packaging/updates.env`. **Make a backup of the private key** and keep it in your password manager:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.fskroes.Striple -x striple-sparkle-key.txt
   # store the file in your password manager, then delete it
   ```

   Without the private key, the installed apps cannot accept new updates. On a new Mac, import it with `generate_keys --account com.fskroes.Striple -f striple-sparkle-key.txt`.

Releases need both keys. With another code signing identity, the designated requirement changes, and macOS asks for the Accessibility permission again after the update. With another EdDSA key, installed apps refuse the update. `make publish` checks both against `Packaging/updates.env` and against the published release.

## Publish a release

1. Increase `VERSION` (for example `0.1.0` to `0.1.1`).
2. Add a `## 0.1.1` section at the top of `CHANGELOG.md`. Write for the person who uses Striple. This text shows in the update window and on the GitHub release.
3. Commit on a branch, merge into `main` (solo repo), and switch to `main`.
4. Check the release without uploading:

   ```sh
   make publish-dry
   ```

5. Publish:

   ```sh
   make publish
   ```

`make publish` (`scripts/release.sh`) stops before it uploads when a check fails:

| Check | Why |
|---|---|
| The working tree is clean and the branch is `main` | The release is a commit you can find again. |
| `VERSION` looks like `1.2.3`, the tag `v<version>` does not exist | One release per version. |
| `VERSION` and the build number are higher than the ones in the published feed | Sparkle offers only a higher build. |
| `CHANGELOG.md` has a section for `VERSION` | The update window shows these notes. |
| The private key in the keychain matches `STRIPLE_ED_PUBLIC_KEY` | Else every installed app refuses the update. |
| The local signing identity is the one `STRIPLE_SIGNING_CERT_SHA1` pins, `SIGN_IDENTITY` is not set | Same designated requirement, so macOS keeps the Accessibility permission. |
| The published release is signed with the same identity and has the same `SUPublicEDKey` | An update that changes either one breaks every installed copy. |
| The app is universal, has the feed URL and the key, and is signed with the local identity | No broken build goes out. |
| The appcast has one item with the right version, build, URL, length and an EdDSA signature | The feed matches the archive. |
| The archive unpacks to an app with a valid signature and the same designated requirement | This is what an update installs. |
| No file in the zip or the DMG contains your home path, user name or Git email | The files are public. `build-app.sh` removes the debug map (`strip -S`), which had the build paths. If the check itself fails (for example a file it cannot read), the release stops too. |

Then it uploads the files to a **draft** release, publishes it, downloads the feed and the archive again and compares them byte for byte, and tags the commit `v<version>` (local tag only).

The files stay in `dist/release/<version>/`. `commit.txt` there names the commit of the build. It is not uploaded.

If the script stops while the DMG is open, its exit handler detaches the DMG before it deletes its temporary folder.

## If something goes wrong

| Problem | Fix |
|---|---|
| "the release vX exists" after a failed run | The draft is still there. `gh release delete vX --repo fskroes/striple-releases --yes`, then run again. |
| "does not return the new appcast", or the run stopped after "Publishing vX" | The release is public, but the check and the tag did not run. Open the release page and check that it is published and "Latest". Then, on the same commit and without a new build: `make publish-finish`. It stops if HEAD is not the commit in `dist/release/<version>/commit.txt`. It checks the files in `dist/release/<version>/` against `SHA256SUMS.txt`, compares the feed and the archive with them, and makes the tag. |
| "X is published already" | Same as above: `make publish-finish`. If the tag exists, increase `VERSION`. |
| "the local signing identity is …, but Packaging/updates.env pins …" | Restore the pinned identity: `./scripts/make-signing-cert.sh --remove --yes`, then `--import <backup file>`. |
| "the Sparkle key … does not match" | Import the backup with `generate_keys --account com.fskroes.Striple -f <file>`. |
| A bad release is out | Publish a fixed version with a higher `VERSION`. Do not delete a published archive: installed apps can be in the middle of an update. |

## Test an update

1. Install the published version: download `Striple.dmg` from the release, or `make install` on the same commit.
2. Publish the next version.
3. In the installed app: menu bar icon > **Check for Updates…** > **Install Update**.
4. After the restart, `striple version` shows the new version, and `striple state` shows `Accessibility: granted`.

Sources: [Sparkle: Publishing an update](https://sparkle-project.org/documentation/publishing/) (archives keep symlinks; an archive without extended attributes is fine when the signature does not use them), [Sparkle: Documentation](https://sparkle-project.org/documentation/), [GitHub: Linking to releases](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases) (the `releases/latest/download/<asset>` URL).
