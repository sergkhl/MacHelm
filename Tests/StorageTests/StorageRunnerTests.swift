import XCTest
@testable import StorageCore

// The app's run of the cleanup script, on small shell scripts that stand for
// it: the lines, the answer to a root removal, and a run that ends badly.
final class StorageRunnerTests: XCTestCase {
    private struct Outcome {
        var events: [StorageEvent] = []
        var status: Int32 = -1
        var errors = ""
    }

    private let done = #"{"event": "done", "reclaimed_kb": 1, "failures": 0, "free_kb": 2}"#

    // Runs `/bin/sh -c script` to its end. `react` is called for every event, on the queue the events come on.
    private func run(_ script: String, react: (@Sendable (StorageEvent, StorageRunner) -> Void)? = nil,
                     file: StaticString = #filePath, line: UInt = #line) -> Outcome {
        let queue = DispatchQueue(label: "storage-runner-tests")
        let runner = StorageRunner(callbacks: queue)
        let finished = expectation(description: "the run ends")
        var outcome = Outcome()
        let started = runner.start(executable: "/bin/sh", arguments: ["-c", script], event: { event in
            outcome.events.append(event)
            react?(event, runner)
        }, ended: { status, errors in
            outcome.status = status
            outcome.errors = errors
            finished.fulfill()
        })
        XCTAssertTrue(started, file: file, line: line)
        wait(for: [finished], timeout: 20)
        return queue.sync { outcome }
    }

    func testTheEventsComeInOrderAndWhatIsNoEventIsLeftOut() {
        let outcome = run("""
        echo '~/somewhere'
        printf '\\033[35m>\\033[39m %s\\n' '{"event": "result", "key": "go", "ok": true, "freed_kb": 12, "error": null}'
        echo 'not an event'
        echo '\(done)'
        """)
        XCTAssertEqual(outcome.events, [.result(key: "go", ok: true, freedKB: 12, error: nil), .done(reclaimedKB: 1, failures: 0, freeKB: 2)])
        XCTAssertEqual(outcome.status, 0)
    }

    func testTheLastLineIsReadWithoutALineBreak() {
        XCTAssertEqual(run("printf '%s' '\(done)'").events, [.done(reclaimedKB: 1, failures: 0, freeKB: 2)])
    }

    // A pipe holds 64 kilobytes; a scan's one line can be longer.
    func testALineLongerThanAPipeIsReadWhole() {
        let outcome = run("""
        long=$(head -c 300000 /dev/zero | tr '\\0' 'x')
        printf '{"event": "error", "message": "%s"}\\n' "$long"
        echo '\(done)'
        """)
        guard case .error(let message)? = outcome.events.first else { return XCTFail("no long line: \(outcome.events.count) events") }
        XCTAssertEqual(message.count, 300_000)
        XCTAssertEqual(outcome.events.last, .done(reclaimedKB: 1, failures: 0, freeKB: 2))
    }

    func testARootRemovalIsAnsweredAndTheScriptGoesOnWithTheAnswer() {
        let script = """
        echo '{"event": "remove-root", "path": "/Library/x"}'
        read answer
        case "$answer" in
          *'"ok":true'*) echo '{"event": "result", "key": "root", "ok": true, "freed_kb": 5, "error": null}' ;;
          *) echo '{"event": "result", "key": "root", "ok": false, "freed_kb": null, "error": "refused"}' ;;
        esac
        echo '\(done)'
        """
        let allowed = run(script) { event, runner in
            if case .removeRoot = event { runner.answer(StorageProtocol.reply(ok: true)) }
        }
        XCTAssertEqual(allowed.events, [.removeRoot(path: "/Library/x"), .result(key: "root", ok: true, freedKB: 5, error: nil),
                                        .done(reclaimedKB: 1, failures: 0, freeKB: 2)])
        let refused = run(script) { event, runner in
            if case .removeRoot = event { runner.answer(StorageProtocol.reply(ok: false, error: "not listed")) }
        }
        XCTAssertEqual(refused.events[1], .result(key: "root", ok: false, freedKB: nil, error: "refused"))
    }

    func testAnAnswerAfterTheScriptHasGoneDoesNoHarm() {
        let queue = DispatchQueue(label: "storage-runner-tests")
        let runner = StorageRunner(callbacks: queue)
        let finished = expectation(description: "the run ends")
        XCTAssertTrue(runner.start(executable: "/bin/sh", arguments: ["-c", "exit 3"], event: { _ in }, ended: { status, _ in
            XCTAssertEqual(status, 3)
            finished.fulfill()
        }))
        wait(for: [finished], timeout: 20)
        runner.answer(StorageProtocol.reply(ok: true))
        runner.cancel()
    }

