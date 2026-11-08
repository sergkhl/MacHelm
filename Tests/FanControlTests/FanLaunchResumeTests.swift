import XCTest
@testable import FanControlCore

// SR-Q1 and SR-Q2 (owner, 2026-10-11): Fan Control starts as the owner left
// it, and a launch brings it back by the rule that follows a wake.
final class FanRememberedChoiceTests: XCTestCase {
    func testTurningOnAndOffSavesTheOwnersChoice() {
        var choice = FanRememberedChoice(saved: false)
        // The press itself counts, while the helper is still entering control.
        XCTAssertEqual(choice.observe(enabled: false, beginning: true, resumePending: false), true)
        XCTAssertNil(choice.observe(enabled: true, beginning: true, resumePending: false))
        XCTAssertNil(choice.observe(enabled: true, beginning: false, resumePending: false))
        XCTAssertTrue(choice.on)
        XCTAssertEqual(choice.observe(enabled: false, beginning: false, resumePending: false), false)
        XCTAssertFalse(choice.on)
    }

    func testABeginThatFailsSavesOff() {
        var choice = FanRememberedChoice(saved: false)
        XCTAssertEqual(choice.observe(enabled: false, beginning: true, resumePending: false), true)
        XCTAssertEqual(choice.observe(enabled: false, beginning: false, resumePending: false), false)
    }

    func testQuitKeepsTheChoice() {
        var choice = FanRememberedChoice(saved: false)
        XCTAssertEqual(choice.observe(enabled: true, beginning: false, resumePending: false), true)
        choice.beginQuit()
        // Quit releases the fans; that is not the owner turning Fan Control off.
        XCTAssertNil(choice.observe(enabled: false, beginning: false, resumePending: false))
        XCTAssertTrue(choice.on)
    }

    func testSleepKeepsTheChoiceWhileTheResumeIsPending() {
        var choice = FanRememberedChoice(saved: false)
        XCTAssertEqual(choice.observe(enabled: true, beginning: false, resumePending: false), true)
        XCTAssertNil(choice.observe(enabled: true, beginning: false, resumePending: true))
        XCTAssertNil(choice.observe(enabled: false, beginning: false, resumePending: true))
        // After the wake the resume becomes a begin, then control.
        XCTAssertNil(choice.observe(enabled: false, beginning: true, resumePending: false))
        XCTAssertNil(choice.observe(enabled: true, beginning: false, resumePending: false))
        XCTAssertTrue(choice.on)
    }

    func testAFaultThatEndsControlSavesOff() {
        var choice = FanRememberedChoice(saved: false)
        XCTAssertEqual(choice.observe(enabled: true, beginning: false, resumePending: false), true)
        XCTAssertEqual(choice.observe(enabled: false, beginning: false, resumePending: false), false)
        XCTAssertNil(choice.observe(enabled: false, beginning: false, resumePending: false))
    }

    func testABlockedResumeSavesOff() {
        // On was saved; this launch is waiting to bring Fan Control back.
        var choice = FanRememberedChoice(saved: true)
        XCTAssertNil(choice.observe(enabled: false, beginning: false, resumePending: true))
        XCTAssertTrue(choice.on)
        XCTAssertEqual(choice.observe(enabled: false, beginning: false, resumePending: false), false)
    }

    func testAnUnconfirmedReleaseAtQuitSavesOff() {
        var choice = FanRememberedChoice(saved: false)
        XCTAssertEqual(choice.observe(enabled: true, beginning: false, resumePending: false), true)
        choice.beginQuit()
        XCTAssertNil(choice.observe(enabled: false, beginning: false, resumePending: false))
        XCTAssertEqual(choice.releaseAtQuitUnconfirmed(), false)
        XCTAssertFalse(choice.on)
    }
}

final class FanLaunchResumeTests: XCTestCase {
    private static let lead = "Fan Control was on when MacHelm last ran."

