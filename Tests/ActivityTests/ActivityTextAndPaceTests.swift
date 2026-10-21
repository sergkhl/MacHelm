import XCTest
@testable import ActivityCore

// The reading paces (Q16, Q31) and the wording of a row (Q2, Q11, Q14).
final class ActivityPaceTests: XCTestCase {
    func testThePacesOfferedAndTheUsualOnes() {
        XCTAssertEqual(ActivityPace.background, [2, 5, 10, 30])
        XCTAssertEqual(ActivityPace.onScreen, [1, 2, 5])
        XCTAssertEqual(ActivityPace.defaultBackground, 5)
        XCTAssertEqual(ActivityPace.defaultOnScreen, 5)
    }

    func testTheBackgroundPaceIsUsedUntilTheListsAreWatched() {
        XCTAssertEqual(ActivityPace.interval(watched: false, background: 5, onScreen: 1, window: 10), 5)
        XCTAssertEqual(ActivityPace.interval(watched: true, background: 5, onScreen: 1, window: 10), 1)
    }

    func testAPaceLongerThanTheWindowIsShortenedToTheWindow() {
        XCTAssertEqual(ActivityPace.interval(watched: false, background: 30, onScreen: 1, window: 10), 10)
        XCTAssertEqual(ActivityPace.interval(watched: false, background: 30, onScreen: 1, window: 300), 30)
        XCTAssertEqual(ActivityPace.interval(watched: true, background: 30, onScreen: 5, window: 5), 5)
    }

    func testAPaceThatIsNotOfferedFallsBackToTheUsualOne() {
        XCTAssertEqual(ActivityPace.interval(watched: false, background: 0, onScreen: 1, window: 10), 5)
        XCTAssertEqual(ActivityPace.interval(watched: true, background: 5, onScreen: 0.01, window: 10), 5)
    }
}

final class ActivityTextTests: XCTestCase {
    private func process(starter: ProcessStarter? = nil, responsibleApp: String? = nil) -> ActivityProcessRow {
        ActivityProcessRow(identity: Sampled.identity(7), name: "tool", value: 1, actions: [], starter: starter, responsibleApp: responsibleApp)
    }

    private let byName = ProcessGroupID(kind: .process, name: "zsh")

    func testASpanReadsInSecondsAndMinutes() {
        XCTAssertEqual(ActivityText.span(5), "5 seconds")
        XCTAssertEqual(ActivityText.span(10), "10 seconds")
        XCTAssertEqual(ActivityText.span(42.4), "42 seconds")
        XCTAssertEqual(ActivityText.span(60), "1 minute")
        XCTAssertEqual(ActivityText.span(300), "5 minutes")
        XCTAssertEqual(ActivityText.span(150), "2 min 30 s")
        // A window that is all but full reads as full.
        XCTAssertEqual(ActivityText.span(299.7), "5 minutes")
    }

    func testAnOriginReadsFromTheNearestStarterOutward() {
        XCTAssertNil(ActivityText.origin([]))
        XCTAssertEqual(ActivityText.origin(["codex"]), "from codex")
        XCTAssertEqual(ActivityText.origin(["@playwright/mcp", "codex", "Ghostty"]), "from @playwright/mcp ← codex ← Ghostty")
    }

    func testAProcessSaysWhoStartedItAndForWhichApp() {
        XCTAssertNil(ActivityText.startedBy(process(), in: byName))
        XCTAssertEqual(ActivityText.startedBy(process(starter: ProcessStarter(pid: 812, name: "zsh"), responsibleApp: "Claude"), in: byName),
                       "started by zsh (PID 812), for Claude")
        XCTAssertEqual(ActivityText.startedBy(process(starter: ProcessStarter(pid: 812, name: "zsh", ended: true)), in: byName),
                       "started by zsh (ended)")
        XCTAssertEqual(ActivityText.startedBy(process(responsibleApp: "Ghostty"), in: byName), "for Ghostty")
    }

    // The row of a copy already names its origin.
    func testWhatTheRowsOriginSaysIsNotSaidAgain() {
        let copy = ProcessGroupID(kind: .app(bundlePath: "/Applications/Blender.app"), name: "Blender", origin: ["codex", "Ghostty"])
        XCTAssertNil(ActivityText.startedBy(process(starter: ProcessStarter(pid: 12, name: "codex"), responsibleApp: "Ghostty"), in: copy))
        XCTAssertEqual(ActivityText.startedBy(process(starter: ProcessStarter(pid: 30, name: "make"), responsibleApp: "Ghostty"), in: copy),
                       "started by make (PID 30)")
    }
}
