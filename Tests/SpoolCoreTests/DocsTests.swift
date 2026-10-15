import Foundation
import Testing

/// Command blocks in README.md, AGENTS.md, docs/*.md and .claude/skills/*/SKILL.md must work when you paste them into zsh, the default shell of macOS.
/// At an interactive prompt zsh does not accept `#` comments (the `interactivecomments` option is off), so a comment
/// becomes arguments of the command. The rule:
///
/// - Blocks tagged `sh`, `bash`, `zsh` or `shell`: every line is a command and is checked.
/// - Blocks tagged `console`, and blocks with no tag: only lines that start with `$ ` are commands. The text after
///   the prompt is checked. The other lines are output or diagrams and are not checked.
/// - Blocks with another tag (for example `json`) are not checked.
///
/// A `#` is a comment when it is outside quotes and is the first character or comes after a space or a tab, as in
/// the shell. Single quotes, double quotes and backslashes are followed, also across the lines of one block.
/// Thus `trap '... # ...' EXIT`, `"#"`, `\#` and `${#x}` are not comments.
@Suite struct DocsTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let shellTags: Set<String> = ["sh", "bash", "zsh", "shell"]

    /// Quote state that carries from one line of a block to the next.
    enum Quote { case none, single, double }

    /// Status of `line` that starts in quote state `quote`: whether it has a comment, and the state at its end.
    static func scan(_ line: Substring, from quote: Quote) -> (comment: Bool, quote: Quote) {
        var q = quote
        var escaped = false
        var previous: Character? = nil
        for c in line {
            defer { previous = c }
            if escaped { escaped = false; continue }
            switch q {
            case .single:
                if c == "'" { q = .none }
            case .double:
                if c == "\\" { escaped = true } else if c == "\"" { q = .none }
            case .none:
                if c == "\\" { escaped = true }
                else if c == "'" { q = .single }
                else if c == "\"" { q = .double }
                else if c == "#", previous == nil || previous == " " || previous == "\t" { return (true, q) }
            }
        }
        return (false, q)
    }

    /// The lines with a `#` comment in the command blocks of `markdown`, as "line number: text".
    static func comments(in markdown: String) -> [String] {
        var found: [String] = []
        var tag: String? = nil
        var quote = Quote.none
        for (index, raw) in markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = raw.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("```") {
                tag = tag == nil ? String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased() : nil
                quote = .none
                continue
            }
            guard let current = tag else { continue }
            let command: Substring
            if shellTags.contains(current) {
                command = trimmed
            } else if current.isEmpty || current == "console" {
                guard trimmed.hasPrefix("$ ") else { continue }
                command = trimmed.dropFirst(2)
            } else {
                continue
            }
            let r = scan(command, from: quote)
            quote = r.quote
            if r.comment { found.append("\(index + 1): \(raw)") }
        }
        return found
    }

    /// README.md, AGENTS.md, docs/*.md and the skills in .claude/skills: agents paste from all of them.
    static func docs() throws -> [URL] {
        let fm = FileManager.default
        let folder = root.appendingPathComponent("docs")
        let names = try fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".md") }.sorted()
        let skills = root.appendingPathComponent(".claude/skills")
        let skillFiles = try fm.contentsOfDirectory(atPath: skills.path).sorted()
            .map { skills.appendingPathComponent($0).appendingPathComponent("SKILL.md") }
            .filter { fm.fileExists(atPath: $0.path) }
        return [root.appendingPathComponent("README.md"), root.appendingPathComponent("AGENTS.md")]
            + names.map { folder.appendingPathComponent($0) } + skillFiles
    }

    @Test func commandBlocksHaveNoComments() throws {
        let files = try Self.docs()
        #expect(files.count >= 3)
        #expect(files.contains { $0.path.hasSuffix(".claude/skills/verify-spool/SKILL.md") })
        for file in files {
            let found = Self.comments(in: try String(contentsOf: file, encoding: .utf8))
            #expect(found.isEmpty, "\(file.lastPathComponent): put the explanation after the block, not in it:\n\(found.joined(separator: "\n"))")
        }
    }

    @Test func theRuleFindsCommentsAndOnlyComments() {
        func block(_ tag: String, _ body: String) -> [String] { Self.comments(in: "text # not code\n```\(tag)\n\(body)\n```\n# Title\n") }
        #expect(block("sh", "make test   # run the tests") == ["3: make test   # run the tests"])
        #expect(block("bash", "# a comment line") == ["3: # a comment line"])
        #expect(block("zsh", "ls\n\tls\t# tab") == ["4: \tls\t# tab"])
        #expect(block("shell", "echo a \\\n  # after a continuation") == ["4:   # after a continuation"])
        #expect(block("console", "$ make app # build\nout # put") == ["3: $ make app # build"])
        #expect(block("", "$ make app # build\ndesignated => H\"x\" # output") == ["3: $ make app # build"])
        #expect(block("SH", "x # y").count == 1)

        #expect(block("sh", "echo '#' \"#\" \\# a#b ${#x} $#").isEmpty)
        #expect(block("sh", "trap 'cd /; rm -rf \"$D\" # inside single quotes' EXIT").isEmpty)
        #expect(block("sh", "echo 'line one\n# still quoted' done").isEmpty)
        #expect(block("sh", "echo \"a \\\" # still quoted\"").isEmpty)
        #expect(block("", "# a heading in a diagram\n  │ # box").isEmpty)
        #expect(block("json", "{ \"a\": 1 } # no shell").isEmpty)
        // A block ends at its fence: a quote that is not closed does not hide the next block.
        #expect(Self.comments(in: "```sh\necho 'open\n```\n```sh\nls # x\n```\n") == ["5: ls # x"])
    }
}
