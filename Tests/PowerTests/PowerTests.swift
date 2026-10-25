import XCTest
@testable import PowerCore

// Keep Awake, the battery level and the sleep timers as the owner decided
// them on 2026-10-12 (Q7, Q20 to Q22 and Q30 of the Power and Storage record).
final class SleepTimerTests: XCTestCase {
    func testTheFourTimersUnderTheNamesMacOSKeepsThem() {
        XCTAssertEqual(SleepTimer.allCases.map(\.source), ["Battery Power", "AC Power", "Battery Power", "AC Power"])
        XCTAssertEqual(SleepTimer.allCases.map(\.key), ["Display Sleep Timer", "Display Sleep Timer", "System Sleep Timer", "System Sleep Timer"])
    }

    func testFromOneMinuteToThreeHoursOrNever() {
        XCTAssertEqual(SleepTimer.minutes.first, 1)
        XCTAssertEqual(SleepTimer.minutes.dropLast().last, 180)
        XCTAssertEqual(SleepTimer.minutes.last, 0)
        XCTAssertEqual(SleepTimer.text(0), "Never")
        XCTAssertEqual(SleepTimer.text(1), "1 minute")
        XCTAssertEqual(SleepTimer.text(45), "45 minutes")
        XCTAssertEqual(SleepTimer.text(60), "1 hour")
        XCTAssertEqual(SleepTimer.text(180), "3 hours")
        // A value set elsewhere that is not offered still reads.
        XCTAssertEqual(SleepTimer.text(90), "1 hour 30 minutes")
    }

    // The dictionary as this Mac had it on 2026-10-12.
    func testTheTimersAreReadFromMacOSsDictionary() {
        let timers = SleepTimers(preferences: [
            "AC Power": ["Display Sleep Timer": 180, "System Sleep Timer": 0, "Disk Sleep Timer": 10],
            "Battery Power": ["Display Sleep Timer": 10, "System Sleep Timer": 1]
        ])
        XCTAssertEqual(timers.minutes, [.displayOnPowerAdapter: 180, .sleepOnPowerAdapter: 0, .displayOnBattery: 10, .sleepOnBattery: 1])
    }

    func testATimerMacOSDoesNotReportIsMissing() {
        XCTAssertEqual(SleepTimers(preferences: ["AC Power": ["Display Sleep Timer": 5]]).minutes, [.displayOnPowerAdapter: 5])
    }
}

final class KeepAwakePolicyTests: XCTestCase {
    private func effect(on: Bool = true, onBattery: Bool = false, charge: Int? = 80, level: Int = 20, helper: Bool = true) -> KeepAwakeEffect {
        KeepAwakePolicy.effect(on: on, onBattery: onBattery, charge: charge, level: level, helperAvailable: helper)
    }

    func testTheLevelsOfferedAndTheUsualOne() {
        XCTAssertEqual(KeepAwakePolicy.levels, [5, 10, 15, 20, 25, 30, 35, 40, 45, 50])
        XCTAssertEqual(KeepAwakePolicy.defaultLevel, 20)
    }

    func testOffPutsNothingInForce() {
        XCTAssertEqual(effect(on: false), KeepAwakeEffect(preventsIdleSleep: false, holdsStayAwake: false, status: .off))
    }

    func testOnKeepsTheMacAwakeAlsoWithTheLidClosed() {
        XCTAssertEqual(effect(), KeepAwakeEffect(preventsIdleSleep: true, holdsStayAwake: true, status: .on))
        XCTAssertEqual(effect(onBattery: true, charge: 21), KeepAwakeEffect(preventsIdleSleep: true, holdsStayAwake: true, status: .on))
    }

    func testWithoutTheHelperItStopsIdleSleepOnly() {
        XCTAssertEqual(effect(helper: false), KeepAwakeEffect(preventsIdleSleep: true, holdsStayAwake: false, status: .idleOnly))
    }

    func testOnBatteryAtOrBelowTheLevelItPauses() {
        let paused = KeepAwakeEffect(preventsIdleSleep: false, holdsStayAwake: false, status: .paused(charge: 20, level: 20))
        XCTAssertEqual(effect(onBattery: true, charge: 20), paused)
        XCTAssertEqual(effect(onBattery: true, charge: 7, level: 10).status, .paused(charge: 7, level: 10))
        XCTAssertEqual(effect(onBattery: true, charge: 20, helper: false).status, .paused(charge: 20, level: 20))
    }

