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

`make app` runs `scripts/build-app.sh`. The script:

1. Reads the version from the `VERSION` file. The build number is `git rev-list --count HEAD`.
2. Builds the app and the `striple` CLI in release mode for arm64 and x86_64.
3. Makes the app icon from `scripts/make-icon.swift` into `.build/icon/AppIcon.icns` (only when it is missing or older than the script).
4. Makes a new `dist/Striple.app` (it deletes the old one first).
5. Signs the bundle from the inside out and verifies it.

You can change the build with these environment variables:

| Variable | Default | Use |
|---|---|---|
| `SIGN_IDENTITY` | `Striple Local Signing` if it is in your keychain, else `-` (ad hoc) | The codesign identity. |
| `STRIPLE_ARCHS` | `arm64 x86_64` | For example `STRIPLE_ARCHS=arm64 make app` for a faster build. |
| `STRIPLE_FEED_URL` | not set | The Sparkle appcast URL (https). See "Updates". |
| `STRIPLE_ED_PUBLIC_KEY` | not set | The Sparkle public EdDSA key. See "Updates". |

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
./scripts/make-signing-cert.sh --dry-run   # show the steps, do not change the keychain
./scripts/make-signing-cert.sh             # make the identity "Striple Local Signing"
```

The script:

1. Makes an RSA key and a certificate with the "Code Signing" extended key usage (`/usr/bin/openssl`, valid 10 years).
2. Imports them into your login keychain (`security import`). Only `codesign` can use the key without a prompt.
3. Trusts the certificate for code signing (`security add-trusted-cert -p codeSign`). macOS asks for your login password.
4. Deletes the key files from `.build/signing-cert`.

When you run the script again, it first checks the identity. If it is valid, the script does nothing. If the certificate is there but step 3 did not finish (for example, you cancelled the password prompt), the script does only step 3 again. If the certificate is there without its private key, the script tells you how to remove it.

After that, `make app` uses the identity automatically. Give the Accessibility permission one more time after the first build with the new identity.

Check the identity:

```sh
security find-identity -v -p codesigning            # shows "Striple Local Signing"
codesign -d -r - /Applications/Striple.app          # the designated requirement
```

Remove the identity:

```sh
security delete-identity -c "Striple Local Signing"
```

Notes:

- The local identity has no Apple Team ID. Thus `build-app.sh` does not use the hardened runtime with it. With the hardened runtime, library validation would block Sparkle.framework.
- The certificate is only on your Mac. Other people cannot check it. To give Striple to other people, use a Developer ID certificate and notarization: `SIGN_IDENTITY="Developer ID Application: ..." make app`. With a Developer ID identity, `build-app.sh` adds `--options runtime --timestamp`. Notarization (`xcrun notarytool`) is not in the scripts.
- Your Mac can have rules (MDM) that stop changes to the keychain or to trust settings. Then use ad hoc signing and give the permission again after each build.

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

Striple uses [Sparkle 2](https://sparkle-project.org) (version 2.10.0, from SwiftPM). Updates are off by default. A build has updates only when you set both `STRIPLE_FEED_URL` and `STRIPLE_ED_PUBLIC_KEY`. Then `build-app.sh` writes `SUFeedURL`, `SUPublicEDKey` and `SUEnableAutomaticChecks` into the Info.plist, and "Check for Updates…" in the menu is on. Without the keys, Striple makes no Sparkle object and shows no update errors. This is also true for `swift run`.

### Decisions for the owner (Fernando)

- **Hosting.** Sparkle needs an HTTPS URL for the appcast (`appcast.xml`) and the update archives. For example GitHub Releases plus GitHub Pages, or an S3 bucket with CloudFront. Not decided.
- **Signing keys.** One EdDSA key pair. The private key stays in the login keychain of the Mac that publishes. Keep a backup (`generate_keys -x`). If you lose it, old installs cannot accept new updates.
- **Code signing for releases.** Build releases with the same identity each time (the local certificate on one Mac, or a Developer ID). If the identity changes, macOS asks for Accessibility permission again after the update.

### The Sparkle tools

SwiftPM puts the Sparkle tools in the build folder after `swift package resolve` (or any build):

```
.build/artifacts/sparkle/Sparkle/bin/generate_keys
.build/artifacts/sparkle/Sparkle/bin/generate_appcast
.build/artifacts/sparkle/Sparkle/bin/sign_update
```

### Publish an update

1. One time: make the key pair. The tool prints the public key.

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys        # make or show the key
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -p     # show the public key only
   ```

2. Increase the version in `VERSION` and commit. The build number comes from the commit count, so it must be higher than the last release.
3. Build with the feed and the key:

   ```sh
   STRIPLE_FEED_URL=https://<your-host>/striple/appcast.xml \
   STRIPLE_ED_PUBLIC_KEY=<public key from step 1> \
   make app
   ```

4. Make the update archive. Keep symlinks (Sparkle.framework has symlinks):

   ```sh
   mkdir -p releases
   ditto -c -k --sequesterRsrc --keepParent dist/Striple.app "releases/Striple-$(cat VERSION).zip"
   ```

5. Make or update the appcast. The tool signs each archive with the private key from your keychain:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_appcast \
       --download-url-prefix https://<your-host>/striple/ releases/
   ```

6. Upload `releases/appcast.xml` and the new archive to the host. Do not change the old archives.

Source: [Sparkle: Documentation](https://sparkle-project.org/documentation/) and [Sparkle: Publishing an update](https://sparkle-project.org/documentation/publishing/).

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
