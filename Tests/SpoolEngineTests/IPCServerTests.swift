import Darwin
import Foundation
import Testing
@testable import SpoolCore
@testable import SpoolEngine

/// A short, unique socket path in the user's temp folder (sun_path allows 103 bytes).
private func tempSocketPath() -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("spool-test-\(UUID().uuidString.prefix(8)).sock").path
    precondition(path.utf8.count <= IPCSocket.maxPathLength, "temp path too long: \(path)")
    return path
}

/// Runs blocking socket code off the main actor, so the server can call its main-actor handler meanwhile.
private func background<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached { try body() }.value
}

@MainActor
private final class Recorder {
    var requests: [IPCRequest] = []
}

private let sampleState = EngineState(running: true, accessibilityTrusted: true, focusedWindow: WindowInfo(id: 5, bundleID: "com.apple.Safari", title: "Hi"),
                                      displays: [], floating: [])

@MainActor
private func makeServer(path: String, maxConnections: Int = 16, idleTimeout: TimeInterval = 10, recorder: Recorder? = nil) -> IPCServer {
    let recorder = recorder ?? Recorder()
    return IPCServer(socketURL: URL(fileURLWithPath: path), maxConnections: maxConnections, idleTimeout: idleTimeout) { request in
        MainActor.assertIsolated()
        recorder.requests.append(request)
        switch (request.query, request.command) {
        case (.ping?, _): return IPCResponse(ok: true)
        case (.state?, _): return IPCResponse(ok: true, state: sampleState)
        case (.stats?, _): return IPCResponse(ok: true, stats: EngineStats(framesWritten: 3))
        case (nil, .stop?): return IPCResponse(ok: false, error: "Already stopped.")
        default: return IPCResponse(ok: true)
        }
    }
}

/// Binds a socket and closes it without removing the file, like a crashed app.
private func makeStaleSocket(at path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    let addr = IPCSocket.address(for: path)!
    precondition(IPCSocket.withSockaddr(addr) { bind(fd, $0, $1) } == 0)
    close(fd)
}

