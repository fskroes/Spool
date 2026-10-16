# Release Spool

Spool publishes its builds on the releases page of the public repository [fskroes/spool-releases](https://github.com/fskroes/spool-releases/releases). That repository holds release files only: the source in `fskroes/Spool` is private. The first real `make publish` makes it, with a README from `Packaging/releases-README.md`. Each release is signed with a Developer ID, notarized by Apple and stapled, so anyone can download it with a browser and open it. The installed app finds new versions through the Sparkle feed of the latest release and installs them itself.

```
 the Mac of the maintainer                        github.com/fskroes/spool-releases/releases
┌───────────────────────────────┐                ┌──────────────────────────────────────────┐
│ make publish                  │  gh release    │ release v0.2.0                           │
│  build + sign (Developer ID)  ├───────────────►│   Spool-0.2.0.zip   (Sparkle archive)    │
│  notarize + staple app, DMG   │                │   Spool.dmg         (notarized, stapled) │
│  zip + appcast (EdDSA)        │                │   appcast.xml       (one item)           │
│  SHA256SUMS.txt               │                │   SHA256SUMS.txt                         │
└───────────────┬───────────────┘                └───────────────────┬──────────────────────┘
                │ notarytool                                         │
                ▼                                                    │
        Apple notary service              releases/latest/download/  │
                                                                     │
 installed Spool.app                                                 │
┌───────────────────────────────┐                                    │
│ Sparkle: check every 24 h,    │◄─────────── appcast.xml ───────────┘
│ or "Check for Updates…"       │   checks the EdDSA signature and the code signature, then installs
└───────────────────────────────┘
```

## What is where

| Thing | Where | Secret? |
|---|---|---|
| Releases repository, source repository, feed URL, public EdDSA key, key account, Team ID, notarytool profile name | `Packaging/updates.env` (committed) | No |
| Code signing identity "Developer ID Application: … (98L4368F9K)" | login keychain; a `.p12` backup in your password manager | **Yes** |
| Notarization credential (Apple ID and an app-specific password) | login keychain, as the notarytool profile `spool-notary` | **Yes** |
| Sparkle private EdDSA key | login keychain, account `com.fskroes.Striple`; backup in your password manager | **Yes** |
| Release notes | `CHANGELOG.md`, one `## <version>` section per release | No |
| GitHub login | `gh auth login` (keyring) | Yes |

The Sparkle key keeps the old name of Spool, Striple: the name is in the keychain item that exists already. A new name needs a new key pair, and installed apps would refuse updates.

Every `make app` reads `Packaging/updates.env`, so every build checks for updates. `SPOOL_UPDATES=off make app` builds without updates.

The feed URL is `https://github.com/fskroes/spool-releases/releases/latest/download/appcast.xml`. GitHub sends it to the `appcast.xml` of the newest published release. Each release has an appcast with one item: its own version. Do not mark another release of this repository as "Latest": the feed follows "Latest".

## Why the Accessibility permission stays after an update

macOS stores the Accessibility permission with the designated requirement of the app. For a Developer ID signature, the requirement names the bundle ID and the Team ID, not one certificate:

```
designated => identifier "com.fskroes.Spool" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = "98L4368F9K"
```

Every release has the same team, so every update matches the stored entry. A renewed Developer ID certificate of the same team also matches. `make publish` stops when the app, the archive or the published release is not signed by the team in `SPOOL_TEAM_ID`.

## One time

1. Install and log in to the GitHub CLI:

   ```sh
   brew install gh
   gh auth login
   ```

   Select GitHub.com and HTTPS, and log in with a web browser.

2. The Developer ID identity. Check that the login keychain has it:

   ```sh
   security find-identity -v -p codesigning
   ```

   The list must have a line `"Developer ID Application: <your name> (98L4368F9K)"`. If it does not, make or download the certificate in Xcode: Settings > Accounts > select the team > Manage Certificates > + > Developer ID Application. On another Mac, import the `.p12` backup into the login keychain. Only the Account Holder of the team can make a Developer ID certificate.

   **Make a backup.** In Keychain Access, select the "Developer ID Application" item under My Certificates, then File > Export Items, as a `.p12` file with a strong password. Put the file and the password in your password manager, then delete the file.

3. The notarization credential. Make an app-specific password at [account.apple.com](https://account.apple.com) > Sign-In and Security > App-Specific Passwords. Then store it in the login keychain as the profile that `Packaging/updates.env` names:

   ```sh
   xcrun notarytool store-credentials spool-notary --apple-id <your Apple ID> --team-id 98L4368F9K
   ```

   The command asks for the password: give the app-specific password, not your Apple ID password. An Apple ID password gives `HTTP status code: 401`. Check the profile without a submission:

   ```sh
   xcrun notarytool history --keychain-profile spool-notary
   ```

4. The Sparkle key pair exists already. Its public key is in `Packaging/updates.env`. **Make a backup of the private key** and keep it in your password manager:

   ```sh
   (umask 077 && .build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.fskroes.Striple -x ~/striple-sparkle-key.txt)
   ```

   This writes the private key to `~/striple-sparkle-key.txt`, outside the repository. `umask 077` makes the file readable only by you. Put the file in your password manager, then delete it.

   Without the private key, the installed apps cannot accept new updates. On a new Mac, run `swift package resolve` once (it downloads the Sparkle tools), then import the key: `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.fskroes.Striple -f ~/striple-sparkle-key.txt`. Delete the file after the import.

## Publish a release

1. Increase `VERSION` (for example `0.1.0` to `0.2.0`).
2. Add a `## 0.2.0` section at the top of `CHANGELOG.md`, with the lines of "Unreleased". Write for the person who uses Spool. This text shows in the update window and on the GitHub release.
3. Commit on a branch, merge into `main`, push `main`, and switch to `main`.
4. Check the release without uploading:

   ```sh
   make publish-dry
   ```

   A dry run notarizes too: it sends the app and the DMG to Apple's notary service (this is not public). Each notarization takes one to fifteen minutes. Run it in the foreground, in your own terminal: notarytool reads its profile from the login keychain.

5. Publish:

   ```sh
   make publish
   ```

`make publish` (`scripts/release.sh`) stops before it uploads when a check fails:

| Check | Why |
|---|---|
| The working tree is clean and the branch is `main` | The release is a commit you can find again. |
| `VERSION` looks like `1.2.3`, the tag `v<version>` does not exist here or in the releases repository | One release per version. A release on an existing tag keeps that tag. |
| The commit is on `main` of the source repository (`SPOOL_SOURCE_REPO`) on GitHub | A release is built from pushed, reviewed code. |
| The releases repository is not the source repository, and it is public | Spool downloads its updates with no login. |
| The releases repository has no release `v<version>`, also no draft. This check comes before the build | A second run does not delete the files that `make publish-finish` needs. |
| `VERSION` and the build number are higher than the ones in the published feed | Sparkle offers only a higher build. |
| `CHANGELOG.md` has a section for `VERSION` | The update window shows these notes. |
| The private key in the keychain matches `SPOOL_ED_PUBLIC_KEY` | Else every installed app refuses the update. |
| The login keychain has a "Developer ID Application" identity of `SPOOL_TEAM_ID`, and `SIGN_IDENTITY` is not set | Every release has the same team, so macOS keeps the Accessibility permission. |
| The notarytool profile `SPOOL_NOTARY_PROFILE` works. This check comes before the build | A missing profile stops the run now, not after the build. |
| The published release is signed by the same team and has the same `SUPublicEDKey` | An update that changes either one breaks every installed copy. |
| The app is universal, has the feed URL and the key, the hardened runtime, and the Developer ID signature of the team | No broken build goes out. Notarization refuses an app without the hardened runtime. |
| Apple notarizes the app, the ticket is stapled, and Gatekeeper says `source=Notarized Developer ID` | Else macOS does not open the app on another Mac. |
| The DMG is signed with the same identity, notarized, stapled, and accepted by Gatekeeper. The app in the DMG has the signature of the team and its own ticket | A notarized app in a DMG without a ticket still shows a warning. The app in the DMG is the copy that a user drags to Applications. |
| The appcast has one item with the right version, build, URL, length and an EdDSA signature | The feed matches the archive. |
| The archive unpacks to an app with a valid signature of the team and a stapled ticket | This is what an update installs. The archive is made after the staple, so it carries the ticket. |
| No file in the zip or the DMG contains your home path, `/Users/<your user name>/` or your Git email | The files are public. The user name alone is not a leak: it is also the GitHub owner, and the bundle ID and the feed URL have it. `build-app.sh` removes the debug map (`strip -S`), which had the build paths. If the check itself fails (for example a file it cannot read), the release stops too. |

Then it uploads the files to a **draft** release and publishes it. GitHub makes the tag `v<version>` in the releases repository, on its own `main`: that repository has no source commit. The release text names the source commit. The script downloads the feed, the archive and the DMG (from `releases/latest/download/`, the link of the website) again and compares them byte for byte, checks that the tag exists in the releases repository, and tags the commit of the build `v<version>` here. That local tag is not pushed: push it with `git push origin v<version>` when you want it on GitHub.

The script reads the commit once, at the start. The build must come from that commit: if HEAD moves or the working tree changes during the build, the release stops before the upload.

The files stay in `dist/release/<version>/`. `commit.txt` there names the commit of the build. It is not uploaded. `make publish-dry` writes to `dist/release/dry-run/<version>/`, so it never replaces the files of a real run. `make clean` keeps `dist/release/<version>/`, because `make publish-finish` needs these files. It deletes only `dist/release/dry-run/` there.

If the script stops while the DMG is open, its exit handler detaches the DMG before it deletes its temporary folder.

## If something goes wrong

| Problem | Fix |
|---|---|
| "this Mac has no \"Developer ID Application\" identity of team …" | Install the certificate (see "One time", step 2). `security find-identity -v -p codesigning` must list it. |
| "the notarytool profile … does not work" | Run `xcrun notarytool store-credentials` (see "One time", step 3). If the profile exists, run the script in the foreground with the login keychain unlocked: a background job cannot read it, and notarytool then says "No Keychain password item found". |
| "Apple did not notarize Spool.app: Invalid" | The message shows Apple's log, and the command to read it again: `xcrun notarytool log <id> --keychain-profile spool-notary`. The log names the file and the problem, for example a binary without the hardened runtime or without a secure timestamp. |
| "Apple did not notarize …: no answer", with `HTTP status code: 401` | The profile has your Apple ID password, or the app-specific password was revoked. Make a new app-specific password and run `store-credentials` again. |
| "Gatekeeper does not accept … as notarized" | The ticket is not on the file. Run again: the script staples before it asks Gatekeeper. If it stays, check the date and time of the Mac, and the network to Apple. |
| "the commit … is not on main of …" | Push `main` first: `git push origin main`. |
| "the tag v… exists in fskroes/spool-releases" | Increase `VERSION`. Do not move a tag of a published release. |
| "the releases repository … is not public" | Spool downloads its updates with no login. Make the repository public again: `gh repo edit fskroes/spool-releases --visibility public --accept-visibility-change-consequences`. |
| "a draft release vX exists" after a failed run | The upload stopped before the publish. `gh release delete vX --repo fskroes/spool-releases --yes`, then run again. |
| "vX is published" | Do not delete it. The run stopped after the publish: see the next row. |
| "does not return the new appcast", or the run stopped after "Publishing vX" | The release is public, but the checks and the tag did not run. Open the release page and check that it is published and "Latest". Then, on the same commit and without a new build: `make publish-finish`. It stops if HEAD is not the commit in `dist/release/<version>/commit.txt`. It checks the files in `dist/release/<version>/` against `SHA256SUMS.txt`, compares the feed, the archive and the DMG with them, checks the tag in the releases repository, and makes the tag here. |
| "X is published already" | Same as above: `make publish-finish`. If the tag exists, increase `VERSION`. |
| "the tag vX does not exist in fskroes/spool-releases" | GitHub did not make the tag when it published. Open the release page. When the release is public, run `make publish-finish` again after some minutes. |
| "the Sparkle key … does not match" | Import the backup with `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account com.fskroes.Striple -f <file>`. |
| "dist/release/<version>/… is missing" from `make publish-finish` | The files of the run are not there. Run `make publish-finish` on the Mac and in the folder of the run. `make clean` keeps these files. If you deleted them, check the release on GitHub by hand and make the tag yourself on the commit of the release text: `git tag v<version> <commit>`. |
| Spool is on in System Settings > Accessibility, but Spool says "Accessibility permission needed" | The entry stores the requirement of an old build, for example a build from source. Settings > Mac Setup > Reset Permission, then turn Spool on. See docs/INSTALL.md, "The switch is on, but Spool has no permission". |
| A bad release is out | Publish a fixed version with a higher `VERSION`. Do not delete a published archive: installed apps can be in the middle of an update. |

## Change the signing team

Use this only when the releases must move to another Apple team. A renewed or a new Developer ID certificate of the same team needs nothing: the requirement names the team.

A release of another team works, and Sparkle installs it (the EdDSA key does not change). But after the update each installed copy loses the Accessibility permission, while the switch still shows on.

1. Set `SPOOL_TEAM_ID` in `Packaging/updates.env` to the new Team ID. Commit it.
2. In the `CHANGELOG.md` section of the next version, tell the users what to do after the update: in Spool, click Settings > Mac Setup > Reset Permission, then turn Spool on in System Settings > Privacy & Security > Accessibility. Turning the switch off and on is not enough.
3. Publish with `./scripts/release.sh --new-identity` (a dry run first: `./scripts/release.sh --dry-run --new-identity`). `make publish` refuses this release, because the published release has the old team ("the published … is not signed by team …"). That check stops a change by mistake. `--new-identity` turns it into a warning, and stops when the published release has the new team already. All other checks stay on.

## Test an update

1. Install the published version: download `Spool.dmg` from the release, or install it from a terminal (docs/INSTALL.md, "Install the release from a terminal").
2. Publish the next version.
3. In the installed app: menu bar icon > **Check for Updates…** > **Install Update**.
4. After the restart, `spool version` shows the new version, and `spool state` shows `Accessibility: granted`.

Sources: [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) (`notarytool store-credentials`, `stapler`), [Apple TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [Sparkle: Publishing an update](https://sparkle-project.org/documentation/publishing/) (archives keep symlinks; an archive without extended attributes is fine when the signature does not use them), [Sparkle: Documentation](https://sparkle-project.org/documentation/), [GitHub: Linking to releases](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases) (the `releases/latest/download/<asset>` URL).