    private func status(frameAt time: Double?, manualFan: Bool = false) -> FanStatus {
        var status = FanStatus(serviceGeneration: "launch-resume-test")
        status.capabilities = FanPolicyTests.capabilities
        if let time {
            var frame = FanPolicyTests.frame(40, at: time)
            if manualFan {
                frame = FanSnapshot(capturedAt: time, temperatures: frame.temperatures,
                                    fans: [FanReading(id: 0, actualRPM: 3000, targetRPM: 3000, mode: 1),
                                           FanReading(id: 1, actualRPM: 1500, targetRPM: 0, mode: 0)],
                                    thermalPressure: .nominal, globalUnlock: 0)
            }
            status.snapshot = frame
        }
        return status
    }

    private func consider(_ resume: inout FanLaunchResume, _ status: FanStatus, now: Double,
                          approved: Bool = true, ready: Bool = true, conflict: String? = nil) -> FanLaunchResume.Decision {
        resume.consider(helperApproved: approved, helperReady: ready, status: status, now: now, conflict: conflict)
    }

    private func assertStaysOff(_ decision: FanLaunchResume.Decision, containing text: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard case .stayOff(let reason) = decision else {
            return XCTFail("Expected Fan Control to stay off, got \(decision)", file: file, line: line)
        }
        XCTAssertTrue(reason.hasPrefix(Self.lead), reason, file: file, line: line)
        XCTAssertTrue(reason.contains(text), reason, file: file, line: line)
    }

