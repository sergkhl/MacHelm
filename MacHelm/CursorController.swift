import Combine
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class CursorController: ObservableObject {
    static let shortcutLabel = CursorKeyBinding.label

    /// MacHelm owns an accepted hide request; this is not a native visibility
    /// measurement and does not describe cursors rendered inside a game.
    @Published private(set) var hidden = false
    @Published private(set) var message: String?
    @Published private(set) var shortcutAvailable = false

    private var visibility: CursorVisibility?
    private var keyBinding: CursorKeyBinding?
    private var operationMessage: String?
    private var shortcutMessage: String?
    private var stopped = false

    init() {
        do {
            visibility = CursorVisibility(backend: try WindowServerCursorBackend())
        } catch {
            operationMessage = error.localizedDescription
        }

        let binding = CursorKeyBinding { [weak self] in self?.toggle() }
        do {
            try binding.start()
            keyBinding = binding
            shortcutAvailable = true
        } catch {
            shortcutMessage = error.localizedDescription
        }
        publishMessage()
    }

    func toggle() {
        guard !stopped, let visibility else { return }
        do {
            try visibility.toggle()
            operationMessage = visibility.ownsHide ? "Cursor hide requested." : "Cursor restore requested."
        } catch {
            operationMessage = error.localizedDescription
        }
        hidden = visibility.ownsHide
        publishMessage()
    }

    func restore() {
        guard let visibility else { return }
        let hadHide = visibility.ownsHide
        do {
            try visibility.restore()
            if hadHide { operationMessage = "Cursor restore requested." }
        } catch {
            operationMessage = error.localizedDescription
        }
        hidden = visibility.ownsHide
        publishMessage()
    }

    /// Call from the normal termination path while the app still has its
    /// WindowServer connection. A failed restore remains retryable.
    func stop() {
        stopped = true
        keyBinding?.stop()
        keyBinding = nil
        shortcutAvailable = false
        guard let visibility else { return }
        do {
            try visibility.stop()
            operationMessage = nil
        } catch {
            operationMessage = error.localizedDescription
        }
        hidden = visibility.ownsHide
        publishMessage()
    }

    private func publishMessage() {
        let notes = [operationMessage, shortcutMessage].compactMap { $0 }
        message = notes.isEmpty ? nil : notes.joined(separator: "\n")
    }
}

/// Experimental private WindowServer API. The SDK exports these symbols, but
/// Apple provides no supported background-visibility or process-exit contract.
/// All calls use MacHelm's own connection; no other application's connection is
/// inspected or changed. There is deliberately no alternative backend.
private final class WindowServerCursorBackend: CursorVisibilityBackend {
    private typealias ConnectionID = UInt32
    private typealias MainConnection = @convention(c) () -> ConnectionID
    private typealias SetProperty = @convention(c) (ConnectionID, ConnectionID, CFString, CFTypeRef) -> Int32
    private typealias SetVisibility = @convention(c) (ConnectionID) -> Int32

    private let library: UnsafeMutableRawPointer
    private let mainConnection: MainConnection
    private let setProperty: SetProperty
    private let hideCursor: SetVisibility
    private let showCursor: SetVisibility
    private var connection: ConnectionID?

    init() throws {
        let path = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        guard let library = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            throw CursorBackendError.unavailable("CoreGraphics could not be loaded")
        }
        do {
            mainConnection = try Self.load("CGSMainConnectionID", from: library, as: MainConnection.self)
            setProperty = try Self.load("CGSSetConnectionProperty", from: library, as: SetProperty.self)
            hideCursor = try Self.load("CGSHideCursor", from: library, as: SetVisibility.self)
            showCursor = try Self.load("CGSShowCursor", from: library, as: SetVisibility.self)
            self.library = library
        } catch {
            dlclose(library)
            throw error
        }
    }

    deinit { dlclose(library) }

    func hide() throws {
        let connection = try preparedConnection()
        try Self.check(hideCursor(connection), operation: "hide the cursor")
    }

    func show() throws {
        guard let connection else {
            throw CursorBackendError.unavailable("MacHelm has no cursor connection to restore")
        }
        try Self.check(showCursor(connection), operation: "restore the cursor")
    }

    private func preparedConnection() throws -> ConnectionID {
        if let connection { return connection }
        let candidate = mainConnection()
        guard candidate != 0 else {
            throw CursorBackendError.unavailable("MacHelm has no WindowServer connection")
        }
        // Ask WindowServer to accept this connection's cursor requests while
        // MacHelm is not active. This changes only this process's connection;
        // it does not itself submit a cursor hide request.
        try Self.check(setProperty(candidate, candidate, "SetsCursorInBackground" as CFString, kCFBooleanTrue),
                       operation: "enable background cursor control")
        connection = candidate
        return candidate
    }

    private static func load<T>(_ symbol: String, from library: UnsafeMutableRawPointer,
                                as type: T.Type) throws -> T {
        guard let address = dlsym(library, symbol) else {
            throw CursorBackendError.unavailable("\(symbol) is missing on this macOS version")
        }
        return unsafeBitCast(address, to: type)
    }

    private static func check(_ status: Int32, operation: String) throws {
        guard status == 0 else {
            throw CursorBackendError.rejected(operation: operation, status: status)
        }
    }
}

private enum CursorBackendError: LocalizedError {
    case unavailable(String)
    case rejected(operation: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Cursor control is unavailable: \(reason)."
        case .rejected(let operation, let status):
            return "Could not \(operation) (WindowServer error \(status))."
        }
    }
}
