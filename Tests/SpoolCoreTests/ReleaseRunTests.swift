import Foundation
import Testing

/// Runs the real scripts/release.sh and scripts/release-lib.sh end to end, in a temporary Git repository on
/// `main`. Each test changes one thing from a setup that publishes, and checks that the run stops with the
/// message of that check, before the upload and before the tag.
///
/// Every tool that would build, sign, read a keychain or use the network is a fake, so a run takes about a
/// second. PATH has only the fakes and the system folders: the real `gh` (Homebrew) cannot run.
/// - scripts/signing-env.sh: a fake. release.sh uses only `spool_developer_id` from it, which prints
///   FAKE_HASH (the SHA-1 of the Developer ID identity). The real parser is tested in ReleaseScriptTests; a
///   fake here means no `security` call at all.
/// - scripts/build-app.sh, scripts/make-dmg.sh: write a small Spool.app with a real Info.plist (FAKE_* change
///   its values) and a "DMG" that is a zip. `hdiutil attach` unpacks it at the mount point.
/// - Sparkle tools: generate_keys prints the key, generate_appcast writes a real one-item appcast.
/// - gh: logs each call to gh.log. `release create` copies the assets into the fake web folder, `release edit`
///   makes that appcast the latest one. curl serves the web folder (404 for a missing file).
/// - codesign: the requirement is the Developer ID form, for the team in Contents/_CodeSignature/team.
/// - xcrun: notarytool accepts each file (FAKE_NOTARY_* change the answer) and logs to xcrun.log; stapler
///   writes Contents/CodeResources into an app, or a marker in the state folder for a DMG.
/// - spctl: accepts the file as "Notarized Developer ID" (FAKE_GATEKEEPER_* reject it).
/// Real tools: git, ditto, shasum, plutil, xmllint, unzip, stat, cmp.
@Suite struct ReleaseRunTests {
    /// The SHA-1 of the Developer ID identity, and the team of the releases.
    static let devid = "B608FA4F3D9A1FC14CDBAB47421A660E429053DC"
    static let team = "A1B2C3D4E5"
    static let otherTeam = "Z9Y8X7W6V5"
    static let profile = "spool-test-notary"
    static let key = Data(repeating: 7, count: 32).base64EncodedString()
    static let otherKey = Data(repeating: 9, count: 32).base64EncodedString()
    /// The license public key of the fixture, and another valid one.
    static let licenseKey = Data(repeating: 5, count: 32).base64EncodedString()
    static let otherLicenseKey = Data(repeating: 6, count: 32).base64EncodedString()
    /// publicKeyA of docs/license-test-vectors.json: the test key, whose seed is public.
    static var testLicenseKey: String { LicenseKeyTests.vectors.publicKeyA }
    static let releases = "fskroes/spool-test"
    /// The private source repository: a release is built from a commit on its main.
    static let source = "fskroes/spool-test-source"
    /// The commit GitHub tags in the releases repository: its own main, not a commit of the source.
    static let releasesMain = "fedcba9876543210fedcba9876543210fedcba98"
    static let feed = "https://github.com/\(releases)/releases/latest/download/appcast.xml"
    static let version = "1.2.0"
    /// The temporary repository has three commits.
    static let build = 3

    struct Result {
        var output: String
        var error: String
        var status: Int32
        var all: String { output + error }
    }

    /// One temporary repository with its fakes. Deleted when the test ends.
    final class Fixture {
        let base: URL
        var repo: URL { base.appendingPathComponent("repo") }
        var bin: URL { base.appendingPathComponent("bin") }
        var web: URL { base.appendingPathComponent("web") }
        var state: URL { base.appendingPathComponent("state") }
        var ghLog: URL { base.appendingPathComponent("gh.log") }
        var xcrunLog: URL { base.appendingPathComponent("xcrun.log") }
        var out: URL { repo.appendingPathComponent("dist/release/\(ReleaseRunTests.version)") }

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("spool-run-\(UUID().uuidString)")
            for dir in [repo, bin, web, state, base.appendingPathComponent("home"), base.appendingPathComponent("tmp")] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let scripts = ReleaseScriptTests.root.appendingPathComponent("scripts")
            for name in ["release.sh", "release-lib.sh"] {
                try FileManager.default.copyItem(at: scripts.appendingPathComponent(name),
                                                 to: repo.appendingPathComponent("scripts/\(name)").creatingParent())
            }
            try FileManager.default.copyItem(at: ReleaseScriptTests.root.appendingPathComponent("docs/license-test-vectors.json"),
                                             to: repo.appendingPathComponent("docs/license-test-vectors.json").creatingParent())
            try writeFakes()
            try write("VERSION", ReleaseRunTests.version + "\n")
            try write("CHANGELOG.md", "# Changelog\n\n## 1.2.0\n\n- A test release.\n\n## 1.1.0\n\n- Older.\n")
            try write("Packaging/updates.env", """
            SPOOL_RELEASES_REPO=\(ReleaseRunTests.releases)
            SPOOL_SOURCE_REPO=\(ReleaseRunTests.source)
            SPOOL_FEED_URL=\(ReleaseRunTests.feed)
            SPOOL_ED_PUBLIC_KEY=\(ReleaseRunTests.key)
            SPOOL_ED_KEY_ACCOUNT=com.fskroes.Striple
            SPOOL_LICENSE_PUBLIC_KEY=\(ReleaseRunTests.licenseKey)
            SPOOL_TEAM_ID=\(ReleaseRunTests.team)
            SPOOL_NOTARY_PROFILE=\(ReleaseRunTests.profile)

            """)
            try write(".gitignore", ".build/\ndist/\n")
            try sh("git init -q -b main && git add -A && git commit -qm one && git commit -q --allow-empty -m two && git commit -q --allow-empty -m three")
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        /// Writes a file in the repository (or at an absolute URL).
        func write(_ path: String, _ text: String, executable: Bool = false) throws {
            try write(repo.appendingPathComponent(path), text, executable: executable)
        }

        func write(_ url: URL, _ text: String, executable: Bool = false) throws {
            try Data(text.utf8).write(to: url.creatingParent())
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }

        var environment: [String: String] {
            [
                "PATH": bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": base.appendingPathComponent("home").path,
                "USER": "spool-test-user",
                "TMPDIR": base.appendingPathComponent("tmp").path + "/",
                "LANG": "en_US.UTF-8",
                "FAKE_HASH": ReleaseRunTests.devid,
            ].merging(ReleaseScriptTests.gitEnv) { $1 }
        }