    // Q30: it is in force again on the power adapter, whatever the charge.
    func testOnThePowerAdapterTheLevelDoesNotCount() {
        XCTAssertEqual(effect(onBattery: false, charge: 3).status, .on)
    }

    func testWithoutAChargeToReadItStaysInForce() {
        XCTAssertEqual(effect(onBattery: true, charge: nil).status, .on)
    }

    func testEveryStatusSaysWhatHolds() {
        XCTAssertEqual(KeepAwakePolicy.note(.off), "The Mac sleeps as its timers say.")
        XCTAssertEqual(KeepAwakePolicy.note(.on), "The Mac stays awake, also with the lid closed. The display still turns off.")
        XCTAssertEqual(KeepAwakePolicy.note(.idleOnly),
                       "The Mac does not sleep by itself. Closing the lid still sleeps it: that needs the toolkit helper.")
        XCTAssertEqual(KeepAwakePolicy.note(.paused(charge: 18, level: 20)),
                       "Paused at 18% on battery (level 20%). In force again on the power adapter.")
    }
}

// macOS as the helper sees it, with what was asked of it.
private final class FakePower: PowerSystem {
    var disabled = false
    // macOS refuses every change.
    var failsToSet = false
    // macOS refuses to set these values only.
    var refuses: Set<Bool> = []
    // The change goes through and cannot be confirmed.
    var throwsAfterWriting = false
    var failsToRead = false
    private(set) var timersSet: [String] = []
    private(set) var writes: [Bool] = []

    func sleepDisabled() throws -> Bool {
        if failsToRead { throw ToolkitHelperError("cannot read") }
        return disabled
    }

    func setSleepDisabled(_ disabled: Bool) throws {
        if failsToSet || refuses.contains(disabled) { throw ToolkitHelperError("macOS refused") }
        writes.append(disabled)
        self.disabled = disabled
        if throwsAfterWriting, disabled { throw ToolkitHelperError("does not read as it was set") }
    }

    func setTimer(_ timer: SleepTimer, minutes: Int) throws {
        if failsToSet { throw ToolkitHelperError("macOS refused") }
        timersSet.append("\(timer.rawValue)=\(minutes)")
    }
}

private final class FakeJournal: StayAwakeJournal {
    var set = false
    var failsToSave = false

    func load() -> Bool { set }

    func save(_ set: Bool) throws {
        if failsToSave { throw ToolkitHelperError("disk full") }
        self.set = set
    }
}

final class ToolkitHelperStateTests: XCTestCase {
    // Seen on 2026-10-12 after the first installation: a helper that was
    // never registered reads as not found, and the page offered no Set up.
    func testAHelperNeverRegisteredCanBeSetUpWhenTheAppHoldsIt() {
        XCTAssertEqual(ToolkitHelperState.reading(.notFound, signed: true, bundled: true), .notSetUp)
        XCTAssertEqual(ToolkitHelperState.reading(.notFound, signed: true, bundled: false),
                       .unavailable("This copy of MacHelm holds no toolkit helper."))
    }

    func testTheHelpersStateFollowsItsRegistration() {
        XCTAssertEqual(ToolkitHelperState.reading(.notRegistered, signed: true, bundled: true), .notSetUp)
        XCTAssertEqual(ToolkitHelperState.reading(.requiresApproval, signed: true, bundled: true), .needsApproval)
        XCTAssertEqual(ToolkitHelperState.reading(.enabled, signed: true, bundled: true), .ready)
        XCTAssertEqual(ToolkitHelperState.reading(.enabled, signed: false, bundled: true),
                       .unavailable("This build is not signed by an Apple team, so it has no toolkit helper."))
    }
}

final class ToolkitHelperControllerTests: XCTestCase {
    private func helper(_ power: FakePower, _ journal: FakeJournal = FakeJournal()) -> ToolkitHelperController {
        ToolkitHelperController(power: power, journal: journal, remover: RootRemover(roots: []))
    }

    // MARK: Stay-awake

