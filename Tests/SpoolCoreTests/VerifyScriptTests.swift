import Foundation
import Testing

/// `scripts/verify` is what an agent runs before it says a change is done and what self-merge runs before a merge
/// (.claude/skills/verify-spool). These tests run its usage rules and its `site` layer on fixture folders. The
/// `build`, `cli` and `app` layers run `swift build` and start the app, so they are not run from inside `swift test`.
@Suite struct VerifyScriptTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let script = root.appendingPathComponent("scripts/verify")

    struct Run {
        var status: Int32
        var lines: [[String: Any]]
        var stderr: String
        var summary: [String: Any]? { lines.last { $0["event"] as? String == "summary" } }
        var checks: [[String: Any]] { lines.filter { $0["event"] as? String == "check" } }
        func problems() -> [String] { checks.flatMap { $0["problems"] as? [String] ?? [] } }
    }

    static func verify(_ args: [String]) throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", script.path] + args
        p.currentDirectoryURL = root
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        return Run(status: p.terminationStatus, lines: lines, stderr: String(decoding: errData, as: UTF8.self))
    }

    static func tempDir(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("spool-verify-test-\(name)-\(UUID().uuidString)")
    }

    static func site(_ files: [String: String]) throws -> URL {
        let dir = tempDir("site")
        for (path, text) in files {
            let file = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        return dir
    }

    @Test func badUsageExitsTwo() throws {
        #expect(try Self.verify(["nonsense"]).status == 2)
        #expect(try Self.verify(["smoke", "--only", "bogus"]).status == 2)
        #expect(try Self.verify(["site", "--only", "site"]).status == 2)
        // Evidence must never land in the repository (no binaries in git).
        let inside = try Self.verify(["site", "--out", Self.root.appendingPathComponent(".build/verify-out").path])
        #expect(inside.status == 2)
        #expect(inside.stderr.contains("outside the repository"))
        // A symlink to the repository is still the repository.
        let link = Self.tempDir("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: Self.root)
        defer { try? FileManager.default.removeItem(at: link) }
        let viaLink = try Self.verify(["site", "--out", link.appendingPathComponent(".build/verify-out").path])
        #expect(viaLink.status == 2)
        #expect(viaLink.stderr.contains("outside the repository"))
    }

    /// Everything verify starts gets an allow list of the caller's environment, so no key, token or socket leaks.
    @Test func childProcessesGetOnlyAllowedVariables() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", "-B", "-c", """
            import importlib.machinery, importlib.util, json, sys
            loader = importlib.machinery.SourceFileLoader("verify", sys.argv[1])
            module = importlib.util.module_from_spec(importlib.util.spec_from_loader("verify", loader))
            loader.exec_module(module)
            print(json.dumps(module.child_env({"SPOOL_HOME": "/tmp/h"})))
            """, Self.script.path]
        p.environment = [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/x", "LANG": "en_US.UTF-8", "LC_ALL": "C",
            "AWS_ACCESS_KEY_ID": "a", "SSH_AUTH_SOCK": "/tmp/s", "DATABASE_URL": "postgres://u:p@h/d",
            "GH_TOKEN": "t", "NOTARY_PW": "n", "SPOOL_SOCKET": "/tmp/other.sock",
        ]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let env = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        // The /usr/bin/python3 shim adds SDKROOT and __CF_USER_TEXT_ENCODING itself; both are on the allow list.
        let allowed: Set = ["PATH", "HOME", "LANG", "LC_ALL", "SPOOL_HOME", "SDKROOT", "__CF_USER_TEXT_ENCODING"]
        #expect(Set(env.keys).isSubset(of: allowed), "\(env.keys.sorted())")
        #expect(Set(["PATH", "HOME", "LANG", "LC_ALL"]).isSubset(of: Set(env.keys)))
        #expect(env["SPOOL_HOME"] == "/tmp/h")
    }

    @Test func aGoodSitePassesWithOneSummaryLine() throws {
        let dir = try Self.site([
            "CNAME": "spool.1yc.dev\n",
            "index.html": """
                <!doctype html><html><head><title>Spool</title>
                <script src="https://cdn.jsdelivr.net/npm/x@1.0.0/x.js"></script></head>
                <body><a href="#install">Install</a><a href="docs/">Docs</a><a href="strip.svg">SVG</a>
                <a href="https://github.com/fskroes/Spool">Code</a><a href="mailto:a@b.c">Mail</a>
                <section id="install"></section></body></html>
                """,
            "docs/index.html": "<!doctype html><title>Docs</title><a href=\"../index.html#install\">Back</a>",
            "strip.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\"/>",
        ])
        let out = Self.tempDir("out")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
        let r = try Self.verify(["site", "--site", dir.path, "--out", out.path])
        #expect(r.status == 0, "\(r.lines)")
        #expect(r.summary?["result"] as? String == "pass")
        #expect(r.lines.filter { $0["event"] as? String == "summary" }.count == 1)
        #expect(r.checks.count == 4, "index, CNAME and one check per page: \(r.checks)")
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("summary.json").path))
    }

    @Test func aBrokenSiteFailsWithEveryReason() throws {
        let dir = try Self.site([
            "CNAME": "spool.example.com\n",
            "index.html": """
                <!doctype html><html><head><script src="https://evil.example/x.js"></script></head>
                <body><a href="missing.html">x</a><a href="#nowhere">y</a><a href="http://example.com">z</a>
                <a href="../../etc/hosts">up</a></body></html>
                """,
        ])
        let out = Self.tempDir("out")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: out) }
        let r = try Self.verify(["site", "--site", dir.path, "--out", out.path])
        #expect(r.status == 1)
        #expect(r.summary?["result"] as? String == "fail")
        let problems = r.problems().joined(separator: "\n")
        for want in ["CNAME is 'spool.example.com'", "no <title>", "broken local link: missing.html",
                     "#nowhere has no element with that id", "plain http link: http://example.com",
                     "broken local link: ../../etc/hosts", "script from a host that is not allowed: https://evil.example/x.js"] {
            #expect(problems.contains(want), "missing \(want) in:\n\(problems)")
        }
    }

    /// A `--only` run must not pass for a full smoke run: the summary line, which agents paste in PRs, names the layers.
    @Test func summaryNamesTheLayersThatRan() throws {
        let out = Self.tempDir("out")
        defer { try? FileManager.default.removeItem(at: out) }
        let partial = try Self.verify(["smoke", "--only", "site", "--out", out.path])
        #expect(partial.status == 0, "\(partial.problems())")
        #expect(partial.summary?["layers"] as? [String] == ["site"])
        let site = try Self.verify(["site", "--out", out.path])
        #expect(site.summary?["layers"] as? [String] == ["site"])
    }

    @Test func theRealSitePasses() throws {
        let out = Self.tempDir("out")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try Self.verify(["site", "--out", out.path])
        #expect(r.status == 0, "\(r.problems())")
    }

    @Test func theVerifySkillNamesTheScriptAndItsModes() throws {
        let skill = try String(contentsOf: Self.root.appendingPathComponent(".claude/skills/verify-spool/SKILL.md"), encoding: .utf8)
        #expect(skill.hasPrefix("---\nname: verify-spool\n"))
        for mode in ["scripts/verify smoke", "scripts/verify site", "scripts/verify e2e"] {
            #expect(skill.contains(mode), "\(mode)")
        }
    }
}
