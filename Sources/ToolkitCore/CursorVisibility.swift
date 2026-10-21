import Foundation

/// A successful operation means that the backend accepted the request. It does
/// not prove what is currently drawn by WindowServer or by a game.
public protocol CursorVisibilityBackend: AnyObject {
    func hide() throws
    func show() throws
    /// Whether macOS reports the system pointer visible, whichever app showed it.
    var pointerIsVisible: Bool { get }
}

/// Keeps the owner's hide request in force and owns at most one accepted hide
/// request (ADR 0007). The caller serializes access to this object. In the
/// app, CursorController does that on the main actor.
public final class CursorVisibility {
    /// The owner asked for the pointer to be hidden and has not restored it.
    public private(set) var requested = false
    /// The backend accepted a hide that has not been shown again.
    public private(set) var ownsHide = false
    public private(set) var isStopped = false

    private let backend: any CursorVisibilityBackend

    public init(backend: any CursorVisibilityBackend) {
        self.backend = backend
    }

    /// Restores while the request stands or a hide is still owned, so a
    /// failed restore is retried by the next toggle.
    public func toggle() throws {
        guard !isStopped else { throw CursorVisibilityError.stopped }
        if requested || ownsHide {
            try restore()
        } else {
            try hide()
        }
    }

    /// A refused first hide makes no request.
    public func hide() throws {
        guard !isStopped else { throw CursorVisibilityError.stopped }
        guard !requested else { return }
        if !ownsHide {
            try backend.hide()
            ownsHide = true
        }
        requested = true
    }

    /// Hides the pointer again when macOS shows it while the request stands.
    /// WindowServer counts hides, so the owned one is shown before a new one
    /// is sent. A refused show ends this round with the hide still owned; a
    /// refused hide keeps the request for the next round. Returns whether a
    /// new hide was accepted.
    @discardableResult
    public func maintain() throws -> Bool {
        guard requested, backend.pointerIsVisible else { return false }
        if ownsHide {
            try backend.show()
            ownsHide = false
        }
        try backend.hide()
        ownsHide = true
        return true
    }

    /// Ends the request. A failed show keeps ownership so a later restore can
    /// retry it. Never sends a show for a hide that this object did not
    /// successfully request.
    public func restore() throws {
        requested = false
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