    func testAHoldSetsSleepDisabledAndARelaseClearsIt() {
        let power = FakePower(), journal = FakeJournal()
        let helper = helper(power, journal)
        XCTAssertEqual(helper.hold(true, client: 1), ToolkitHelperReply(stayAwakeHeld: true, sleepDisabled: true))
        XCTAssertTrue(power.disabled)
        XCTAssertTrue(journal.set)
        XCTAssertFalse(helper.isIdle)

        XCTAssertEqual(helper.hold(false, client: 1), ToolkitHelperReply(stayAwakeHeld: false, sleepDisabled: false))
        XCTAssertFalse(power.disabled)
        XCTAssertFalse(journal.set)
        XCTAssertTrue(helper.isIdle)
    }

    func testAHoldAskedTwiceIsSetOnce() {
        let power = FakePower()
        let helper = helper(power)
        _ = helper.hold(true, client: 1)
        XCTAssertEqual(helper.hold(true, client: 1).stayAwakeHeld, true)
        XCTAssertEqual(power.writes, [true])
    }

    // Q33: Keep Awake must not stay set after MacHelm is gone.
    func testWhenTheClientIsGoneTheHoldIsCleared() {
        let power = FakePower(), journal = FakeJournal()
        let helper = helper(power, journal)
        _ = helper.hold(true, client: 1)
        helper.clientGone(1)
        XCTAssertFalse(power.disabled)
        XCTAssertFalse(journal.set)
        XCTAssertTrue(helper.isIdle)
    }

    func testAnotherConnectionGoingDoesNotClearTheHold() {
        let power = FakePower()
        let helper = helper(power)
        _ = helper.hold(true, client: 1)
        helper.clientGone(2)
        XCTAssertTrue(power.disabled)
        XCTAssertFalse(helper.isIdle)
    }

    func testAHoldLeftByARunThatEndedWithoutReleasingIsClearedAtTheNextStart() {
        let power = FakePower(), journal = FakeJournal()
        power.disabled = true
        journal.set = true
        helper(power, journal).start()
        XCTAssertFalse(power.disabled)
        XCTAssertFalse(journal.set)
    }

    func testSleepDisabledThatTheHelperDidNotSetIsLeftAlone() {
        // The owner ran `pmset disablesleep 1` themselves.
        let power = FakePower(), journal = FakeJournal()
        power.disabled = true
        let helper = helper(power, journal)
        helper.start()
        XCTAssertTrue(power.disabled)

        XCTAssertEqual(helper.hold(true, client: 1), ToolkitHelperReply(stayAwakeHeld: true, sleepDisabled: true))
        XCTAssertFalse(journal.set)
        _ = helper.hold(false, client: 1)
        XCTAssertTrue(power.disabled)
        XCTAssertEqual(power.writes, [])
    }

    func testAHoldThatMacOSRefusesIsNotHeld() {
        let power = FakePower(), journal = FakeJournal()
        power.refuses = [true]
        let reply = helper(power, journal).hold(true, client: 1)
        XCTAssertFalse(reply.stayAwakeHeld)
        XCTAssertEqual(reply.error, "macOS refused")
        XCTAssertFalse(journal.set)
    }

    // The review's finding: the change went through and its reading back
    // failed. The setting is taken back, so that nothing is left set off the record.
    func testAHoldThatCannotBeConfirmedIsTakenBack() {
        let power = FakePower(), journal = FakeJournal()
        power.throwsAfterWriting = true
        let helper = helper(power, journal)
        let reply = helper.hold(true, client: 1)
        XCTAssertFalse(reply.stayAwakeHeld)
        XCTAssertEqual(reply.error, "does not read as it was set")
        XCTAssertFalse(power.disabled)
        XCTAssertFalse(journal.set)
        XCTAssertTrue(helper.isIdle)
    }

    func testAHoldThatCanNeitherBeConfirmedNorTakenBackStaysOnRecord() {
        let power = FakePower(), journal = FakeJournal()
        power.throwsAfterWriting = true
        power.refuses = [false]
        let helper = helper(power, journal)
        XCTAssertFalse(helper.hold(true, client: 1).stayAwakeHeld)
        XCTAssertTrue(power.disabled)
        // The next start, or the helper's stopping, clears it.
        XCTAssertTrue(journal.set)
        power.refuses = []
        helper.stopping()
        XCTAssertFalse(power.disabled)
        XCTAssertFalse(journal.set)
    }

