import Darwin
import Foundation
import SpoolCore

/// The Unix socket server that answers the `spool` CLI.
///
/// Wire format: one JSON `IPCRequest` per line in, one JSON `IPCResponse` per line out (see `IPCWire`).
/// All socket work runs on a private serial queue. Only `handler` runs on the main actor,
/// so a slow client never blocks the main thread, and a busy main thread never blocks the socket.
public final class IPCServer: @unchecked Sendable {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// Another process listens on the socket.
        case alreadyRunning
        case pathTooLong(String)
        /// A file that is not a socket is at the socket path. Spool does not remove it.
        case notASocket(String)
        case system(String)

        public var description: String {
            switch self {
            case .alreadyRunning: return "Another Spool already listens on the socket."
            case .pathTooLong(let p): return "The socket path is too long (more than \(IPCSocket.maxPathLength) bytes): \(p)"
            case .notASocket(let p): return "A file that is not a socket is at \(p). Remove it and start again."
            case .system(let m): return m
            }
        }
    }

    public let socketURL: URL
    public let maxConnections: Int
    public let idleTimeout: TimeInterval
    /// Requests that one connection can queue while the handler works.
    public let maxQueuedRequests = 64

    private let handler: @MainActor @Sendable (IPCRequest) -> IPCResponse
    private let queue = DispatchQueue(label: "app.spool.ipc")
    private let queueKey = DispatchSpecificKey<Bool>()

    // Only used on `queue`.
    private var acceptSource: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private var connections: [Int: Connection] = [:]
    private var nextConnectionID = 0
    private var socketIdentity: (dev: dev_t, ino: ino_t)?

    public init(socketURL: URL, maxConnections: Int = 16, idleTimeout: TimeInterval = 10,
                handler: @escaping @MainActor @Sendable (IPCRequest) -> IPCResponse) {
        self.socketURL = socketURL
        self.maxConnections = max(maxConnections, 1)
        self.idleTimeout = idleTimeout
        self.handler = handler
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { stop() }

    public var isRunning: Bool { onQueue { acceptSource != nil } }

    /// Open client connections.
    public var connectionCount: Int { onQueue { connections.count } }

    /// Binds the socket and starts to accept clients. Does nothing if the server already runs.
    public func start() throws {
        try onQueue {
            guard acceptSource == nil else { return }
            let path = socketURL.path
            guard let addr = IPCSocket.address(for: path) else { throw Error.pathTooLong(path) }
            do {
                try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw Error.system("Cannot create the folder for the socket: \(error.localizedDescription)")
            }
            try removeStaleSocket(at: path)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Error.system("socket: \(IPCSocket.errorText(errno))") }
            IPCSocket.setCloseOnExec(fd)
            IPCSocket.setNonBlocking(fd)
            if IPCSocket.withSockaddr(addr, { bind(fd, $0, $1) }) != 0 {
                let code = errno
                Darwin.close(fd)
                throw code == EADDRINUSE ? Error.alreadyRunning : Error.system("bind \(path): \(IPCSocket.errorText(code))")
            }
            // Only this user can connect. getpeereid below checks it again for each client.
            _ = chmod(path, 0o600)
            guard listen(fd, 16) == 0 else {
                let code = errno
                Darwin.close(fd)
                _ = unlink(path)
                throw Error.system("listen: \(IPCSocket.errorText(code))")
            }
            var st = stat()
            socketIdentity = lstat(path, &st) == 0 ? (st.st_dev, st.st_ino) : nil

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll() }
            source.setCancelHandler { Darwin.close(fd) }
            listenFD = fd
            acceptSource = source
            source.resume()
        }
    }

    /// Closes all connections, stops listening and removes the socket file. Safe to call more than once.
    public func stop() {
        onQueue {
            guard let source = acceptSource else { return }
            acceptSource = nil
            listenFD = -1
            source.cancel()
            let open = Array(connections.values)
            connections.removeAll()
            for c in open { c.close() }
            removeOwnSocketFile()
        }
    }

    // MARK: - Queue helpers

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
        return try queue.sync(execute: body)
    }

    /// Removes the socket file only if it is still the one this server made.
    private func removeOwnSocketFile() {
        let path = socketURL.path
        var st = stat()
        if let id = socketIdentity, lstat(path, &st) == 0, st.st_dev == id.dev, st.st_ino == id.ino {
            _ = unlink(path)
        }
        socketIdentity = nil
    }

    /// A socket file without a listener is left behind by a crash. Remove it, but never take a live socket.
    private func removeStaleSocket(at path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == ENOENT { return }
            throw Error.system("lstat \(path): \(IPCSocket.errorText(errno))")
        }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else { throw Error.notASocket(path) }
        // A successful connect means a process listens. That process does not need to answer,
        // so this works even when the other server waits for its own main thread.
        do {
            let probe = try IPCConnection(socketPath: path, timeout: 0.5)
            probe.close()
            throw Error.alreadyRunning
        } catch IPCClient.Error.notRunning {
            guard unlink(path) == 0 || errno == ENOENT else {
                throw Error.system("Cannot remove the old socket \(path): \(IPCSocket.errorText(errno))")
            }
        } catch let error as Error {
            throw error
        } catch {
            throw Error.alreadyRunning
        }
    }

    // MARK: - Accept

    private func acceptAll() {
        guard listenFD >= 0 else { return }
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            IPCSocket.setCloseOnExec(fd)
            IPCSocket.setNonBlocking(fd)
            IPCSocket.setNoSigPipe(fd)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                Darwin.close(fd)
                continue
            }
            guard connections.count < maxConnections else {
                if let data = try? IPCWire.encode(IPCResponse(ok: false, error: "Too many connections. Try again.")) {
                    _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                }
                Darwin.close(fd)
                continue
            }
            let id = nextConnectionID
            nextConnectionID += 1
            let connection = Connection(fd: fd, queue: queue, idleTimeout: idleTimeout, maxQueuedRequests: maxQueuedRequests,
                                        dispatch: { [weak self] request in self?.dispatch(request, connection: id) },
                                        onClose: { [weak self] in self?.connections[id] = nil })
            connections[id] = connection
            connection.start()
        }
    }

    /// Runs the handler on the main actor and sends the response back to the connection on the server queue.
    private func dispatch(_ request: IPCRequest, connection id: Int) {
        let handler = self.handler
        DispatchQueue.main.async { [weak self] in
            let response = MainActor.assumeIsolated { handler(request) }
            self?.queue.async { [weak self] in self?.connections[id]?.finish(response) }
        }
    }
}