    // The review's second critical finding: the owner presses Stop while a
    // root removal waits for its answer, and the answer is written when
    // nobody reads any more. Here the script closes its own input and lives on.
    func testAnAnswerNobodyReadsFailsWithoutEndingWhoeverWroteIt() {
        let outcome = run("""
        exec 0<&-
        echo '{"event": "remove-root", "path": "/Library/x"}'
        sleep 1
        echo '\(done)'
        """) { event, runner in
            if case .removeRoot = event { runner.answer(StorageProtocol.reply(ok: true)) }
        }
        XCTAssertEqual(outcome.events, [.removeRoot(path: "/Library/x"), .done(reclaimedKB: 1, failures: 0, freeKB: 2)])
    }

    func testStoppingEndsTheRun() {
        let began = Date()
        let outcome = run("echo '{\"event\": \"error\", \"message\": \"started\"}'; sleep 30; echo '\(done)'") { event, runner in
            if case .error = event { runner.cancel() }
        }
        XCTAssertEqual(outcome.events, [.error("started")])
        XCTAssertEqual(outcome.status, SIGTERM)
        XCTAssertLessThan(Date().timeIntervalSince(began), 10)
    }

    // L2: the login shell ignores the terminate signal while it starts.
    func testStoppingEndsARunThatIgnoresTheFirstSignal() {
        let began = Date()
        let outcome = run("trap '' TERM; echo '{\"event\": \"error\", \"message\": \"started\"}'; sleep 30; echo '\(done)'") { event, runner in
            if case .error = event { runner.cancel() }
        }
        XCTAssertEqual(outcome.events, [.error("started")])
        XCTAssertEqual(outcome.status, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(began), 10)
    }

    // L4: at Quit nothing waits for a script to take the hint.
    func testEndingARunAtOnceDoesNotWaitForIt() {
        let outcome = run("trap '' TERM; echo '{\"event\": \"error\", \"message\": \"started\"}'; sleep 30") { event, runner in
            if case .error = event { runner.end() }
        }
        XCTAssertEqual(outcome.status, SIGKILL)
    }

    // L18: whoever starts a run holds it in the closures it hands over, as the app does.
    func testARunLetsGoOfWhatItWasHandedWhenItEnds() {
        let queue = DispatchQueue(label: "storage-runner-tests")
        weak var kept: StorageRunner?
        let finished = expectation(description: "the run ends")
        do {
            let runner = StorageRunner(callbacks: queue)
            kept = runner
            XCTAssertTrue(runner.start(executable: "/bin/sh", arguments: ["-c", "echo '\(done)'"], event: { _ in _ = runner }, ended: { _, _ in
                _ = runner
                finished.fulfill()
            }))
        }
        wait(for: [finished], timeout: 20)
        // The callbacks' queue and the runner's own have nothing of it left to do.
        queue.sync {}
        let gone = expectation(description: "the run is let go")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { gone.fulfill() }
        wait(for: [gone], timeout: 5)
        XCTAssertNil(kept)
    }

    func testWhatTheScriptComplainsAboutIsHandedOverAndMuchOfItDoesNotHoldTheRun() {
        let outcome = run("""
        head -c 300000 /dev/zero | tr '\\0' 'e' >&2
        echo >&2
        echo 'Refusing to run: du is required' >&2
        echo '\(done)'
        exit 1
        """)
        XCTAssertEqual(outcome.status, 1)
        XCTAssertEqual(outcome.events, [.done(reclaimedKB: 1, failures: 0, freeKB: 2)])
        XCTAssertEqual(outcome.errors.split(separator: "\n").last.map(String.init), "Refusing to run: du is required")
    }

    // A program the script started keeps the output open after the script has gone.
    func testARunEndsAlthoughSomethingItStartedLivesOn() {
        let began = Date()
        let outcome = run("echo '\(done)'; (sleep 8) & exit 0")
        XCTAssertEqual(outcome.events, [.done(reclaimedKB: 1, failures: 0, freeKB: 2)])
        XCTAssertEqual(outcome.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(began), 6)
    }

    func testAProgramThatCannotBeStartedSaysSo() {
        let runner = StorageRunner(callbacks: DispatchQueue(label: "storage-runner-tests"))
        XCTAssertFalse(runner.start(executable: "/nonexistent/shell", arguments: [], event: { _ in }, ended: { _, _ in }))
    }

    // The remainder of L18: a run that never started is let go as well.
    func testARunThatCouldNotStartLetsGoOfWhatItWasHanded() {
        weak var kept: StorageRunner?
        do {
            let runner = StorageRunner(callbacks: DispatchQueue(label: "storage-runner-tests"))
            kept = runner
            XCTAssertFalse(runner.start(executable: "/nonexistent/shell", arguments: [], event: { _ in _ = runner }, ended: { _, _ in _ = runner }))
        }
        XCTAssertNil(kept)
    }
}