    func testThreeHealthyReadingsInARowBringItBack() {
        var resume = FanLaunchResume(launchedAt: 100)
        XCTAssertEqual(consider(&resume, status(frameAt: 101), now: 101), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 102), now: 102), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 103), now: 103), .begin)
    }

    func testARepeatedReadingDoesNotCount() {
        var resume = FanLaunchResume(launchedAt: 100)
        XCTAssertEqual(consider(&resume, status(frameAt: 101), now: 101), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 101), now: 101.5), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 102), now: 102), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 102), now: 102.5), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 103), now: 103), .begin)
    }

    func testItWaitsForTheHelperForThirtySecondsAndNoLonger() {
        var resume = FanLaunchResume(launchedAt: 100)
        XCTAssertEqual(consider(&resume, status(frameAt: nil), now: 101, ready: false), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: nil), now: 129.9, ready: false), .wait)
        assertStaysOff(consider(&resume, status(frameAt: nil), now: 130, ready: false), containing: "30 seconds")
    }

    func testAHelperThatAnswersLateStillBringsItBack() {
        var resume = FanLaunchResume(launchedAt: 100)
        XCTAssertEqual(consider(&resume, status(frameAt: nil), now: 120, ready: false), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 125), now: 125), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 126), now: 126), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 127), now: 127), .begin)
    }

    func testAHelperThatDropsOutStartsTheCountAgain() {
        var resume = FanLaunchResume(launchedAt: 100)
        XCTAssertEqual(consider(&resume, status(frameAt: 101), now: 101), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 102), now: 102), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 102), now: 103, ready: false), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 104), now: 104), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 105), now: 105), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 106), now: 106), .begin)
    }

    func testReadingsThatNeverComeEndTheWaitToo() {
        var resume = FanLaunchResume(launchedAt: 100)
        XCTAssertEqual(consider(&resume, status(frameAt: nil), now: 110), .wait)
        assertStaysOff(consider(&resume, status(frameAt: nil), now: 130), containing: "30 seconds")
    }

    // SR-Q7 (owner, 2026-10-11): inside the 30 seconds the launch keeps
    // waiting, whatever else it sees. Only a hold, the helper's own recovery
    // and another fan utility end it at once.
    func testAHelperThatReadsNotApprovedAtFirstIsWaitedFor() {
        var resume = FanLaunchResume(launchedAt: 100)
        XCTAssertEqual(consider(&resume, status(frameAt: nil), now: 101, approved: false, ready: false), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: nil), now: 102, approved: false, ready: false), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 103), now: 103), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 104), now: 104), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 105), now: 105), .begin)
    }

    func testAHelperThatStaysNotApprovedEndsTheWait() {
        var resume = FanLaunchResume(launchedAt: 100)
        XCTAssertEqual(consider(&resume, status(frameAt: nil), now: 129, approved: false, ready: false), .wait)
        let decision = consider(&resume, status(frameAt: nil), now: 130, approved: false, ready: false)
        assertStaysOff(decision, containing: "not approved")
        assertStaysOff(decision, containing: "30 seconds")
    }

    func testARecoveryHoldStaysOff() {
        var resume = FanLaunchResume(launchedAt: 100)
        var held = status(frameAt: 101)
        held.externalRecoveryRequired = true
        held.mode = .externalRecoveryRequired
        assertStaysOff(consider(&resume, held, now: 101), containing: "recovery hold")
    }

    func testAnotherFanUtilityStaysOff() {
        var resume = FanLaunchResume(launchedAt: 100)
        assertStaysOff(consider(&resume, status(frameAt: 101), now: 101, conflict: "Macs Fan Control"),
                       containing: "Macs Fan Control")
    }

    // A relaunch straight after a force-quit finds the helper still releasing.
    func testFansThatBecomeAutomaticAreWaitedFor() {
        var resume = FanLaunchResume(launchedAt: 100)
        XCTAssertEqual(consider(&resume, status(frameAt: 101, manualFan: true), now: 101), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 102), now: 102), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 103), now: 103), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 104), now: 104), .begin)
    }

    func testAFanThatStaysManualEndsTheWait() {
        var resume = FanLaunchResume(launchedAt: 100)
        XCTAssertEqual(consider(&resume, status(frameAt: 129, manualFan: true), now: 129), .wait)
        assertStaysOff(consider(&resume, status(frameAt: 130, manualFan: true), now: 130), containing: "automatic")
    }

    func testAnOverrideTheHelperStillOwnsIsWaitedForAndEndsTheWait() {
        var resume = FanLaunchResume(launchedAt: 100)
        var owning = status(frameAt: 101)
        owning.ownsOverride = true
        XCTAssertEqual(consider(&resume, owning, now: 101), .wait)
        owning = status(frameAt: 130)
        owning.ownsOverride = true
        assertStaysOff(consider(&resume, owning, now: 130), containing: "still holds")
    }

    // The review's finding 13: the firmware's wrong reading can label the idle
    // helper unavailable for a second. That must not end the launch's attempt.
    func testAPassingFaultLabelIsWaitedOutAndStartsTheCountAgain() {
        var resume = FanLaunchResume(launchedAt: 100)
        XCTAssertEqual(consider(&resume, status(frameAt: 101), now: 101), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 102), now: 102), .wait)
        var faulted = status(frameAt: 102)
        faulted.mode = .unavailable
        faulted.reason = "Temperature TCMz is out of range."
        XCTAssertEqual(consider(&resume, faulted, now: 103), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 104), now: 104), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 105), now: 105), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 106), now: 106), .begin)
    }

    func testAFaultThatStaysEndsTheWait() {
        for mode in [FanOperatingMode.unavailable, .restorationFailed] {
            var resume = FanLaunchResume(launchedAt: 100)
            var faulted = status(frameAt: 101)
            faulted.mode = mode
            faulted.reason = "A sensor read failed."
            XCTAssertEqual(consider(&resume, faulted, now: 101), .wait)
            assertStaysOff(consider(&resume, faulted, now: 130), containing: "A sensor read failed.")
        }
    }

    // The review's finding 14. After the helper's own recovery Fan Control
    // stays off until the owner turns it on again. The app was not running to
    // save that, so the launch must read it from the helper.
    func testAfterTheHelpersOwnRecoveryItStaysOffUntilTurnedOnAgain() {
        var resume = FanLaunchResume(launchedAt: 100)
        for second in 101...104 {
            var recovered = status(frameAt: Double(second))
            recovered.mode = .paused
            recovered.reason = "A fan command could not be confirmed. The fans were returned to automatic and checked. Turn Fan Control on again to resume."
            var receipt = FanSelfRecoveryReceipt(recoveryID: "the-session-that-ended", trigger: .automatic, cause: "deadline",
                                                 unconfirmed: .mode(fan: 0, manual: false), startedAt: 90)
            receipt.confirmedAt = 93
            recovered.selfRecoveryReceipt = receipt
            assertStaysOff(consider(&resume, recovered, now: Double(second)), containing: "could not be confirmed")
        }
    }

    // The helper's state after every ordinary Quit, and after a lost
    // connection: paused, with the reason control ended. It does not block.
    func testAHelperPausedByTheLastQuitBringsItBack() {
        var resume = FanLaunchResume(launchedAt: 100)
        func paused(_ time: Double) -> FanStatus {
            var status = status(frameAt: time)
            status.mode = .paused
            status.reason = "Fan Control was turned off by the app."
            return status
        }
        XCTAssertEqual(consider(&resume, paused(101), now: 101), .wait)
        XCTAssertEqual(consider(&resume, paused(102), now: 102), .wait)
        XCTAssertEqual(consider(&resume, paused(103), now: 103), .begin)
    }

    func testAReadingThatIsNotHealthyIsWaitedOutAndEndsTheWait() {
        var resume = FanLaunchResume(launchedAt: 100)
        // Ten seconds old: the helper has stopped delivering fresh readings.
        XCTAssertEqual(consider(&resume, status(frameAt: 101), now: 111), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 112), now: 112), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 113), now: 113), .wait)
        XCTAssertEqual(consider(&resume, status(frameAt: 114), now: 114), .begin)

        var never = FanLaunchResume(launchedAt: 100)
        assertStaysOff(consider(&never, status(frameAt: 101), now: 130), containing: "healthy")
    }
}