// MARK: - Connection

/// One client. Every method runs on the server queue.
private final class Connection {
    private let fd: Int32
    private let queue: DispatchQueue
    private let idleTimeout: TimeInterval
    private let maxQueuedRequests: Int
    /// Sends a request to the handler. The server calls `finish` with the response.
    private let dispatch: (IPCRequest) -> Void
    private let onClose: () -> Void

    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
    private let timer: DispatchSourceTimer
    private var lines = LineBuffer()
    private var readBuffer = [UInt8](repeating: 0, count: 65_536)
    private var queued: [Data] = []
    private var output = Data()
    private var inFlight = false
    private var readDone = false
    private var closeAfterFlush = false
    private var writeResumed = false
    private var closed = false

    init(fd: Int32, queue: DispatchQueue, idleTimeout: TimeInterval, maxQueuedRequests: Int,
         dispatch: @escaping (IPCRequest) -> Void, onClose: @escaping () -> Void) {
        self.fd = fd
        self.queue = queue
        self.idleTimeout = idleTimeout
        self.maxQueuedRequests = maxQueuedRequests
        self.dispatch = dispatch
        self.onClose = onClose
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        timer = DispatchSource.makeTimerSource(queue: queue)
    }

    func start() {
        // The descriptor is closed after both I/O sources are cancelled.
        let fd = self.fd
        var openSources = 2
        let sourceDone = {
            openSources -= 1
            if openSources == 0 { Darwin.close(fd) }
        }
        readSource.setCancelHandler(handler: sourceDone)
        writeSource.setCancelHandler(handler: sourceDone)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        writeSource.setEventHandler { [weak self] in self?.flush() }
        timer.setEventHandler { [weak self] in self?.idleTimerFired() }
        timer.schedule(deadline: .now() + idleTimeout)
        timer.resume()
        readSource.resume()
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer.cancel()
        if !readDone {
            readDone = true
            readSource.cancel()
        }
        // A suspended source must be resumed before cancel, or its cancel handler never runs.
        if !writeResumed { writeSource.resume() }
        writeSource.cancel()
        onClose()
    }

