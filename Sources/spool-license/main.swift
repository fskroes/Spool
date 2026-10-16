import Foundation
import SpoolCore

// Thin I/O shell around LicenseTool (in SpoolCore), so the logic is covered by tests.

let output = LicenseTool.run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.code)
