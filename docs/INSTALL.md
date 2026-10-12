# Install Striple

This page tells you how to build, install, sign, update and remove Striple.

## Requirements

- macOS 13 or later.
- The Xcode Command Line Tools with Swift 6 (`xcode-select --install`). Xcode is not necessary.
- An internet connection for the first build. SwiftPM downloads Sparkle (the update framework).

The app is a universal binary (Apple silicon and Intel).

## Build from source

```sh
make test     # run the tests
make app      # build and sign dist/Striple.app
make dmg      # optional: make dist/Striple-<version>.dmg
```

To publish a release on GitHub: `make publish-dry`, then `make publish`. See [RELEASING.md](RELEASING.md).

`make app` runs `scripts/build-app.sh`. The script:

1. Reads the version from the `VERSION` file. The build number is `git rev-list --count HEAD`.
2. Builds the app and the `striple` CLI in release mode for arm64 and x86_64.
3. Makes the app icon from `scripts/make-icon.swift` into `.build/icon/AppIcon.icns` (only when it is missing or older than the script).
4. Makes a new `dist/Striple.app` (it deletes the old one first).
5. Signs the bundle from the inside out and verifies it.

You can change the build with these environment variables:

| Variable | Default | Use |
|---|---|---|
| `SIGN_IDENTITY` | the local identity from `make-signing-cert.sh` if it exists, else `-` (ad hoc) | The codesign identity. |
| `STRIPLE_ARCHS` | `arm64 x86_64` | For example `STRIPLE_ARCHS=arm64 make app` for a faster build. |
| `STRIPLE_FEED_URL` | from `Packaging/updates.env` | The Sparkle appcast URL (https). See "Updates". |
| `STRIPLE_ED_PUBLIC_KEY` | from `Packaging/updates.env` | The Sparkle public EdDSA key. See "Updates". |
| `STRIPLE_UPDATES` | `on` | `off` builds without updates. |

The bundle has this layout:

```
Striple.app/Contents/
  Info.plist
  MacOS/Striple                       the app (SwiftPM product StripleApp)
  Helpers/striple                     the CLI
  Frameworks/Sparkle.framework
  Library/LaunchAgents/com.fskroes.Striple.agent.plist
  Resources/AppIcon.icns
```

To make the icon only: `make icon`.

## Install

```sh
make install                                    # build, then install
./scripts/install.sh --dry-run                  # show what install does, change nothing
./scripts/install.sh --prefix ~/Applications    # install into another folder
```

`scripts/install.sh` does these steps:

1. It quits Striple if it runs. The first time, macOS can ask if your terminal can control Striple. Click OK.
2. It copies `dist/Striple.app` to `/Applications`. If you cannot write to `/Applications`, it uses `~/Applications`.
3. It makes the link `~/.local/bin/striple` to `Striple.app/Contents/Helpers/striple`. If `~/.local/bin` is not on your `PATH`, it tells you the line to add to `~/.zshrc`.

### Install a published release

