import XCTest
@testable import ToolkitCore

final class CursorVisibilityTests: XCTestCase {
    func testRepeatedHideAndRestoreCallsOwnOnlyOneBalancedRequest() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)

        try visibility.restore()
        try visibility.hide()
        try visibility.hide()
        XCTAssertTrue(visibility.ownsHide)
        XCTAssertEqual(backend.calls, [.hide])

        try visibility.restore()
        try visibility.restore()
        XCTAssertFalse(visibility.ownsHide)
        XCTAssertEqual(backend.calls, [.hide, .show])
    }

    func testFailedHideDoesNotAuthorizeAnUnmatchedShow() throws {
        let backend = RecordingCursorBackend()
        backend.hideFailure = .rejected
        let visibility = CursorVisibility(backend: backend)

        XCTAssertThrowsError(try visibility.toggle())
        XCTAssertFalse(visibility.ownsHide)
        try visibility.restore()
        XCTAssertEqual(backend.calls, [.hide])

        backend.hideFailure = nil
        try visibility.toggle()
        XCTAssertTrue(visibility.ownsHide)
        XCTAssertEqual(backend.calls, [.hide, .hide])
    }

    func testFailedRestoreRetainsOwnershipAndTheNextToggleRetriesShow() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)
        try visibility.toggle()
        backend.showFailure = .rejected

        XCTAssertThrowsError(try visibility.toggle())
        XCTAssertTrue(visibility.ownsHide)

        backend.showFailure = nil
        try visibility.toggle()
        XCTAssertFalse(visibility.ownsHide)
        XCTAssertEqual(backend.calls, [.hide, .show, .show])
    }

    func testStopRestoresOnlyOwnedHideAndPreventsAnotherHide() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)
        try visibility.hide()

        try visibility.stop()
        try visibility.stop()
        XCTAssertTrue(visibility.isStopped)
        XCTAssertFalse(visibility.ownsHide)
        XCTAssertThrowsError(try visibility.toggle()) { error in
            XCTAssertEqual(error as? CursorVisibilityError, .stopped)
        }
        XCTAssertThrowsError(try visibility.hide())
        XCTAssertEqual(backend.calls, [.hide, .show])
    }

    func testFailedStopAllowsRestorationRetryWithoutReenablingHide() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)
        try visibility.hide()
        backend.showFailure = .rejected

        XCTAssertThrowsError(try visibility.stop())
        XCTAssertTrue(visibility.isStopped)
        XCTAssertTrue(visibility.ownsHide)
        XCTAssertThrowsError(try visibility.toggle())
        XCTAssertEqual(backend.calls, [.hide, .show])

        backend.showFailure = nil
        try visibility.restore()
        XCTAssertFalse(visibility.ownsHide)
        XCTAssertTrue(visibility.isStopped)
        XCTAssertEqual(backend.calls, [.hide, .show, .show])
    }

    func testStoppingWithoutAnOwnedHideDoesNotChangeAnotherAppsCursor() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)

        try visibility.stop()

        XCTAssertTrue(visibility.isStopped)
        XCTAssertFalse(visibility.ownsHide)
        XCTAssertTrue(backend.calls.isEmpty)
    }
}

private final class RecordingCursorBackend: CursorVisibilityBackend {
    enum Call { case hide, show }
    enum Failure: Error { case rejected }

    var calls: [Call] = []
    var hideFailure: Failure?
    var showFailure: Failure?

    func hide() throws {
        calls.append(.hide)
        if let hideFailure { throw hideFailure }
    }

    func show() throws {
        calls.append(.show)
        if let showFailure { throw showFailure }
    }
}