// G-Q3 (owner, 2026-11-05): on 2026-11-03 one status reply older than three
// seconds ended Fan Control, and it stayed off until turned on again.
// L-Q3 (owner, 2026-11-08): the app gives up only after the lease and a margin
// of its own running time without a usable reply.
final class FanStatusWaitTests: XCTestCase {
    func testALateReplyIsDroppedAndAskedAgainInsteadOfEndingFanControl() {
        var wait = FanStatusWait()
        wait.asked(running: 0)
        XCTAssertEqual(wait.reply(requestedAt: 100, now: 102.9, running: 2.9), .usable)
        wait.asked(running: 3)
        XCTAssertEqual(wait.reply(requestedAt: 103, now: 106, running: 6), .askAgain)
        XCTAssertEqual(wait.reply(requestedAt: 106, now: 106.1, running: 6.1), .usable)
    }

    func testLateRepliesInARowAreAskedAgainUntilTheLimit() {
        var wait = FanStatusWait()
        wait.asked(running: 0)
        XCTAssertEqual(wait.reply(requestedAt: 100, now: 103, running: 3), .askAgain)
        wait.asked(running: 3)
        XCTAssertEqual(wait.reply(requestedAt: 103, now: 106, running: 6), .askAgain)
        XCTAssertEqual(wait.reply(requestedAt: 128, now: 131.9, running: 31.9), .askAgain)
        XCTAssertEqual(wait.reply(requestedAt: 129, now: 132, running: 32), .giveUp)
    }

    func testAUsableReplyOrANewConnectionStartsTheWaitAgain() {
        var usable = FanStatusWait()
        usable.asked(running: 0)
        XCTAssertEqual(usable.reply(requestedAt: 100, now: 103, running: 30), .askAgain)
        XCTAssertEqual(usable.reply(requestedAt: 103, now: 103.1, running: 31), .usable)
        usable.asked(running: 31)
        XCTAssertFalse(usable.overdue(running: 62.9))
        XCTAssertTrue(usable.overdue(running: 63))

        var reconnected = FanStatusWait()
        reconnected.asked(running: 0)
        XCTAssertTrue(reconnected.overdue(running: 32))
        reconnected.reset()
        XCTAssertFalse(reconnected.overdue(running: 40))
        reconnected.asked(running: 40)
        XCTAssertEqual(reconnected.reply(requestedAt: 140, now: 143, running: 43), .askAgain)
    }

