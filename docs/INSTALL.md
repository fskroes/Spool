# Install Spool

This page tells you how to install, build, sign, update and remove Spool.

## Requirements

- macOS 13 or later. The app is a universal binary (Apple silicon and Intel).
- Only to build from source: the Xcode Command Line Tools with Swift 6 (`xcode-select --install`), and an internet connection for the first build (SwiftPM downloads Sparkle, the update framework). Xcode is not necessary.

## Install the release

1. Buy Spool on https://1yc.dev/spool (EUR 0.99, one time). The email has your license key, an activation link and the download link.
2. Download [Spool.dmg](https://github.com/fskroes/spool-releases/releases/latest/download/Spool.dmg) from the [latest release](https://github.com/fskroes/spool-releases/releases/latest).
3. Open `Spool.dmg` and drag Spool to Applications.
4. Open Spool from Applications. Spool shows the window "Activate Spool". Paste the key and click **Activate** (or press Command-Return), or click the activation link in the email. Spool checks the key on your Mac, with no network connection, and stores it. The window manager starts when the key is valid. Lost your key? https://1yc.dev/spool/restore sends it again.
5. Do the [first run](#first-run) steps.

The app and the DMG are signed with a Developer ID and notarized by Apple, and the ticket is stapled to both. Thus macOS opens Spool after a download with a browser, with no "Open Anyway" step and without a network connection. You can check it:

```sh
spctl --assess --type execute -vv /Applications/Spool.app
```

The output has `accepted` and `source=Notarized Developer ID`.

Spool updates itself (see [Updates](#updates-sparkle)). The Accessibility permission stays after each update: macOS stores it with the bundle ID and the Team ID of the signature, and every release has the same team.

To use the `spool` CLI in a terminal, link it once:

```sh
mkdir -p ~/.local/bin
ln -sf /Applications/Spool.app/Contents/Helpers/spool ~/.local/bin/spool
```

If `~/.local/bin` is not on your `PATH`, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`.

### Install the release from a terminal

This block also checks the download against `SHA256SUMS.txt` of the release:

```sh
(
set -e
D=$(mktemp -d)
trap 'cd /; hdiutil detach -quiet "$D/dmg" 2>/dev/null || true; rm -rf "$D"' EXIT
cd "$D"
U=https://github.com/fskroes/spool-releases/releases/latest/download
curl -fsSLO "$U/Spool.dmg"
curl -fsSLO "$U/SHA256SUMS.txt"
shasum -a 256 -c --ignore-missing SHA256SUMS.txt
if pgrep -xq Spool; then osascript -e 'quit app id "com.fskroes.Spool"'; fi
while pgrep -xq Spool; do sleep 0.5; done
rm -rf /Applications/Spool.app
hdiutil attach -nobrowse -readonly -mountpoint "$D/dmg" Spool.dmg
ditto "$D/dmg/Spool.app" /Applications/Spool.app
hdiutil detach "$D/dmg"
mkdir -p ~/.local/bin
ln -sf /Applications/Spool.app/Contents/Helpers/spool ~/.local/bin/spool
)
```

Paste the block as one piece. It runs in a subshell with `set -e`: the first command that fails stops it, and your terminal stays open. The steps:

1. Download `Spool.dmg` and `SHA256SUMS.txt` to a new temporary folder.
2. Check the DMG. `shasum` prints `Spool.dmg: OK`. If it does not, the block stops before it changes anything: the download is not the published file. `shasum` fails also when `SHA256SUMS.txt` has no line for `Spool.dmg`.
3. Quit Spool if it runs, and wait until it quit.
4. Remove the old `/Applications/Spool.app`: `ditto` merges into an old copy.
5. Copy the app from the DMG and detach the DMG.
6. Make the link `~/.local/bin/spool`.

On every exit, also after a stop, the `trap` line detaches the DMG and deletes the temporary folder.

The block has no `#` comments: zsh, the default shell of macOS, does not accept comments at the prompt unless `setopt interactivecomments` is on.

If the copy that you replace was a build from source, its Accessibility entry stores another signature. Then click Settings > Mac Setup > **Reset Permission** once, and turn Spool on.

## Build from source

```sh
make test
make app
make dmg
```

- `make test` runs the tests, except `SigningScriptTests`. `make test-signing` runs those (see the README).
- On a managed Mac, use `make test-quiet` in place of `make test`. It runs only the suites that start no process and make no executable file. `scripts/quiet-tests.sh --list` shows which files are in the lane and why the others are not.
- `make app` builds and signs `dist/Spool.app`. `Packaging/updates.env` names the Apple team of the releases (`SPOOL_TEAM_ID`). When this Mac has a "Developer ID Application" identity of that team, `make app` signs with it, like a release. A Developer ID signature gets a secure timestamp from Apple, so this build needs a network connection; without one, `codesign` fails. Else it signs with the free identity of `scripts/make-signing-cert.sh` (see "Keep the Accessibility permission after a rebuild"). When this Mac has neither, `make app` stops and tells you the ways on. You can also sign with your own Apple Development or Developer ID identity (`SIGN_IDENTITY="<name or SHA-1>" make app`; a self-signed identity does not work there, because the hardened runtime blocks Sparkle.framework), or ad hoc (`SIGN_IDENTITY=- make app`) and click Settings > Mac Setup > **Reset Permission** after each rebuild.
- `make dmg` is optional. It makes `dist/Spool-<version>.dmg`.

To publish a release on GitHub: `make publish-dry`, then `make publish`. See [RELEASING.md](RELEASING.md).

`make app` runs `scripts/build-app.sh`. The script:

1. Reads the version from the `VERSION` file. The build number is `git rev-list --count HEAD`.
2. Builds the app and the `spool` CLI in release mode for arm64 and x86_64.
3. Makes the app icon from `scripts/make-icon.swift` into `.build/icon/AppIcon.icns` (only when it is missing or older than the script).
4. Makes a new `dist/Spool.app` (it deletes the old one first).
5. Signs the bundle from the inside out and verifies it.

You can change the build with these environment variables:

| Variable | Default | Use |
|---|---|---|
| `SIGN_IDENTITY` | the Developer ID of the team in `Packaging/updates.env`, else the local identity from `make-signing-cert.sh`. When a team is set and neither is on this Mac, the build stops. Without a team and without a local identity: `-` (ad hoc) | The codesign identity. |
| `SPOOL_ARCHS` | `arm64 x86_64` | For example `SPOOL_ARCHS=arm64 make app` for a faster build. |
| `SPOOL_FEED_URL` | from `Packaging/updates.env` | The Sparkle appcast URL (https). See "Updates". |
| `SPOOL_ED_PUBLIC_KEY` | from `Packaging/updates.env` | The Sparkle public EdDSA key. See "Updates". |
| `SPOOL_UPDATES` | `on` | `off` builds without updates. |
| `SPOOL_LICENSE_PUBLIC_KEY` | from `Packaging/updates.env` | The public key that checks license keys (32 bytes, base64). See "License". |

### License

Spool costs EUR 0.99 ([LICENSE-KEYS.md](LICENSE-KEYS.md)). A bundled build (`make app`, `make install`, `make dmg`) asks for a license key at its start and does not start the window manager without a valid one. The key must match the public key in the build: `SPOOL_LICENSE_PUBLIC_KEY` in `Packaging/updates.env`. A build from this repository has the key of the owner, so only the owner can issue a key for it. The owner makes one with `spool-license issue` and activates it with `spool license <key>` ([RELEASING.md](RELEASING.md), "License keys"). While the value in `Packaging/updates.env` is empty, `make app` warns and the app cannot accept any key.

A binary from `swift build` (not in an app bundle) does not need a license. This is the build that the tests and `scripts/verify smoke` use.

The bundle has this layout:

```
Spool.app/Contents/
  Info.plist
  MacOS/Spool                       the app (SwiftPM product SpoolApp)
  Helpers/spool                     the CLI
  Frameworks/Sparkle.framework
  Library/LaunchAgents/com.fskroes.Spool.agent.plist
  Resources/AppIcon.icns
```

To make the icon only: `make icon`.

## Install a build from source

```sh
make install
./scripts/install.sh --dry-run
./scripts/install.sh --prefix ~/Applications
```

- `make install` builds, then installs.
- `--dry-run` shows what the install does and changes nothing.
- `--prefix ~/Applications` installs into another folder.

`scripts/install.sh` does these steps:

1. It quits Striple (the old name of Spool) and Spool if they run. The first time, macOS can ask if your terminal can control them. Click OK.
2. It copies `dist/Spool.app` to `/Applications`. If you cannot write to `/Applications`, it uses `~/Applications`.
3. It removes Striple if it finds it. See [Upgrade from Striple](#upgrade-from-striple).
4. It makes the link `~/.local/bin/spool` to `Spool.app/Contents/Helpers/spool`. If `~/.local/bin` is not on your `PATH`, it tells you the line to add to `~/.zshrc`.

### Upgrade from Striple

Spool had the name Striple before. The bundle ID, the URL scheme, the CLI and the folders have the new name too. Your settings, layout and logs come with you.

`make install` (or `./scripts/install.sh`) does the upgrade:

1. It quits Striple, then installs Spool as usual.
2. It finds `Striple.app` where the Striple install could have put it: the app that the `~/.local/bin/striple` link points into, `/Applications` and `~/Applications` (with `--prefix DIR`, also `DIR`). It removes only an app with the bundle ID `com.fskroes.Striple`. If the install stops before Spool is copied, Striple stays: open it again.
3. It runs `Striple --unregister-login`, so the login agent of Striple does not start a deleted app at the next login. Then it removes `Striple.app`, and the `~/.local/bin/striple` link if it points into a removed Striple or into a Striple that is gone. If a step fails, the script shows a warning and continues: Spool is installed already.

When Spool starts the first time, it does these steps before it reads the settings:

1. If Striple still runs, Spool stops it (SIGTERM, the same as a quit) and waits up to 10 seconds. If Striple does not stop, Spool shows a message and quits. Two window managers must not move the same windows.
2. If Striple ran, or a Striple folder is still there, Spool runs `Striple --unregister-login` for that Striple and for the installed `Striple.app`. Then the login agent of Striple does not start it again.
3. It moves `~/Library/Application Support/Striple` to `~/Library/Application Support/Spool`, and `~/Library/Logs/Striple` to `~/Library/Logs/Spool`. A folder moves only when the Spool folder does not exist, so Spool never writes over its own settings. The engine log has a line for each move: "Striple is now Spool: moved … to …". If both folders exist, Spool keeps both and writes "Striple is now Spool: kept …" at each start. Then copy what you need from the Striple folder (for example `config.json`) while Spool does not run, and remove the Striple folder.
4. If the setting "Launch at login" was on in the settings of Striple, Spool turns it on again. Striple updates that setting when you open its Settings window, so a change you made only in System Settings > Login Items does not count. You can turn it off in Settings > General.

You must do these steps yourself:

- **Give Spool the Accessibility permission.** macOS stores the permission with the bundle ID, so the permission of Striple does not apply to Spool. Remove the old entry with `tccutil reset Accessibility com.fskroes.Striple`.
- **Use the new names.** The CLI is `spool`, the URL scheme is `spool://`. The Raycast scripts in `Integrations/Raycast` are named `spool-*.sh` now. Raycast reads them from the same folder, but a hotkey or an alias belongs to one script: give them again.
- **If you copy Spool.app yourself** (not with the install script), delete `Striple.app` after the first start of Spool. Spool turns off the login item of Striple at that start (step 2), so delete it after, not before.

## First run

1. Open Spool: `open /Applications/Spool.app`. Spool shows in the menu bar. It has a Dock icon and a menu bar only while one of its windows is open: Settings, the guide, About or an update window. A minimized window counts as open.
2. Spool asks for Accessibility permission. It needs this permission to move and resize windows.
3. Open System Settings > Privacy & Security > Accessibility and turn on Spool.

If Spool is in the list but does not work, click Settings > Mac Setup > **Reset Permission** in Spool, then turn Spool on again. See [The switch is on, but Spool has no permission](#the-switch-is-on-but-spool-has-no-permission).

## Keep the Accessibility permission after a rebuild

### The problem

macOS stores the Accessibility permission with the "designated requirement" of the app. Apple TN3127 says:

> Ad hoc signed code, called Sign to Run Locally by Xcode, has a DR but it's tied to that specific version of the code.

Source: [TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

An ad hoc signature is a hash of the code (a cdhash). Each build has a new hash. Thus after each `make app` the Accessibility entry no longer matches: the switch still shows on, but Spool has no permission. Then click Settings > Mac Setup > **Reset Permission** (see "The switch is on, but Spool has no permission"). `build-app.sh` shows a warning when it signs ad hoc. You can see this on an ad hoc build:

```sh
codesign -d -r - dist/Spool.app
```

The output is similar to this:

```
designated => cdhash H"2d50fa83..." or cdhash H"29730e60..."
```

### The fix: a local signing certificate

Make a self-signed code signing certificate one time. Then each build has the same designated requirement: the bundle ID plus the hash of your certificate. The permission stays after a rebuild.

```sh
./scripts/make-signing-cert.sh --dry-run
./scripts/make-signing-cert.sh
```

The first command shows the steps. It reads and changes no keychain. The second command makes the identity "Striple Local Signing" and its backup.

This identity is for your own builds. The releases do not use it: they are signed with the Developer ID of the team in `Packaging/updates.env` (`SPOOL_TEAM_ID`). When this Mac has that Developer ID, `make app` uses it and not this identity.

The script can also pin one identity, for a fork that publishes with a self-signed identity: `SPOOL_SIGNING_CERT_SHA1` in `Packaging/updates.env`. This repository sets no pin. With a pin, the second command stops and makes nothing: with a new identity, every installed copy would lose the Accessibility permission after the next update, while the switch still shows on. Restore the pinned identity from its backup with `--import` (see below). To change the pinned identity on purpose, use `./scripts/make-signing-cert.sh --new-identity`. Then set the pin to the new SHA-1, as the script tells you. `SPOOL_UPDATES_ENV` sets another file than `Packaging/updates.env`. If that file is not there, the script stops: a missing file would turn the pin off.

The script:

1. Checks that it can write the backup file. If it cannot, it stops before it changes anything.
2. Makes an RSA key and a certificate with the "Code Signing" extended key usage (`/usr/bin/openssl`, valid 10 years).
3. Writes the backup `~/Striple-signing-identity.p12` (`SPOOL_SIGNING_BACKUP` sets another path). The file is encrypted with a random passphrase. The script writes the passphrase to a file next to the backup, `~/Striple-signing-identity-passphrase.txt`, and does not print it: terminal output stays in scrollback and logs. Only you can read both files. If the passphrase file exists, the script stops before it changes anything. The backup comes first, so a failure in a later step does not lose the key.
4. Makes a separate keychain, `~/Library/Keychains/striple-signing.keychain-db`, with a random password. The keychain does not lock itself.
5. Puts that password in your login keychain as the item "Striple Local Signing keychain". Only `/usr/bin/security` can read it without a prompt.
6. Imports the identity into the new keychain. Only `codesign` can use the key, and `set-key-partition-list` stops the "allow access" prompt.
7. Adds the new keychain to your keychain search list. `codesign` finds identities only in keychains on that list.
8. Signs a test file and checks that its designated requirement names the certificate hash, and that this hash is the one in the backup.
9. Deletes the key files from `.build/signing-cert`.

The script does not ask for your login password. It does not change trust settings. A self-signed certificate does not have to be trusted for `codesign` to use it: the designated requirement uses the certificate hash, not a trust chain. Passwords go to `security` on stdin (`security -i`) and to `openssl` in the environment, so they are not in the argument list that `ps` or a monitoring tool can see. A passphrase can contain `"` and `\`: the script escapes them for `security -i`. It cannot contain a line break, and each `security -i` command must be shorter than 4000 bytes: `security -i` reads 4096 bytes at a time and runs the rest of a longer line as a second command. The script refuses such a value and runs nothing with it.

**Back up the identity.** Put the `.p12` file and its passphrase in your password manager, then delete both files. The key cannot be exported from the keychain later: macOS asks for the password of the Spool keychain, which only the script knows. Without the backup, a new Mac or a lost keychain means a new identity, and every installed Spool loses the Accessibility permission after the next update, while the switch still shows on.

Restore the identity from the backup (on a new Mac, or after `--remove`):

```sh
./scripts/make-signing-cert.sh --import ~/Striple-signing-identity.p12
```

The script asks for the passphrase. `SPOOL_SIGNING_P12_PASSWORD` gives it without a prompt.

When you run the script again and the identity works, the script signs a test file to check it and changes nothing. With `--import`, the identity in the keychain must be the one in the file. If it is another one, the script stops and changes nothing: run `--remove --yes` first. If the keychain is there but not usable (for example, the password item was deleted), the script tells you to run `--remove --yes` first, then `--import` your backup.

With a pin, the script accepts only the pinned identity. It stops and changes nothing when:

- the backup that you import has another SHA-1, or has no private key (also without a pin),
- the keychain has another identity. Remove it with `--remove --yes`, then import the backup of the pinned identity.

After that, `make app` uses the identity automatically, when this Mac has no Developer ID of the team of the releases. It selects the identity by its SHA-1 hash, so a certificate with the same name in another keychain is never used. When `Packaging/updates.env` names a team and `make app` finds neither the Developer ID of that team nor the local identity (not made, not imported, or its keychain does not unlock), `make app` stops: an ad hoc build there gets a grant that no later build matches (see below). Without a team and without a local identity, it signs ad hoc and warns. `SIGN_IDENTITY=- make app` makes an ad hoc test build on purpose. If you give such a build the Accessibility permission, the entry stops working after the next build, while the switch still shows on. Then click Settings > Mac Setup > Reset Permission. `make app` and `make install` warn when the app is not signed by the team of the releases: a grant for an ad hoc app stops working after the next build, and a grant for an app with another identity stops working after an update to a release. In both cases the switch still shows on. After it signs, `build-app.sh` checks that the designated requirement names the certificate (or, for the Developer ID, the team), and stops if it does not. After the first build with the new identity, remove the old Spool entry and give the permission again (see below). Turning the switch off and on is not enough.

Check the identity:

```sh
security find-identity -p codesigning ~/Library/Keychains/striple-signing.keychain-db
codesign -d -r - /Applications/Spool.app
```

The `codesign` output is similar to this:

```
designated => identifier "com.fskroes.Spool" and certificate leaf = H"b608fa4f..."
```

`security find-identity -v` does not show the identity, because `-v` shows only trusted identities. That is correct and does not stop signing.

Remove the identity (the keychain, its password item and its search list entry). Without `--yes` the script only warns, because only the backup can bring the key back:

```sh
./scripts/make-signing-cert.sh --remove --yes
```

When the keychain has the pinned identity, the script deletes it only when you give its backup. This is also true when the script cannot read the identity, because it can be the pinned one. The script reads the backup (the passphrase rules are the same as for `--import`). It deletes the identity only when the certificate in the backup has the pinned SHA-1 and the backup has the private key. Else it stops and deletes nothing.

```sh
./scripts/make-signing-cert.sh --remove --yes --backup ~/Striple-signing-identity.p12
```

The script cannot make a backup of an identity that is in the keychain already. Thus keep the backup that the script wrote when it made the identity.

Notes:

- The local identity has no Apple Team ID. Thus `build-app.sh` does not use the hardened runtime with it. With the hardened runtime, library validation would block Sparkle.framework.
- The certificate is only on your Mac. Other people cannot check it. The releases use a Developer ID and notarization instead: `make publish` notarizes the app and the DMG with `xcrun notarytool` and staples the tickets (see [RELEASING.md](RELEASING.md)). With a Developer ID identity, `build-app.sh` adds `--options runtime --timestamp`.
- On this Mac (Intune managed) the script works: no MDM profile stops a user keychain or user Accessibility grants. If a Mac has rules that stop it, use ad hoc signing (`SIGN_IDENTITY=- make app`). Then after each build, click Settings > Mac Setup > Reset Permission and turn Spool on again.

### The switch is on, but Spool has no permission

Symptom: System Settings > Privacy & Security > Accessibility shows Spool on, but the Spool menu says "Accessibility permission needed", and Mac Setup shows the Accessibility check in red.

Cause: macOS stores an entry with the code requirement of the build that was on screen when the entry was made. Turning the switch off and on changes only the switch, not the stored requirement. When the entry was made for an ad hoc build (before the local identity existed, or with `SIGN_IDENTITY=-`), it stores the cdhashes of that build. No later build matches them.

Check it. `tccd` logs the failed match about once each time Spool starts. Quit Spool and open it again, then run this command. It names the stored requirement and the requirement of the current build:

```sh
/usr/bin/log show --last 5m --style compact \
  --predicate 'process == "tccd" AND eventMessage CONTAINS "Failed to match existing code requirement"' \
  | grep -A2 com.fskroes.Spool
```

The output is similar to this. The first indented line is the stored requirement. The second is the requirement of the current build:

```
Failed to match existing code requirement for subject com.fskroes.Spool and service kTCCServiceAccessibility
	cdhash H"9cba34a0..." or cdhash H"e26922bc..."
	identifier "com.fskroes.Spool" and certificate leaf = H"75929cf2..."
```

Fix: remove the entry, so that macOS makes a new one with the requirement of the current build. Do one of these:

- In Spool: Settings > Mac Setup > **Reset Permission**. Spool removes only its own entry, asks again, and opens System Settings. Turn Spool on. If Spool is not in the list, add `Spool.app` with the plus button. Spool starts in a few seconds, and you do not have to open it again.
- In a terminal: `tccutil reset Accessibility com.fskroes.Spool`. No admin password is necessary. Spool is then not in the list. Click Settings > Mac Setup > **Request Permission** in Spool (opening Spool again does not ask), or add `Spool.app` with the plus button. Then turn Spool on.
- In System Settings: select Spool, click the minus button, then add `Spool.app` again with the plus button.

Do this with a build that is signed with the local identity. Check the copy that runs (`/Applications/Spool.app` after `make install`, `dist/Spool.app` after `make app`): `codesign -d -r - /Applications/Spool.app` must name `certificate leaf`. Then the new entry stores the certificate, and the permission stays after each rebuild. Tested on macOS 26.7.1 on 2026-10-14: a test app signed with the local identity stayed trusted after a rebuild with a new cdhash. The certificate needs no trust setting for this. On an ad hoc build, Reset Permission asks first: a new entry for that build stops working after the next build.

## Launch at login and restart after a crash

The bundle has a launch agent: `Contents/Library/LaunchAgents/com.fskroes.Spool.agent.plist`.

| Key | Value | Why |
|---|---|---|
| `Label` | `com.fskroes.Spool.agent` | The launchd name. |
| `BundleProgram` | `Contents/MacOS/Spool` | The path in the app bundle. You can move the app. |
| `AssociatedBundleIdentifiers` | `com.fskroes.Spool` | System Settings > Login Items shows it as Spool. |
| `RunAtLoad` | true | Start at login. |
| `KeepAlive` > `SuccessfulExit` | false | Start again after a crash or a non-zero exit. Not after Quit (exit status 0). |
| `ProcessType` | `Interactive` | No CPU or I/O throttling for a UI app. |
| `ThrottleInterval` | 5 | Wait at least 5 seconds between two starts. |

When you turn on "Launch at login" in Spool, the app registers the agent with `SMAppService.agent(plistName: "com.fskroes.Spool.agent.plist")`. If that fails, it uses `SMAppService.mainApp` (a normal login item without crash restart). macOS shows a "Background Items Added" notification the first time. You can turn the item off in System Settings > General > Login Items (on macOS 15 and later: Login Items & Extensions).
Then the agent status is `requiresApproval`, and the toggle in Spool shows off with the note "Turned off in System Settings, or waiting for your approval".

`man launchd.plist` says that `BundleProgram` "is only supported for plists that are installed using SMAppService". Do not copy the plist to `~/Library/LaunchAgents`.

### Does SMAppService.agent work with an ad hoc signed app?

Findings (not tested on this Mac, because the build must not register login items):

- The SDK header `ServiceManagement.framework/Headers/SMAppService.h` says: "Apps that use SMAppService APIs must be code signed." An unsigned app gets `kSMErrorInvalidSignature` ("The app's code signature doesn't meet the requirements to perform the operation"). Source: the header in the Command Line Tools SDK, and [Apple: kSMErrorInvalidSignature](https://developer.apple.com/documentation/servicemanagement/ksmerrorinvalidsignature).
- No Apple document says yes or no for ad hoc signatures. Apple DTS is reported to say that ad hoc signing causes lost approvals for background items, and to tell people to sign with an Apple-issued identity: Apple Developer Forums [thread 799910](https://developer.apple.com/forums/thread/799910) and [thread 782645](https://developer.apple.com/forums/thread/782645). These forum pages need a browser check, so the quotes were not read directly. They come from the research notes in [jnsdls/slopwatch#32](https://github.com/jnsdls/slopwatch/issues/32).
- Notarization is necessary only for apps with launch daemons, not for launch agents (SMAppService.h: "Apps that contain LaunchDaemons must be notarized").

What this means: an ad hoc build can probably register the agent, but the approval can stop matching after a rebuild, the same as the Accessibility entry. Use the local signing certificate (above) or a Developer ID. To check the result on your Mac: turn on "Launch at login", then run `sfltool dumpbtm | grep -A8 com.fskroes.Spool` and `launchctl print gui/$(id -u)/com.fskroes.Spool.agent`.

### After an update

SMAppService.h says: "If an app updates either the plist or the executable for a LaunchAgent or LaunchDaemon, the SMAppService must be re-registered or it may not launch. It is recommended to also call unregister before re-registering if the executable has been changed." Spool does this itself. At launch it compares the build stamp with the stamp it registered last (the `LoginItemRegisteredBuild` default). The stamp is `CFBundleVersion` plus the modification time of the executable, so a rebuild without a new commit also counts as a change. If the stamps differ and the agent is on, Spool unregisters and registers the agent again. It does not do this when the agent started the process, because unregistering would stop that process. The next manual start does it.

The same header says: "If the service corresponds to a LoginItem, LaunchAgent, or LaunchDaemon and the service is currently running it will be killed." So when the agent started Spool and you turn off "Open Spool when you log in", Spool keeps running. It removes the agent when you quit it (the `LoginItemOffAtQuit` default). If Spool stops in a different way, the next manual start removes the agent.

Spool uses the plain login item only when the agent is `notRegistered` or `notFound`. When the agent waits for your approval (`requiresApproval`), Spool does not add a second item, because both would start Spool after you approve.

## Updates (Sparkle)

Spool uses [Sparkle 2](https://sparkle-project.org) (version 2.10.0, from SwiftPM). Updates come from the releases of [fskroes/spool-releases](https://github.com/fskroes/spool-releases/releases). `build-app.sh` reads the feed URL and the public EdDSA key from `Packaging/updates.env` and writes `SUFeedURL`, `SUPublicEDKey` and `SUEnableAutomaticChecks` into the Info.plist. Then Spool checks for updates every 24 hours, and "Check for Updates…" in the menu is on.

`SPOOL_UPDATES=off make app` builds without updates. Without the keys, Spool makes no Sparkle object and shows no update errors. This is also true for `swift run`.

To publish a release, see [RELEASING.md](RELEASING.md).

## Use on a managed work Mac

A window manager controls the windows of all your apps. On a Mac that your employer manages, ask before you
use it. This section lists what Spool does, what the Mac allows, and who decides.

### What Spool does on the Mac

| Item | Spool |
|---|---|
| Permission | Accessibility only. You give it in System Settings > Privacy & Security. It is not given automatically. |
| Admin rights | Not necessary. It is a normal app in `/Applications` or `~/Applications`. No kernel or system extension, no daemon, no installer package. For launch at login it registers its own user LaunchAgent (see [Launch at login](#launch-at-login-and-restart-after-a-crash)). |
| Keyboard | Global shortcuts with `RegisterEventHotKey`. Spool does not read what you type. It asks only for the time since the last input (`CGEventSource.secondsSinceLastEventType`). |
| Mouse and trackpad | A listen-only event tap for trackpad gestures, and global monitors for mouse down and mouse up. |
| Private frameworks | SkyLight (window focus) and MultitouchSupport (trackpad swipes). See "Known limits" in the [README](../README.md). |
| Network | Only Sparkle update checks: the feed on github.com in `Packaging/updates.env`. A build with `SPOOL_UPDATES=off make app` has no feed and makes no network calls. |
| Data | Config and state in `~/Library/Application Support/Spool`, logs in `~/Library/Logs/Spool`. Only the update check leaves the Mac. |

### What the Mac allows (technical controls)

You can see the device profiles without admin rights: `system_profiler SPConfigurationProfileDataType`. On the
NN Mac where Spool was made (2026-10-12) the result was:

| Control | Result | Effect on Spool |
|---|---|---|
| Gatekeeper (`AllowIdentifiedDevelopers = 1`) | Apps from identified developers are allowed | The release is a notarized Developer ID app, so Gatekeeper allows it. A self-signed build with the quarantine flag is blocked. See [Install the release](#install-the-release). |
| Privacy (TCC) profiles | They only allow access for named apps (OneDrive, Edge, Defender, Intune and others). No profile denies Accessibility. | You can give Spool the Accessibility permission. |
| App block lists | None | Spool can run. |
| Security tools | Microsoft Defender and Zscaler are installed | They can see and report the app. |

A technical control that allows something is not a policy that permits it. These checks show only that Spool
can run.

### What the policy says

| Source | What it says |
|---|---|
| ServiceNow KB0011506, KB0022286 | Software requests go through the Packaging process in the ServiceNow portal. Software that is not packaged is not a reason for local admin rights. |
| ServiceNow KB0029698 | Proctoring software is not allowed. |
| Window managers, Accessibility tools | No knowledge article covers them (search on 2026-10-12). |

### Who decides

The decision is not Spool's to make. It is yours and NN IT's. Before you use Spool on a work Mac, do one of
these:

1. Make a software request in the ServiceNow portal (Packaging). Give this text:
   "Spool: a scrolling window manager for macOS, built from source by me. It needs the Accessibility
   permission. No admin rights, no extensions, no network except update checks on github.com
   (off when built with SPOOL_UPDATES=off)."
2. Ask your Business Security Officer (BSO) if a self-built Accessibility app is permitted.

Until you have an answer, use Spool only on a Mac that you own.

## Uninstall

```sh
make uninstall
./scripts/install.sh --uninstall --dry-run
```

`make uninstall` runs `./scripts/install.sh --uninstall`. The second command shows what the uninstall does and changes nothing.

The script first quits Spool. Then it runs `Spool --unregister-login`, which removes the login agent and the login item. This order is necessary: if the agent started Spool, removing the agent first would stop Spool without a clean quit. Then the script removes the app and the `~/.local/bin/spool` link. With `--prefix`, the link is kept when it points to a Spool in another folder that is not removed.

Without `--prefix`, the script removes every Spool it finds: the app that the `spool` link points into, `/Applications/Spool.app` and `~/Applications/Spool.app`. So you do not have to remember the folder you installed into. An app with another bundle ID at one of these paths is kept. With `--prefix DIR`, only `DIR/Spool.app` is removed. The script does not remove your settings and logs. It shows the commands to remove them yourself:

```sh
rm -r ~/Library/Application\ Support/Spool
rm -r ~/Library/Logs/Spool
tccutil reset Accessibility com.fskroes.Spool
```

These commands remove the settings, the logs and the Accessibility permission, in this sequence.