@MainActor
@Suite struct IPCServerTests {
    @Test func answersQueriesAndCommands() async throws {
        let path = tempSocketPath()
        let recorder = Recorder()
        let server = makeServer(path: path, recorder: recorder)
        try server.start()
        defer { server.stop() }
        #expect(server.isRunning)

        let responses = try await background {
            let client = IPCClient(socketPath: path)
            return [try client.send(IPCRequest(query: .ping)), try client.send(IPCRequest(query: .state)),
                    try client.send(IPCRequest(command: .focusIndex(3))), try client.send(IPCRequest(command: .stop))]
        }
        #expect(responses == [IPCResponse(ok: true), IPCResponse(ok: true, state: sampleState), IPCResponse(ok: true),
                              IPCResponse(ok: false, error: "Already stopped.")])
        #expect(recorder.requests == [IPCRequest(query: .ping), IPCRequest(query: .state), IPCRequest(command: .focusIndex(3)),
                                      IPCRequest(command: .stop)])
    }

    @Test func socketIsPrivate() throws {
        let path = tempSocketPath()
        let server = makeServer(path: path)
        try server.start()
        defer { server.stop() }
        var st = stat()
        #expect(lstat(path, &st) == 0)
        #expect((st.st_mode & S_IFMT) == S_IFSOCK)
        #expect((st.st_mode & 0o777) == 0o600)
    }

    // `spool license <key>` sends a request with only a key. The server must pass it to the handler.
    // Found by a live check: the server answered "Bad request" and the key was never stored.
    @Test func aRequestWithOnlyALicenseKeyReachesTheHandler() async throws {
        let path = tempSocketPath()
        let recorder = Recorder()
        let server = makeServer(path: path, recorder: recorder)
        try server.start()
        defer { server.stop() }
        let response = try await background { try IPCClient(socketPath: path).send(IPCRequest(licenseKey: "SPOOL-a.b")) }
        #expect(response == IPCResponse(ok: true))
        #expect(recorder.requests == [IPCRequest(licenseKey: "SPOOL-a.b")])
    }

    @Test func badRequestsGetAnErrorAndTheConnectionStaysOpen() async throws {
        let path = tempSocketPath()
        let server = makeServer(path: path)
        try server.start()
        defer { server.stop() }

        let lines = try await background { () -> [String] in
            let c = try IPCConnection(socketPath: path)
            try c.writeAll(Data("this is not json\n\n{\"command\":\"fly\"}\n{}\n".utf8))
            var lines = [try c.readLine(), try c.readLine(), try c.readLine()].map { String(decoding: $0, as: UTF8.self) }
            lines.append(try c.send(IPCRequest(query: .ping)).ok ? "ping ok" : "ping failed")
            return lines
        }
        #expect(lines == [
            #"{"error":"Bad request: The request is not valid JSON.","ok":false}"#,
            #"{"error":"Bad request: Unknown command fly","ok":false}"#,
            #"{"error":"Bad request: it has no command and no query.","ok":false}"#,
            "ping ok",
        ])
    }

    @Test func pipelinedRequestsAnswerInOrder() async throws {
        let path = tempSocketPath()
        let server = makeServer(path: path)
        try server.start()
        defer { server.stop() }

        let (responses, closedAfter) = try await background { () -> ([IPCResponse], Bool) in
            let c = try IPCConnection(socketPath: path)
            let batch = try IPCWire.encode(IPCRequest(query: .stats)) + IPCWire.encode(IPCRequest(query: .ping))
                + IPCWire.encode(IPCRequest(command: .stop))
            try c.writeAll(batch)
            // The client says it is done; the server still answers everything, then closes.
            c.shutdownWrite()
            let r = try (0..<3).map { _ in try IPCWire.decodeResponse(c.readLine()) }
            let closed = (try? c.readLine()) == nil
            return (r, closed)
        }
        #expect(closedAfter)
        #expect(responses == [IPCResponse(ok: true, stats: EngineStats(framesWritten: 3)), IPCResponse(ok: true),
                              IPCResponse(ok: false, error: "Already stopped.")])
    }

    @Test func twoClientsAtOnce() async throws {
        let path = tempSocketPath()
        let server = makeServer(path: path)
        try server.start()
        defer { server.stop() }

        async let a = background { () -> [Bool] in
            let c = try IPCConnection(socketPath: path)
            return try (0..<20).map { _ in try c.send(IPCRequest(query: .ping)).ok }
        }
        async let b = background { () -> [Bool] in
            let c = try IPCConnection(socketPath: path)
            return try (0..<20).map { _ in try c.send(IPCRequest(command: .focusLeft)).ok }
        }
        let (ra, rb) = try await (a, b)
        #expect(ra == Array(repeating: true, count: 20))
        #expect(rb == Array(repeating: true, count: 20))
    }

    @Test func connectionLimit() async throws {
        let path = tempSocketPath()
        let server = makeServer(path: path, maxConnections: 2)
        try server.start()
        defer { server.stop() }

        let third = try await background { () -> String in
            let c1 = try IPCConnection(socketPath: path)
            let c2 = try IPCConnection(socketPath: path)
            _ = try c1.send(IPCRequest(query: .ping))
            _ = try c2.send(IPCRequest(query: .ping))
            let c3 = try IPCConnection(socketPath: path)
            let line = String(decoding: try c3.readLine(), as: UTF8.self)
            withExtendedLifetime((c1, c2)) {}
            return line
        }
        #expect(third == #"{"error":"Too many connections. Try again.","ok":false}"#)
    }

    @Test func idleConnectionsAreClosed() async throws {
        let path = tempSocketPath()
        let server = makeServer(path: path, idleTimeout: 0.2)
        try server.start()
        defer { server.stop() }

        let error = try await background { () -> IPCClient.Error? in
            let c = try IPCConnection(socketPath: path, timeout: 2)
            _ = try c.send(IPCRequest(query: .ping))
            do { _ = try c.readLine(); return nil } catch let e as IPCClient.Error { return e }
        }
        #expect(error == .protocolError("Spool closed the connection before it answered."))
        #expect(server.connectionCount == 0)
    }

    @Test func oversizeRequestIsRejected() async throws {
        let path = tempSocketPath()
        let server = makeServer(path: path)
        try server.start()
        defer { server.stop() }

        let response = try await background { () -> IPCResponse in
            let c = try IPCConnection(socketPath: path)
            try? c.writeAll(Data(repeating: 0x20, count: IPCWire.maxLineLength + 10))
            return try IPCWire.decodeResponse(c.readLine())
        }
        #expect(response == IPCResponse(ok: false, error: "The request is longer than 1048576 bytes."))
    }

    @Test func staleSocketFileIsReplaced() async throws {
        let path = tempSocketPath()
        makeStaleSocket(at: path)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(throws: IPCClient.Error.notRunning) { try IPCClient(socketPath: path).send(IPCRequest(query: .ping)) }

        let server = makeServer(path: path)
        try server.start()
        defer { server.stop() }
        let ok = try await background { try IPCClient(socketPath: path).send(IPCRequest(query: .ping)).ok }
        #expect(ok)
    }

    @Test func secondServerDoesNotStealALiveSocket() async throws {
        let path = tempSocketPath()
        let first = makeServer(path: path)
        try first.start()
        defer { first.stop() }

        let second = makeServer(path: path)
        #expect(throws: IPCServer.Error.alreadyRunning) { try second.start() }
        second.stop()
        #expect(FileManager.default.fileExists(atPath: path))
        let ok = try await background { try IPCClient(socketPath: path).send(IPCRequest(query: .ping)).ok }
        #expect(ok)
    }

    @Test func refusesToRemoveAFileThatIsNotASocket() throws {
        let path = tempSocketPath()
        FileManager.default.createFile(atPath: path, contents: Data("keep".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(throws: IPCServer.Error.notASocket(path)) { try makeServer(path: path).start() }
        #expect(FileManager.default.contents(atPath: path) == Data("keep".utf8))
    }

    @Test func stopRemovesTheSocketAndCanRestart() async throws {
        let path = tempSocketPath()
        let server = makeServer(path: path)
        try server.start()
        try server.start()
        server.stop()
        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: path))
        server.stop()
        let error = try await background { () -> IPCClient.Error? in
            do { _ = try IPCClient(socketPath: path).send(IPCRequest(query: .ping)); return nil } catch let e as IPCClient.Error { return e }
        }
        #expect(error == .notRunning)

        try server.start()
        defer { server.stop() }
        let ok = try await background { try IPCClient(socketPath: path).send(IPCRequest(query: .ping)).ok }
        #expect(ok)
    }

    @Test func stopClosesOpenConnections() async throws {
        let path = tempSocketPath()
        let server = makeServer(path: path)
        try server.start()
        let connection = try await background { () -> Bool in
            let c = try IPCConnection(socketPath: path)
            return try c.send(IPCRequest(query: .ping)).ok
        }
        #expect(connection)
        let held = try IPCConnection(socketPath: path)
        server.stop()
        #expect(throws: IPCClient.Error.self) { try held.readLine() }
    }

    @Test func pathTooLongIsAnError() {
        let path = "/" + String(repeating: "x", count: 120)
        #expect(throws: IPCServer.Error.pathTooLong(path)) { try makeServer(path: path).start() }
    }

    @Test func cliRunAgainstARealServer() async throws {
        let path = tempSocketPath()
        let server = makeServer(path: path)
        try server.start()
        defer { server.stop() }
        let outputs = try await background { () -> [SpoolCLI.Output] in
            let client = IPCClient(socketPath: path)
            return [["ping"], ["state"], ["stop"]].map { SpoolCLI.run(SpoolCLI.parse($0), versionLine: "", send: client.send) }
        }
        #expect(outputs[0] == .init(stdout: "Spool is running.\n"))
        #expect(outputs[1].stdout.hasPrefix("Engine: running. Accessibility: granted.\nFocused: Safari \"Hi\" (window 5)\n"))
        #expect(outputs[2] == .init(stderr: "Already stopped.\n", code: .failed))
    }
}

@Suite struct LifecycleTimeoutTests {
    @Test func theCLIWaitsLongerThanTheEngineReleasesWindows() {
        // stop answers after releaseAll: up to releaseWait for the writes, then settleWait, then a session save.
        // restart adds a scan. Keep at least 3 s for those, or `spool stop` reports a timeout although it worked.
        #expect(IPCClient.lifecycleTimeout >= Engine.releaseWait + Engine.settleWait + 3)
    }
}