    private func touch() {
        timer.schedule(deadline: .now() + idleTimeout)
    }

    private func idleTimerFired() {
        if inFlight { touch() } else { close() }
    }

    private func stopReading() {
        guard !readDone else { return }
        readDone = true
        readSource.cancel()
    }

    private func readAvailable() {
        guard !closed, !readDone else { return }
        let n = readBuffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            close()
            return
        }
        if n == 0 {
            // The client sent all its requests. Answer them, then close.
            stopReading()
            finishIfDone()
            return
        }
        touch()
        let received: [Data]
        do {
            received = try lines.append(Data(readBuffer[0..<n]))
        } catch {
            stopReading()
            closeAfterFlush = true
            send(IPCResponse(ok: false, error: "The request is longer than \(IPCWire.maxLineLength) bytes."))
            return
        }
        for line in received where !isBlank(line) {
            guard queued.count < maxQueuedRequests else {
                stopReading()
                closeAfterFlush = true
                queued.removeAll()
                send(IPCResponse(ok: false, error: "Too many requests at the same time."))
                return
            }
            queued.append(line)
        }
        pump()
    }

    private func isBlank(_ line: Data) -> Bool {
        line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
    }

    /// Sends the queued requests to the handler, one at a time, so the answers keep their order.
    private func pump() {
        while !inFlight, !closed, !queued.isEmpty {
            let line = queued.removeFirst()
            let request: IPCRequest
            do {
                request = try IPCWire.decodeRequest(line)
            } catch {
                send(IPCResponse(ok: false, error: "Bad request: \(IPCWire.describe(error))"))
                continue
            }
            // `spool license <key>` sends only a key: the app answers it before the engine.
            guard request.command != nil || request.query != nil || request.licenseKey != nil else {
                send(IPCResponse(ok: false, error: "Bad request: it has no command and no query."))
                continue
            }
            inFlight = true
            dispatch(request)
        }
        finishIfDone()
    }

    func finish(_ response: IPCResponse) {
        inFlight = false
        guard !closed else { return }
        send(response)
        pump()
    }

    private func send(_ response: IPCResponse) {
        guard !closed else { return }
        let data: Data
        do {
            data = try IPCWire.encode(response)
        } catch {
            // Cannot happen with the current types; answer with a plain error so the client is not left waiting.
            data = (try? IPCWire.encode(IPCResponse(ok: false, error: "Cannot encode the response."))) ?? Data()
        }
        output.append(data)
        flush()
    }

    private func flush() {
        guard !closed else { return }
        while !output.isEmpty {
            let n = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                output = output.count == n ? Data() : Data(output.dropFirst(n))
                touch()
                continue
            }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && errno == EAGAIN {
                if !writeResumed {
                    writeResumed = true
                    writeSource.resume()
                }
                return
            }
            close()
            return
        }
        if writeResumed {
            writeResumed = false
            writeSource.suspend()
        }
        finishIfDone()
    }

    private func finishIfDone() {
        guard !closed, output.isEmpty else { return }
        if closeAfterFlush || (readDone && !inFlight && queued.isEmpty) { close() }
    }
}