    // The review's first critical finding. launchd stops the helper with the
    // terminate signal, as when the owner turns MacHelm off under Login
    // Items & Extensions; nothing would start it again to clear what it set.
    func testWhenTheHelperIsStoppedTheHoldIsCleared() {
        let power = FakePower(), journal = FakeJournal()
        let helper = helper(power, journal)
        _ = helper.hold(true, client: 1)
        helper.stopping()
        XCTAssertFalse(power.disabled)
        XCTAssertFalse(journal.set)
        XCTAssertTrue(helper.isIdle)
    }

    func testStoppingLeavesASettingTheHelperDidNotMake() {
        let power = FakePower(), journal = FakeJournal()
        power.disabled = true
        let helper = helper(power, journal)
        _ = helper.hold(true, client: 1)
        helper.stopping()
        XCTAssertTrue(power.disabled)
        XCTAssertEqual(power.writes, [])
    }

    func testWithoutAJournalNothingIsSet() {
        // What could not be written down could not be cleared after a crash.
        let power = FakePower(), journal = FakeJournal()
        journal.failsToSave = true
        let reply = helper(power, journal).hold(true, client: 1)
        XCTAssertFalse(reply.stayAwakeHeld)
        XCTAssertEqual(reply.error, "disk full")
        XCTAssertEqual(power.writes, [])
    }

    func testAReleaseThatMacOSRefusesStaysOnRecord() {
        let power = FakePower(), journal = FakeJournal()
        let helper = helper(power, journal)
        _ = helper.hold(true, client: 1)
        power.refuses = [false]
        let reply = helper.hold(false, client: 1)
        XCTAssertEqual(reply.error, "macOS refused")
        XCTAssertTrue(reply.stayAwakeHeld)
        // The next start tries again.
        XCTAssertTrue(journal.set)
    }

    func testTheStateSaysWhatIsHeldAndWhatMacOSSays() {
        let power = FakePower()
        let helper = helper(power)
        XCTAssertEqual(helper.state(), ToolkitHelperReply(stayAwakeHeld: false, sleepDisabled: false))
        _ = helper.hold(true, client: 1)
        XCTAssertEqual(helper.state(), ToolkitHelperReply(stayAwakeHeld: true, sleepDisabled: true))
        power.failsToRead = true
        XCTAssertNil(helper.state().sleepDisabled)
    }

    // MARK: Sleep timers

    func testATimerIsWrittenWithTheValueChosen() {
        let power = FakePower()
        let helper = helper(power)
        XCTAssertNil(helper.setTimer("displayOnBattery", minutes: 10).error)
        XCTAssertNil(helper.setTimer("sleepOnPowerAdapter", minutes: 0).error)
        XCTAssertEqual(power.timersSet, ["displayOnBattery=10", "sleepOnPowerAdapter=0"])
    }

    func testATimerOrAValueThatIsNotOfferedIsRefusedAndNothingIsWritten() {
        let power = FakePower()
        let helper = helper(power)
        XCTAssertNotNil(helper.setTimer("hibernatemode", minutes: 10).error)
        XCTAssertNotNil(helper.setTimer("displayOnBattery", minutes: 7).error)
        XCTAssertNotNil(helper.setTimer("displayOnBattery", minutes: -1).error)
        XCTAssertNotNil(helper.setTimer("displayOnBattery", minutes: 100_000).error)
        XCTAssertEqual(power.timersSet, [])
    }

    func testATimerMacOSRefusesIsReported() {
        let power = FakePower()
        power.failsToSet = true
        XCTAssertEqual(helper(power).setTimer("displayOnBattery", minutes: 10).error, "macOS refused")
    }
}

// The removal of a root target (Q25, Q28), on real folders made for the test.
final class RootRemoverTests: XCTestCase {
    private var base = ""
    private var root = ""
    private var other = ""