        func exec(_ tool: String, _ args: [String], env extra: [String: String] = [:]) throws -> Result {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.currentDirectoryURL = repo
            p.environment = environment.merging(extra) { $1 }
            let errFile = base.appendingPathComponent("stderr-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: errFile.path, contents: nil)
            let err = try FileHandle(forWritingTo: errFile)
            defer { try? FileManager.default.removeItem(at: errFile) }
            let out = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let o = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            try err.close()
            let e = try Data(contentsOf: errFile)
            return Result(output: String(decoding: o, as: UTF8.self), error: String(decoding: e, as: UTF8.self),
                          status: p.terminationStatus)
        }

        /// Runs a command in the repository with bash. Throws when it fails.
        @discardableResult
        func sh(_ command: String) throws -> String {
            let r = try exec("/bin/bash", ["-c", command])
            guard r.status == 0 else { throw Failure(text: "\(command): \(r.all)") }
            return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Runs scripts/release.sh.
        func release(_ args: String..., env: [String: String] = [:]) throws -> Result {
            try exec("/bin/bash", [repo.appendingPathComponent("scripts/release.sh").path] + args, env: env)
        }

        func head() throws -> String { try sh("git rev-parse HEAD") }
        func tags() throws -> String { try sh("git tag -l") }
        var ghCalls: String { (try? String(contentsOf: ghLog, encoding: .utf8)) ?? "" }
        var xcrunCalls: String { (try? String(contentsOf: xcrunLog, encoding: .utf8)) ?? "" }
        var uploaded: Bool { ghCalls.contains("release create") }

        /// A published release `version` in the fake web: its appcast is the latest, and its archive has an app
        /// signed by `team` and the update key `key`.
        func publish(version: String, build: Int, team: String = ReleaseRunTests.team, key: String = ReleaseRunTests.key) throws {
            let dir = base.appendingPathComponent("published-\(UUID().uuidString)")
            let app = dir.appendingPathComponent("Spool.app/Contents")
            try write(app.appendingPathComponent("Info.plist"),
                      Fixture.plist(version: version, build: "\(build)", feed: ReleaseRunTests.feed, key: key))
            try write(app.appendingPathComponent("_CodeSignature/team"), team + "\n")
            try write(app.appendingPathComponent("MacOS/Spool"), "fake app binary\n")
            let url = "https://github.com/\(ReleaseRunTests.releases)/releases/download/v\(version)/Spool-\(version).zip"
            let zip = web.appendingPathComponent(String(url.dropFirst("https://".count)))
            try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try sh("ditto -c -k --keepParent '\(dir.appendingPathComponent("Spool.app").path)' '\(zip.path)'")
            let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int ?? 0
            try write(web.appendingPathComponent(String(ReleaseRunTests.feed.dropFirst("https://".count))), """
            <?xml version="1.0" standalone="yes"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Spool</title>
            <item><title>\(version)</title><sparkle:version>\(build)</sparkle:version><sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
            <enclosure url="\(url)" length="\(size)" type="application/octet-stream" sparkle:edSignature="c2ln"/></item>
            </channel></rss>

            """)
        }

        /// The published feed has this text.
        func feed(_ text: String) throws {
            try write(web.appendingPathComponent(String(ReleaseRunTests.feed.dropFirst("https://".count))), text)
        }

        /// The archive of the published `version`, in the fake web.
        func publishedZip(_ version: String) -> URL {
            web.appendingPathComponent("github.com/\(ReleaseRunTests.releases)/releases/download/v\(version)/Spool-\(version).zip")
        }

        /// gh answers `release view` for `tag` with this isDraft value ("true" or "false").
        func releaseState(_ tag: String, isDraft: String) throws {
            try write(state.appendingPathComponent(tag), isDraft + "\n")
        }

        static func plist(version: String, build: String, feed: String, key: String, bundle: String = "com.fskroes.Spool",
                          license: String = ReleaseRunTests.licenseKey) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(bundle)</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleVersion</key><string>\(build)</string>
            <key>SUFeedURL</key><string>\(feed)</string>
            <key>SUPublicEDKey</key><string>\(key)</string>
            <key>SpoolLicensePublicKey</key><string>\(license)</string>
            </dict></plist>

            """
        }

        // swiftlint:disable:next function_body_length
        private func writeFakes() throws {
            let webPath = web.path, statePath = state.path
            try write("scripts/signing-env.sh", #"""
            # Fake for ReleaseRunTests: no keychain. The SHA-1 of the Developer ID identity is FAKE_HASH.
            spool_developer_id() { [ -n "${FAKE_HASH:-}" ] || return 1; printf '%s\n' "$FAKE_HASH"; }

            """#)
            let plist = Fixture.plist(version: "${FAKE_APP_VERSION:-$(tr -d '[:space:]' < VERSION)}",
                                      build: "${FAKE_APP_BUILD:-$(git rev-list --count HEAD)}",
                                      feed: "${FAKE_APP_FEED:-\(ReleaseRunTests.feed)}",
                                      key: "${FAKE_APP_KEY:-\(ReleaseRunTests.key)}",
                                      bundle: "${FAKE_BUNDLE_ID:-com.fskroes.Spool}",
                                      // Like the real build-app.sh: the environment wins over updates.env.
                                      license: "${FAKE_APP_LICENSE_KEY:-${SPOOL_LICENSE_PUBLIC_KEY:-\(ReleaseRunTests.licenseKey)}}")
            try write("scripts/build-app.sh", #"""
            #!/bin/bash
            set -euo pipefail
            cd "$(dirname "$0")/.."
            APP=dist/Spool.app
            rm -rf "$APP"
            mkdir -p "$APP/Contents/MacOS" "$APP/Contents/_CodeSignature"
            cat > "$APP/Contents/Info.plist" <<PLIST
            \#(plist)PLIST
            printf 'fake app binary\n' > "$APP/Contents/MacOS/Spool"
            printf '%s\n' "${FAKE_SIGNED_TEAM:-\#(ReleaseRunTests.team)}" > "$APP/Contents/_CodeSignature/team"
            [ -z "${FAKE_BAD_SIGNATURE:-}" ] || : > "$APP/Contents/_CodeSignature/invalid"
            [ -z "${FAKE_BUILD_COMMITS:-}" ] || git commit -q --allow-empty -m "a commit during the build"
            [ -z "${FAKE_BUILD_DIRTIES:-}" ] || echo x > stray.txt
            [ -z "${FAKE_APP_MACOSX:-}" ] || mkdir -p "$APP/Contents/__MACOSX"
            [ -z "${FAKE_APP_PRIVATE:-}" ] || { mkdir -p "$APP/Contents/Resources"; printf 'built in %s\n' "$HOME" > "$APP/Contents/Resources/where.txt"; }
            [ -z "${FAKE_BUILD_MAKES_DRAFT:-}" ] || echo true > '\#(statePath)/v'"$(tr -d '[:space:]' < VERSION)"
            [ -z "${FAKE_BUILD_MAKES_TAG:-}" ] || echo 0123456789abcdef0123456789abcdef01234567 > '\#(statePath)/remote-v'"$(tr -d '[:space:]' < VERSION)"
            [ -z "${FAKE_APP_USER_PATH:-}" ] || { mkdir -p "$APP/Contents/Resources"; printf 'built in /Users/%s/dev/Spool\n' "$USER" > "$APP/Contents/Resources/where.txt"; }
            echo "==> Built $APP"

            """#, executable: true)
            try write("scripts/make-dmg.sh", #"""
            #!/bin/bash
            set -euo pipefail
            cd "$(dirname "$0")/.."
            V=$(plutil -extract CFBundleShortVersionString raw -o - dist/Spool.app/Contents/Info.plist)
            rm -f "dist/Spool-$V.dmg"
            printf '%s\n' "${SIGN_IDENTITY:-}" > '\#(statePath)/dmg-identity'
            if [ -n "${FAKE_DMG_EMPTY:-}" ]; then
              mkdir -p dist/empty && echo readme > dist/empty/README && ditto -c -k dist/empty "dist/Spool-$V.dmg"
            else
              ditto -c -k --keepParent dist/Spool.app "dist/Spool-$V.dmg"
            fi

            """#, executable: true)

            let sparkle = ".build/artifacts/sparkle/Sparkle/bin/"
            try write(sparkle + "generate_keys", #"""
            #!/bin/sh
            for a; do [ "$a" = -p ] && { echo "A public key line"; echo "${FAKE_SPARKLE_KEY:-\#(ReleaseRunTests.key)}"; exit 0; }; done
            echo "fake generate_keys: unexpected: $*" >&2; exit 1
            """#, executable: true)
            try write(sparkle + "generate_appcast", #"""
            #!/bin/sh
            set -e
            while [ $# -gt 0 ]; do
              case "$1" in
                --download-url-prefix) prefix=${FAKE_APPCAST_PREFIX:-$2}; shift ;;
                -o) out=$2; shift ;;
                --account|--link) shift ;;
                -*) ;;
                *) dir=$1 ;;
              esac
              shift
            done
            zip=$(ls "$dir"/*.zip)
            unzip -p "$zip" Spool.app/Contents/Info.plist > "$dir/Info.plist"
            short=$(plutil -extract CFBundleShortVersionString raw -o - "$dir/Info.plist")
            build=$(plutil -extract CFBundleVersion raw -o - "$dir/Info.plist")
            length=$(stat -f %z "$zip")
            cat > "$out" <<XML
            <?xml version="1.0" standalone="yes"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Spool</title>
            <item><title>$short</title><sparkle:version>$build</sparkle:version><sparkle:shortVersionString>$short</sparkle:shortVersionString>
            <enclosure url="$prefix$(basename "$zip")" length="$length" type="application/octet-stream" sparkle:edSignature="c2ln"/></item>
            </channel></rss>
            XML
            """#, executable: true)
            try write(sparkle + "sign_update", #"""
            #!/bin/sh
            [ -z "${FAKE_BAD_EDDSA:-}" ] && [ "$3" = --verify ] && [ "$5" = c2ln ]
            """#, executable: true)

            try write(bin.appendingPathComponent("gh"), #"""
            #!/bin/sh
            printf '%s\n' "$*" >> '\#(ghLog.path)'
            W='\#(webPath)/github.com'
            S='\#(statePath)'
            case "$1 $2" in
              "auth status") [ -z "${FAKE_GH_NO_AUTH:-}" ] ;;
              "api user") echo "${FAKE_GH_LOGIN:-fskroes}" ;;
              "api repos/"*"/compare/"*) echo "${FAKE_GH_COMPARE:-identical}" ;;
              "api repos/"*"/commits/refs/tags/"*)
                if [ -f "$S/remote-${2##*/}" ]; then cat "$S/remote-${2##*/}"
                else echo "gh: No commit found for SHA: refs/tags/${2##*/} (HTTP 422)" >&2; exit 1; fi ;;
              "repo view")
                [ -z "${FAKE_GH_NO_REPO:-}" ] || [ -f "$S/repo-made" ] || exit 1
                case "$*" in *visibility*) if [ -n "${FAKE_GH_PRIVATE:-}" ]; then echo PRIVATE; else echo PUBLIC; fi ;; esac ;;
              "api -X")
                case "$*" in
                  *" user/repos "*) : > "$S/repo-made" ;;
                  *"/contents/README.md "*) : > "$S/readme-made" ;;
                  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
                esac ;;
              "release list")
                case "${FAKE_GH_LIST:-zero}" in
                  zero) echo 0 ;;
                  one) echo 1 ;;
                  norepo) echo "GraphQL: Could not resolve to a Repository with the name '$4'. (repository)" >&2; exit 1 ;;
                  network) echo "error connecting to api.github.com" >&2; exit 1 ;;
                esac ;;
              "release view")
                if [ -f "$S/$3" ]; then cat "$S/$3"; else echo "release not found" >&2; exit 1; fi ;;
              "release create")
                tag=$3 repo=$5
                shift 5
                d="$W/$repo/releases/download/$tag"
                mkdir -p "$d"
                while [ $# -gt 0 ]; do
                  case "$1" in --title|--notes-file) shift ;; --*) ;; *) cp "$1" "$d/" ;; esac
                  shift
                done
                [ -z "${FAKE_GH_CORRUPT_UPLOAD:-}" ] || for z in "$d"/*.zip; do printf x >> "$z"; done
                echo true > "$S/$tag" ;;
              "release edit")
                tag=$3 repo=$5
                echo false > "$S/$tag"
                # GitHub makes the tag on main of the releases repository when it publishes.
                [ -n "${FAKE_GH_NO_TAG:-}" ] || echo \#(ReleaseRunTests.releasesMain) > "$S/remote-$tag"
                [ -z "${FAKE_GH_NO_LATEST:-}" ] || exit 0
                mkdir -p "$W/$repo/releases/latest/download"
                cp "$W/$repo/releases/download/$tag/appcast.xml" "$W/$repo/releases/download/$tag/Spool.dmg" "$W/$repo/releases/latest/download/"
                [ -z "${FAKE_GH_CORRUPT_DMG:-}" ] || printf x >> "$W/$repo/releases/latest/download/Spool.dmg" ;;
              *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
            esac
            """#, executable: true)
            try write(bin.appendingPathComponent("curl"), #"""
            #!/bin/sh
            out=/dev/stdout fmt= fail=0 url=
            while [ $# -gt 0 ]; do
              case "$1" in
                -o) out=$2; shift ;;
                -w) fmt=$2; shift ;;
                --max-time) shift ;;
                -*f*) fail=1 ;;
                -*) ;;
                *) url=$1 ;;
              esac
              shift
            done
            file='\#(webPath)/'"${url#https://}"
            code=200
            if [ "$url" = '\#(ReleaseRunTests.feed)' ] && [ -n "${FAKE_FEED_UNREACHABLE:-}" ]; then
              echo "curl: (6) Could not resolve host: github.com" >&2; exit 6
            fi
            if [ "$url" = '\#(ReleaseRunTests.feed)' ] && [ -n "${FAKE_FEED_CODE:-}" ]; then code=$FAKE_FEED_CODE
            elif [ ! -f "$file" ]; then code=404; fi
            if [ "$code" != 200 ] && [ $fail = 1 ]; then echo "curl: (22) The requested URL returned error: $code" >&2; exit 22; fi
            if [ "$code" = 200 ]; then cp "$file" "$out"; else printf 'Not Found' > "$out"; fi
            [ -z "$fmt" ] || printf '%s' "$code"
            """#, executable: true)
            try write(bin.appendingPathComponent("codesign"), #"""
            #!/bin/sh
            for a; do app=$a; done
            sig="$app/Contents/_CodeSignature"
            dr() {
              echo "designated => identifier \"com.fskroes.Spool\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \"$1\""
            }
            case "$app" in
              */unpacked/*)
                [ "$1" != --verify ] || [ -z "${FAKE_ZIP_BAD_SIGNATURE:-}" ] || { echo "$app: invalid signature" >&2; exit 1; }
                if [ "$1" = -d ] && [ "$2" = -r ] && [ -n "${FAKE_ZIP_SIGNED_TEAM:-}" ]; then dr "$FAKE_ZIP_SIGNED_TEAM"; exit 0; fi ;;
              */dmg/*)
                if [ "$1" = -d ] && [ "$2" = -r ] && [ -n "${FAKE_DMG_APP_TEAM:-}" ]; then dr "$FAKE_DMG_APP_TEAM"; exit 0; fi ;;
            esac
            case "$1" in
              --verify)
                [ -f "$sig/team" ] && [ ! -e "$sig/invalid" ] || { echo "$app: invalid signature" >&2; exit 1; }
                case "$2" in
                  -R=*)
                    want="-R=anchor apple generic and certificate leaf[subject.OU] = \"$(cat "$sig/team")\""
                    [ -z "${FAKE_TRUST_FAIL:-}" ] && [ "$2" = "$want" ] || { echo "$app: does not satisfy its designated Requirement" >&2; exit 3; } ;;
                esac ;;
              -d) echo "Executable=$app/Contents/MacOS/Spool" >&2
                  if [ "$2" = -r ]; then dr "$(cat "$sig/team")"
                  elif [ -n "${FAKE_NO_RUNTIME:-}" ]; then echo "CodeDirectory v=20500 size=1 flags=0x0(none) hashes=1+0 location=embedded" >&2
                  else echo "CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+0 location=embedded" >&2; fi ;;
              *) echo "fake codesign: unexpected: $*" >&2; exit 1 ;;
            esac
            """#, executable: true)
            // The feed check after the publish tries 10 times, 3 seconds apart.
            try write(bin.appendingPathComponent("sleep"), "#!/bin/sh\nexit 0\n", executable: true)
            try write(bin.appendingPathComponent("lipo"), #"""
            #!/bin/sh
            [ "$1" = -archs ] && echo "${FAKE_ARCHS:-x86_64 arm64}"
            """#, executable: true)
            try write(bin.appendingPathComponent("hdiutil"), #"""
            #!/bin/sh
            case "$1" in
              attach)
                [ -z "${FAKE_DMG_ATTACH_FAIL:-}" ] || { echo "hdiutil: attach failed - image not recognized" >&2; exit 1; }
                shift
                while [ $# -gt 0 ]; do case "$1" in -mountpoint) mp=$2; shift ;; -*) ;; *) img=$1 ;; esac; shift; done
                mkdir -p "$mp" && ditto -x -k "$img" "$mp" ;;
              detach) rm -rf "$2" ;;
              *) echo "fake hdiutil: unexpected: $*" >&2; exit 1 ;;
            esac
            """#, executable: true)
            try write(bin.appendingPathComponent("xcrun"), #"""
            #!/bin/sh
            printf '%s\n' "$*" >> '\#(xcrunLog.path)'
            S='\#(statePath)'
            case "$1 $2" in
              "notarytool history")
                [ -z "${FAKE_NO_NOTARY_PROFILE:-}" ] || { echo "Error: No Keychain password item found for profile: $4" >&2; exit 1; } ;;
              "notarytool submit")
                case "$3" in *.dmg) st=${FAKE_NOTARY_DMG:-Accepted} ;; *) st=${FAKE_NOTARY_APP:-Accepted} ;; esac
                [ "$st" != none ] || { echo "Error: HTTP status code: 401. Unable to authenticate." >&2; exit 1; }
                echo "{\"id\":\"11111111-2222-3333-4444-555555555555\",\"status\":\"$st\",\"message\":\"Processing complete\"}"
                [ "$st" = Accepted ] ;;
              "notarytool log") echo '{"issues":[{"message":"The binary is not signed with a valid Developer ID certificate."}]}' ;;
              "stapler staple")
                [ -z "${FAKE_STAPLE_FAIL:-}" ] || { echo "CloudKit query failed" >&2; exit 65; }
                if [ -d "$3" ]; then : > "$3/Contents/CodeResources"; else : > "$S/stapled-$(basename "$3")"; fi ;;
              "stapler validate")
                case "$3" in
                  */unpacked/*) [ -z "${FAKE_ZIP_NO_TICKET:-}" ] || exit 65 ;;
                  */dmg/*) [ -z "${FAKE_DMG_APP_NO_TICKET:-}" ] || exit 65 ;;
                esac
                if [ -d "$3" ]; then [ -f "$3/Contents/CodeResources" ]; else [ -f "$S/stapled-$(basename "$3")" ]; fi ;;
              *) echo "fake xcrun: unexpected: $*" >&2; exit 1 ;;
            esac
            """#, executable: true)
            try write(bin.appendingPathComponent("spctl"), #"""
            #!/bin/sh
            for a; do f=$a; done
            case "$f" in
              *.dmg) want="--assess --type open --context context:primary-signature -vv $f"; v=${FAKE_GATEKEEPER_DMG:-ok} ;;
              *) want="--assess --type execute -vv $f"; v=${FAKE_GATEKEEPER_APP:-ok} ;;
            esac
            [ "$*" = "$want" ] || { printf '%s: rejected (fake spctl: expected "%s", got "%s")\n' "$f" "$want" "$*" >&2; exit 3; }
            if [ "$v" = ok ]; then printf '%s: accepted\nsource=Notarized Developer ID\n' "$f" >&2
            else printf '%s: rejected\nsource=Unnotarized Developer ID\n' "$f" >&2; exit 3; fi
            """#, executable: true)
        }
    }

    struct Failure: Error, CustomStringConvertible { var text: String; var description: String { text } }

    /// The run stopped with `message`, uploaded nothing and made no tag.
    static func expectRefused(_ r: Result, _ message: String, _ f: Fixture,
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(r.status != 0, "the run must stop", sourceLocation: sourceLocation)
        #expect(r.error.contains(message), "expected '\(message)' in: \(r.all)", sourceLocation: sourceLocation)
        #expect(!f.uploaded, "nothing is uploaded: \(f.ghCalls)", sourceLocation: sourceLocation)
        #expect(try f.tags().isEmpty, "no tag is made", sourceLocation: sourceLocation)
    }

    // MARK: runs that go through

    @Test func aDryRunMakesTheFilesAndUploadsNothing() throws {
        let f = try Fixture()
        let r = try f.release("--dry-run")
        #expect(r.status == 0, "\(r.all)")
        #expect(r.output.contains("Dry run: nothing was uploaded"))
        let dir = f.repo.appendingPathComponent("dist/release/dry-run/\(Self.version)")
        let commit = try String(contentsOf: dir.appendingPathComponent("commit.txt"), encoding: .utf8)
        #expect(commit == (try f.head()) + "\n")
        for name in ["Spool-\(Self.version).zip", "Spool.dmg", "appcast.xml", "SHA256SUMS.txt", "notes.md"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), "\(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: f.out.path), "a dry run never writes the files of a real run")
        #expect(f.ghCalls.isEmpty, "a dry run never calls gh: \(f.ghCalls)")
        #expect(try f.tags().isEmpty)
    }

    // A dry run checks the whole chain: the app and the DMG are notarized, stapled and accepted by Gatekeeper.
    @Test func aRunNotarizesStaplesAndChecksTheAppAndTheDMG() throws {
        let f = try Fixture()
        let r = try f.release("--dry-run")
        #expect(r.status == 0, "\(r.all)")
        let calls = f.xcrunCalls
        #expect(calls.contains("notarytool history --keychain-profile \(Self.profile) --output-format json"))
        #expect(calls.contains("/notarize/Spool.zip --keychain-profile \(Self.profile) --wait --output-format json"), "\(calls)")
        #expect(calls.contains("Spool.dmg --keychain-profile \(Self.profile) --wait --output-format json"), "\(calls)")
        #expect(calls.contains("stapler staple \(f.repo.path)/dist/Spool.app"), "\(calls)")
        #expect(calls.contains("stapler validate ") && calls.contains("/unpacked/Spool.app"), "the archive carries the ticket: \(calls)")
        #expect(r.output.contains("==> Apple notarized Spool.app"))
        #expect(r.output.contains("==> Apple notarized Spool.dmg"))
        // The DMG is signed with the Developer ID, like the app.
        let identity = try String(contentsOf: f.state.appendingPathComponent("dmg-identity"), encoding: .utf8)
        #expect(identity == Self.devid + "\n")
    }

    // The first release: no feed yet. The run uploads, publishes and tags the commit of the build.
    @Test func aFirstReleasePublishesAndTagsTheCommitOfTheBuild() throws {
        let f = try Fixture()
        let head = try f.head()
        let r = try f.release()
        #expect(r.status == 0, "\(r.all)")
        #expect(r.output.contains("No release published yet. New: \(Self.version) (\(Self.build))"))
        #expect(r.output.contains("Published Spool \(Self.version): https://github.com/\(Self.releases)/releases/tag/v\(Self.version)"))
        #expect(f.ghCalls.contains("api repos/\(Self.source)/compare/\(head)...main --jq .status"),
                "the commit is on main of the source, not of the releases repository")
        #expect(!f.ghCalls.contains("api repos/\(Self.releases)/compare/"))
        #expect(f.ghCalls.contains("release create v\(Self.version) --repo \(Self.releases) --draft --title"))
        #expect(!f.ghCalls.contains("--target"), "the releases repository has no commit of the source")
        #expect(f.ghCalls.contains("release edit v\(Self.version) --repo \(Self.releases) --draft=false --latest"))
        #expect(!f.ghCalls.contains("user/repos"), "the run never makes a repository")
        #expect(try f.sh("git rev-parse 'v\(Self.version)^{commit}'") == head)
        #expect(try f.sh("git cat-file -t v\(Self.version)") == "commit")
        let commit = try String(contentsOf: f.out.appendingPathComponent("commit.txt"), encoding: .utf8)
        #expect(commit == head + "\n")
    }

    @Test func aReleaseAfterAPublishedOneChecksItsIdentityAndKey() throws {
        let f = try Fixture()
        try f.publish(version: "1.1.0", build: 2)
        let r = try f.release()
        #expect(r.status == 0, "\(r.all)")
        #expect(r.output.contains("Published now: 1.1.0 (2). New: \(Self.version) (\(Self.build))"))
        #expect(r.output.contains("The published 1.1.0 has the same signing team and update key"))
        #expect(try f.sh("git rev-parse 'v\(Self.version)^{commit}'") == (try f.head()))
        #expect(!f.ghCalls.contains("user/repos"), "the repository exists")
    }

    // MARK: checks before the build

    @Test(arguments: [
        (["SIGN_IDENTITY": "Someone"], "unset SIGN_IDENTITY: releases are signed with the Developer ID of team \(team) only"),
        (["SPOOL_UPDATES": "off"], "unset SPOOL_UPDATES: a release must have updates on"),
        (["FAKE_SPARKLE_KEY": otherKey], "does not match SPOOL_ED_PUBLIC_KEY"),
        (["FAKE_HASH": ""], "this Mac has no \"Developer ID Application\" identity of team \(team)"),
        (["FAKE_NO_NOTARY_PROFILE": "1"], "the notarytool profile \(profile) does not work. Make it once"),
        (["FAKE_GH_COMPARE": "behind"], "is not on main of \(source) (behind). Push main first"),
    ])
    func aWrongSettingStopsTheRunBeforeTheBuild(_ env: [String: String], _ message: String) throws {
        let f = try Fixture()
        let r = try f.release(env: env)
        try Self.expectRefused(r, message, f)
        #expect(!FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("dist/Spool.app").path))
    }

    // A dry run builds from a task branch: it does not ask GitHub where the commit is.
    @Test func aDryRunDoesNotNeedTheCommitOnGitHub() throws {
        let f = try Fixture()
        let r = try f.release("--dry-run", env: ["FAKE_GH_COMPARE": "behind"])
        #expect(r.status == 0, "\(r.all)")
    }

    @Test func aTeamIDThatIsNotATeamIDStopsTheRun() throws {
        let f = try Fixture()
        let file = f.repo.appendingPathComponent("Packaging/updates.env")
        let text = try String(contentsOf: file, encoding: .utf8)
        try f.write("Packaging/updates.env", text.replacingOccurrences(of: "SPOOL_TEAM_ID=\(Self.team)", with: "SPOOL_TEAM_ID=a1b2"))
        try f.sh("git commit -qam 'bad team'")
        try Self.expectRefused(try f.release(), "SPOOL_TEAM_ID must be a Team ID of 10 capital letters and digits, got 'a1b2'", f)
    }

    // A release on an existing tag keeps that tag: the version is taken.
    @Test func aTagInTheReleasesRepositoryStopsTheRunBeforeTheBuild() throws {
        let f = try Fixture()
        try f.write(f.state.appendingPathComponent("remote-v\(Self.version)"), "0123456789abcdef0123456789abcdef01234567\n")
        try Self.expectRefused(try f.release(), "the tag v\(Self.version) exists in \(Self.releases) (on 0123456789abcdef0123456789abcdef01234567). Increase VERSION.", f)
        #expect(!FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("dist/Spool.app").path))
    }

    @Test func aChangedTreeStopsARealRunAndWarnsInADryRun() throws {
        let f = try Fixture()
        try f.write("stray.txt", "x\n")
        try Self.expectRefused(try f.release(), "error: the working tree has changes. Commit them first.", f)
        let dry = try f.release("--dry-run")
        #expect(dry.status == 0, "\(dry.all)")
        #expect(dry.error.contains("warning (dry run): the working tree has changes"))
    }

    @Test func aBranchOtherThanMainStopsARealRunAndWarnsInADryRun() throws {
        let f = try Fixture()
        try f.sh("git switch -qc topic")
        try Self.expectRefused(try f.release(), "error: release from main (now on 'topic')", f)
        let dry = try f.release("--dry-run")
        #expect(dry.status == 0, "\(dry.all)")
        #expect(dry.error.contains("warning (dry run): release from main (now on 'topic')"))
    }

    @Test func anExistingTagStopsTheRun() throws {
        let f = try Fixture()
        try f.sh("git tag v\(Self.version) HEAD~1")
        let r = try f.release()
        #expect(r.status != 0)
        #expect(r.error.contains("the tag v\(Self.version) exists. Increase VERSION."), "\(r.all)")
        #expect(!f.uploaded)
        #expect(try f.sh("git rev-parse 'v\(Self.version)^{commit}'") == (try f.sh("git rev-parse HEAD~1")), "the tag is not moved")
    }

    @Test func aVersionWithoutReleaseNotesStopsTheRun() throws {
        let f = try Fixture()
        try f.write("CHANGELOG.md", "# Changelog\n\n## 1.1.0\n\n- Older.\n")
        try f.sh("git commit -qam 'no notes'")
        try Self.expectRefused(try f.release(), "CHANGELOG.md has no '## \(Self.version)' section with text", f)
    }

    // MARK: the published feed

    @Test(arguments: [
        (version, 2, team, key, "\(version) is published already. If its run stopped before the tag"),
        ("1.3.0", 2, team, key, "VERSION \(version) is not higher than the published 1.3.0"),
        ("1.1.0", build, team, key, "build \(build) is not higher than the published build \(build)"),
        ("1.1.0", 2, otherTeam, key, "the published 1.1.0 is not signed by team \(team)"),
        ("1.1.0", 2, team, otherKey, "the published 1.1.0 has another SUPublicEDKey than Packaging/updates.env"),
    ])
    func aPublishedReleaseThatDoesNotFitStopsTheRun(_ version: String, _ build: Int, _ team: String, _ key: String,
                                                    _ message: String) throws {
        let f = try Fixture()
        try f.publish(version: version, build: build, team: team, key: key)
        try Self.expectRefused(try f.release(), message, f)
    }

    @Test func publishedReleasesWithoutAFeedStopTheRun() throws {
        let f = try Fixture()
        try Self.expectRefused(try f.release(env: ["FAKE_GH_LIST": "one"]),
                               "\(Self.releases) has published releases but no feed at \(Self.feed)", f)
    }

    // gh that cannot list the releases must not read as "no releases": that skips the identity and key checks.
    @Test func aReleaseCheckThatCannotTellStopsTheRun() throws {
        let f = try Fixture()
        try Self.expectRefused(try f.release(env: ["FAKE_GH_LIST": "network"]),
                               "cannot list the releases of \(Self.releases): error connecting to api.github.com", f)
        #expect(!FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("dist/Spool.app").path))
    }

    @Test func anUnexpectedFeedAnswerStopsTheRun() throws {
        let f = try Fixture()
        try Self.expectRefused(try f.release(env: ["FAKE_FEED_CODE": "500"]), "unexpected HTTP 500 from \(Self.feed)", f)
    }

    @Test func aDraftOfThisVersionStopsTheRunBeforeTheBuild() throws {
        let f = try Fixture()
        try f.releaseState("v\(Self.version)", isDraft: "true")
        try Self.expectRefused(try f.release(), "a draft release v\(Self.version) exists in \(Self.releases)", f)
        #expect(!FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("dist/Spool.app").path))
    }

    // MARK: checks after the build

    @Test(arguments: [
        (["FAKE_BUNDLE_ID": "com.example.Other"], "wrong bundle ID in"),
        (["FAKE_APP_VERSION": "9.9.9"], "the app version is not \(version)"),
        (["FAKE_APP_BUILD": "99"], "the app build is not \(build)"),
        (["FAKE_APP_FEED": "https://example.com/appcast.xml"], "the app has the wrong SUFeedURL"),
        (["FAKE_APP_KEY": otherKey], "the app has the wrong SUPublicEDKey"),
        (["FAKE_APP_LICENSE_KEY": otherLicenseKey], "the app has the wrong SpoolLicensePublicKey"),
        (["FAKE_BAD_SIGNATURE": "1"], "the signature of the app is not valid"),
        (["FAKE_SIGNED_TEAM": otherTeam], "the app is not signed with the Developer ID of team \(team)"),
        (["FAKE_NO_RUNTIME": "1"], "the app does not have the hardened runtime"),
        (["FAKE_TRUST_FAIL": "1"], "the app does not meet the requirement of its license check"),
        (["FAKE_ARCHS": "arm64"], "the app has no x86_64 slice"),
        (["FAKE_ARCHS": "x86_64"], "the app has no arm64 slice"),
    ])
    func aWrongAppStopsTheRunAfterTheBuild(_ env: [String: String], _ message: String) throws {
        let f = try Fixture()
        let r = try f.release(env: env)
        try Self.expectRefused(r, message, f)
        #expect(r.output.contains("==> Building the app"), "the check comes after the build")
        #expect(!FileManager.default.fileExists(atPath: f.out.path))
    }

    // MARK: notarization

    // Each failure stops the run before the upload. Those of the app come before the files are made, so
    // the files of the last run stay.
    @Test(arguments: [
        (["FAKE_NOTARY_APP": "Invalid"], "Apple did not notarize Spool.app: Invalid"),
        (["FAKE_NOTARY_APP": "none"], "Apple did not notarize Spool.app: no answer. Error: HTTP status code: 401"),
        (["FAKE_STAPLE_FAIL": "1"], "cannot staple the ticket to Spool.app"),
        (["FAKE_GATEKEEPER_APP": "reject"], "Gatekeeper does not accept Spool.app as notarized"),
    ])
    func anAppThatAppleOrGatekeeperRefusesStopsTheRun(_ env: [String: String], _ message: String) throws {
        let f = try Fixture()
        let r = try f.release(env: env)
        try Self.expectRefused(r, message, f)
        #expect(!FileManager.default.fileExists(atPath: f.out.path), "no files are made")
    }

    @Test(arguments: [
        (["FAKE_NOTARY_DMG": "Invalid"], "Apple did not notarize Spool.dmg: Invalid"),
        (["FAKE_GATEKEEPER_DMG": "reject"], "Gatekeeper does not accept Spool.dmg as notarized"),
    ])
    func aDMGThatAppleOrGatekeeperRefusesStopsTheRun(_ env: [String: String], _ message: String) throws {
        let f = try Fixture()
        let r = try f.release(env: env)
        try Self.expectRefused(r, message, f)
        #expect(r.output.contains("==> Apple notarized Spool.app"))
        #expect(!FileManager.default.fileExists(atPath: f.out.appendingPathComponent("SHA256SUMS.txt").path))
    }

    // An invalid notarization shows Apple's log: the reason is in it, not in the status.
    @Test func anInvalidNotarizationShowsTheLogOfApple() throws {
        let f = try Fixture()
        let r = try f.release(env: ["FAKE_NOTARY_APP": "Invalid"])
        #expect(r.error.contains("The binary is not signed with a valid Developer ID certificate."), "\(r.all)")
        #expect(r.error.contains("Read why: xcrun notarytool log 11111111-2222-3333-4444-555555555555 --keychain-profile \(Self.profile)"))
    }

    @Test func aCommitDuringTheBuildStopsADryRun() throws {
        let f = try Fixture()
        let r = try f.release("--dry-run", env: ["FAKE_BUILD_COMMITS": "1"])
        #expect(r.status != 0)
        #expect(r.error.contains("the app is not a build of"), "\(r.all)")
        #expect(r.error.contains("HEAD moved from"))
        #expect(!FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("dist/release").path))
    }

    @Test func aChangeOfTheTreeDuringTheBuildStopsARealRun() throws {
        let f = try Fixture()
        let r = try f.release(env: ["FAKE_BUILD_DIRTIES": "1"])
        try Self.expectRefused(r, "the app is not a build of", f)
        #expect(r.error.contains("the working tree changed during the release"))
    }

    // MARK: options, settings and tools

    @Test(arguments: [
        (["--bogus"], "error: unknown option: --bogus"),
        (["--finish", "--dry-run"], "error: --finish takes no other option"),
        (["--finish", "--new-identity"], "error: --finish takes no other option"),
    ])
    func aWrongOptionStopsTheRun(_ args: [String], _ message: String) throws {
        let f = try Fixture()
        let r = try f.exec("/bin/bash", [f.repo.appendingPathComponent("scripts/release.sh").path] + args)
        try Self.expectRefused(r, message, f)
    }

    // Each value is needed: without one, the run cannot check the feed, the update key or the identity.
    @Test(arguments: ["SPOOL_RELEASES_REPO", "SPOOL_SOURCE_REPO", "SPOOL_FEED_URL", "SPOOL_ED_PUBLIC_KEY", "SPOOL_ED_KEY_ACCOUNT",
                      "SPOOL_TEAM_ID", "SPOOL_NOTARY_PROFILE"])
    func aSettingThatIsMissingStopsTheRun(_ key: String) throws {
        let f = try Fixture()
        let file = f.repo.appendingPathComponent("Packaging/updates.env")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.hasPrefix(key + "=") })
        try f.write("Packaging/updates.env", lines.filter { !$0.hasPrefix(key + "=") }.joined(separator: "\n") + "\n")
        try f.sh("git commit -qam 'no \(key)'")
        try Self.expectRefused(try f.release(), "Packaging/updates.env needs SPOOL_RELEASES_REPO, SPOOL_SOURCE_REPO, SPOOL_FEED_URL", f)
    }

    @Test func aFeedThatIsNotTheFeedOfTheRepositoryStopsTheRun() throws {
        let f = try Fixture()
        let file = f.repo.appendingPathComponent("Packaging/updates.env")
        let text = try String(contentsOf: file, encoding: .utf8)
        try f.write("Packaging/updates.env", text.replacingOccurrences(of: "SPOOL_FEED_URL=\(Self.feed)",
                                                                      with: "SPOOL_FEED_URL=https://example.com/appcast.xml"))
        try f.sh("git commit -qam 'other feed'")
        try Self.expectRefused(try f.release(), "SPOOL_FEED_URL must be \(Self.feed)", f)
    }

    // MARK: license public key

    /// The updates.env of the fixture with SPOOL_LICENSE_PUBLIC_KEY set to `value`, or without the line (nil).
    private func setLicenseKey(_ value: String?, in f: Fixture) throws {
        let file = f.repo.appendingPathComponent("Packaging/updates.env")
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("SPOOL_LICENSE_PUBLIC_KEY=") }
        try f.write("Packaging/updates.env", (lines + (value.map { ["SPOOL_LICENSE_PUBLIC_KEY=\($0)"] } ?? [])).joined(separator: "\n") + "\n")
        try f.sh("git commit -qam 'license key'")
    }

    @Test(arguments: [nil, ""] as [String?])
    func anEmptyLicenseKeyStopsTheRunBeforeTheBuild(_ value: String?) throws {
        let f = try Fixture()
        try setLicenseKey(value, in: f)
        let r = try f.release()
        try Self.expectRefused(r, "SPOOL_LICENSE_PUBLIC_KEY in Packaging/updates.env is empty", f)
        #expect(r.error.contains("spool-license keygen"))
        #expect(!r.output.contains("==> Building the app"))
    }

    @Test(arguments: ["abc", "not base64 not base64 not base64 not base64!", Data(repeating: 1, count: 31).base64EncodedString(),
                      Data(repeating: 1, count: 33).base64EncodedString(),
                      // 32 bytes, but the last character carries bits that are not zero: not the canonical spelling.
                      String(Data(repeating: 5, count: 32).base64EncodedString().dropLast(2)) + "B="])
    func aLicenseKeyThatIsNotA32ByteKeyStopsTheRunBeforeTheBuild(_ value: String) throws {
        let f = try Fixture()
        try setLicenseKey(value, in: f)
        let r = try f.release()
        try Self.expectRefused(r, "SPOOL_LICENSE_PUBLIC_KEY in Packaging/updates.env is not a 32-byte public key in base64", f)
        #expect(!r.output.contains("==> Building the app"))
    }

    // Their seeds are public: with a test key anyone can make a license key for the release.
    @Test(arguments: [LicenseKeyTests.vectors.publicKeyA, LicenseKeyTests.vectors.publicKeyB])
    func aTestLicenseKeyStopsTheRunBeforeTheBuild(_ key: String) throws {
        let f = try Fixture()
        try setLicenseKey(key, in: f)
        let r = try f.release()
        try Self.expectRefused(r, "is a public test key of docs/license-test-vectors.json", f)
        #expect(!r.output.contains("==> Building the app"))
        #expect(try ReleaseScriptTests.call("spool_license_key_valid", key).status == 0,
                "the test key has the right form, so only the test-key check can stop this run")
    }

    // build-app.sh lets SPOOL_LICENSE_PUBLIC_KEY in the environment win (make e2e uses that). A release must not.
    @Test func aLicenseKeyInTheEnvironmentNeverReachesTheReleaseBuild() throws {
        let f = try Fixture()
        let r = try f.release("--dry-run", env: ["SPOOL_LICENSE_PUBLIC_KEY": Self.testLicenseKey])
        #expect(r.status == 0, "\(r.all)")
        let plist = f.repo.appendingPathComponent("dist/Spool.app/Contents/Info.plist")
        #expect(try f.sh("plutil -extract SpoolLicensePublicKey raw -o - '\(plist.path)'") == Self.licenseKey)
    }

    @Test func aVersionThatIsNotLike123StopsTheRun() throws {
        let f = try Fixture()
        try f.write("VERSION", "1.2\n")
        try f.sh("git commit -qam 'short version'")
        try Self.expectRefused(try f.release(), "VERSION must look like 1.2.3, got '1.2'", f)
    }

    @Test func aMissingSparkleToolStopsTheRun() throws {
        let f = try Fixture()
        try FileManager.default.removeItem(at: f.repo.appendingPathComponent(".build/artifacts/sparkle/Sparkle/bin/sign_update"))
        try Self.expectRefused(try f.release("--dry-run"), "missing Sparkle tool: ", f)
    }

    // A dry run needs no gh. A real run needs it, logged in.
    @Test func aRealRunNeedsGhLoggedIn() throws {
        let f = try Fixture()
        try Self.expectRefused(try f.release(env: ["FAKE_GH_NO_AUTH": "1"]), "gh is not logged in (run: gh auth login)", f)
        try FileManager.default.removeItem(at: f.bin.appendingPathComponent("gh"))
        try Self.expectRefused(try f.release(), "missing tool: gh (brew install gh, then gh auth login)", f)
        let dry = try f.release("--dry-run")
        #expect(dry.status == 0, "\(dry.all)")
    }

    // MARK: the published feed, more

    @Test func aFeedThatCannotBeReadStopsTheRun() throws {
        let f = try Fixture()
        try Self.expectRefused(try f.release(env: ["FAKE_FEED_UNREACHABLE": "1"]), "cannot read \(Self.feed)", f)
    }

    @Test func aFeedWithoutAReleaseStopsTheRun() throws {
        let f = try Fixture()
        try f.feed("<?xml version=\"1.0\"?>\n<rss version=\"2.0\"><channel><title>Spool</title></channel></rss>\n")
        try Self.expectRefused(try f.release(), "the published feed has no release item: \(Self.feed)", f)
    }

    @Test func aFeedItemWithoutAnArchiveStopsTheRun() throws {
        let f = try Fixture()
        try f.feed("""
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Spool</title>
        <item><title>1.1.0</title><sparkle:version>2</sparkle:version><sparkle:shortVersionString>1.1.0</sparkle:shortVersionString></item>
        </channel></rss>

        """)
        try Self.expectRefused(try f.release(), "the published feed has no enclosure URL", f)
    }

    // Without the published app, the run cannot check its identity and key.
    @Test func aPublishedArchiveThatCannotBeReadStopsTheRun() throws {
        let f = try Fixture()
        try f.publish(version: "1.1.0", build: 2)
        let zip = f.publishedZip("1.1.0")
        try Data("not a zip\n".utf8).write(to: zip)
        try Self.expectRefused(try f.release(), "cannot unpack \(Self.prefix("1.1.0"))Spool-1.1.0.zip", f)
        try FileManager.default.removeItem(at: zip)
        try Self.expectRefused(try f.release(), "cannot download \(Self.prefix("1.1.0"))Spool-1.1.0.zip", f)
    }

    static func prefix(_ version: String) -> String { "https://github.com/\(releases)/releases/download/v\(version)/" }

    // MARK: --new-identity

    @Test func newIdentityPublishesOverAReleaseWithAnotherIdentity() throws {
        let f = try Fixture()
        try f.publish(version: "1.1.0", build: 2, team: Self.otherTeam)
        let r = try f.release("--new-identity")
        #expect(r.status == 0, "\(r.all)")
        #expect(r.error.contains("warning: the published 1.1.0 is not signed by team \(Self.team) (--new-identity)"), "\(r.all)")
        #expect(r.output.contains("The published 1.1.0 has the same update key, and another signing team (--new-identity)"))
        #expect(try f.sh("git rev-parse 'v\(Self.version)^{commit}'") == (try f.head()))
    }

    // The option is for a change of identity only. The update key is checked as always.
    @Test func newIdentityStopsWhenTheIdentityIsTheSameOrTheKeyIsNot() throws {
        let f = try Fixture()
        try f.publish(version: "1.1.0", build: 2)
        try Self.expectRefused(try f.release("--new-identity"),
                               "the published 1.1.0 is signed by team \(Self.team) already. Run without --new-identity.", f)
        let g = try Fixture()
        try g.publish(version: "1.1.0", build: 2, team: Self.otherTeam, key: Self.otherKey)
        try Self.expectRefused(try g.release("--new-identity"), "the published 1.1.0 has another SUPublicEDKey", g)
    }

    // MARK: checks of the archive and the DMG, before the upload

    @Test(arguments: [
        (["FAKE_APPCAST_PREFIX": "https://example.com/"], "the appcast is not correct"),
        (["FAKE_BAD_EDDSA": "1"], "the EdDSA signature of Spool-\(version).zip is not valid"),
        (["FAKE_APP_MACOSX": "1"], "Spool-\(version).zip has __MACOSX entries"),
        (["FAKE_ZIP_BAD_SIGNATURE": "1"], "the app in Spool-\(version).zip has no valid signature"),
        (["FAKE_ZIP_SIGNED_TEAM": otherTeam], "the app in Spool-\(version).zip is not signed with the Developer ID of team \(team)"),
        (["FAKE_ZIP_NO_TICKET": "1"], "the app in Spool-\(version).zip has no notarization ticket"),
        (["FAKE_APP_PRIVATE": "1"], "files in Spool-\(version).zip contain your home path, user name or Git email"),
        (["FAKE_APP_USER_PATH": "1"], "files in Spool-\(version).zip contain your home path, user name or Git email"),
        (["FAKE_DMG_ATTACH_FAIL": "1"], "cannot open Spool.dmg"),
        (["FAKE_DMG_EMPTY": "1"], "Spool.dmg has no Spool.app"),
        (["FAKE_DMG_APP_NO_TICKET": "1"], "the app in Spool.dmg has no notarization ticket"),
        (["FAKE_DMG_APP_TEAM": otherTeam], "the app in Spool.dmg is not signed with the Developer ID of team \(team)"),
    ])
    func aWrongArchiveStopsTheRunBeforeTheUpload(_ env: [String: String], _ message: String) throws {
        let f = try Fixture()
        let r = try f.release(env: env)
        try Self.expectRefused(r, message, f)
        #expect(r.output.contains("==> Making appcast.xml"), "the check comes after the files are made")
        #expect(!FileManager.default.fileExists(atPath: f.out.appendingPathComponent("SHA256SUMS.txt").path))
    }

    // The user name of the maintainer is also the GitHub owner: the bundle ID and the feed URL have it.
    // Only a path with it is a leak.
    @Test func aUserNameThatIsAlsoTheGitHubOwnerDoesNotStopTheRun() throws {
        let f = try Fixture()
        let owner = String(Self.releases.split(separator: "/")[0])
        let r = try f.release("--dry-run", env: ["USER": owner])
        #expect(r.status == 0, "\(r.all)")
        let leak = try f.release("--dry-run", env: ["USER": owner, "FAKE_APP_USER_PATH": "1"])
        #expect(leak.status != 0)
        #expect(leak.error.contains("contain your home path, user name or Git email"), "\(leak.all)")
    }

    // MARK: the publish

    // The first real run makes the public releases repository, with a README, through the API.
    @Test func aMissingReleasesRepositoryIsMadePublicWithItsReadme() throws {
        let f = try Fixture()
        let r = try f.release(env: ["FAKE_GH_NO_REPO": "1"])
        #expect(r.status == 0, "\(r.all)")
        #expect(r.output.contains("==> Making the public repository \(Self.releases)"))
        let made = try #require(f.ghCalls.split(separator: "\n").first { $0.contains(" user/repos ") })
        #expect(made.contains("-f name=spool-test") && made.contains("-F private=false"), "\(made)")
        #expect(f.ghCalls.contains("api -X PUT repos/\(Self.releases)/contents/README.md"))
    }

    // Spool downloads its updates with no login: a private releases repository breaks every update.
    @Test func aPrivateReleasesRepositoryStopsTheRunBeforeTheUpload() throws {
        let f = try Fixture()
        try Self.expectRefused(try f.release(env: ["FAKE_GH_PRIVATE": "1"]),
                               "the releases repository \(Self.releases) is not public", f)
    }

    // The source is private: a release there would be a release nobody can download.
    @Test func theReleasesRepositoryMustNotBeTheSource() throws {
        let f = try Fixture()
        let file = f.repo.appendingPathComponent("Packaging/updates.env")
        let text = try String(contentsOf: file, encoding: .utf8)
        try f.write("Packaging/updates.env", text.replacingOccurrences(of: "SPOOL_SOURCE_REPO=\(Self.source)",
                                                                       with: "SPOOL_SOURCE_REPO=\(Self.releases)"))
        try f.sh("git commit -qam 'same repository'")
        try Self.expectRefused(try f.release(), "SPOOL_RELEASES_REPO must not be the source repository \(Self.releases)", f)
    }

    @Test func aGhLoginThatDoesNotOwnTheRepositoryStopsTheRun() throws {
        let f = try Fixture()
        try Self.expectRefused(try f.release(env: ["FAKE_GH_LOGIN": "someone"]),
                               "gh is logged in as someone, but the releases repository is \(Self.releases)", f)
    }

    // Another run can make the release during this build: the check runs again before the upload.
    // Notarization takes minutes. Another run can publish the version in that time.
    @Test func aTagMadeDuringTheBuildStopsTheRunBeforeTheUpload() throws {
        let f = try Fixture()
        let r = try f.release(env: ["FAKE_BUILD_MAKES_TAG": "1"])
        try Self.expectRefused(r, "the tag v\(Self.version) exists in \(Self.releases) (on 0123456789abcdef0123456789abcdef01234567)", f)
        #expect(r.output.contains("==> Apple notarized Spool.dmg"), "the check runs again after the notarization")
    }

    @Test func aDraftMadeDuringTheBuildStopsTheRunBeforeTheUpload() throws {
        let f = try Fixture()
        let r = try f.release(env: ["FAKE_BUILD_MAKES_DRAFT": "1"])
        try Self.expectRefused(r, "a draft release v\(Self.version) exists in \(Self.releases)", f)
        #expect(r.output.contains("==> Building the app"))
    }

    // After the publish: the run tags only when the feed and the archive are the uploaded files.
    @Test(arguments: [
        (["FAKE_GH_NO_LATEST": "1"], "\(feed) does not return the new appcast"),
        (["FAKE_GH_CORRUPT_UPLOAD": "1"], "the downloaded Spool-\(version).zip is not the same as the uploaded one"),
        (["FAKE_GH_CORRUPT_DMG": "1"], "the downloaded Spool.dmg is not the same as the uploaded one"),
        (["FAKE_GH_NO_TAG": "1"], "the tag v\(version) does not exist in \(releases)"),
    ])
    func aPublishedReleaseThatIsNotTheUploadedOneIsNotTagged(_ env: [String: String], _ message: String) throws {
        let f = try Fixture()
        let r = try f.release(env: env)
        #expect(r.status != 0)
        #expect(r.error.contains(message), "\(r.all)")
        #expect(f.ghCalls.contains("release edit v\(Self.version)"), "the release is published")
        #expect(try f.tags().isEmpty, "no tag")
    }

    // MARK: --finish

    /// A real run that published, and then lost its tag: the state that --finish repairs.
    static func publishedWithoutTag() throws -> Fixture {
        let f = try Fixture()
        let r = try f.release()
        guard r.status == 0 else { throw Failure(text: "the setup run failed: \(r.all)") }
        try f.sh("git tag -d v\(version)")
        return f
    }

    @Test func finishTagsAPublishedReleaseThatStoppedBeforeTheTag() throws {
        let f = try Self.publishedWithoutTag()
        let r = try f.release("--finish")
        #expect(r.status == 0, "\(r.all)")
        #expect(r.output.contains("Published Spool \(Self.version)"))
        #expect(try f.sh("git rev-parse 'v\(Self.version)^{commit}'") == (try f.head()))
        #expect(f.ghCalls.components(separatedBy: "release create").count == 2, "--finish uploads nothing")
    }

    static func expectFinishRefused(_ f: Fixture, _ message: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let r = try f.release("--finish")
        #expect(r.status != 0, sourceLocation: sourceLocation)
        #expect(r.error.contains(message), "expected '\(message)' in: \(r.all)", sourceLocation: sourceLocation)
        #expect(try f.tags().isEmpty, sourceLocation: sourceLocation)
    }

    @Test func finishNeedsEveryFileOfTheRun() throws {
        let f = try Self.publishedWithoutTag()
        try FileManager.default.removeItem(at: f.out.appendingPathComponent("Spool.dmg"))
        try Self.expectFinishRefused(f, "Spool.dmg is missing. --finish needs the files of the run that published")
    }

    @Test func finishNeedsFilesThatMatchTheirChecksums() throws {
        let f = try Self.publishedWithoutTag()
        let appcast = f.out.appendingPathComponent("appcast.xml")
        try (try String(contentsOf: appcast, encoding: .utf8) + "<!-- changed -->\n").write(to: appcast, atomically: true, encoding: .utf8)
        try Self.expectFinishRefused(f, "do not match SHA256SUMS.txt")
    }

    @Test func finishNeedsAnAppcastWithARelease() throws {
        let f = try Self.publishedWithoutTag()
        try f.sh("""
        cd '\(f.out.path)' && printf '<rss version="2.0"><channel></channel></rss>\\n' > appcast.xml \
          && shasum -a 256 Spool-\(Self.version).zip Spool.dmg appcast.xml > SHA256SUMS.txt
        """)
        try Self.expectFinishRefused(f, "appcast.xml has no release item")
    }

    @Test func finishNeedsTheCommitOfTheRelease() throws {
        let f = try Self.publishedWithoutTag()
        try f.sh("git commit -q --allow-empty -m later")
        try Self.expectFinishRefused(f, "--finish must run on the commit of the release.")
    }

    @Test func finishNeedsTheBuildOfTheRelease() throws {
        let f = try Self.publishedWithoutTag()
        try f.sh("""
        cd '\(f.out.path)' && sed -i '' 's|<sparkle:version>\(Self.build)</sparkle:version>|<sparkle:version>99</sparkle:version>|' appcast.xml \
          && shasum -a 256 Spool-\(Self.version).zip Spool.dmg appcast.xml > SHA256SUMS.txt
        """)
        try Self.expectFinishRefused(f, "was built at build 99, HEAD is build \(Self.build)")
    }

    @Test func finishNeedsAPublishedRelease() throws {
        let f = try Self.publishedWithoutTag()
        try f.releaseState("v\(Self.version)", isDraft: "true")
        try Self.expectFinishRefused(f, "v\(Self.version) is not a published release in \(Self.releases)")
    }
}

private extension URL {
    /// Makes the parent folder, returns self.
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}
