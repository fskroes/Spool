import Foundation
import Testing

/// Runs the real scripts/release.sh and scripts/release-lib.sh end to end, in a temporary Git repository on
/// `main`. Each test changes one thing from a setup that publishes, and checks that the run stops with the
/// message of that check, before the upload and before the tag.
///
/// Every tool that would build, sign, read a keychain or use the network is a fake, so a run takes about a
/// second. PATH has only the fakes and the system folders: the real `gh` (Homebrew) cannot run.
/// - scripts/signing-env.sh: a fake. release.sh uses only `striple_signing_identity` from it, which prints
///   FAKE_HASH. The real function is tested in SigningScriptTests; a fake here means no `security` call at all.
/// - scripts/build-app.sh, scripts/make-dmg.sh: write a small Striple.app with a real Info.plist (FAKE_* change
///   its values) and a "DMG" that is a zip. `hdiutil attach` unpacks it at the mount point.
/// - Sparkle tools: generate_keys prints the key, generate_appcast writes a real one-item appcast.
/// - gh: logs each call to gh.log. `release create` copies the assets into the fake web folder, `release edit`
///   makes that appcast the latest one. curl serves the web folder (404 for a missing file).
/// - codesign: the requirement names the SHA-1 in Contents/_CodeSignature/hash of the app.
/// Real tools: git, ditto, shasum, plutil, xmllint, unzip, stat, cmp.
@Suite struct ReleaseRunTests {
    static let pin = "B608FA4F3D9A1FC14CDBAB47421A660E429053DC"
    static let otherHash = "0123456789ABCDEF0123456789ABCDEF01234567"
    static let key = Data(repeating: 7, count: 32).base64EncodedString()
    static let otherKey = Data(repeating: 9, count: 32).base64EncodedString()
    static let releases = "fskroes/striple-test"
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
        var out: URL { repo.appendingPathComponent("dist/release/\(ReleaseRunTests.version)") }

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("striple-run-\(UUID().uuidString)")
            for dir in [repo, bin, web, state, base.appendingPathComponent("home"), base.appendingPathComponent("tmp")] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let scripts = ReleaseScriptTests.root.appendingPathComponent("scripts")
            for name in ["release.sh", "release-lib.sh"] {
                try FileManager.default.copyItem(at: scripts.appendingPathComponent(name),
                                                 to: repo.appendingPathComponent("scripts/\(name)").creatingParent())
            }
            try writeFakes()
            try write("VERSION", ReleaseRunTests.version + "\n")
            try write("CHANGELOG.md", "# Changelog\n\n## 1.2.0\n\n- A test release.\n\n## 1.1.0\n\n- Older.\n")
            try write("Packaging/releases-README.md", "# Striple releases\n")
            try write("Packaging/updates.env", """
            STRIPLE_RELEASES_REPO=\(ReleaseRunTests.releases)
            STRIPLE_FEED_URL=\(ReleaseRunTests.feed)
            STRIPLE_ED_PUBLIC_KEY=\(ReleaseRunTests.key)
            STRIPLE_ED_KEY_ACCOUNT=com.fskroes.Striple
            STRIPLE_SIGNING_CERT_SHA1=\(ReleaseRunTests.pin)

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
                "USER": "striple-test-user",
                "TMPDIR": base.appendingPathComponent("tmp").path + "/",
                "LANG": "en_US.UTF-8",
                "FAKE_HASH": ReleaseRunTests.pin,
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
        var uploaded: Bool { ghCalls.contains("release create") }

        /// A published release `version` in the fake web: its appcast is the latest, and its archive has an app
        /// signed with `hash` and the update key `key`.
        func publish(version: String, build: Int, hash: String = ReleaseRunTests.pin, key: String = ReleaseRunTests.key) throws {
            let dir = base.appendingPathComponent("published-\(UUID().uuidString)")
            let app = dir.appendingPathComponent("Striple.app/Contents")
            try write(app.appendingPathComponent("Info.plist"),
                      Fixture.plist(version: version, build: "\(build)", feed: ReleaseRunTests.feed, key: key))
            try write(app.appendingPathComponent("_CodeSignature/hash"), hash + "\n")
            try write(app.appendingPathComponent("MacOS/Striple"), "fake app binary\n")
            let url = "https://github.com/\(ReleaseRunTests.releases)/releases/download/v\(version)/Striple-\(version).zip"
            let zip = web.appendingPathComponent(String(url.dropFirst("https://".count)))
            try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try sh("ditto -c -k --keepParent '\(dir.appendingPathComponent("Striple.app").path)' '\(zip.path)'")
            let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int ?? 0
            try write(web.appendingPathComponent(String(ReleaseRunTests.feed.dropFirst("https://".count))), """
            <?xml version="1.0" standalone="yes"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Striple</title>
            <item><title>\(version)</title><sparkle:version>\(build)</sparkle:version><sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
            <enclosure url="\(url)" length="\(size)" type="application/octet-stream" sparkle:edSignature="c2ln"/></item>
            </channel></rss>

            """)
        }

        /// gh answers `release view` for `tag` with this isDraft value ("true" or "false").
        func releaseState(_ tag: String, isDraft: String) throws {
            try write(state.appendingPathComponent(tag), isDraft + "\n")
        }

        static func plist(version: String, build: String, feed: String, key: String, bundle: String = "com.fskroes.Striple") -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>\(bundle)</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleVersion</key><string>\(build)</string>
            <key>SUFeedURL</key><string>\(feed)</string>
            <key>SUPublicEDKey</key><string>\(key)</string>
            </dict></plist>

            """
        }