    override func setUpWithError() throws {
        // The real path: the temporary folder is reached through a link, and
        // Foundation's own resolving leaves that link in.
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { return XCTFail("no temporary folder") }
        defer { free(resolved) }
        base = String(cString: resolved) + "/root-remover-\(UUID().uuidString)"
        root = base + "/dyld"
        other = base + "/elsewhere"
        for path in [root + "/25G83/sub", root + "/keep", other + "/victim"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/25G83/sub/cache.bin"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/a-file"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    private var remover: RootRemover { RootRemover(roots: [.init(root, depth: 1)]) }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    // A simulator's dyld cache sits under the folder of the macOS build it was
    // made for, so the folder is cleaned one level deeper as well. It is the
    // only folder: nothing the app can ask for lies anywhere else (L9).
    func testTheOneFolderOfADR0003() {
        XCTAssertEqual(RootRemover.roots, [.init("/Library/Developer/CoreSimulator/Caches/dyld", depth: 2)])
    }

    func testAFolderCleanedTwoLevelsDeepTakesADirectoryAtEitherLevelAndNoDeeper() throws {
        let deep = RootRemover(roots: [.init(root, depth: 2)])
        try FileManager.default.createDirectory(atPath: root + "/25G83/sub/deeper", withIntermediateDirectories: true)
        XCTAssertThrowsError(try deep.remove(root + "/25G83/sub/deeper"))
        XCTAssertTrue(exists(root + "/25G83/sub/deeper"))
        try deep.remove(root + "/25G83/sub")
        XCTAssertFalse(exists(root + "/25G83/sub"))
        XCTAssertTrue(exists(root + "/25G83"))
        try deep.remove(root + "/25G83")
        XCTAssertFalse(exists(root + "/25G83"))
        XCTAssertThrowsError(try deep.remove(root))
        XCTAssertTrue(exists(root))
    }

    func testTwoLevelsDeepThePathMayNotPassThroughALink() throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: other)
        XCTAssertThrowsError(try RootRemover(roots: [.init(root, depth: 2)]).remove(root + "/link/victim"))
        XCTAssertTrue(exists(other + "/victim"))
    }

    func testADirectoryDirectlyInsideARootIsRemovedWithWhatItHolds() throws {
        try remover.remove(root + "/25G83")
        XCTAssertFalse(exists(root + "/25G83"))
        XCTAssertTrue(exists(root + "/keep"))
        XCTAssertTrue(exists(root))
    }

    func testAnythingElseIsRefusedAndNothingIsRemoved() {
        let refused = [
            other + "/victim",                    // outside the roots
            root,                                 // a root itself
            root + "/25G83/sub",                  // deeper than directly inside
            root + "/../elsewhere/victim",        // out through the parent
            root + "/25G83/../keep",
            root + "/./25G83",
            "dyld/25G83",                         // not from the top
            root + "/missing",
            root + "/a-file",                     // not a directory
            root + "/",
            ""
        ]
        for path in refused {
            XCTAssertThrowsError(try remover.remove(path), path)
        }
        for path in [other + "/victim", root + "/25G83/sub/cache.bin", root + "/keep", root + "/a-file"] {
            XCTAssertTrue(exists(path), path)
        }
    }

    func testALinkIsRefusedAndWhatItPointsAtStays() throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: other + "/victim")
        XCTAssertThrowsError(try remover.remove(root + "/link"))
        XCTAssertTrue(exists(other + "/victim"))
        XCTAssertTrue(exists(root + "/link"))
    }

    func testARootReachedThroughALinkIsNotARoot() throws {
        try FileManager.default.createSymbolicLink(atPath: base + "/alias", withDestinationPath: root)
        XCTAssertThrowsError(try RootRemover(roots: [.init(base + "/alias", depth: 1)]).remove(base + "/alias/25G83"))
        XCTAssertTrue(exists(root + "/25G83"))
    }

    func testALinkInsideTheDirectoryIsRemovedAsALink() throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/25G83/out", withDestinationPath: other + "/victim")
        try remover.remove(root + "/25G83")
        XCTAssertFalse(exists(root + "/25G83"))
        XCTAssertTrue(exists(other + "/victim"))
    }

    func testTheHelperAnswersARemovalWithoutAnErrorOrWithTheReason() {
        let helper = ToolkitHelperController(power: FakePower(), journal: FakeJournal(), remover: remover)
        XCTAssertNotNil(helper.remove(path: other + "/victim").error)
        XCTAssertTrue(exists(other + "/victim"))
        XCTAssertNil(helper.remove(path: root + "/25G83").error)
        XCTAssertFalse(exists(root + "/25G83"))
    }
}
