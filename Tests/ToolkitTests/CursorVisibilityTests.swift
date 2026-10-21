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

    // MARK: Keeping the request in force (ADR 0007)

    func testAPointerShownAgainIsHiddenAgainWithOneOwnedHide() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)
        try visibility.toggle()
        backend.visible = true

        XCTAssertTrue(try visibility.maintain())
        XCTAssertTrue(visibility.requested)
        XCTAssertTrue(visibility.ownsHide)
        XCTAssertEqual(backend.calls, [.hide, .show, .hide])
        XCTAssertEqual(backend.outstanding, 1)

        XCTAssertTrue(try visibility.maintain())
        XCTAssertEqual(backend.outstanding, 1)

        // A single show balances what is owned.
        try visibility.toggle()
        XCTAssertEqual(backend.calls, [.hide, .show, .hide, .show, .hide, .show])
        XCTAssertEqual(backend.outstanding, 0)
    }

    func testAHiddenPointerGetsNoCalls() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)
        try visibility.hide()

        XCTAssertFalse(try visibility.maintain())
        XCTAssertEqual(backend.calls, [.hide])
    }

    func testARefusedShowSkipsTheHideAndKeepsTheOwnedOne() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)
        try visibility.hide()
        backend.visible = true
        backend.showFailure = .rejected

        XCTAssertThrowsError(try visibility.maintain())
        XCTAssertTrue(visibility.requested)
        XCTAssertTrue(visibility.ownsHide)
        XCTAssertEqual(backend.calls, [.hide, .show])
        XCTAssertEqual(backend.outstanding, 1)

        backend.showFailure = nil
        XCTAssertTrue(try visibility.maintain())
        XCTAssertEqual(backend.calls, [.hide, .show, .show, .hide])
        XCTAssertEqual(backend.outstanding, 1)
    }

    func testARefusedHideKeepsTheRequestAndTheNextRoundOnlyHides() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)
        try visibility.hide()
        backend.visible = true
        backend.hideFailure = .rejected

        XCTAssertThrowsError(try visibility.maintain())
        XCTAssertTrue(visibility.requested)
        XCTAssertFalse(visibility.ownsHide)
        XCTAssertEqual(backend.calls, [.hide, .show, .hide])
        XCTAssertEqual(backend.outstanding, 0)

        backend.hideFailure = nil
        XCTAssertTrue(try visibility.maintain())
        XCTAssertTrue(visibility.ownsHide)
        XCTAssertEqual(backend.calls, [.hide, .show, .hide, .hide])
        XCTAssertEqual(backend.outstanding, 1)
    }

    func testRestoreEndsTheRehides() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)
        try visibility.hide()
        try visibility.restore()
        backend.visible = true

        XCTAssertFalse(try visibility.maintain())
        XCTAssertFalse(visibility.requested)
        XCTAssertEqual(backend.calls, [.hide, .show])
    }

    func testToggleAfterARefusedRehideEndsTheRequestWithoutAnUnmatchedShow() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)
        try visibility.toggle()
        backend.visible = true
        backend.hideFailure = .rejected
        XCTAssertThrowsError(try visibility.maintain())

        try visibility.toggle()
        XCTAssertFalse(visibility.requested)
        XCTAssertFalse(visibility.ownsHide)
        XCTAssertFalse(try visibility.maintain())
        XCTAssertEqual(backend.calls, [.hide, .show, .hide])
        XCTAssertEqual(backend.outstanding, 0)
    }

    func testARefusedFirstHideMakesNoRequest() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)
        backend.hideFailure = .rejected
        XCTAssertThrowsError(try visibility.toggle())
        backend.visible = true

        XCTAssertFalse(visibility.requested)
        XCTAssertFalse(try visibility.maintain())
        XCTAssertEqual(backend.calls, [.hide])
    }

    func testStopEndsTheRequestAndTheRehides() throws {
        let backend = RecordingCursorBackend()
        let visibility = CursorVisibility(backend: backend)
        try visibility.hide()
        try visibility.stop()
        backend.visible = true

        XCTAssertFalse(visibility.requested)
        XCTAssertFalse(try visibility.maintain())
        XCTAssertEqual(backend.calls, [.hide, .show])
        XCTAssertEqual(backend.outstanding, 0)
    }
}

private final class RecordingCursorBackend: CursorVisibilityBackend {
    enum Call { case hide, show }
    enum Failure: Error { case rejected }

    var calls: [Call] = []
    var hideFailure: Failure?
    var showFailure: Failure?
    // What macOS reports about the pointer; the tests set it.
    var visible = false
    // Accepted hides not yet shown, counted as WindowServer counts them for one connection.
    private(set) var outstanding = 0

    var pointerIsVisible: Bool { visible }

    func hide() throws {
        calls.append(.hide)
        if let hideFailure { throw hideFailure }
        outstanding += 1
    }

    func show() throws {
        calls.append(.show)
        if let showFailure { throw showFailure }
        outstanding -= 1
    }
}