Releases are at [fskroes/striple-releases](https://github.com/fskroes/striple-releases/releases). Download with `curl`, not with a browser:

```sh
curl -fsSL -o /tmp/Striple.dmg https://github.com/fskroes/striple-releases/releases/latest/download/Striple.dmg
hdiutil attach -nobrowse -readonly -mountpoint /tmp/striple-dmg /tmp/Striple.dmg
ditto /tmp/striple-dmg/Striple.app /Applications/Striple.app
hdiutil detach /tmp/striple-dmg && rm /tmp/Striple.dmg
ln -sf /Applications/Striple.app/Contents/Helpers/striple ~/.local/bin/striple
```

Why: a browser adds the quarantine flag (`com.apple.quarantine`) to a download. For an app with that flag, Gatekeeper accepts only Apple and Developer ID signatures. Striple is signed with the local certificate, so `spctl -a -t exec` says `rejected` and macOS does not open it. `curl` does not add the flag. Gatekeeper checks only apps with the flag, so the app opens. If you downloaded with a browser: System Settings > Privacy & Security > "Open Anyway" (needs an admin password), or `xattr -dr com.apple.quarantine /Applications/Striple.app`.

Sparkle updates do not have this problem: Sparkle removes the quarantine flag from the update before it installs it.

## First run

1. Open Striple: `open /Applications/Striple.app`. Striple has no Dock icon. It shows in the menu bar.
2. Striple asks for Accessibility permission. It needs this permission to move and resize windows.
3. Open System Settings > Privacy & Security > Accessibility and turn on Striple.

If Striple is in the list but does not work, remove it from the list with the minus button, then add it again.

## Keep the Accessibility permission after a rebuild

### The problem

macOS stores the Accessibility permission with the "designated requirement" of the app. Apple TN3127 says:

> Ad hoc signed code, called Sign to Run Locally by Xcode, has a DR but it's tied to that specific version of the code.

Source: [TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

An ad hoc signature is a hash of the code (a cdhash). Each build has a new hash. Thus macOS forgets the permission after each `make app`. `build-app.sh` shows a warning when it signs ad hoc. You can see this on an ad hoc build:

```sh
codesign -d -r - dist/Striple.app
# designated => cdhash H"2d50fa83..." or cdhash H"29730e60..."
```

### The fix: a local signing certificate

Make a self-signed code signing certificate one time. Then each build has the same designated requirement: the bundle ID plus the hash of your certificate. The permission stays after a rebuild.

```sh
./scripts/make-signing-cert.sh --dry-run   # show the steps; reads and changes no keychain
./scripts/make-signing-cert.sh             # make the identity "Striple Local Signing" and its backup
```

The script:

1. Makes an RSA key and a certificate with the "Code Signing" extended key usage (`/usr/bin/openssl`, valid 10 years).
2. Makes a separate keychain, `~/Library/Keychains/striple-signing.keychain-db`, with a random password. The keychain does not lock itself.
3. Puts that password in your login keychain as the item "Striple Local Signing keychain". Only `/usr/bin/security` can read it without a prompt.
4. Imports the identity into the new keychain. Only `codesign` can use the key, and `set-key-partition-list` stops the "allow access" prompt.
5. Adds the new keychain to your keychain search list. `codesign` finds identities only in keychains on that list.
6. Signs a test file and checks that its designated requirement names the certificate hash.
7. Writes the backup `~/Striple-signing-identity.p12` (`STRIPLE_SIGNING_BACKUP` sets another path). The file is encrypted with a random passphrase that the script prints one time.
8. Deletes the key files from `.build/signing-cert`.

The script does not ask for your login password. It does not change trust settings. A self-signed certificate does not have to be trusted for `codesign` to use it: the designated requirement uses the certificate hash, not a trust chain. Passwords go to `security` on stdin (`security -i`) and to `openssl` in the environment, so they are not in the argument list that `ps` or a monitoring tool can see.

**Back up the identity.** Put the `.p12` file and its passphrase in your password manager, then delete the file. The key cannot be exported from the keychain later: macOS asks for the password of the Striple keychain, which only the script knows. Without the backup, a new Mac or a lost keychain means a new identity, and macOS asks every installed Striple for the Accessibility permission again.

Restore the identity from the backup (on a new Mac, or after `--remove`):

```sh
./scripts/make-signing-cert.sh --import ~/Striple-signing-identity.p12   # asks for the passphrase
```

When you run the script again and the identity works, the script does nothing. If the keychain is there but not usable (for example, the password item was deleted), the script tells you to run `--remove --yes` first, then `--import` your backup.

After that, `make app` uses the identity automatically. It selects the identity by its SHA-1 hash, so a certificate with the same name in another keychain is never used. After it signs, `build-app.sh` checks that the designated requirement names the certificate, and stops if it does not. Give the Accessibility permission one more time after the first build with the new identity.

Check the identity:

```sh
security find-identity -p codesigning ~/Library/Keychains/striple-signing.keychain-db
codesign -d -r - /Applications/Striple.app
# designated => identifier "com.fskroes.Striple" and certificate leaf = H"b608fa4f..."
```

`security find-identity -v` does not show the identity, because `-v` shows only trusted identities. That is correct and does not stop signing.

Remove the identity (the keychain, its password item and its search list entry). Without `--yes` the script only warns, because only the backup can bring the key back:

```sh
./scripts/make-signing-cert.sh --remove --yes
```

Notes:

- The local identity has no Apple Team ID. Thus `build-app.sh` does not use the hardened runtime with it. With the hardened runtime, library validation would block Sparkle.framework.
- The certificate is only on your Mac. Other people cannot check it. To give Striple to other people, use a Developer ID certificate and notarization: `SIGN_IDENTITY="Developer ID Application: ..." make app`. With a Developer ID identity, `build-app.sh` adds `--options runtime --timestamp`. Notarization (`xcrun notarytool`) is not in the scripts.
- On this Mac (Intune managed) the script works: no MDM profile stops a user keychain or user Accessibility grants. If a Mac has rules that stop it, use ad hoc signing and give the permission again after each build.

## Launch at login and restart after a crash

The bundle has a launch agent: `Contents/Library/LaunchAgents/com.fskroes.Striple.agent.plist`.

| Key | Value | Why |
|---|---|---|
| `Label` | `com.fskroes.Striple.agent` | The launchd name. |
| `BundleProgram` | `Contents/MacOS/Striple` | The path in the app bundle. You can move the app. |
| `AssociatedBundleIdentifiers` | `com.fskroes.Striple` | System Settings > Login Items shows it as Striple. |
| `RunAtLoad` | true | Start at login. |
| `KeepAlive` > `SuccessfulExit` | false | Start again after a crash or a non-zero exit. Not after Quit (exit status 0). |
| `ProcessType` | `Interactive` | No CPU or I/O throttling for a UI app. |
| `ThrottleInterval` | 5 | Wait at least 5 seconds between two starts. |

When you turn on "Launch at login" in Striple, the app registers the agent with `SMAppService.agent(plistName: "com.fskroes.Striple.agent.plist")`. If that fails, it uses `SMAppService.mainApp` (a normal login item without crash restart). macOS shows a "Background Items Added" notification the first time. You can turn the item off in System Settings > General > Login Items (on macOS 15 and later: Login Items & Extensions).
Then the agent status is `requiresApproval`, and the toggle in Striple shows off with the note "Turned off in System Settings, or waiting for your approval".

`man launchd.plist` says that `BundleProgram` "is only supported for plists that are installed using SMAppService". Do not copy the plist to `~/Library/LaunchAgents`.

### Does SMAppService.agent work with an ad hoc signed app?

Findings (not tested on this Mac, because the build must not register login items):

- The SDK header `ServiceManagement.framework/Headers/SMAppService.h` says: "Apps that use SMAppService APIs must be code signed." An unsigned app gets `kSMErrorInvalidSignature` ("The app's code signature doesn't meet the requirements to perform the operation"). Source: the header in the Command Line Tools SDK, and [Apple: kSMErrorInvalidSignature](https://developer.apple.com/documentation/servicemanagement/ksmerrorinvalidsignature).
- No Apple document says yes or no for ad hoc signatures. Apple DTS is reported to say that ad hoc signing causes lost approvals for background items, and to tell people to sign with an Apple-issued identity: Apple Developer Forums [thread 799910](https://developer.apple.com/forums/thread/799910) and [thread 782645](https://developer.apple.com/forums/thread/782645). These forum pages need a browser check, so the quotes were not read directly. They come from the research notes in [jnsdls/slopwatch#32](https://github.com/jnsdls/slopwatch/issues/32).
- Notarization is necessary only for apps with launch daemons, not for launch agents (SMAppService.h: "Apps that contain LaunchDaemons must be notarized").

What this means: an ad hoc build can probably register the agent, but macOS can forget the approval after a rebuild, the same as the Accessibility permission. Use the local signing certificate (above) or a Developer ID. To check the result on your Mac: turn on "Launch at login", then run `sfltool dumpbtm | grep -A8 com.fskroes.Striple` and `launchctl print gui/$(id -u)/com.fskroes.Striple.agent`.

### After an update

SMAppService.h says: "If an app updates either the plist or the executable for a LaunchAgent or LaunchDaemon, the SMAppService must be re-registered or it may not launch. It is recommended to also call unregister before re-registering if the executable has been changed." Striple does this itself. At launch it compares the build stamp with the stamp it registered last (the `LoginItemRegisteredBuild` default). The stamp is `CFBundleVersion` plus the modification time of the executable, so a rebuild without a new commit also counts as a change. If the stamps differ and the agent is on, Striple unregisters and registers the agent again. It does not do this when the agent started the process, because unregistering would stop that process. The next manual start does it.

The same header says: "If the service corresponds to a LoginItem, LaunchAgent, or LaunchDaemon and the service is currently running it will be killed." So when the agent started Striple and you turn off "Open Striple when you log in", Striple keeps running. It removes the agent when you quit it (the `LoginItemOffAtQuit` default). If Striple stops in a different way, the next manual start removes the agent.

Striple uses the plain login item only when the agent is `notRegistered` or `notFound`. When the agent waits for your approval (`requiresApproval`), Striple does not add a second item, because both would start Striple after you approve.

## Updates (Sparkle)

Striple uses [Sparkle 2](https://sparkle-project.org) (version 2.10.0, from SwiftPM). Updates come from the public repository [fskroes/striple-releases](https://github.com/fskroes/striple-releases). `build-app.sh` reads the feed URL and the public EdDSA key from `Packaging/updates.env` and writes `SUFeedURL`, `SUPublicEDKey` and `SUEnableAutomaticChecks` into the Info.plist. Then Striple checks for updates every 24 hours, and "Check for Updates…" in the menu is on.

`STRIPLE_UPDATES=off make app` builds without updates. Without the keys, Striple makes no Sparkle object and shows no update errors. This is also true for `swift run`.

To publish a release, see [RELEASING.md](RELEASING.md).

## Uninstall

```sh
make uninstall                            # or: ./scripts/install.sh --uninstall
./scripts/install.sh --uninstall --dry-run
```

The script first quits Striple. Then it runs `Striple --unregister-login`, which removes the login agent and the login item. This order is necessary: if the agent started Striple, removing the agent first would stop Striple without a clean quit. Then the script removes the app and the `~/.local/bin/striple` link. With `--prefix`, the link is kept when it points to a Striple in another folder that is not removed.

Without `--prefix`, the script removes every Striple it finds: the app that the `striple` link points into, `/Applications/Striple.app` and `~/Applications/Striple.app`. So you do not have to remember the folder you installed into. An app with another bundle ID at one of these paths is kept. With `--prefix DIR`, only `DIR/Striple.app` is removed. The script does not remove your settings and logs. It shows the commands to remove them yourself:

```sh
rm -r ~/Library/Application\ Support/Striple    # settings
rm -r ~/Library/Logs/Striple                    # logs
tccutil reset Accessibility com.fskroes.Striple # Accessibility permission
```
