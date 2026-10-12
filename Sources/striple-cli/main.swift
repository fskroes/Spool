import Foundation
import StripleCore

// Thin I/O shell around StripleCLI (in StripleCore), so the logic is covered by tests.

/// The app puts this tool at Striple.app/Contents/Helpers/striple, so the app Info.plist is one folder up.
func appInfo() -> [String: Any]? {
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    return NSDictionary(contentsOf: plist) as? [String: Any]
}

let invocation = StripleCLI.parse(Array(CommandLine.arguments.dropFirst()))
let client = IPCClient(socketPath: StripleCLI.socketPath(option: invocation.options.socketPath,
                                                         environment: ProcessInfo.processInfo.environment))
let output = StripleCLI.run(invocation, versionLine: StripleCLI.versionLine(info: appInfo()), send: client.send)
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.code.rawValue)
