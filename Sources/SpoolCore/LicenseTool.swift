import Foundation

/// The logic of `spool-license`, the owner's tool for license keys (docs/LICENSE-KEYS.md, docs/RELEASING.md,
/// "License keys"). The executable in Sources/spool-license only passes the arguments and writes the output,
/// so tests call `run` with a temporary folder. Files are read and written only at the paths that the
/// arguments name; the default path of the signing key is used only when no `--out` or `--key` is given.
public enum LicenseTool {
    /// What the tool needs from outside. Tests replace each value.
    public struct Environment {
        public var home: URL
        /// The folder where `verify` starts to look for Packaging/updates.env.
        public var currentDirectory: URL
        public var now: () -> Date
        /// `count` random bytes. The default is the system generator.
        public var randomBytes: (Int) -> Data

        public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                    now: @escaping () -> Date = Date.init,
                    randomBytes: @escaping (Int) -> Data = LicenseTool.systemRandomBytes) {
            self.home = home
            self.currentDirectory = currentDirectory
            self.now = now
            self.randomBytes = randomBytes
        }
    }

    public struct Output: Equatable, Error {
        public var stdout: String
        public var stderr: String
        public var code: Int32

        public init(stdout: String = "", stderr: String = "", code: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.code = code
        }
    }

    public static let ok: Int32 = 0
    public static let failed: Int32 = 1
    public static let usageError: Int32 = 2

    public static let privateKeyVariable = "SPOOL_LICENSE_SIGNING_KEY"
    public static let publicKeyVariable = "SPOOL_LICENSE_PUBLIC_KEY"

    public static func systemRandomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    /// `~/.config/spool/license-signing.key`
    public static func defaultKeyURL(home: URL) -> URL {
        home.appendingPathComponent(".config/spool/license-signing.key")
    }

    // MARK: Help

    public static let help = """
    spool-license: the owner's tool for Spool license keys. Not part of the app.

    Usage: spool-license <command> [options]

    Commands:
      keygen [--out <path>]               Make the key pair once. Writes the private key (base64 seed, mode 600)
                                          to <path>, default ~/.config/spool/license-signing.key. Refuses when the
                                          file exists. Prints the public key and the line for Packaging/updates.env.
      env-line [--key <path>]             Print SPOOL_LICENSE_SIGNING_KEY=<seed> for ~/1yc/.env on the server of
                                          1yc.dev. The only command that prints the private key.
      issue --email <email> [--id <id>] [--key <path>]
                                          Print a license key. The id is comp-<YYYY-MM-DD>-<4 hex> by default.
                                          The date is today, UTC.
      verify <key> [--public-key <base64>]
                                          Print the fields of a key, or say that it is not valid. The default
                                          public key is SPOOL_LICENSE_PUBLIC_KEY in Packaging/updates.env,
                                          found from the current folder upward.
      help                                Show this text.

    Exit codes: 0 done, 1 failed (a file, a key, a signature), 2 wrong usage.

    A new key pair makes every sold key invalid. Make the pair once. See docs/RELEASING.md, "License keys".

    """

    public static let keygenHelp = """
    Usage: spool-license keygen [--out <path>]

    Makes a new Ed25519 key pair. Writes the private key, the 32-byte seed in base64, to <path> with mode 600
    and makes the folder when it is missing. The default path is ~/.config/spool/license-signing.key.

    It refuses when the file exists: a new pair makes every sold key invalid.
    It prints the public key, the line for Packaging/updates.env and where the private key is. It does not print
    the private key.

    """

    public static let envLineHelp = """
    Usage: spool-license env-line [--key <path>]

    Prints SPOOL_LICENSE_SIGNING_KEY=<seed in base64> for ~/1yc/.env on the server of 1yc.dev.
    This is the only command that prints the private key. Do not paste the output in a chat, a ticket or a repository.
    The default path is ~/.config/spool/license-signing.key.

    """

    public static let issueHelp = """
    Usage: spool-license issue --email <email> [--id <id>] [--key <path>]

    Prints one license key on standard output. The id is comp-<YYYY-MM-DD>-<4 hex> by default (a key you give
    away). The issue date is today, UTC. The tool checks that the key it made is valid for the public key of the
    private key. The default path of the private key is ~/.config/spool/license-signing.key.

    """

    public static let verifyHelp = """
    Usage: spool-license verify <key> [--public-key <base64>]

    Prints the id, the email and the issue date of a valid key. For a key that is not valid it prints
    "\(LicenseKey.invalidMessage)" and exits with 1.
    The default public key is SPOOL_LICENSE_PUBLIC_KEY in Packaging/updates.env, found from the current folder
    upward. Outside the repository, --public-key is required.

    """

    // MARK: Run

    public static func run(_ arguments: [String], environment env: Environment = Environment()) -> Output {
        guard let command = arguments.first else {
            return Output(stderr: "spool-license: no command.\n\n" + help, code: usageError)
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            return Output(stdout: help, code: ok)
        case "keygen":
            return withOptions(rest, flags: ["--out"], positional: 0, help: keygenHelp) { options, _ in
                keygen(path: options["--out"].map(expand) ?? defaultKeyURL(home: env.home), env: env)
            }
        case "env-line":
            return withOptions(rest, flags: ["--key"], positional: 0, help: envLineHelp) { options, _ in
                envLine(path: options["--key"].map(expand) ?? defaultKeyURL(home: env.home))
            }
        case "issue":
            return withOptions(rest, flags: ["--email", "--id", "--key"], positional: 0, help: issueHelp) { options, _ in
                guard let email = options["--email"] else { return usage("issue needs --email <email>.", issueHelp) }
                return issue(email: email, id: options["--id"],
                             path: options["--key"].map(expand) ?? defaultKeyURL(home: env.home), env: env)
            }
        case "verify":
            return withOptions(rest, flags: ["--public-key"], positional: 1, help: verifyHelp) { options, positional in
                verify(key: positional[0], publicKey: options["--public-key"], env: env)
            }
        default:
            return Output(stderr: "spool-license: unknown command '\(command)'.\n\n" + help, code: usageError)
        }
    }

    // MARK: Argument parsing

    /// Splits `arguments` into the options in `flags` (each takes one value, as `--out value` or
    /// `--out=value`) and `positional` words. `--help` anywhere shows `help`. Anything else is a usage error.
    static func withOptions(_ arguments: [String], flags: Set<String>, positional count: Int, help: String,
                            _ body: ([String: String], [String]) -> Output) -> Output {
        var options: [String: String] = [:]
        var words: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--help" || argument == "-h" { return Output(stdout: help, code: ok) }
            if argument.hasPrefix("--") {
                let name: String, value: String
                if let equals = argument.firstIndex(of: "=") {
                    name = String(argument[..<equals])
                    value = String(argument[argument.index(after: equals)...])
                } else {
                    name = argument
                    guard flags.contains(name) else { return usage("unknown option '\(argument)'.", help) }
                    guard index < arguments.count else { return usage("\(name) needs a value.", help) }
                    value = arguments[index]
                    index += 1
                }
                guard flags.contains(name) else { return usage("unknown option '\(name)'.", help) }
                guard options[name] == nil else { return usage("\(name) is given twice.", help) }
                guard !value.isEmpty else { return usage("\(name) needs a value.", help) }
                options[name] = value
            } else {
                words.append(argument)
            }
        }
        guard words.count == count else {
            return usage(count == 0 ? "unexpected argument '\(words[0])'." : "this command needs \(count) argument.", help)
        }
        return body(options, words)
    }

    static func usage(_ message: String, _ help: String) -> Output {
        Output(stderr: "spool-license: \(message)\n\n" + help, code: usageError)
    }

    static func fail(_ message: String) -> Output {
        Output(stderr: "spool-license: \(message)\n", code: failed)
    }

    /// `~/x` to the home folder is the job of the shell; this handles only the path as given.
    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    // MARK: keygen

    static func keygen(path: URL, env: Environment) -> Output {
        let seed = env.randomBytes(32)
        guard seed.count == 32, let publicKey = try? LicenseKey.publicKey(seed: seed) else {
            return fail("cannot make a key from the random bytes.")
        }
        do {
            try writeNewPrivateFile(Data((seed.base64EncodedString() + "\n").utf8), to: path)
        } catch let error as KeyFileError {
            return fail(error.text(path: path))
        } catch {
            return fail("cannot write \(path.path): \(error.localizedDescription)")
        }
        let line = "\(publicKeyVariable)=\(publicKey.base64EncodedString())"
        return Output(stdout: """
        Made a new license key pair.

        Private key: \(path.path)
        It holds the secret seed (mode 600). Back it up now, for example in your password manager.
        Never put it in a repository. A lost key cannot be made again.

        Public key: \(publicKey.base64EncodedString())

        Put this line in Packaging/updates.env, then make a release:
        \(line)

        Next: `spool-license env-line` prints the line for ~/1yc/.env on the server of 1yc.dev.

        """, code: ok)
    }

    enum KeyFileError: Error {
        case exists
        func text(path: URL) -> String {
            "\(path.path) exists. A new key pair makes every sold license key invalid, so keygen never replaces a key. "
                + "To start again on purpose, move the file away yourself."
        }
    }

    /// Makes the folder (mode 700) and a new file with mode 600. `O_EXCL` refuses an existing file and a symlink
    /// in one step, so two runs cannot both write.
    static func writeNewPrivateFile(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if descriptor < 0 {
            if errno == EEXIST { throw KeyFileError.exists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    // MARK: Reading the private key

    /// The 32-byte seed in the file, or an error text.
    static func readSeed(_ path: URL) -> Result<Data, Output> {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .failure(fail("no private key at \(path.path). Run `spool-license keygen` once, or give the file with --key."))
        }
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return .failure(fail("cannot read \(path.path)."))
        }
        guard let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), seed.count == 32,
              (try? LicenseKey.publicKey(seed: seed)) != nil else {
            return .failure(fail("\(path.path) does not hold a private key (a 32-byte seed in base64)."))
        }
        return .success(seed)
    }

    /// A warning text when other users can read the file.
    static func looseModeWarning(_ path: URL) -> String? {
        guard let mode = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.posixPermissions] as? Int,
              mode & 0o077 != 0 else { return nil }
        return String(format: "warning: %@ has mode %o. Other users can read it. Run: chmod 600 %@\n", path.path, mode & 0o777, path.path)
    }

    // MARK: env-line

    static func envLine(path: URL) -> Output {
        switch readSeed(path) {
        case .failure(let output): return output
        case .success(let seed):
            return Output(stdout: "\(privateKeyVariable)=\(seed.base64EncodedString())\n",
                          stderr: looseModeWarning(path) ?? "", code: ok)
        }
    }

    // MARK: issue

    static func issue(email: String, id: String?, path: URL, env: Environment) -> Output {
        let badCharacters = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard email.rangeOfCharacter(from: badCharacters) == nil, email.contains("@"),
              !email.hasPrefix("@"), !email.hasSuffix("@") else {
            return usage("--email must be an email address without spaces.", issueHelp)
        }
        if let id, id.rangeOfCharacter(from: badCharacters) != nil {
            return usage("--id must not have spaces.", issueHelp)
        }
        let seed: Data
        switch readSeed(path) {
        case .failure(let output): return output
        case .success(let data): seed = data
        }
        let day = utcDate(env.now())
        let orderID = id ?? "comp-\(day)-" + env.randomBytes(2).map { String(format: "%02x", $0) }.joined()
        guard let key = try? LicenseKey.issue(id: orderID, email: email, issued: day, seed: seed),
              let publicKey = try? LicenseKey.publicKey(seed: seed),
              let license = LicenseKey.verify(key, publicKey: publicKey),
              license.id == orderID, license.email == email, license.issued == day else {
            return fail("the key that was made does not verify with the public key of \(path.path). Nothing was printed.")
        }
        return Output(stdout: key + "\n",
                      stderr: (looseModeWarning(path) ?? "") + "Issued \(orderID) for \(email), \(day).\n", code: ok)
    }

    /// `YYYY-MM-DD` of `date` in UTC.
    public static func utcDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    // MARK: verify

    static func verify(key: String, publicKey: String?, env: Environment) -> Output {
        let base64: String
        if let publicKey {
            base64 = publicKey
        } else {
            guard let file = updatesEnvFile(from: env.currentDirectory) else {
                return usage("no Packaging/updates.env found here or above. Give the key with --public-key <base64>.", verifyHelp)
            }
            guard let value = updatesValue(publicKeyVariable, in: file), !value.isEmpty else {
                return usage("\(publicKeyVariable) in \(file.path) is empty. Give the key with --public-key <base64>.", verifyHelp)
            }
            base64 = value
        }
        guard let keyData = LicenseKey.publicKey(base64: base64) else {
            return usage("the public key is not a 32-byte Ed25519 key in base64.", verifyHelp)
        }
        guard let license = LicenseKey.verify(key, publicKey: keyData) else {
            return Output(stderr: LicenseKey.invalidMessage + "\n", code: failed)
        }
        return Output(stdout: "id: \(license.id)\nemail: \(license.email)\nissued: \(license.issued)\n", code: ok)
    }

    /// Packaging/updates.env in `directory` or the nearest folder above it.
    static func updatesEnvFile(from directory: URL) -> URL? {
        var folder = directory.standardizedFileURL
        while true {
            let file = folder.appendingPathComponent("Packaging/updates.env")
            if FileManager.default.fileExists(atPath: file.path) { return file }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return nil }
            folder = parent
        }
    }

    /// The value of `name` in a KEY=VALUE file, like `spool_updates_value` in scripts/release-lib.sh: comment lines
    /// are skipped, trailing white space and one pair of quotes are removed.
    public static func updatesValue(_ name: String, in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedStart = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmedStart.hasPrefix("#") || !line.hasPrefix(name + "=") { continue }
            var value = String(line.dropFirst(name.count + 1))
            while let last = value.last, last == " " || last == "\t" || last == "\r" { value.removeLast() }
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }
}