    func testALaterRequestDoesNotRestartTheWait() {
        var wait = FanStatusWait()
        wait.asked(running: 0)
        wait.asked(running: 20)
        XCTAssertTrue(wait.overdue(running: 32))
    }

    func testAReplyFromTheFutureAuthorizesNothing() {
        var wait = FanStatusWait()
        wait.asked(running: 0)
        XCTAssertEqual(wait.reply(requestedAt: 100, now: 99, running: 1), .askAgain)
    }

    // The app must not give up while the helper could still keep the session.
    // Running time never runs ahead of real time, so a limit past the lease in
    // running time is past it in real time too.
    func testNoReplyIsWaitedForUntilAfterTheLeaseHasRunOut() throws {
        var wait = FanStatusWait()
        wait.asked(running: 0)
        let keeping = FanSafetyGate()
        let kept = try keeping.begin(owner: "app", now: 100)
        XCTAssertTrue(keeping.renew(owner: "app", session: kept, now: 129.9))
        XCTAssertFalse(wait.overdue(running: 29.9))

        let losing = FanSafetyGate()
        let lost = try losing.begin(owner: "app", now: 100)
        XCTAssertFalse(losing.renew(owner: "app", session: lost, now: 130))
        XCTAssertFalse(wait.overdue(running: 31.9))
        XCTAssertTrue(wait.overdue(running: 32))
    }
}

// L-Q2 (owner, 2026-11-08): on 2026-11-08 the app's main thread froze for 8.2
// seconds under memory pressure. Its own limits must not count that.
final class FanRunningClockTests: XCTestCase {
    func testTicksASecondApartCountInFull() {
        var clock = FanRunningClock(uptime: 100)
        for second in 1...10 { XCTAssertEqual(clock.read(uptime: 100 + Double(second)), Double(second), accuracy: 1e-9) }
        XCTAssertEqual(clock.read(uptime: 111.9), 11.9, accuracy: 1e-9)
    }

    func testAFreezeCountsOnlyTheStepLimit() {
        var clock = FanRunningClock(uptime: 100)
        XCTAssertEqual(clock.read(uptime: 101), 1, accuracy: 1e-9)
        XCTAssertEqual(clock.read(uptime: 109.2), 1 + FanRunningClock.stepLimit, accuracy: 1e-9)
        XCTAssertEqual(clock.read(uptime: 110.2), 2 + FanRunningClock.stepLimit, accuracy: 1e-9)
    }

