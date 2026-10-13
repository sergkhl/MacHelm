import Foundation

/// A successful operation means that the backend accepted the request. It does
/// not prove what is currently drawn by WindowServer or by a game.
public protocol CursorVisibilityBackend: AnyObject {
    func hide() throws
    func show() throws
}

/// Owns at most one hide request. The caller serializes access to this object.
/// In the app, CursorController does that on the main actor.
public final class CursorVisibility {
    public private(set) var ownsHide = false
    public private(set) var isStopped = false

    private let backend: any CursorVisibilityBackend

    public init(backend: any CursorVisibilityBackend) {
        self.backend = backend
    }

    public func toggle() throws {
        guard !isStopped else { throw CursorVisibilityError.stopped }
        if ownsHide {
            try restore()
        } else {
            try hide()
        }
    }

    public func hide() throws {
        guard !isStopped else { throw CursorVisibilityError.stopped }
        guard !ownsHide else { return }
        try backend.hide()
        ownsHide = true
    }

    /// A failed show keeps ownership so a later restore can retry it. Never
    /// sends a show for a hide that this object did not successfully request.
    public func restore() throws {
        guard ownsHide else { return }
        try backend.show()
        ownsHide = false
    }

    /// Stops new hide requests before attempting restoration. Calling stop or
    /// restore again remains useful if the first restoration attempt failed.
    public func stop() throws {
        isStopped = true
        try restore()
    }
}

public enum CursorVisibilityError: LocalizedError, Equatable {
    case stopped

    public var errorDescription: String? {
        "Cursor control has stopped."
    }
}