        // swiftlint:disable:next function_body_length
        private func writeFakes() throws {
            let webPath = web.path, statePath = state.path
            try write("scripts/signing-env.sh", #"""
            # Fake for ReleaseRunTests: no keychain. The SHA-1 of the local identity is FAKE_HASH.
            striple_signing_identity() { [ -n "${FAKE_HASH:-}" ] || return 1; printf '%s\n' "$FAKE_HASH"; }

            """#)
            let plist = Fixture.plist(version: "${FAKE_APP_VERSION:-$(tr -d '[:space:]' < VERSION)}",
                                      build: "${FAKE_APP_BUILD:-$(git rev-list --count HEAD)}",
                                      feed: "${FAKE_APP_FEED:-\(ReleaseRunTests.feed)}",
                                      key: "${FAKE_APP_KEY:-\(ReleaseRunTests.key)}",
                                      bundle: "${FAKE_BUNDLE_ID:-com.fskroes.Striple}")
            try write("scripts/build-app.sh", #"""
            #!/bin/bash
            set -euo pipefail
            cd "$(dirname "$0")/.."
            APP=dist/Striple.app
            rm -rf "$APP"
            mkdir -p "$APP/Contents/MacOS" "$APP/Contents/_CodeSignature"
            cat > "$APP/Contents/Info.plist" <<PLIST
            \#(plist)PLIST
            printf 'fake app binary\n' > "$APP/Contents/MacOS/Striple"
            printf '%s\n' "${FAKE_SIGNED_HASH:-$FAKE_HASH}" > "$APP/Contents/_CodeSignature/hash"
            [ -z "${FAKE_BAD_SIGNATURE:-}" ] || : > "$APP/Contents/_CodeSignature/invalid"
            [ -z "${FAKE_BUILD_COMMITS:-}" ] || git commit -q --allow-empty -m "a commit during the build"
            [ -z "${FAKE_BUILD_DIRTIES:-}" ] || echo x > stray.txt
            echo "==> Built $APP"

            """#, executable: true)
            try write("scripts/make-dmg.sh", #"""
            #!/bin/bash
            set -euo pipefail
            cd "$(dirname "$0")/.."
            V=$(plutil -extract CFBundleShortVersionString raw -o - dist/Striple.app/Contents/Info.plist)
            rm -f "dist/Striple-$V.dmg"
            ditto -c -k --keepParent dist/Striple.app "dist/Striple-$V.dmg"

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
                --download-url-prefix) prefix=$2; shift ;;
                -o) out=$2; shift ;;
                --account|--link) shift ;;
                -*) ;;
                *) dir=$1 ;;
              esac
              shift
            done
            zip=$(ls "$dir"/*.zip)
            unzip -p "$zip" Striple.app/Contents/Info.plist > "$dir/Info.plist"
            short=$(plutil -extract CFBundleShortVersionString raw -o - "$dir/Info.plist")
            build=$(plutil -extract CFBundleVersion raw -o - "$dir/Info.plist")
            length=$(stat -f %z "$zip")
            cat > "$out" <<XML
            <?xml version="1.0" standalone="yes"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Striple</title>
            <item><title>$short</title><sparkle:version>$build</sparkle:version><sparkle:shortVersionString>$short</sparkle:shortVersionString>
            <enclosure url="$prefix$(basename "$zip")" length="$length" type="application/octet-stream" sparkle:edSignature="c2ln"/></item>
            </channel></rss>
            XML
            """#, executable: true)
            try write(sparkle + "sign_update", #"""
            #!/bin/sh
            [ "$3" = --verify ] && [ "$5" = c2ln ]
            """#, executable: true)

            try write(bin.appendingPathComponent("gh"), #"""
            #!/bin/sh
            printf '%s\n' "$*" >> '\#(ghLog.path)'
            W='\#(webPath)/github.com'
            S='\#(statePath)'
            case "$1 $2" in
              "auth status") exit 0 ;;
              "api user") echo "${FAKE_GH_LOGIN:-fskroes}" ;;
              "api -X") exit 0 ;;
              "repo view") [ -z "${FAKE_GH_NO_REPO:-}" ] ;;
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
                echo true > "$S/$tag" ;;
              "release edit")
                tag=$3 repo=$5
                echo false > "$S/$tag"
                mkdir -p "$W/$repo/releases/latest/download"
                cp "$W/$repo/releases/download/$tag/appcast.xml" "$W/$repo/releases/latest/download/" ;;
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
            case "$1" in
              --verify) [ -f "$sig/hash" ] && [ ! -e "$sig/invalid" ] || { echo "$app: invalid signature" >&2; exit 1; } ;;
              -d) echo "Executable=$app/Contents/MacOS/Striple" >&2
                  echo "designated => identifier \"com.fskroes.Striple\" and certificate leaf = H\"$(tr 'A-F' 'a-f' < "$sig/hash")\"" ;;
              *) echo "fake codesign: unexpected: $*" >&2; exit 1 ;;
            esac
            """#, executable: true)
            try write(bin.appendingPathComponent("lipo"), #"""
            #!/bin/sh
            [ "$1" = -archs ] && echo "${FAKE_ARCHS:-x86_64 arm64}"
            """#, executable: true)
            try write(bin.appendingPathComponent("hdiutil"), #"""
            #!/bin/sh
            case "$1" in
              attach)
                shift
                while [ $# -gt 0 ]; do case "$1" in -mountpoint) mp=$2; shift ;; -*) ;; *) img=$1 ;; esac; shift; done
                mkdir -p "$mp" && ditto -x -k "$img" "$mp" ;;
              detach) rm -rf "$2" ;;
              *) echo "fake hdiutil: unexpected: $*" >&2; exit 1 ;;
            esac
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
        for name in ["Striple-\(Self.version).zip", "Striple.dmg", "appcast.xml", "SHA256SUMS.txt", "notes.md"] {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), "\(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: f.out.path), "a dry run never writes the files of a real run")
        #expect(f.ghCalls.isEmpty, "a dry run never calls gh: \(f.ghCalls)")
        #expect(try f.tags().isEmpty)
    }

    // The first release: no feed, no repository. The run makes the repository, uploads, publishes and tags.
    @Test func aFirstReleaseMakesTheRepositoryPublishesAndTags() throws {
        let f = try Fixture()
        let head = try f.head()
        let r = try f.release(env: ["FAKE_GH_LIST": "norepo", "FAKE_GH_NO_REPO": "1"])
        #expect(r.status == 0, "\(r.all)")
        #expect(r.output.contains("No release published yet. New: \(Self.version) (\(Self.build))"))
        #expect(r.output.contains("Published Striple \(Self.version): https://github.com/\(Self.releases)/releases/tag/v\(Self.version)"))
        #expect(f.ghCalls.contains("api -X POST user/repos -f name=striple-test"))
        #expect(f.ghCalls.contains("release create v\(Self.version) --repo \(Self.releases) --draft"))
        #expect(f.ghCalls.contains("release edit v\(Self.version) --repo \(Self.releases) --draft=false --latest"))
        #expect(try f.sh("git rev-parse 'v\(Self.version)^{commit}'") == head)
        #expect(try f.sh("git cat-file -t v\(Self.version)") == "tag")
        let commit = try String(contentsOf: f.out.appendingPathComponent("commit.txt"), encoding: .utf8)
        #expect(commit == head + "\n")
    }

    @Test func aReleaseAfterAPublishedOneChecksItsIdentityAndKey() throws {
        let f = try Fixture()
        try f.publish(version: "1.1.0", build: 2)
        let r = try f.release()
        #expect(r.status == 0, "\(r.all)")
        #expect(r.output.contains("Published now: 1.1.0 (2). New: \(Self.version) (\(Self.build))"))
        #expect(r.output.contains("The published 1.1.0 has the same signing identity and update key"))
        #expect(try f.sh("git rev-parse 'v\(Self.version)^{commit}'") == (try f.head()))
        #expect(!f.ghCalls.contains("user/repos"), "the repository exists")
    }

    // MARK: checks before the build

    @Test(arguments: [
        (["SIGN_IDENTITY": "Someone"], "unset SIGN_IDENTITY: releases are signed with the local identity only"),
        (["STRIPLE_UPDATES": "off"], "unset STRIPLE_UPDATES: a release must have updates on"),
        (["FAKE_SPARKLE_KEY": otherKey], "does not match STRIPLE_ED_PUBLIC_KEY"),
        (["FAKE_HASH": ""], "no local signing identity. Restore it from your backup"),
        (["FAKE_HASH": otherHash], "the local signing identity is \(otherHash), but Packaging/updates.env pins \(pin)"),
    ])
    func aWrongSettingStopsTheRunBeforeTheBuild(_ env: [String: String], _ message: String) throws {
        let f = try Fixture()
        let r = try f.release(env: env)
        try Self.expectRefused(r, message, f)
        #expect(!FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("dist/Striple.app").path))
    }

    // A pinned SHA-1 in other case is the same pin.
    @Test func thePinIgnoresCase() throws {
        let f = try Fixture()
        let r = try f.release("--dry-run", env: ["FAKE_HASH": Self.pin.lowercased()])
        #expect(r.status == 0, "\(r.all)")
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
        (version, 2, pin, key, "\(version) is published already. If its run stopped before the tag"),
        ("1.3.0", 2, pin, key, "VERSION \(version) is not higher than the published 1.3.0"),
        ("1.1.0", build, pin, key, "build \(build) is not higher than the published build \(build)"),
        ("1.1.0", 2, otherHash, key, "the published 1.1.0 is not signed with \(pin)"),
        ("1.1.0", 2, pin, otherKey, "the published 1.1.0 has another SUPublicEDKey than Packaging/updates.env"),
    ])
    func aPublishedReleaseThatDoesNotFitStopsTheRun(_ version: String, _ build: Int, _ hash: String, _ key: String,
                                                    _ message: String) throws {
        let f = try Fixture()
        try f.publish(version: version, build: build, hash: hash, key: key)
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
        #expect(!FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("dist/Striple.app").path))
    }

    @Test func anUnexpectedFeedAnswerStopsTheRun() throws {
        let f = try Fixture()
        try Self.expectRefused(try f.release(env: ["FAKE_FEED_CODE": "500"]), "unexpected HTTP 500 from \(Self.feed)", f)
    }

    @Test func aDraftOfThisVersionStopsTheRunBeforeTheBuild() throws {
        let f = try Fixture()
        try f.releaseState("v\(Self.version)", isDraft: "true")
        try Self.expectRefused(try f.release(), "a draft release v\(Self.version) exists in \(Self.releases)", f)
        #expect(!FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("dist/Striple.app").path))
    }

    // MARK: checks after the build

    @Test(arguments: [
        (["FAKE_BUNDLE_ID": "com.example.Other"], "wrong bundle ID in"),
        (["FAKE_APP_VERSION": "9.9.9"], "the app version is not \(version)"),
        (["FAKE_APP_BUILD": "99"], "the app build is not \(build)"),
        (["FAKE_APP_FEED": "https://example.com/appcast.xml"], "the app has the wrong SUFeedURL"),
        (["FAKE_APP_KEY": otherKey], "the app has the wrong SUPublicEDKey"),
        (["FAKE_BAD_SIGNATURE": "1"], "the signature of the app is not valid"),
        (["FAKE_SIGNED_HASH": otherHash], "the app is not signed with the local identity \(pin)"),
        (["FAKE_ARCHS": "arm64"], "the app has no x86_64 slice"),
        (["FAKE_ARCHS": "x86_64"], "the app has no arm64 slice"),
    ])
    func aWrongAppStopsTheRunAfterTheBuild(_ env: [String: String], _ message: String) throws {
        let f = try Fixture()
        let r = try f.release(env: env)
        try Self.expectRefused(r, message, f)
        #expect(r.output.contains("==> Built dist/Striple.app"), "the check comes after the build")
        #expect(!FileManager.default.fileExists(atPath: f.out.path))
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
        #expect(r.output.contains("Published Striple \(Self.version)"))
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
        try FileManager.default.removeItem(at: f.out.appendingPathComponent("Striple.dmg"))
        try Self.expectFinishRefused(f, "Striple.dmg is missing. --finish needs the files of the run that published")
    }

    @Test func finishNeedsFilesThatMatchTheirChecksums() throws {
        let f = try Self.publishedWithoutTag()
        let appcast = f.out.appendingPathComponent("appcast.xml")
        try (try String(contentsOf: appcast, encoding: .utf8) + "<!-- changed -->\n").write(to: appcast, atomically: true, encoding: .utf8)
        try Self.expectFinishRefused(f, "do not match SHA256SUMS.txt")
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
          && shasum -a 256 Striple-\(Self.version).zip Striple.dmg appcast.xml > SHA256SUMS.txt
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