    func testTheClockNeverRunsAheadOfUptimeOrBackwards() {
        var clock = FanRunningClock(uptime: 100)
        XCTAssertEqual(clock.read(uptime: 99), 0)
        XCTAssertEqual(clock.read(uptime: 100.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(clock.read(uptime: 100.5), 0.5, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(clock.read(uptime: 140), 40)
    }

    // An 8.2 s freeze while a status request is out no longer ends the wait.
    func testAFreezeOfEightSecondsDoesNotUseUpTheStatusWait() {
        var clock = FanRunningClock(uptime: 100)
        var wait = FanStatusWait()
        wait.asked(running: clock.read(uptime: 100))
        let resumed = clock.read(uptime: 108.2)
        XCTAssertFalse(wait.overdue(running: resumed))
        XCTAssertEqual(wait.reply(requestedAt: 100, now: 108.2, running: resumed), .askAgain)
        XCTAssertEqual(wait.reply(requestedAt: 108.2, now: 108.3, running: clock.read(uptime: 108.3)), .usable)
    }
}

// G-Q2 (owner, 2026-10-29): why Fan Control ended without the owner is kept,
// told in the helper's words when the helper ended it, and announced once.
final class FanStopNoteTests: XCTestCase {
    private func status(_ mode: FanOperatingMode, reason: String?, session: String? = nil) -> FanStatus {
        var status = FanStatus(serviceGeneration: "stop-note-test")
        status.mode = mode; status.reason = reason; status.sessionID = session
        return status
    }

    func testTheHelpersAccountOfAnEndingReplacesTheAppsOwn() {
        var note = FanStopNote(reason: "The control lease ended.", at: Date(), awaitingHelper: true)
        XCTAssertFalse(note.adopt(status(.paused, reason: "Too early.", session: UUID().uuidString)))
        XCTAssertFalse(note.adopt(status(.unavailable, reason: "An idle fault label.")))
        XCTAssertFalse(note.adopt(status(.paused, reason: nil)))
        XCTAssertEqual(note.reason, "The control lease ended.")
        XCTAssertTrue(note.adopt(status(.paused, reason: "No complete fresh sensor snapshot for four seconds.")))
        XCTAssertEqual(note.reason, "No complete fresh sensor snapshot for four seconds.")
        XCTAssertFalse(note.awaitingHelper)
        // Only the first account counts; a later ending is a later note.
        XCTAssertFalse(note.adopt(status(.paused, reason: "Fan Control was turned off by the app.")))
        XCTAssertEqual(note.reason, "No complete fresh sensor snapshot for four seconds.")

        var stuck = FanStopNote(reason: "The control lease ended.", at: Date(), awaitingHelper: true)
        XCTAssertTrue(stuck.adopt(status(.restorationFailed, reason: "Fan mode or target changed unexpectedly; ownership was lost.")))
        XCTAssertEqual(stuck.reason, "Fan mode or target changed unexpectedly; ownership was lost.")
    }

    func testAnAppAccountIsNotReplaced() {
        var note = FanStopNote(reason: "Fan helper disconnected.", at: Date(), awaitingHelper: false)
        XCTAssertFalse(note.adopt(status(.paused, reason: "The authenticated app connection was lost.")))
        XCTAssertEqual(note.reason, "Fan helper disconnected.")
    }

    func testAnEndingTheHelperMadeIsAnnouncedOnceItsAccountCameOrAfterFiveSeconds() {
        var waiting = FanStopNote(reason: "The control lease ended.", at: Date(), awaitingHelper: true)
        XCTAssertFalse(waiting.announce(waited: 4.9, coveredElsewhere: false))
        XCTAssertFalse(waiting.announced)
        XCTAssertTrue(waiting.announce(waited: 5, coveredElsewhere: false))
        XCTAssertTrue(waiting.announced)
        XCTAssertFalse(waiting.announce(waited: 6, coveredElsewhere: false))

        var told = FanStopNote(reason: "The control lease ended.", at: Date(), awaitingHelper: true)
        XCTAssertTrue(told.adopt(status(.paused, reason: FanSafetyGate.leaseExpiredReason)))
        XCTAssertTrue(told.announce(waited: 1, coveredElsewhere: false))
    }

    func testAnEndingWithAnAlertOfItsOwnIsMarkedWithoutASecondOne() {
        var note = FanStopNote(reason: "Fan helper disconnected.", at: Date(), awaitingHelper: false)
        XCTAssertFalse(note.announce(waited: 0, coveredElsewhere: true))
        XCTAssertTrue(note.announced)
        XCTAssertFalse(note.announce(waited: 10, coveredElsewhere: false))
    }

    func testASavedNoteKeepsItsReasonTimeAndAnnouncementButNotTheWait() throws {
        let at = Date(timeIntervalSince1970: 1_793_143_405)
        var note = FanStopNote(reason: "The control lease ended.", at: at, awaitingHelper: true)
        let saved = try JSONDecoder().decode(FanStopNote.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(saved.reason, "The control lease ended."); XCTAssertEqual(saved.at, at)
        XCTAssertFalse(saved.awaitingHelper, "A later run may no longer have the helper's account.")
        XCTAssertFalse(saved.announced)
        XCTAssertTrue(note.announce(waited: 5, coveredElsewhere: false))
        XCTAssertTrue(try JSONDecoder().decode(FanStopNote.self, from: JSONEncoder().encode(note)).announced)
    }
}
