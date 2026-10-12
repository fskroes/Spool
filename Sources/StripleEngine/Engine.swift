import Combine
import Foundation
import StripleCore

/// The public face of the window engine. The app owns one instance.
/// Everything runs on the main thread except AX frame writes, which run on per-app queues.
@MainActor
public final class Engine: ObservableObject {
    public enum Status: Equatable, Sendable {
        case stopped
        case running
        /// Accessibility permission is missing. The engine starts by itself once it is granted.
        case noPermission
    }

    @Published public private(set) var status: Status = .stopped
    public let configStore: ConfigStore

    /// While true, global shortcuts are not handled (the shortcut recorder sets this).
    public var hotkeysSuspended = false

    public init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    public func start() { status = Permissions.isTrusted ? .running : .noPermission }
    public func stop() { status = .stopped }
    public func restart() { stop(); start() }
    public func toggle() { status == .stopped ? start() : stop() }

    /// Runs a command from a shortcut, the CLI, a URL or the menu.
    public func perform(_ command: Command) {}

    /// Answers a CLI request.
    public func handle(_ request: IPCRequest) -> IPCResponse { IPCResponse(ok: false, error: "not implemented") }

    public func currentState() -> EngineState {
        EngineState(running: status == .running, accessibilityTrusted: Permissions.isTrusted, focusedWindow: nil, displays: [], floating: [])
    }

    public func currentStats() -> EngineStats { EngineStats() }
}
