import Foundation
import SpoolCore

// Thin I/O shell around SpoolCLI (in SpoolCore), so the logic is covered by tests.

/// The app puts this tool at Spool.app/Contents/Helpers/spool, so the app Info.plist is one folder up.
func appInfo() -> [String: Any]? {
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    return NSDictionary(contentsOf: plist) as? [String: Any]
}

let invocation = SpoolCLI.parse(Array(CommandLine.arguments.dropFirst()))
let client = IPCClient(socketPath: SpoolCLI.socketPath(option: invocation.options.socketPath,
                                                       environment: ProcessInfo.processInfo.environment))
let output = SpoolCLI.run(invocation, versionLine: SpoolCLI.versionLine(info: appInfo()), send: client.send)
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.code.rawValue)
