import Foundation
import Testing

/// `scripts/site-domain` connects spool.1yc.dev to GitHub Pages. It changes Cloudflare DNS and the Pages settings, so
/// these tests never let it reach the network: `gh`, `dig` and `curl` on its PATH are one fake tool that answers from
/// a list of rules and logs every call (arguments, stdin, and whether the Cloudflare token was in its environment).
@Suite struct SiteDomainScriptTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let script = root.appendingPathComponent("scripts/site-domain")
    static let token = "cf-test-token-7f3a"

    static let fakeTool = """
        #!/usr/bin/python3 -I
        import json, os, sys
        tool = os.path.basename(sys.argv[0])
        stdin = sys.stdin.read()
        log = os.environ["FAKE_LOG"]
        with open(log, "a") as f:
            f.write(json.dumps({"tool": tool, "argv": sys.argv[1:], "stdin": stdin,
                                "tokenInEnv": "CLOUDFLARE_API_TOKEN" in os.environ}) + "\\n")
        text = " ".join(sys.argv[1:]) + "\\n" + stdin
        for i, rule in enumerate(json.load(open(os.environ["FAKE_RULES"]))):
            if rule["tool"] == tool and all(m in text for m in rule["match"]):
                count = log + ".%d" % i
                n = int(open(count).read()) if os.path.exists(count) else 0
                open(count, "w").write(str(n + 1))
                r = rule["responses"][min(n, len(rule["responses"]) - 1)]
                sys.stdout.write(r.get("out", "")); sys.stderr.write(r.get("err", "")); sys.exit(r.get("code", 0))
        sys.stderr.write("fake %s: no rule for %r" % (tool, text)); sys.exit(99)
        """

    struct Call { var tool: String; var argv: [String]; var stdin: String; var tokenInEnv: Bool }

    struct Run {
        var status: Int32
        var lines: [[String: Any]]
        var stderr: String
        var calls: [Call]
        var summary: [String: Any]? { lines.last { $0["event"] as? String == "summary" } }
        func step(_ name: String) -> [String: Any]? {
            lines.first { $0["event"] as? String == "step" && $0["step"] as? String == name }
        }
        func status(of name: String) -> String? { step(name)?["status"] as? String }
        func cloudflare(_ method: String) -> [Call] {
            calls.filter { $0.tool == "curl" && $0.stdin.contains("request = \"\(method)\"") }
        }
        func pagesPuts() -> [[String]] { calls.filter { $0.tool == "gh" && $0.argv.contains("PUT") }.map(\.argv) }
    }

    /// One rule: the first rule of the tool whose `match` strings are all in "arguments + stdin" answers. Each call
    /// takes the next response; the last response repeats.
    static func rule(_ tool: String, _ match: [String], _ outs: String...) -> [String: Any] {
        ["tool": tool, "match": match, "responses": outs.map { ["out": $0] }]
    }

    static func run(_ args: [String], rules: [[String: Any]], token: String? = nil) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spool-site-domain-\(UUID().uuidString)")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for tool in ["gh", "dig", "curl"] {
            let file = bin.appendingPathComponent(tool)
            try Data(fakeTool.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let rulesFile = dir.appendingPathComponent("rules.json"), log = dir.appendingPathComponent("calls.jsonl")
        try JSONSerialization.data(withJSONObject: rules).write(to: rulesFile)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", script.path] + args
        p.currentDirectoryURL = root
        var env = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": dir.path, "FAKE_RULES": rulesFile.path,
                   "FAKE_LOG": log.path, "LANG": "en_US.UTF-8"]
        if let token { env["CLOUDFLARE_API_TOKEN"] = token }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let calls = logText.split(separator: "\n").compactMap { line -> Call? in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return Call(tool: o["tool"] as? String ?? "", argv: o["argv"] as? [String] ?? [],
                        stdin: o["stdin"] as? String ?? "", tokenInEnv: o["tokenInEnv"] as? Bool ?? true)
        }
        return Run(status: p.terminationStatus, lines: lines, stderr: String(decoding: errData, as: UTF8.self), calls: calls)
    }

    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func pages(cert: String?, https: Bool = false) -> String {
        var o: [String: Any] = ["cname": "spool.1yc.dev", "https_enforced": https]
        if let cert { o["https_certificate"] = ["state": cert, "description": "test"] }
        return json(o)
    }

    static func cf(_ result: Any) -> String { json(["success": true, "errors": [], "result": result]) }

    static let proxiedDNS = [
        rule("dig", ["spool.1yc.dev CNAME"], ""),
        rule("dig", ["spool.1yc.dev A\n"], "188.114.96.0\n188.114.97.0\n"),
    ]
    static let githubDNS = [
        rule("dig", ["spool.1yc.dev CNAME"], "fskroes.github.io.\n"),
        rule("dig", ["spool.1yc.dev A\n"], "fskroes.github.io.\n185.199.108.153\n185.199.109.153\n"),
    ]
    static let liveSite = [
        rule("curl", ["-sSI", "https://spool.1yc.dev/"], "HTTP/2 200\r\nserver: GitHub.com\r\n\r\n"),
        rule("curl", ["-sSI", "http://spool.1yc.dev/"], "HTTP/1.1 301 Moved Permanently\r\nLocation: https://spool.1yc.dev/\r\n\r\n"),
    ]

    /// Today's state: the name falls under a proxied wildcard. status names the exact record to add and writes nothing.
    @Test func statusNamesTheRecordToAddAndChangesNothing() throws {
        let r = try Self.run(["status"], rules: Self.proxiedDNS)
        #expect(r.status == 1, "\(r.lines) \(r.stderr)")
        #expect(r.status(of: "dns") == "todo")
        let action = r.step("dns")?["action"] as? String ?? ""
        for want in ["zone 1yc.dev", "Type CNAME, Name spool, Target fskroes.github.io", "DNS only", "CLOUDFLARE_API_TOKEN"] {
            #expect(action.contains(want), "\(want) in \(action)")
        }
        #expect(["pages", "certificate", "https", "live"].allSatisfy { r.status(of: $0) == "blocked" })
        #expect(r.summary?["result"] as? String == "needs-action")
        #expect(r.calls.allSatisfy { $0.tool == "dig" }, "status must not call gh or curl here: \(r.calls.map(\.argv))")
    }

    @Test func statusIsDoneWhenEveryStepHolds() throws {
        let r = try Self.run(["status"], rules: Self.githubDNS + Self.liveSite + [
            Self.rule("gh", ["api repos/fskroes/Spool/pages"], Self.pages(cert: "approved", https: true)),
        ])
        #expect(r.status == 0, "\(r.lines) \(r.stderr)")
        #expect(r.summary?["result"] as? String == "done")
        #expect(r.summary?["done"] as? [String] == ["dns", "pages", "certificate", "https", "live"])
        #expect(r.pagesPuts().isEmpty)
        #expect(r.cloudflare("POST").isEmpty && r.cloudflare("PATCH").isEmpty)
    }

    /// status is read only also when GitHub needs a change: it says to run apply and calls no PUT.
    @Test func statusNeverWritesToGitHub() throws {
        let noDomain = try Self.run(["status"], rules: Self.githubDNS + [
            Self.rule("gh", ["api repos/fskroes/Spool/pages"], Self.json(["cname": NSNull(), "https_enforced": false])),
        ])
        #expect(noDomain.status == 1, "\(noDomain.lines) \(noDomain.stderr)")
        #expect(noDomain.status(of: "pages") == "todo")
        #expect(noDomain.pagesPuts().isEmpty)

        let noCert = try Self.run(["status"], rules: Self.githubDNS + [
            Self.rule("gh", ["api repos/fskroes/Spool/pages"], Self.pages(cert: nil)),
        ])
        #expect(noCert.status == 1, "\(noCert.lines) \(noCert.stderr)")
        #expect(noCert.status(of: "certificate") == "todo")
        #expect(noCert.status(of: "https") == "blocked")
        #expect(noCert.pagesPuts().isEmpty)
    }

    /// The whole path: add the record with the proxy off, wait for DNS, save the domain once to start the
    /// certificate, wait for it, then enforce HTTPS. The token reaches curl on stdin only.
    @Test func applyAddsTheRecordThenFinishesEveryStep() throws {
        let rules: [[String: Any]] = [
            Self.rule("dig", ["spool.1yc.dev CNAME"], "", "fskroes.github.io.\n"),
            Self.rule("dig", ["spool.1yc.dev A\n"], "188.114.96.0\n", "185.199.108.153\n"),
            Self.rule("curl", ["request = \"GET\"", "/zones?name=1yc.dev"], Self.cf([["id": "z1"]])),
            Self.rule("curl", ["request = \"GET\"", "/zones/z1/dns_records?name=spool.1yc.dev"], Self.cf([])),
            Self.rule("curl", ["request = \"POST\"", "/zones/z1/dns_records"], Self.cf(["id": "r1"])),
            Self.rule("gh", ["-X PUT repos/fskroes/Spool/pages"], ""),
            Self.rule("gh", ["api repos/fskroes/Spool/pages"],
                      Self.pages(cert: nil), Self.pages(cert: "authorization_pending"), Self.pages(cert: "approved")),
        ] + Self.liveSite
        let r = try Self.run(["apply", "--wait", "10", "--interval", "0"], rules: rules, token: Self.token)
        #expect(r.status == 0, "\(r.lines) \(r.stderr)")
        #expect(r.summary?["result"] as? String == "done")

        let post = r.cloudflare("POST")
        #expect(post.count == 1)
        for want in ["\\\"type\\\": \\\"CNAME\\\"", "\\\"name\\\": \\\"spool.1yc.dev\\\"",
                     "\\\"content\\\": \\\"fskroes.github.io\\\"", "\\\"proxied\\\": false"] {
            #expect(post.first?.stdin.contains(want) == true, "\(want) in \(post.first?.stdin ?? "")")
        }
        #expect(r.pagesPuts() == [["api", "-X", "PUT", "repos/fskroes/Spool/pages", "-f", "cname=spool.1yc.dev"],
                                  ["api", "-X", "PUT", "repos/fskroes/Spool/pages", "-F", "https_enforced=true"]])

        #expect(r.calls.allSatisfy { !$0.argv.joined(separator: " ").contains(Self.token) }, "token on a command line")
        #expect(r.calls.allSatisfy { !$0.tokenInEnv }, "token in a child environment")
        #expect(r.calls.filter { $0.stdin.contains(Self.token) }.allSatisfy { $0.tool == "curl" })
    }

    @Test func applyTurnsTheProxyOffOnTheGitHubRecordAndWaitsForDNS() throws {
        let rules = Self.proxiedDNS + [
            Self.rule("curl", ["request = \"GET\"", "/zones?name=1yc.dev"], Self.cf([["id": "z1"]])),
            Self.rule("curl", ["request = \"GET\"", "/dns_records?name="],
                      Self.cf([["id": "r9", "type": "CNAME", "content": "fskroes.github.io", "proxied": true]])),
            Self.rule("curl", ["request = \"PATCH\"", "/zones/z1/dns_records/r9"], Self.cf(["id": "r9"])),
        ]
        let r = try Self.run(["apply"], rules: rules, token: Self.token)
        #expect(r.status == 3, "\(r.lines) \(r.stderr)")
        #expect(r.status(of: "dns") == "wait")
        #expect(r.summary?["result"] as? String == "waiting")
        #expect(r.cloudflare("PATCH").count == 1)
        #expect(r.cloudflare("PATCH").first?.stdin.contains("\\\"proxied\\\": false") == true)
        #expect(r.cloudflare("POST").isEmpty)
        #expect(!r.calls.contains { $0.tool == "gh" })
    }

    /// The script owns only the GitHub CNAME. Any other record under the name is for a person to change.
    @Test func applyNeverChangesAnotherRecord() throws {
        let rules = Self.proxiedDNS + [
            Self.rule("curl", ["request = \"GET\"", "/zones?name=1yc.dev"], Self.cf([["id": "z1"]])),
            Self.rule("curl", ["request = \"GET\"", "/dns_records?name="],
                      Self.cf([["id": "r1", "type": "CNAME", "content": "cname.vercel-dns.com", "proxied": true]])),
        ]
        let r = try Self.run(["apply"], rules: rules, token: Self.token)
        #expect(r.status == 1, "\(r.lines) \(r.stderr)")
        #expect(r.status(of: "dns") == "fail")
        #expect((r.step("dns")?["detail"] as? String ?? "").contains("CNAME cname.vercel-dns.com"))
        #expect(r.calls.allSatisfy { $0.tool != "curl" || $0.stdin.contains("request = \"GET\"") }, "a write call")
    }

    @Test func aCloudflareErrorIsAFailWithItsMessage() throws {
        let rules = Self.proxiedDNS + [
            Self.rule("curl", ["/zones?name=1yc.dev"],
                      Self.json(["success": false, "errors": [["code": 1000, "message": "Invalid API Token"]]])),
        ]
        let r = try Self.run(["apply"], rules: rules, token: Self.token)
        #expect(r.status == 1)
        #expect(r.status(of: "dns") == "fail")
        #expect((r.step("dns")?["detail"] as? String ?? "").contains("Invalid API Token"))
    }

    /// A certificate in progress is not saved again (that would restart it), and HTTPS is not enforced before it exists.
    @Test func applyWaitsForTheCertificateAndDoesNotEnforceHttpsEarly() throws {
        let r = try Self.run(["apply"], rules: Self.githubDNS + [
            Self.rule("gh", ["api repos/fskroes/Spool/pages"], Self.pages(cert: "authorization_pending")),
        ])
        #expect(r.status == 3, "\(r.lines) \(r.stderr)")
        #expect(r.status(of: "certificate") == "wait")
        #expect(r.status(of: "https") == "blocked")
        #expect(r.pagesPuts().isEmpty)
    }

    /// A new domain is saved once. The certificate is not there yet right after the save, and a second save in the
    /// same run would start its request again.
    @Test func applySavesANewDomainOnce() throws {
        let r = try Self.run(["apply", "--wait", "10", "--interval", "0"], rules: Self.githubDNS + Self.liveSite + [
            Self.rule("gh", ["-X PUT repos/fskroes/Spool/pages"], ""),
            Self.rule("gh", ["api repos/fskroes/Spool/pages"],
                      Self.json(["cname": NSNull(), "https_enforced": false]), Self.pages(cert: nil),
                      Self.pages(cert: "authorization_pending"), Self.pages(cert: "approved")),
        ])
        #expect(r.status == 0, "\(r.lines) \(r.stderr)")
        #expect(r.pagesPuts().filter { $0.contains("cname=spool.1yc.dev") }.count == 1, "\(r.pagesPuts())")
    }

    /// An errored certificate gets one new try. When it is still errored, a person must look.
    @Test func applyRetriesAnErroredCertificateOnce() throws {
        let r = try Self.run(["apply"], rules: Self.githubDNS + [
            Self.rule("gh", ["-X PUT repos/fskroes/Spool/pages"], ""),
            Self.rule("gh", ["api repos/fskroes/Spool/pages"], Self.pages(cert: "errored")),
        ])
        #expect(r.status == 1, "\(r.lines) \(r.stderr)")
        #expect(r.status(of: "certificate") == "fail")
        #expect(r.pagesPuts() == [["api", "-X", "PUT", "repos/fskroes/Spool/pages", "-f", "cname=spool.1yc.dev"]])
    }

    /// A GitHub CNAME with the proxy off is already right: apply writes nothing and waits for the resolver.
    @Test func applyWritesNothingWhenTheRecordIsRight() throws {
        let rules = Self.proxiedDNS + [
            Self.rule("curl", ["request = \"GET\"", "/zones?name=1yc.dev"], Self.cf([["id": "z1"]])),
            Self.rule("curl", ["request = \"GET\"", "/dns_records?name="],
                      Self.cf([["id": "r1", "type": "CNAME", "content": "fskroes.github.io.", "proxied": false]])),
        ]
        let r = try Self.run(["apply"], rules: rules, token: Self.token)
        #expect(r.status == 3, "\(r.lines) \(r.stderr)")
        #expect(r.status(of: "dns") == "wait")
        #expect(r.calls.allSatisfy { $0.tool != "curl" || $0.stdin.contains("request = \"GET\"") }, "a write call")
    }

    /// The GitHub CNAME next to another record under the same name: the script does not choose, a person does.
    @Test func applyStopsWhenTheNameHasMoreThanOneRecord() throws {
        let rules = Self.proxiedDNS + [
            Self.rule("curl", ["request = \"GET\"", "/zones?name=1yc.dev"], Self.cf([["id": "z1"]])),
            Self.rule("curl", ["request = \"GET\"", "/dns_records?name="], Self.cf([
                ["id": "r1", "type": "CNAME", "content": "fskroes.github.io", "proxied": true],
                ["id": "r2", "type": "TXT", "content": "keep me", "proxied": false],
            ])),
        ]
        let r = try Self.run(["apply"], rules: rules, token: Self.token)
        #expect(r.status == 1, "\(r.lines) \(r.stderr)")
        #expect(r.status(of: "dns") == "fail")
        #expect(r.calls.allSatisfy { $0.tool != "curl" || $0.stdin.contains("request = \"GET\"") }, "a write call")
    }

    /// An answer of an unexpected shape is a fail step with a summary line, not a traceback.
    @Test func anUnexpectedAnswerStillEndsWithASummary() throws {
        let rules = Self.proxiedDNS + [
            Self.rule("curl", ["request = \"GET\"", "/zones?name=1yc.dev"], Self.cf([["name": "1yc.dev"]])),
        ]
        let r = try Self.run(["apply"], rules: rules, token: Self.token)
        #expect(r.status == 1, "\(r.lines) \(r.stderr)")
        #expect(r.status(of: "dns") == "fail")
        #expect(r.summary?["result"] as? String == "needs-action")
        #expect(!r.stderr.contains("Traceback"))
    }

    @Test func aSiteThatDoesNotAnswerIsWaiting() throws {
        let r = try Self.run(["status"], rules: Self.githubDNS + [
            Self.rule("gh", ["api repos/fskroes/Spool/pages"], Self.pages(cert: "approved", https: true)),
            Self.rule("curl", ["-sSI", "https://spool.1yc.dev/"], "HTTP/2 404\r\nserver: GitHub.com\r\n\r\n"),
        ])
        #expect(r.status == 3, "\(r.lines) \(r.stderr)")
        #expect(r.status(of: "live") == "wait")
        #expect((r.step("live")?["detail"] as? String ?? "").contains("answered 404"))
    }

    /// The token is never printed, also when Cloudflare fails and the error goes to the output.
    @Test func theTokenIsNeverInTheOutput() throws {
        let rules = Self.proxiedDNS + [
            Self.rule("curl", ["/zones?name=1yc.dev"],
                      Self.json(["success": false, "errors": [["code": 9109, "message": "Unauthorized"]]])),
        ]
        let r = try Self.run(["apply"], rules: rules, token: Self.token)
        let printed = r.lines.map { Self.json($0) }.joined() + r.stderr
        #expect(!r.lines.isEmpty)
        #expect(!printed.contains(Self.token))
    }

    @Test func usageErrorsExitTwo() throws {
        #expect(try Self.run(["nonsense"], rules: []).status == 2)
        #expect(try Self.run(["status", "--wait", "5"], rules: []).status == 2)
        #expect(try Self.run(["status", "--host", "spool.1yc.dev; rm -rf x"], rules: []).status == 2)
    }
}
