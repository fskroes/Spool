import Foundation
import Testing
@testable import SpoolCore

/// docs/SHORTCUTS.md shows the default shortcuts. The table between the markers is generated from
/// `DefaultBindings`, so the doc cannot drift from the code. On a mismatch the expected table is written
/// to $TMPDIR/spool-shortcuts-table.md: paste it between the markers.
@Suite struct ShortcutsDocTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let begin = "<!-- shortcuts:begin (generated from DefaultBindings, checked by ShortcutsDocTests) -->"
    static let end = "<!-- shortcuts:end -->"

    static func table() -> String {
        let bindings = DefaultBindings.make()
        var lines = ["| Action | Default shortcut | CLI |", "|---|---|---|"]
        for command in Command.bindable {
            let keys = (bindings[command] ?? []).map { "`\($0.usLabel)`" }.joined(separator: " or ")
            lines.append("| \(command.title) | \(keys.isEmpty ? "(none)" : keys) | `spool \(command.name)` |")
        }
        return lines.joined(separator: "\n")
    }

    @Test func docTableMatchesDefaults() throws {
        let doc = try String(contentsOf: Self.root.appendingPathComponent("docs/SHORTCUTS.md"), encoding: .utf8)
        let start = try #require(doc.range(of: Self.begin))
        let stop = try #require(doc.range(of: Self.end))
        let current = doc[start.upperBound..<stop.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = Self.table()
        if current != expected {
            try? expected.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("spool-shortcuts-table.md"),
                                atomically: true, encoding: .utf8)
        }
        #expect(current == expected, "docs/SHORTCUTS.md is out of date; see $TMPDIR/spool-shortcuts-table.md")
    }
}
