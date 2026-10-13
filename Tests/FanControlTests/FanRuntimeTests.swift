import XCTest
@testable import FanControlCore
@testable import FanControlHardware
@testable import FanControlRuntime

private final class TestClock {
    private let lock = NSLock()
    private var value: Double = 0
    private let realTime: Bool
    init(realTime: Bool = false) { self.realTime = realTime }
    var now: Double {
        get {
            if realTime { return ProcessInfo.processInfo.systemUptime }
            lock.lock(); defer { lock.unlock() }; return value
        }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private final class MemoryJournal: FanRecoveryPersistence {
    var record: FanRecoveryRecord?
    var saves: [FanRecoveryRecord] = []
    var removeCount = 0
    var failSave = false
    func load() throws -> FanRecoveryRecord? { record }
    func save(_ record: FanRecoveryRecord) throws {
        if failSave { throw FanControlError.ownership("Injected journal failure") }
        try record.validate()
        saves.append(record); self.record = record
    }
    func remove() throws { removeCount += 1; record = nil }
}

private final class FakeFans: FanHardware {
    var capabilities = FanPolicyTests.capabilities
    let clock: TestClock
    var temperature: Double = 75
    var cpuMaximum: Double?
    var gpu: Double = 40
    var observation = FanPolicyTests.frame(75).controlObservation
    var operations: [FanOperation] = []
    var failOperation: FanOperation?
    var ignoreOperation: FanOperation?
    var invalidTelemetry = false
    var temperatureOverride: [String: Double]?
    var onPerform: ((FanOperation) -> Void)?
    var failDirectMode = false
    var blockNextRead: (() -> Void)?
    var captureTime: Double?
    // The next frames, this many, are otherwise valid with an out-of-range TCMz.
    var invalidMaximumReads = 0
    static let invalidMaximum = 255.97

    init(clock: TestClock) { self.clock = clock }
    func discover() throws -> FanCapabilities { capabilities }
    func read(_ capabilities: FanCapabilities) throws -> FanSnapshot {
        if let block = blockNextRead { blockNextRead = nil; block() }
        if invalidTelemetry { throw FanControlError.invalid("Required CPU sensor disappeared") }
        var temperatures = temperatureOverride ?? FanPolicyTests.frame(temperature, gpu: gpu, cpuMaximum: cpuMaximum).temperatures
        if invalidMaximumReads > 0 { invalidMaximumReads -= 1; temperatures["TCMz"] = Self.invalidMaximum }
        return FanSnapshot(capturedAt: captureTime ?? clock.now, temperatures: temperatures, fans: observation.fans,
                           thermalPressure: .nominal, globalUnlock: observation.globalUnlock)
    }
    func readControlState(_ capabilities: FanCapabilities) throws -> FanControlObservation {
        FanControlObservation(capturedAt: clock.now, fans: observation.fans, globalUnlock: observation.globalUnlock)
    }
    func perform(_ operation: FanOperation, capabilities: FanCapabilities, cancelled: () -> Bool) throws {
        guard !cancelled() else { throw FanControlError.cancelled }
        onPerform?(operation)
        guard !cancelled() else { throw FanControlError.cancelled }
        if operation == failOperation { throw FanControlError.hardware("Injected write failure") }
        if failDirectMode, case .mode(_, true) = operation, observation.globalUnlock == 0 {
            throw FanControlError.hardware("Direct mode unavailable")
        }
        operations.append(operation)
        if ignoreOperation == operation { return }
        switch operation {
        case .mode(let id, let manual): observation.fans[id].mode = manual ? 1 : 0
        case .target(let id, let rpm): observation.fans[id].targetRPM = rpm
        case .globalUnlock(let enabled): observation.globalUnlock = enabled ? 1 : 0
        }
    }
}

final class FanRuntimeTests: XCTestCase {
    private let boot = UUID().uuidString
    private let generation = UUID().uuidString

    private func actuator(_ hardware: FakeFans, journal: MemoryJournal) throws -> FanActuator {
        try FanActuator(hardware: hardware, persistence: journal, bootID: boot,
                        serviceGeneration: generation, artifactIdentity: "test-artifact")
    }

    // A begin that waits for an entry frame advances the test clock instead
    // of sleeping.
    private func controller(_ hardware: FakeFans, journal: MemoryJournal,
                            conflict: @escaping () -> String? = { nil },
                            entryFramePause: ((TimeInterval) -> Void)? = nil) throws -> FanHelperController {
        try FanHelperController(hardware: hardware, persistence: journal, bootID: boot,
                                artifactIdentity: "test-artifact", conflict: conflict,
                                clock: { hardware.clock.now }, startTimers: false,
                                entryFramePause: entryFramePause ?? { hardware.clock.now += $0 })
    }

    private func begin(_ controller: FanHelperController, owner: String = "owner", profile: FanProfile = .standard) -> FanStatus {
        let done = expectation(description: "begin")
        var result = FanStatus(serviceGeneration: "none")
        controller.begin(owner: owner, profile: profile) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result
    }
    private func poll(_ controller: FanHelperController) {
        let done = expectation(description: "poll")
        controller.poll { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
    private static let appStop = "Fan Control was turned off by the app."
    private func stop(_ controller: FanHelperController, owner: String = "owner") -> FanStatus {
        let done = expectation(description: "stop")
        var result = FanStatus(serviceGeneration: "none")
        controller.stop(owner: owner, reason: Self.appStop) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result
    }
    // One observed idle poll that fails, then one that reads a healthy frame.
    private func idleFaultThenHealthyFrame(_ controller: FanHelperController,
                                           _ hardware: FakeFans) -> (fault: FanStatus, after: FanStatus) {
        hardware.invalidTelemetry = true; hardware.clock.now += 0.25
        _ = controller.status(observe: true)
        poll(controller)
        let fault = controller.status(observe: false)
        hardware.invalidTelemetry = false; hardware.clock.now += 0.25
        poll(controller)
        return (fault, controller.status(observe: false))
    }

    func testLeaseBindingAndExactExpiryDeadlines() throws {
        let gate = FanSafetyGate()
        let session = try gate.begin(owner: "first", now: 0)
        XCTAssertThrowsError(try gate.begin(owner: "second", now: 0))
        XCTAssertFalse(gate.renew(owner: "second", session: session, now: 1))
        XCTAssertFalse(gate.renew(owner: "first", session: UUID().uuidString, now: 1))
        gate.fresh(at: 2, now: 2)
        XCTAssertTrue(gate.renew(owner: "first", session: session, now: 2))
        XCTAssertNil(gate.check(now: 5.99).reason)
        XCTAssertTrue(gate.check(now: 6).reason!.contains("four seconds"))
        XCTAssertFalse(gate.renew(owner: "first", session: session, now: 6))
        gate.finish()
        let next = try gate.begin(owner: "first", now: 10)
        for time in [11.0, 12, 13, 14] { gate.fresh(at: time, now: time) }
        XCTAssertFalse(gate.renew(owner: "first", session: next, now: 15))
        XCTAssertTrue(gate.check(now: 15).reason!.contains("five seconds"))
    }

    // H-Q4: a session survives four seconds without a complete usable frame,
    // not three. A frame must still be less than three seconds old to count.
    func testCompleteFrameLimitIsFourSeconds() throws {
        let gate = FanSafetyGate()
        let session = try gate.begin(owner: "owner", now: 0)
        XCTAssertEqual(gate.nextDeadline(now: 0), 4)
        XCTAssertNil(gate.check(now: 3.99).reason)
        gate.fresh(at: 1, now: 3.99)
        XCTAssertTrue(gate.renew(owner: "owner", session: session, now: 3.99))
        XCTAssertEqual(gate.nextDeadline(now: 3.99), 5)
        gate.fresh(at: 1.5, now: 4.5) // Exactly three seconds old: it does not count.
        XCTAssertEqual(gate.nextDeadline(now: 4.5), 5)
        XCTAssertNil(gate.check(now: 4.99).reason)
        XCTAssertEqual(gate.check(now: 5).reason, "No complete fresh sensor snapshot for four seconds.")
    }

    func testProfileRevisionAndDisconnectCancelObsoleteCommands() throws {
        let gate = FanSafetyGate()
        let session = try gate.begin(owner: "owner", now: 0)
        let revision = gate.check(now: 0).generation
        XCTAssertFalse(gate.revise(owner: "other", session: session, now: 0))
        XCTAssertTrue(gate.permits(revision, now: 0))
        XCTAssertTrue(gate.revise(owner: "owner", session: session, now: 0))
        XCTAssertFalse(gate.permits(revision, now: 0))
        let current = gate.check(now: 0).generation
        gate.stop(owner: "other", reason: "wrong owner")
        XCTAssertTrue(gate.permits(current, now: 0))
        gate.stop(owner: "owner", reason: "connection lost")
        XCTAssertFalse(gate.permits(current, now: 0))
    }

    func testDurableIntentPrecedesWriteAndReadbackPrecedesReceipt() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let actuator = try actuator(hardware, journal: journal)
        try actuator.establish(session: UUID().uuidString, capabilities: hardware.capabilities, baseline: hardware.observation)
        hardware.onPerform = { operation in XCTAssertEqual(journal.record?.pending, operation) }
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false })
        XCTAssertNil(journal.record?.pending)
        XCTAssertEqual(journal.record?.acknowledged.fans[0].mode, 1)
        hardware.ignoreOperation = .target(fan: 0, rpm: 4000)
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }))
        XCTAssertNotNil(journal.record?.pending)
        XCTAssertEqual(journal.record?.acknowledged.fans[0].targetRPM, 0)
    }

    func testUnconfirmedManualCommandRetainsOperationAndEffectiveObservations() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let actuator = try actuator(hardware, journal: journal)
        try actuator.establish(session: UUID().uuidString, capabilities: hardware.capabilities, baseline: hardware.observation)
        hardware.ignoreOperation = .mode(fan: 0, manual: true)
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false })) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("not confirmed by readback"))
            XCTAssertTrue(message.contains("\"mode\":{\"fan\":0,\"manual\":true}"))
            XCTAssertTrue(message.contains("before:"))
            XCTAssertTrue(message.contains("after:"))
            XCTAssertTrue(message.contains("\"globalUnlock\":0"))
            XCTAssertTrue(message.contains("\"mode\":0"))
        }
        XCTAssertEqual(hardware.operations, [.mode(fan: 0, manual: true)])
        XCTAssertEqual(journal.record?.pending, .mode(fan: 0, manual: true))
        XCTAssertTrue(journal.record!.acknowledged.isFullyAutomatic)
    }

    func testJournalFailureAndMalformedOperationsCannotMutateHardware() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let actuator = try actuator(hardware, journal: journal)
        try actuator.establish(session: UUID().uuidString, capabilities: hardware.capabilities, baseline: hardware.observation)
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 9000), cancelled: { false }))
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 10, manual: true), cancelled: { false }))
        journal.failSave = true
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }))
        XCTAssertTrue(hardware.operations.isEmpty)
    }

    func testIdleRemovalDoesNotReadOrMutateOtherControllersSettings() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        hardware.observation.fans[0].mode = 1
        let actuator = try actuator(hardware, journal: journal)
        XCTAssertNil(try actuator.restore(conflict: { "Macs Fan Control" }))
        XCTAssertTrue(hardware.operations.isEmpty)
        XCTAssertEqual(hardware.observation.fans[0].mode, 1)
    }

    func testOwnedRestorationWorksWithMissingTemperatureChannel() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let actuator = try actuator(hardware, journal: journal)
        try actuator.establish(session: UUID().uuidString, capabilities: hardware.capabilities, baseline: hardware.observation)
        _ = try actuator.mutate(.globalUnlock(true), cancelled: { false })
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false })
        _ = try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false })
        hardware.invalidTelemetry = true
        XCTAssertTrue(try actuator.restore(conflict: { nil })!.isFullyAutomatic)
        XCTAssertNil(journal.record)
        XCTAssertEqual(hardware.observation.fans[0].targetRPM, 0)
        XCTAssertEqual(hardware.observation.globalUnlock, 0)
    }

    func testUnconfirmedRestoreRetainsRecordAndDoesNotRetry() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let actuator = try actuator(hardware, journal: journal)
        try actuator.establish(session: UUID().uuidString, capabilities: hardware.capabilities, baseline: hardware.observation)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false })
        hardware.failOperation = .mode(fan: 0, manual: false)
        XCTAssertThrowsError(try actuator.restore(conflict: { nil }))
        XCTAssertNotNil(journal.record)
        let attempts = hardware.operations
        hardware.failOperation = nil
        XCTAssertThrowsError(try actuator.restore(conflict: { nil }))
        XCTAssertNotNil(journal.record)
        XCTAssertTrue(actuator.requiresExternalRecovery)
        XCTAssertEqual(hardware.operations, attempts)
    }

    func testForeignBootOrArtifactCannotReplayRecovery() throws {
        for changingBoot in [true, false] {
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            let old = try actuator(hardware, journal: journal)
            try old.establish(session: UUID().uuidString, capabilities: hardware.capabilities, baseline: hardware.observation)
            _ = try old.mutate(.mode(fan: 0, manual: true), cancelled: { false })
            let operations = hardware.operations
            let restarted = try FanActuator(hardware: hardware, persistence: journal,
                                            bootID: changingBoot ? UUID().uuidString : boot,
                                            serviceGeneration: UUID().uuidString,
                                            artifactIdentity: changingBoot ? "test-artifact" : "different-artifact")
            XCTAssertThrowsError(try restarted.restore(conflict: { nil }))
            XCTAssertEqual(hardware.operations, operations)
            hardware.observation.fans[0].mode = 0
            XCTAssertTrue(try restarted.restore(conflict: { nil })!.isFullyAutomatic)
            XCTAssertNil(journal.record)
        }
    }

    func testSameBootRestartQuarantinesRecordedPendingWrite() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let old = try actuator(hardware, journal: journal)
        try old.establish(session: UUID().uuidString, capabilities: hardware.capabilities, baseline: hardware.observation)
        // Crash after the durable intent and before its hardware receipt.
        journal.record!.pending = .mode(fan: 0, manual: true)
        hardware.observation.fans[0].mode = 1
        let restarted = try actuator(hardware, journal: journal)
        XCTAssertThrowsError(try restarted.restore(conflict: { nil }))
        XCTAssertNotNil(journal.record)
        XCTAssertTrue(restarted.requiresExternalRecovery)
        XCTAssertTrue(hardware.operations.isEmpty)
    }

    func testConflictsAndUnexpectedTargetChangesStopWithoutFighting() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let actuator = try actuator(hardware, journal: journal)
        try actuator.establish(session: UUID().uuidString, capabilities: hardware.capabilities, baseline: hardware.observation)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false })
        _ = try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false })
        let operations = hardware.operations
        XCTAssertThrowsError(try actuator.restore(conflict: { "Macs Fan Control" }))
        XCTAssertEqual(hardware.operations, operations)
        hardware.observation.fans[0].targetRPM = 4500
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }))
        XCTAssertThrowsError(try actuator.restore(conflict: { nil }))
        XCTAssertEqual(hardware.operations, operations)
    }

    func testBlockedActivationAndSecondOwnerLeaveHardwareAndOwnerIntact() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let blocked = try controller(hardware, journal: journal, conflict: { "Macs Fan Control" })
        XCTAssertNil(begin(blocked).sessionID)
        XCTAssertTrue(hardware.operations.isEmpty)
        let normal = try controller(hardware, journal: journal)
        let first = begin(normal)
        let operations = hardware.operations
        let second = begin(normal, owner: "second")
        XCTAssertNotNil(second.requestError)
        XCTAssertEqual(second.sessionID, first.sessionID)
        XCTAssertEqual(hardware.operations, operations)
        XCTAssertTrue(normal.renew(owner: "owner", session: first.sessionID!))
    }

    func testUnexplainedManualBaselineAndMalformedProfileBlockActivation() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        hardware.observation.fans[0].mode = 1
        let controller = try controller(hardware, journal: journal)
        XCTAssertNil(begin(controller).sessionID)
        XCTAssertTrue(hardware.operations.isEmpty)
        let invalid = begin(controller, profile: FanProfile(start: 70, maximum: 71))
        XCTAssertNotNil(invalid.requestError)
        XCTAssertTrue(hardware.operations.isEmpty)
    }

    func testPartialWriteFailureHoldsJournalAndDisarmsAllFurtherWrites() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        hardware.failOperation = .target(fan: 1, rpm: 1500 + 4000 / 3)
        let controller = try controller(hardware, journal: journal)
        let result = begin(controller)
        XCTAssertNil(result.sessionID)
        XCTAssertFalse(hardware.observation.isFullyAutomatic)
        XCTAssertNotNil(journal.record)
        XCTAssertFalse(result.releaseVerified)
        XCTAssertFalse(result.safeToUnregister)
        XCTAssertTrue(result.externalRecoveryRequired)
        XCTAssertEqual(result.mode, .externalRecoveryRequired)
        let attempts = hardware.operations
        poll(controller)
        XCTAssertEqual(hardware.operations, attempts)
    }

    func testMissingTelemetryReleasesImmediatelyAndRequiresReEnable() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let controller = try controller(hardware, journal: journal)
        XCTAssertNotNil(begin(controller).sessionID)
        hardware.invalidTelemetry = true; hardware.clock.now = 1
        poll(controller)
        XCTAssertNil(controller.status(observe: false).sessionID)
        XCTAssertTrue(controller.status(observe: false).releaseVerified)
        XCTAssertTrue(hardware.observation.isFullyAutomatic)
        let activeFault = controller.status(observe: false).reason
        let releasedOperations = hardware.operations
        XCTAssertEqual(controller.status(observe: false).mode, .paused)
        hardware.invalidTelemetry = false; hardware.clock.now = 2
        _ = controller.status(observe: true)
        poll(controller)
        let healthy = controller.status(observe: false)
        XCTAssertNotNil(healthy.snapshot)
        XCTAssertNil(healthy.sessionID)
        XCTAssertEqual(healthy.mode, .paused)
        XCTAssertEqual(healthy.reason, activeFault)
        // A later idle failure replaces the visible paused status for as long
        // as it lasts. The next good frame shows the fault that ended control
        // again (F-Q4); it does not resume the session.
        hardware.invalidTelemetry = true; hardware.clock.now = 2.25
        poll(controller)
        XCTAssertEqual(controller.status(observe: false).mode, .unavailable)
        hardware.invalidTelemetry = false; hardware.clock.now = 2.5
        poll(controller)
        let afterIdleFault = controller.status(observe: false)
        XCTAssertNotNil(afterIdleFault.snapshot)
        XCTAssertEqual(afterIdleFault.mode, .paused)
        XCTAssertEqual(afterIdleFault.reason, activeFault)
        XCTAssertNil(afterIdleFault.sessionID)
        XCTAssertEqual(hardware.operations, releasedOperations)
        hardware.clock.now = 2.75
        XCTAssertNotNil(begin(controller).sessionID)
    }

    // L-Q1 to L-Q3: after the app's own stop an idle fault label is temporary.
    // A healthy idle frame returns it to what the stop left, and writes nothing.
    func testIdleFaultLabelReturnsToPausedAfterTheAppsStop() throws {
        for withSession in [true, false] {
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            let controller = try controller(hardware, journal: journal)
            if withSession { XCTAssertNotNil(begin(controller).sessionID) }
            let stopped = stop(controller)
            XCTAssertEqual(stopped.mode, .paused); XCTAssertEqual(stopped.reason, Self.appStop)
            XCTAssertTrue(hardware.observation.isFullyAutomatic)
            let released = hardware.operations, saves = journal.saves.count, removes = journal.removeCount
            let log = stopped.diagnostics
            for _ in 0..<2 {
                let (fault, after) = idleFaultThenHealthyFrame(controller, hardware)
                XCTAssertEqual(fault.mode, .unavailable); XCTAssertNotEqual(fault.reason, Self.appStop)
                XCTAssertEqual(after.mode, .paused); XCTAssertEqual(after.reason, Self.appStop)
                XCTAssertNotNil(after.snapshot); XCTAssertNil(after.sessionID)
                XCTAssertFalse(after.ownsOverride); XCTAssertFalse(after.externalRecoveryRequired)
            }
            // F-Q5: the flips are counted in status and write no log line.
            let flipped = controller.status(observe: false)
            XCTAssertEqual(flipped.diagnostics, log)
            XCTAssertEqual(flipped.idleFaults?.count, 2)
            XCTAssertEqual(flipped.idleFaults?.lastReason, "Required CPU sensor disappeared")
            XCTAssertEqual(hardware.operations, released)
            XCTAssertNil(journal.record)
            XCTAssertEqual(journal.saves.count, saves); XCTAssertEqual(journal.removeCount, removes)
            XCTAssertNotNil(begin(controller).sessionID)
        }
    }

    // Review finding 1. The app's stop can land while a control cycle or a
    // begin is running. The cancelled cycle is that stop, not a fault, so the
    // label still returns afterwards.
    func testTheAppsStopDuringACycleOrABeginIsStillAnOrdinaryStop() throws {
        for duringBegin in [false, true] {
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            let controller = try controller(hardware, journal: journal)
            var stopped = FanStatus(serviceGeneration: "none")
            let replied = expectation(description: "stop reply")
            let stopDuringTheRead = {
                controller.stop(owner: "owner", reason: Self.appStop) { stopped = $0; replied.fulfill() }
            }
            if duringBegin {
                hardware.blockNextRead = stopDuringTheRead
                XCTAssertNil(begin(controller).sessionID)
            } else {
                XCTAssertNotNil(begin(controller).sessionID)
                hardware.blockNextRead = stopDuringTheRead
                hardware.clock.now = 1
                poll(controller)
            }
            wait(for: [replied], timeout: 2)
            XCTAssertEqual(stopped.mode, .paused); XCTAssertEqual(stopped.reason, Self.appStop)
            XCTAssertNil(stopped.sessionID); XCTAssertFalse(stopped.externalRecoveryRequired)
            XCTAssertTrue(hardware.observation.isFullyAutomatic); XCTAssertNil(journal.record)
            XCTAssertTrue(stopped.diagnostics.contains { $0.contains("Control stopped: ") })
            let (fault, after) = idleFaultThenHealthyFrame(controller, hardware)
            XCTAssertEqual(fault.mode, .unavailable)
            XCTAssertEqual(after.mode, .paused, "during begin: \(duringBegin)")
            XCTAssertEqual(after.reason, Self.appStop, "during begin: \(duringBegin)")
            XCTAssertNotNil(begin(controller).sessionID)
        }
    }

    // L-Q2b: a sleep that finds Fan Control off is not an ending. The label
    // and the recorded ending stay as they were, and nothing is written.
    func testASleepWhileFanControlIsOffLeavesTheLabelAsItWas() throws {
        for stopped in [false, true] {
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            let controller = try controller(hardware, journal: journal)
            if stopped {
                XCTAssertNotNil(begin(controller).sessionID)
                XCTAssertEqual(stop(controller).reason, Self.appStop)
            }
            let before = controller.status(observe: false)
            XCTAssertEqual(before.mode, stopped ? .paused : .off)
            let operations = hardware.operations, saves = journal.saves.count
            for _ in 0..<2 {
                let slept = expectation(description: "sleep")
                controller.systemWillSleep { slept.fulfill() }
                wait(for: [slept], timeout: 2)
                controller.systemDidWake()
                let woken = controller.status(observe: false)
                XCTAssertEqual(woken.mode, before.mode); XCTAssertEqual(woken.reason, before.reason)
                let (fault, after) = idleFaultThenHealthyFrame(controller, hardware)
                XCTAssertEqual(fault.mode, .unavailable)
                XCTAssertEqual(after.mode, before.mode); XCTAssertEqual(after.reason, before.reason)
                XCTAssertNotNil(after.snapshot)
            }
            XCTAssertEqual(hardware.operations, operations); XCTAssertEqual(journal.saves.count, saves)
            XCTAssertNil(journal.record)
            XCTAssertNotNil(begin(controller).sessionID)
        }
    }

    // F-Q4: one rule for every ending. A good idle frame returns an idle fault
    // label to paused with the reason control ended. Turning Fan Control on
    // again stays explicit, and returning the label writes nothing.
    func testIdleFaultLabelReturnsToPausedWithTheReasonControlEnded() throws {
        let endings: [(String, String, (FanHelperController, FakeFans) -> Void)] = [
            ("a fault, then the app's stop", Self.appStop, { controller, hardware in
                hardware.invalidTelemetry = true; hardware.clock.now = 1
                self.poll(controller)
                hardware.invalidTelemetry = false
                _ = self.stop(controller)
            }),
            ("an expired lease", "The app lease expired after five seconds.", { controller, hardware in
                hardware.clock.now = 6
                self.poll(controller)
            }),
            ("an expired lease already recorded when the app's stop arrives", Self.appStop, { controller, hardware in
                hardware.clock.now = 6
                _ = controller.safety.check(now: 6)
                _ = self.stop(controller)
            }),
            ("no complete frame for four seconds", "No complete fresh sensor snapshot for four seconds.", { controller, hardware in
                hardware.clock.now = 4
                self.poll(controller)
            }),
            ("a lost app connection", "The authenticated app connection was lost.", { controller, _ in
                controller.disconnected(owner: "owner")
                self.poll(controller)
            }),
            ("a lost app connection during a running cycle", "The authenticated app connection was lost.", { controller, hardware in
                hardware.blockNextRead = { controller.disconnected(owner: "owner") }
                hardware.clock.now = 1
                self.poll(controller)
            }),
            ("system sleep during a session", "System sleep requested.", { controller, _ in
                let slept = self.expectation(description: "sleep")
                controller.systemWillSleep { slept.fulfill() }
                self.wait(for: [slept], timeout: 2)
                controller.systemDidWake()
            }),
            ("a helper removal request", "Helper removal requested.", { controller, _ in
                let prepared = self.expectation(description: "removal")
                controller.prepareRemoval(owner: "owner") { _ in prepared.fulfill() }
                self.wait(for: [prepared], timeout: 2)
                controller.disconnected(owner: "owner")
            }),
            ("a failed begin after the app's stop", "Required CPU sensor disappeared", { controller, hardware in
                XCTAssertEqual(self.stop(controller).reason, Self.appStop)
                hardware.invalidTelemetry = true
                XCTAssertNil(self.begin(controller).sessionID)
                hardware.invalidTelemetry = false
            }),
            ("a fault, then a begin that the app's stop cancels", Self.appStop, { controller, hardware in
                hardware.invalidTelemetry = true; hardware.clock.now = 1
                self.poll(controller)
                hardware.invalidTelemetry = false
                hardware.blockNextRead = { controller.stop(owner: "owner", reason: Self.appStop) { _ in } }
                XCTAssertNil(self.begin(controller).sessionID)
                self.poll(controller)
            })
        ]
        for (name, expected, end) in endings {
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            let controller = try controller(hardware, journal: journal)
            XCTAssertNotNil(begin(controller).sessionID, name)
            end(controller, hardware)
            let ended = controller.status(observe: false)
            XCTAssertEqual(ended.mode, .paused, name); XCTAssertEqual(ended.reason, expected, name)
            XCTAssertNil(ended.sessionID, name); XCTAssertTrue(hardware.observation.isFullyAutomatic, name)
            let released = hardware.operations, saves = journal.saves.count, removes = journal.removeCount
            for _ in 0..<2 {
                let (fault, after) = idleFaultThenHealthyFrame(controller, hardware)
                XCTAssertEqual(fault.mode, .unavailable, name)
                XCTAssertEqual(fault.reason, "Required CPU sensor disappeared", name)
                XCTAssertEqual(after.mode, .paused, name); XCTAssertEqual(after.reason, expected, name)
                XCTAssertNotNil(after.snapshot, name); XCTAssertNil(after.sessionID, name)
                XCTAssertFalse(after.ownsOverride, name); XCTAssertFalse(after.externalRecoveryRequired, name)
            }
            XCTAssertEqual(hardware.operations, released, name); XCTAssertNil(journal.record, name)
            XCTAssertEqual(journal.saves.count, saves, name); XCTAssertEqual(journal.removeCount, removes, name)
            XCTAssertNotNil(begin(controller).sessionID, name)
        }
    }

    // F-Q5: a failed idle observation and the label's return write no log
    // line. Status keeps how many there were, the last one's text and its time.
    func testIdleFaultsAreCountedInStatusAndWriteNoLogLine() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let controller = try controller(hardware, journal: journal)
        XCTAssertNotNil(begin(controller).sessionID)
        let stopped = stop(controller)
        XCTAssertEqual(stopped.reason, Self.appStop); XCTAssertNil(stopped.idleFaults)
        for round in 1...3 {
            let (fault, after) = idleFaultThenHealthyFrame(controller, hardware)
            XCTAssertEqual(fault.mode, .unavailable); XCTAssertEqual(after.mode, .paused)
            XCTAssertEqual(fault.idleFaults?.count, round); XCTAssertEqual(after.idleFaults?.count, round)
            XCTAssertEqual(after.idleFaults?.lastReason, "Required CPU sensor disappeared")
            XCTAssertEqual(after.idleFaults?.lastAt, hardware.clock.now - 0.25)
            XCTAssertEqual(fault.diagnostics, stopped.diagnostics, "No line for the fault.")
            XCTAssertEqual(after.diagnostics, stopped.diagnostics, "No line for the label's return.")
        }
        // The count is kept across the next session, and a reply carries it.
        XCTAssertNotNil(begin(controller).sessionID)
        let reply = try JSONDecoder().decode(FanStatus.self, from: controller.status(observe: false).encodedReply())
        XCTAssertEqual(reply.idleFaults?.count, 3)
        XCTAssertEqual(reply.idleFaults?.lastAtUTC.isEmpty, false)
    }

    // H-Q2: at idle an otherwise valid frame with an out-of-range reading is
    // skipped, as inside a session. The last frame and the label are kept,
    // and unavailable is shown only once no usable frame has arrived for the
    // complete-frame limit. Nothing is logged or written.
    func testAnOutOfRangeIdleFrameIsSkippedUntilTheCompleteFrameLimit() throws {
        for stopped in [false, true] {
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            let controller = try controller(hardware, journal: journal)
            hardware.temperature = 60
            if stopped {
                XCTAssertNotNil(begin(controller).sessionID)
                XCTAssertEqual(stop(controller).reason, Self.appStop)
            }
            let label = controller.status(observe: false)
            XCTAssertEqual(label.mode, stopped ? .paused : .off)
            func idle(_ time: Double, invalid: Bool) -> FanStatus {
                hardware.invalidMaximumReads = invalid ? 1 : 0; hardware.clock.now = time
                _ = controller.status(observe: true)
                poll(controller)
                return controller.status(observe: false)
            }
            let usable = try XCTUnwrap(idle(1, invalid: false).snapshot)
            XCTAssertEqual(usable.capturedAt, 1)
            let operations = hardware.operations, saves = journal.saves.count
            let log = controller.status(observe: false).diagnostics
            // One, two and three invalid frames in a row keep the label.
            for time in [2.0, 3, 4] {
                let skipped = idle(time, invalid: true)
                XCTAssertEqual(skipped.mode, label.mode, "\(time)"); XCTAssertEqual(skipped.reason, label.reason, "\(time)")
                // The last usable frame stays visible until it is three seconds old.
                XCTAssertEqual(skipped.snapshot, time < 4 ? usable : nil, "\(time)")
                XCTAssertEqual(skipped.fanProbe?.observation.capturedAt, time, "The fan state is still read: \(time)")
                XCTAssertEqual(skipped.idleFaults?.count, Int(time) - 1)
                XCTAssertEqual(skipped.idleFaults?.lastReason.contains("\(FakeFans.invalidMaximum)"), true)
                XCTAssertEqual(skipped.idleFaults?.lastAt, time)
                XCTAssertEqual(skipped.diagnostics, log, "No log line: \(time)")
            }
            // Four seconds without a usable frame: unavailable, naming the reading.
            let expired = idle(5, invalid: true)
            XCTAssertEqual(expired.mode, .unavailable); XCTAssertNil(expired.snapshot)
            XCTAssertEqual(expired.reason?.contains("\(FakeFans.invalidMaximum)"), true)
            // The next good frame returns the label.
            let recovered = idle(6, invalid: false)
            XCTAssertEqual(recovered.mode, label.mode); XCTAssertEqual(recovered.reason, label.reason)
            XCTAssertEqual(recovered.snapshot?.capturedAt, 6)
            XCTAssertEqual(recovered.idleFaults?.count, 4); XCTAssertEqual(recovered.diagnostics, log)
            XCTAssertEqual(idle(7, invalid: true).mode, label.mode, "A single invalid frame is skipped again.")
            XCTAssertEqual(hardware.operations, operations); XCTAssertEqual(journal.saves.count, saves)
            XCTAssertNil(journal.record)
            // Any other idle fault still shows at once.
            hardware.invalidTelemetry = true; hardware.clock.now = 8
            poll(controller)
            let other = controller.status(observe: false)
            XCTAssertEqual(other.mode, .unavailable); XCTAssertEqual(other.reason, "Required CPU sensor disappeared")
            hardware.invalidTelemetry = false; hardware.temperature = 75; hardware.clock.now = 9
            XCTAssertNotNil(begin(controller).sessionID)
        }
    }

    func testIdleAvailabilityRecoversWithoutEnablingOrWriting() throws {
        for manual in [false, true] {
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            let controller = try controller(hardware, journal: journal)
            hardware.invalidTelemetry = true
            _ = controller.status(observe: true)
            poll(controller)
            let fault = controller.status(observe: false)
            XCTAssertEqual(fault.mode, .unavailable); XCTAssertEqual(fault.reason, "Required CPU sensor disappeared")
            XCTAssertEqual(fault.idleFaults?.count, 1)
            XCTAssertEqual(fault.idleFaults?.lastReason, "Required CPU sensor disappeared")
            XCTAssertTrue(fault.diagnostics.isEmpty)
            let generation = controller.safety.check(now: 0).generation
            hardware.invalidTelemetry = false; hardware.clock.now = 1
            hardware.cpuMaximum = manual ? 75 : 108
            hardware.gpu = manual ? 40 : 90
            if manual { hardware.observation.fans[0].mode = 1 }
            poll(controller)
            let recovered = controller.status(observe: false)
            XCTAssertEqual(recovered.mode, .off); XCTAssertNil(recovered.reason)
            XCTAssertNotNil(recovered.snapshot)
            XCTAssertNil(recovered.sessionID); XCTAssertFalse(recovered.ownsOverride)
            XCTAssertFalse(recovered.externalRecoveryRequired); XCTAssertTrue(recovered.safeToUnregister)
            XCTAssertFalse(recovered.releaseVerified); XCTAssertTrue(recovered.requestedRPM.isEmpty)
            XCTAssertEqual(recovered.idleFaults, fault.idleFaults)
            XCTAssertTrue(recovered.diagnostics.isEmpty)
            XCTAssertEqual(controller.safety.check(now: 1).generation, generation)
            XCTAssertTrue(hardware.operations.isEmpty)
            XCTAssertNil(journal.record); XCTAssertTrue(journal.saves.isEmpty); XCTAssertEqual(journal.removeCount, 0)
            if manual {
                XCTAssertFalse(try XCTUnwrap(recovered.snapshot).isFullyAutomatic)
                XCTAssertNil(begin(controller).sessionID)
                XCTAssertTrue(hardware.operations.isEmpty)
            }
        }
    }

    func testInvalidOrStaleIdleTelemetryDoesNotClearUnavailable() throws {
        for fault in 0..<8 {
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            let controller = try controller(hardware, journal: journal)
            hardware.invalidTelemetry = true
            _ = controller.status(observe: true)
            poll(controller)
            hardware.invalidTelemetry = false; hardware.clock.now = 1
            var values = FanPolicyTests.frame(75).temperatures
            switch fault {
            case 0: values["TCMz"] = nil
            case 1: values["TCMz"] = .nan
            case 2: values["TCMz"] = .infinity
            case 3: values["TCMz"] = 263.37811279296875
            case 4: values["TCMb"] = 6.7
            case 5: values["Tg0f"] = nil
            case 6: hardware.captureTime = -2 // Exactly three seconds old.
            default: hardware.captureTime = 2 // A future capture is invalid.
            }
            hardware.temperatureOverride = values
            poll(controller)
            let status = controller.status(observe: false)
            XCTAssertEqual(status.mode, .unavailable); XCTAssertNotNil(status.reason)
            XCTAssertNil(status.snapshot); XCTAssertNil(status.sessionID)
            // No usable frame came first, so even the out-of-range frame is not skipped.
            XCTAssertEqual(status.idleFaults?.count, 2)
            XCTAssertTrue(hardware.operations.isEmpty)
            XCTAssertNil(journal.record); XCTAssertTrue(journal.saves.isEmpty); XCTAssertEqual(journal.removeCount, 0)
        }
    }

    func testIdleAvailabilityPreservesPendingRecoveryWithAutomaticFans() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        hardware.ignoreOperation = .mode(fan: 0, manual: true)
        let controller = try controller(hardware, journal: journal)
        let failed = begin(controller)
        XCTAssertTrue(failed.externalRecoveryRequired)
        XCTAssertTrue(hardware.observation.isFullyAutomatic)
        let pending = try XCTUnwrap(journal.record)
        let operations = hardware.operations, saves = journal.saves.count
        _ = controller.status(observe: true)
        hardware.clock.now = 1
        poll(controller)
        let status = controller.status(observe: false)
        XCTAssertEqual(status.mode, .externalRecoveryRequired)
        XCTAssertTrue(status.externalRecoveryRequired); XCTAssertTrue(status.ownsOverride)
        XCTAssertEqual(status.externalRecoveryID, pending.ownerSession)
        XCTAssertTrue(try XCTUnwrap(status.fanProbe).observation.isFullyAutomatic)
        XCTAssertEqual(journal.record, pending); XCTAssertNotNil(pending.pending)
        XCTAssertEqual(hardware.operations, operations); XCTAssertEqual(journal.saves.count, saves)
        XCTAssertEqual(journal.removeCount, 0)
    }

    func testIdleAvailabilityDoesNotPublishOverConcurrentBegin() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let controller = try controller(hardware, journal: journal)
        hardware.invalidTelemetry = true
        _ = controller.status(observe: true)
        poll(controller)
        hardware.invalidTelemetry = false; hardware.temperature = 60; hardware.clock.now = 1
        let blocked = expectation(description: "idle read blocked")
        let readReturned = expectation(description: "idle read completed before queued begin")
        let began = expectation(description: "explicit begin completed")
        let unblock = DispatchSemaphore(value: 0)
        defer { unblock.signal() }
        hardware.blockNextRead = { blocked.fulfill(); _ = unblock.wait(timeout: .now() + 2) }
        controller.poll {
            let status = controller.status(observe: false)
            XCTAssertEqual(status.mode, .unavailable)
            XCTAssertNotNil(status.reason)
            readReturned.fulfill()
        }
        wait(for: [blocked], timeout: 1)
        controller.begin(owner: "new owner", profile: .standard) { status in
            XCTAssertNotNil(status.sessionID); XCTAssertNil(status.reason)
            XCTAssertEqual(status.mode, .automatic)
            began.fulfill()
        }
        XCTAssertNotNil(controller.safety.check(now: 1).session)
        unblock.signal()
        wait(for: [readReturned, began], timeout: 2)
        XCTAssertTrue(hardware.operations.isEmpty)
        XCTAssertNil(journal.record); XCTAssertTrue(journal.saves.isEmpty); XCTAssertEqual(journal.removeCount, 0)
    }

    func testIdleObservationCommitRejectsReservationsAndStaleGenerations() throws {
        for kind in 0..<8 {
            let gate = FanSafetyGate()
            let original = gate.check(now: 0).generation
            var expected = original
            switch kind {
            case 0:
                _ = try gate.begin(owner: "owner", now: 0)
                expected = gate.check(now: 0).generation
            case 1:
                _ = try gate.begin(owner: "owner", now: 0)
                gate.stop(owner: "owner", reason: "active fault")
                expected = gate.check(now: 0).generation
            case 2: XCTAssertTrue(gate.prepareRemoval(owner: "remover"))
            case 3: gate.suspendForSleep()
            case 4: expected = try gate.reserveExternalRecovery(owner: "verifier")
            case 5:
                _ = try gate.begin(owner: "owner", now: 0)
                gate.finish() // No current owner, but the observation's generation is obsolete.
            default: break
            }
            var published = false
            let now = kind == 6 ? Double.nan : (kind == 7 ? -1.0 : 0)
            XCTAssertFalse(gate.commitIdleObservation(generation: expected, clock: { now }) { _ in
                published = true; return true
            })
            XCTAssertFalse(published)
        }
        let idle = FanSafetyGate()
        var published = false
        XCTAssertTrue(idle.commitIdleObservation(generation: 0, clock: { 0 }) { now in
            XCTAssertEqual(now, 0); published = true; return true
        })
        XCTAssertTrue(published)
        XCTAssertNil(idle.check(now: 0).session)
        XCTAssertNotNil(try idle.begin(owner: "owner", now: 0))
    }

    func testWatchdogDetectsExpiryWhileHardwareExecutorIsStalled() throws {
        let clock = TestClock(), journal = MemoryJournal()
        let hardware = FakeFans(clock: clock)
        let controller = try controller(hardware, journal: journal)
        let result = begin(controller)
        XCTAssertNotNil(result.sessionID)
        clock.now = 1
        let blocked = expectation(description: "hardware stalled")
        let recovered = expectation(description: "hardware returned and recovery completed")
        let unblock = DispatchSemaphore(value: 0)
        hardware.blockNextRead = { blocked.fulfill(); _ = unblock.wait(timeout: .now() + 2) }
        controller.poll { recovered.fulfill() }
        wait(for: [blocked], timeout: 1)
        clock.now = 3.99
        controller.checkWatchdog()
        XCTAssertNil(controller.safety.check(now: 3.99).reason)
        XCTAssertEqual(controller.status(observe: false).mode, .custom)
        clock.now = 4
        controller.checkWatchdog()
        XCTAssertEqual(controller.safety.check(now: 4).reason, "No complete fresh sensor snapshot for four seconds.")
        XCTAssertEqual(controller.status(observe: false).mode, .restoring)
        XCTAssertFalse(controller.status(observe: false).releaseVerified)
        XCTAssertFalse(controller.renew(owner: "owner", session: result.sessionID!))
        unblock.signal()
        wait(for: [recovered], timeout: 2)
        poll(controller)
        XCTAssertTrue(controller.status(observe: false).releaseVerified)
        XCTAssertTrue(hardware.observation.isFullyAutomatic)
    }

    func testRejectedDirectModeNeverAuthorizesAnUnlockOrRetry() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        hardware.failDirectMode = true
        let controller = try controller(hardware, journal: journal)
        let result = begin(controller)
        XCTAssertEqual(result.mode, .externalRecoveryRequired)
        XCTAssertEqual(hardware.observation.globalUnlock, 0)
        XCTAssertNil(result.sessionID)
        XCTAssertFalse(result.releaseVerified)
        XCTAssertEqual(journal.record?.pending, .mode(fan: 0, manual: true))
        hardware.clock.now = 1
        XCTAssertFalse(controller.renew(owner: "owner", session: journal.record!.ownerSession))
        poll(controller)
        XCTAssertEqual(controller.status(observe: false).mode, .externalRecoveryRequired)
        let done = expectation(description: "stop while uncertain")
        controller.stop(owner: "owner", reason: "sleep") { status in
            XCTAssertFalse(status.releaseVerified); XCTAssertTrue(status.externalRecoveryRequired); done.fulfill()
        }
        wait(for: [done], timeout: 1)
        XCTAssertTrue(hardware.observation.isFullyAutomatic)
        XCTAssertEqual(hardware.observation.globalUnlock, 0)
        XCTAssertTrue(hardware.operations.isEmpty)
    }

    func testArmedWatchdogExpiresWithoutManualPollingWhileHardwareIsBlocked() throws {
        let clock = TestClock(realTime: true), journal = MemoryJournal()
        let hardware = FakeFans(clock: clock)
        let controller = try FanHelperController(hardware: hardware, persistence: journal,
                                                bootID: boot, artifactIdentity: "test-artifact",
                                                conflict: { nil }, clock: { clock.now })
        let result = begin(controller)
        XCTAssertNotNil(result.sessionID)
        let blocked = expectation(description: "hardware read blocked")
        let returned = expectation(description: "blocked read returned")
        let unblock = DispatchSemaphore(value: 0)
        defer { unblock.signal() }
        hardware.blockNextRead = { blocked.fulfill(); _ = unblock.wait(timeout: .now() + 7) }
        controller.poll { returned.fulfill() }
        wait(for: [blocked], timeout: 1)
        let deadlineDetected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            controller.status(observe: false).mode == .restoring
        }, object: nil)
        wait(for: [deadlineDetected], timeout: 5.5)
        let expired = controller.status(observe: false)
        XCTAssertFalse(expired.releaseVerified)
        XCTAssertTrue(expired.diagnostics.contains { $0.contains("Watchdog detected") })
        XCTAssertFalse(controller.renew(owner: "owner", session: try XCTUnwrap(result.sessionID)))
        unblock.signal()
        wait(for: [returned], timeout: 2)
        poll(controller)
        XCTAssertTrue(controller.status(observe: false).releaseVerified)
        XCTAssertTrue(hardware.observation.isFullyAutomatic)
    }

    func testReadOnlyM2FixtureCannotQualifyCPUControl() throws {
        struct LegacySensor: Decodable { let key: String; let group: FanSensorGroup }
        struct LegacyCapabilities: Decodable { let model: String; let sensors: [LegacySensor] }
        struct LegacySnapshot: Decodable { let temperatures: [String: Double]; let fans: [FanReading] }
        struct Fixture: Decodable { let capabilities: LegacyCapabilities; let snapshot: LegacySnapshot }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "m2-pro-first-read", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        XCTAssertEqual(fixture.capabilities.model, "Mac14,9")
        XCTAssertEqual(fixture.capabilities.sensors.count, 14)
        XCTAssertFalse(fixture.snapshot.fans.allSatisfy(\.isAutomatic))
        let cpu = fixture.capabilities.sensors.filter { $0.group != .gpu }
        XCTAssertEqual(cpu.count, 12)
        for sensor in cpu { XCTAssertLessThan(try XCTUnwrap(fixture.snapshot.temperatures[sensor.key]), 10) }
        // Keep the original fixture intact, readable as historical evidence,
        // and impossible to decode as current aggregate capabilities.
        struct CurrentFixture: Decodable { let capabilities: FanCapabilities }
        XCTAssertThrowsError(try JSONDecoder().decode(CurrentFixture.self, from: data))
    }

    func testSigningRequirementsRejectInjectedIdentitiesAndAdHocClients() throws {
        XCTAssertThrowsError(try FanSigning.requirement(identifier: "untrusted", team: "TESTTEAM01"))
        XCTAssertThrowsError(try FanSigning.requirement(identifier: FanServiceIdentity.app, team: "A\" or true"))
        let text = try FanSigning.requirement(identifier: FanServiceIdentity.app, team: "TESTTEAM01")
        XCTAssertTrue(text.contains("anchor apple generic"))
        XCTAssertThrowsError(try FanSigning.selfIdentity()) // SwiftPM test executable is ad-hoc signed.
    }

    func testRecoveryStoreEnforcesPermissionsAndRejectsSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FanRecoveryStore(directory: directory, requiredUID: geteuid())
        let record = FanRecoveryRecord(bootID: boot, serviceGeneration: generation, artifactIdentity: "test-artifact",
                                       ownerSession: UUID().uuidString, capabilities: FanPolicyTests.capabilities,
                                       baseline: FanPolicyTests.frame(75).controlObservation)
        try store.save(record)
        XCTAssertEqual(try store.load(), record)
        let file = directory.appendingPathComponent("ownership.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.remove())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try store.remove()
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertThrowsError(try store.load())
    }

    func testRemovalReservesServiceUntilUnregisteredOrConnectionCloses() throws {
        let gate = FanSafetyGate()
        XCTAssertTrue(gate.prepareRemoval(owner: "remover"))
        XCTAssertThrowsError(try gate.begin(owner: "new owner", now: 0))
        gate.cancelRemoval(owner: "wrong owner")
        XCTAssertThrowsError(try gate.begin(owner: "new owner", now: 0))
        gate.cancelRemoval(owner: "remover")
        let session = try gate.begin(owner: "new owner", now: 0)
        XCTAssertFalse(gate.prepareRemoval(owner: "remover"))
        XCTAssertTrue(gate.renew(owner: "new owner", session: session, now: 1))
        XCTAssertTrue(gate.prepareRemoval(owner: "new owner"))
        XCTAssertFalse(gate.renew(owner: "new owner", session: session, now: 1))
        gate.finish()
        XCTAssertThrowsError(try gate.begin(owner: "another owner", now: 1))
    }

    func testHelperSleepRevokesLeaseAndRestoresOwnedOverride() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let controller = try controller(hardware, journal: journal)
        let result = begin(controller)
        XCTAssertNotNil(result.sessionID)
        let done = expectation(description: "helper sleep release")
        controller.systemWillSleep { done.fulfill() }
        XCTAssertFalse(controller.renew(owner: "owner", session: result.sessionID!))
        wait(for: [done], timeout: 1)
        XCTAssertTrue(hardware.observation.isFullyAutomatic)
        XCTAssertTrue(controller.status(observe: false).safeToUnregister)
        XCTAssertNil(begin(controller).sessionID)
        controller.systemDidWake()
        hardware.clock.now = 1
        XCTAssertNotNil(begin(controller).sessionID)
    }

    // The power observer lets the system sleep once owned release finishes, or
    // after this allowance. A bounded two-fan release takes about 1.3–1.8 s and
    // about 3.5 s at worst; macOS waits up to 30 s for the acknowledgement.
    func testSleepAllowanceCoversABoundedTwoFanRelease() {
        XCTAssertEqual(FanHelperController.sleepAllowanceSeconds, 5)
    }

    func testHIDMapDoesNotAdoptPMUDieOrUnknownZones() {
        XCTAssertEqual(FanHIDSensorMap.group(for: "pACC MTR Temp Sensor0"), .performance)
        XCTAssertEqual(FanHIDSensorMap.group(for: "eACC MTR Temp Sensor3"), .efficiency)
        XCTAssertEqual(FanHIDSensorMap.group(for: "GPU MTR Temp Sensor63"), .gpu)
        for unknown in ["PMU tdie1", "PMU tdev1", "SOC MTR Temp Sensor0", "pACC MTR Temp Sensor64",
                        "pACC MTR Temp Sensor00", "pACC MTR Temp Sensor-1", "pACC2 MTR Temp Sensor0"] {
            XCTAssertNil(FanHIDSensorMap.group(for: unknown))
        }
    }

    func testMissingOrNonFiniteAggregateRestoresImmediatelyWithoutFreshRampOrAutoRestart() throws {
        for key in ["TCMb", "TCMz"] {
            for fault in [nil, Double.nan, .infinity, -.infinity] as [Double?] {
                let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
                let controller = try controller(hardware, journal: journal)
                XCTAssertNotNil(begin(controller).sessionID)
                let previousOperations = hardware.operations.count
                var values = FanPolicyTests.frame(75).temperatures
                values[key] = fault
                hardware.temperatureOverride = values; hardware.clock.now = 1
                poll(controller)
                let status = controller.status(observe: false)
                XCTAssertNil(status.sessionID); XCTAssertNil(status.snapshot); XCTAssertNil(status.smoothedCPU)
                XCTAssertTrue(status.releaseVerified); XCTAssertTrue(status.safeToUnregister)
                XCTAssertTrue(hardware.observation.isFullyAutomatic); XCTAssertNil(journal.record)
                for operation in hardware.operations.dropFirst(previousOperations) {
                    if case .target(_, let rpm) = operation { XCTAssertEqual(rpm, 0) }
                    if case .mode(_, let manual) = operation { XCTAssertFalse(manual) }
                }
                hardware.temperatureOverride = nil; hardware.clock.now = 2
                poll(controller)
                XCTAssertNil(controller.status(observe: false).sessionID)
            }
        }
    }

    // A finite out-of-range value in an otherwise valid frame makes that frame
    // unusable: no decision or write, nothing substituted, clamped or kept for
    // control, and the last usable frame stays visible until it is 3 s old.
    func testFiniteOutOfRangeReadingSkipsTheFrameWithinTheCompleteFrameDeadline() throws {
        let faults: [(String, Double)] = [("TCMb", 6.7), ("TCMb", 4.633), ("TCMb", 121), ("TCMz", 263.37811279296875),
                                          ("TCMz", 9.99), ("Tg0f", 0), ("Tg0f", 130), ("Tg0f", -1)]
        for (key, fault) in faults {
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            let controller = try controller(hardware, journal: journal)
            let started = begin(controller)
            let session = try XCTUnwrap(started.sessionID)
            let operations = hardware.operations, saves = journal.saves.count
            let usable = try XCTUnwrap(controller.status(observe: false).snapshot)
            let smoothed = controller.status(observe: false).smoothedCPU
            var values = FanPolicyTests.frame(80).temperatures
            values[key] = fault
            hardware.temperatureOverride = values; hardware.clock.now = 1
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            poll(controller)
            let skipped = controller.status(observe: false)
            XCTAssertEqual(skipped.sessionID, session, key)
            XCTAssertEqual(skipped.mode, .custom, key)
            XCTAssertEqual(skipped.snapshot, usable, "The last usable frame stays visible: \(key)")
            XCTAssertEqual(skipped.smoothedCPU, smoothed, "No decision follows: \(key)")
            XCTAssertEqual(hardware.operations, operations, "No write follows: \(key)")
            XCTAssertEqual(journal.saves.count, saves, key)
            XCTAssertTrue(skipped.diagnostics.contains { $0.contains("Unusable frame skipped") && $0.contains("\(fault)") }, key)
            // The next usable frame resumes ordinary control within the deadline.
            hardware.temperatureOverride = nil; hardware.temperature = 80; hardware.clock.now = 2
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            poll(controller)
            let resumed = controller.status(observe: false)
            XCTAssertEqual(resumed.sessionID, session, key); XCTAssertEqual(resumed.mode, .custom, key)
            XCTAssertEqual(resumed.snapshot?.capturedAt, 2, key)
            XCTAssertGreaterThan(hardware.operations.count, operations.count, key)
        }
    }

    // A skipped frame during protection cannot count as a cool second: the
    // ten-second cool-down restarts at the next usable cool frame.
    func testSkippedFrameRestartsTheProtectionCoolDownInTheController() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        hardware.cpuMaximum = 92
        let controller = try controller(hardware, journal: journal)
        let session = try XCTUnwrap(begin(controller).sessionID)
        func tick(_ time: Double, maximum: Double = 80, glitch: Bool = false) -> FanOperatingMode {
            var values = FanPolicyTests.frame(75, cpuMaximum: maximum).temperatures
            if glitch { values["TCMz"] = 263.37811279296875 }
            hardware.temperatureOverride = values; hardware.clock.now = time
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            poll(controller)
            return controller.status(observe: false).mode
        }
        // P-Q1: the entry frame and the next are hot; the third starts the spell.
        XCTAssertEqual(controller.status(observe: false).mode, .custom)
        XCTAssertEqual(tick(1, maximum: 92), .custom)
        XCTAssertEqual(tick(2, maximum: 92), .protection)
        for time in 3...6 { XCTAssertEqual(tick(Double(time)), .protection) }
        XCTAssertEqual(tick(7, glitch: true), .protection)
        for time in 8...17 { XCTAssertEqual(tick(Double(time)), .protection, "\(time)") }
        XCTAssertEqual(tick(18), .custom)
    }

    // P-Q1 through the controller: a frame skipped for an out-of-range
    // reading neither counts toward the three hot readings nor ends the run,
    // and until the third the ramp's own request stands.
    func testThreeHotReadingsStartProtectionAcrossASkippedFrameInTheController() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        hardware.temperature = 75; hardware.cpuMaximum = 92
        let controller = try controller(hardware, journal: journal)
        let started = begin(controller)
        let session = try XCTUnwrap(started.sessionID)
        let ramp = FanPolicyTests.capabilities.fans.map { $0.target(demand: 1.0 / 3) }
        func tick(_ time: Double, invalid: Bool = false) -> FanStatus {
            hardware.invalidMaximumReads = invalid ? 1 : 0; hardware.clock.now = time
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            poll(controller)
            return controller.status(observe: false)
        }
        XCTAssertEqual(started.mode, .custom); XCTAssertNil(started.reason)
        let second = tick(1)
        XCTAssertEqual(second.mode, .custom)
        XCTAssertEqual(second.requestedRPM[0], ramp[0]); XCTAssertEqual(second.requestedRPM[1], ramp[1])
        let writes = hardware.operations.count
        let skipped = tick(2, invalid: true)
        XCTAssertEqual(skipped.mode, .custom); XCTAssertEqual(skipped.sessionID, session)
        XCTAssertEqual(hardware.operations.count, writes, "No decision or write on a skipped frame.")
        XCTAssertEqual(skipped.diagnostics.filter { $0.contains("Unusable frame skipped") }.count, 1)
        let third = tick(3)
        XCTAssertEqual(third.mode, .protection)
        XCTAssertEqual(third.reason, "Firmware CPU die maximum (TCMz) ≥90 °C for three readings in a row")
        XCTAssertEqual(third.requestedRPM[0], 6000); XCTAssertEqual(third.requestedRPM[1], 5500)
        // A run of two ended by a cooler reading starts nothing, also across a skip.
        let other = FakeFans(clock: TestClock())
        other.temperature = 75; other.cpuMaximum = 92
        let cooled = try self.controller(other, journal: MemoryJournal())
        let cooledSession = try XCTUnwrap(begin(cooled).sessionID)
        for (time, maximum, invalid) in [(1.0, 92.0, false), (2, 92, true), (3, 89.9, false), (4, 92, false), (5, 92, false)] {
            other.cpuMaximum = maximum; other.invalidMaximumReads = invalid ? 1 : 0; other.clock.now = time
            XCTAssertTrue(cooled.renew(owner: "owner", session: cooledSession))
            poll(cooled)
            XCTAssertEqual(cooled.status(observe: false).mode, .custom, "\(time)")
        }
    }

    // H-Q3: an out-of-range entry frame makes begin wait for the next frame,
    // one second later, for at most three seconds. The frame that qualifies
    // is checked in full and starts the session's deadlines.
    func testAnOutOfRangeEntryFrameWaitsForTheNextFrame() throws {
        for invalid in 1...3 {
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            var pauses: [TimeInterval] = []
            let controller = try controller(hardware, journal: journal,
                                            entryFramePause: { pauses.append($0); hardware.clock.now += $0 })
            hardware.invalidMaximumReads = invalid
            let started = begin(controller)
            let session = try XCTUnwrap(started.sessionID, "\(invalid)")
            XCTAssertNil(started.requestError); XCTAssertEqual(started.mode, .custom, "\(invalid)")
            XCTAssertEqual(pauses, Array(repeating: 1, count: invalid), "\(invalid)")
            XCTAssertEqual(started.snapshot?.capturedAt, Double(invalid))
            XCTAssertFalse(hardware.operations.isEmpty); XCTAssertNotNil(journal.record)
            XCTAssertEqual(started.diagnostics.filter {
                $0.contains("Entry frame unusable") && $0.contains("\(FakeFans.invalidMaximum)")
            }.count, invalid, "\(invalid)")
            XCTAssertNil(started.idleFaults, "An entry frame is logged, not counted as an idle fault.")
            XCTAssertEqual(controller.safety.nextDeadline(now: hardware.clock.now), 5, "The lease still runs from the request.")
            hardware.clock.now += 1
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            XCTAssertEqual(controller.safety.nextDeadline(now: hardware.clock.now), Double(invalid) + 4)
            poll(controller)
            XCTAssertEqual(controller.status(observe: false).sessionID, session, "\(invalid)")
        }
    }

    // Entry frames that stay out of range for three seconds fail the begin as
    // a single one did before: no write, no journal record, no skip.
    func testEntryFramesOutOfRangeForThreeSecondsFailActivationWithoutAWrite() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        var pauses: [TimeInterval] = []
        let controller = try controller(hardware, journal: journal,
                                        entryFramePause: { pauses.append($0); hardware.clock.now += $0 })
        hardware.invalidMaximumReads = 5
        let status = begin(controller)
        XCTAssertNil(status.sessionID); XCTAssertFalse(status.ownsOverride); XCTAssertEqual(status.mode, .paused)
        XCTAssertTrue(status.reason?.contains("outside its qualified reading range") == true)
        XCTAssertEqual(pauses, [1, 1, 1]); XCTAssertEqual(hardware.clock.now, 3)
        XCTAssertEqual(hardware.invalidMaximumReads, 1, "Four frames were read.")
        XCTAssertTrue(hardware.operations.isEmpty); XCTAssertNil(journal.record); XCTAssertTrue(journal.saves.isEmpty)
        XCTAssertFalse(status.diagnostics.contains { $0.contains("Unusable frame skipped") })
        XCTAssertNil(controller.safety.check(now: hardware.clock.now).session)
        hardware.invalidMaximumReads = 0
        XCTAssertNotNil(begin(controller).sessionID)
    }

    // Only an out-of-range frame is waited for. Any other entry fault fails
    // at once, every entry check is repeated for the next frame, and a stop
    // during the wait cancels the begin.
    func testWaitingForAnEntryFrameEndsOnAnyOtherFaultOrAStop() throws {
        do { // A sensor that disappears on the next frame.
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            var pauses = 0
            let controller = try controller(hardware, journal: journal, entryFramePause: {
                pauses += 1; hardware.clock.now += $0; hardware.invalidTelemetry = true
            })
            hardware.invalidMaximumReads = 3
            let status = begin(controller)
            XCTAssertNil(status.sessionID); XCTAssertEqual(pauses, 1)
            XCTAssertEqual(status.reason, "Required CPU sensor disappeared")
            XCTAssertTrue(hardware.operations.isEmpty); XCTAssertNil(journal.record)
        }
        do { // A fan found in manual on the frame that would have qualified.
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            let controller = try controller(hardware, journal: journal, entryFramePause: {
                hardware.clock.now += $0; hardware.observation.fans[0].mode = 1
            })
            hardware.invalidMaximumReads = 1
            let status = begin(controller)
            XCTAssertNil(status.sessionID)
            XCTAssertTrue(status.reason?.contains("already in custom control") == true)
            XCTAssertTrue(hardware.operations.isEmpty); XCTAssertNil(journal.record)
        }
        do { // A competing utility that appears during the wait.
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            var utility: String?
            let controller = try controller(hardware, journal: journal, conflict: { utility }, entryFramePause: {
                hardware.clock.now += $0; utility = "Macs Fan Control"
            })
            hardware.invalidMaximumReads = 1
            let status = begin(controller)
            XCTAssertNil(status.sessionID)
            XCTAssertEqual(status.reason, "Quit Macs Fan Control before enabling Fan Control.")
            XCTAssertEqual(hardware.invalidMaximumReads, 0, "One frame was read.")
            XCTAssertTrue(hardware.operations.isEmpty); XCTAssertNil(journal.record)
        }
        do { // The app's stop during the wait.
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            var waiting: FanHelperController?
            var stopped = FanStatus(serviceGeneration: "none")
            let replied = expectation(description: "stop reply")
            let controller = try controller(hardware, journal: journal, entryFramePause: {
                hardware.clock.now += $0
                waiting?.stop(owner: "owner", reason: Self.appStop) { stopped = $0; replied.fulfill() }
            })
            waiting = controller
            hardware.invalidMaximumReads = 1
            XCTAssertNil(begin(controller).sessionID)
            wait(for: [replied], timeout: 2)
            XCTAssertEqual(stopped.mode, .paused); XCTAssertEqual(stopped.reason, Self.appStop)
            XCTAssertEqual(hardware.invalidMaximumReads, 0, "No second frame was read.")
            XCTAssertTrue(hardware.operations.isEmpty); XCTAssertNil(journal.record)
            XCTAssertNotNil(begin(controller).sessionID)
        }
    }

    // A skipped frame's fan state must still match this helper's ownership.
    func testSkippedFrameStillStopsOnAForeignFanChangeWithoutFighting() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let controller = try controller(hardware, journal: journal)
        let session = try XCTUnwrap(begin(controller).sessionID)
        let operations = hardware.operations
        var values = FanPolicyTests.frame(75).temperatures
        values["TCMz"] = 263.37811279296875
        hardware.temperatureOverride = values
        hardware.observation.fans[0].targetRPM = 4321 // Another writer.
        hardware.clock.now = 1
        XCTAssertTrue(controller.renew(owner: "owner", session: session))
        poll(controller)
        let status = controller.status(observe: false)
        XCTAssertNil(status.sessionID); XCTAssertEqual(status.mode, .restorationFailed)
        XCTAssertTrue(status.diagnostics.contains { $0.contains("ownership was lost") })
        XCTAssertFalse(status.diagnostics.contains { $0.contains("Unusable frame skipped") })
        XCTAssertEqual(hardware.operations, operations, "No write fights the other controller.")
        XCTAssertNotNil(journal.record)
    }

    func testRepeatedOutOfRangeFramesReleaseAtTheFourSecondDeadline() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let controller = try controller(hardware, journal: journal)
        let session = try XCTUnwrap(begin(controller).sessionID)
        var values = FanPolicyTests.frame(75).temperatures
        values["TCMz"] = 262.48748779296875
        hardware.temperatureOverride = values
        for time in [1.0, 2.0, 3.0, 3.99] {
            hardware.clock.now = time
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            poll(controller)
            XCTAssertEqual(controller.status(observe: false).sessionID, session, "Skipped at \(time)")
        }
        XCTAssertFalse(hardware.observation.isFullyAutomatic)
        hardware.clock.now = 4
        poll(controller)
        let released = controller.status(observe: false)
        XCTAssertNil(released.sessionID); XCTAssertEqual(released.mode, .paused)
        XCTAssertEqual(released.reason, "No complete fresh sensor snapshot for four seconds.")
        XCTAssertTrue(released.releaseVerified); XCTAssertTrue(hardware.observation.isFullyAutomatic)
        XCTAssertNil(journal.record)
        hardware.temperatureOverride = nil; hardware.clock.now = 5
        poll(controller)
        XCTAssertNil(controller.status(observe: false).sessionID, "Explicit re-enabling is still required.")
    }

    // H-Q4: two invalid frames in a row are ridden out; three end the
    // session, because the watchdog fires before a fourth frame is read.
    func testTwoOutOfRangeFramesInARowAreRiddenOutAndThreeEndTheSession() throws {
        for invalid in [2, 3] {
            let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
            let controller = try controller(hardware, journal: journal)
            let session = try XCTUnwrap(begin(controller).sessionID)
            let operations = hardware.operations.count
            hardware.invalidMaximumReads = invalid
            for time in 1...invalid {
                hardware.clock.now = Double(time)
                XCTAssertTrue(controller.renew(owner: "owner", session: session))
                poll(controller)
                XCTAssertEqual(controller.status(observe: false).sessionID, session, "\(invalid): skipped at \(time)")
                XCTAssertEqual(hardware.operations.count, operations, "\(invalid): no write at \(time)")
            }
            // One second later the watchdog runs first, then the next frame is read.
            hardware.temperature = 80; hardware.clock.now = Double(invalid) + 1
            controller.checkWatchdog()
            _ = controller.renew(owner: "owner", session: session)
            poll(controller)
            let status = controller.status(observe: false)
            XCTAssertEqual(status.diagnostics.filter { $0.contains("Unusable frame skipped") }.count, invalid)
            if invalid == 2 {
                XCTAssertEqual(status.sessionID, session); XCTAssertEqual(status.mode, .custom)
                XCTAssertEqual(status.snapshot?.capturedAt, 3)
                XCTAssertGreaterThan(hardware.operations.count, operations, "Control resumes on the next usable frame.")
            } else {
                XCTAssertNil(status.sessionID); XCTAssertEqual(status.mode, .paused)
                XCTAssertEqual(status.reason, "No complete fresh sensor snapshot for four seconds.")
                XCTAssertTrue(status.releaseVerified); XCTAssertTrue(hardware.observation.isFullyAutomatic)
                XCTAssertNil(journal.record)
            }
        }
    }

    // Frame validation reports a range fault only when everything else in the
    // frame is valid, so a frame with another fault still releases at once.
    func testOutOfRangeIsReportedOnlyForAnOtherwiseValidFrame() throws {
        let capabilities = FanPolicyTests.capabilities, base = FanPolicyTests.frame(75)
        func frame(_ changes: [String: Double], fans: [FanReading]? = nil, at time: Double = 0) -> FanSnapshot {
            FanSnapshot(capturedAt: time, temperatures: base.temperatures.merging(changes) { $1 }, fans: fans ?? base.fans,
                        thermalPressure: .nominal, globalUnlock: base.globalUnlock)
        }
        XCTAssertThrowsError(try frame(["TCMz": 263.37811279296875]).validate(against: capabilities, now: 0)) {
            guard case .readingOutOfRange(let reason)? = $0 as? FanControlError else { return XCTFail("\($0)") }
            XCTAssertTrue(reason.contains("TCMz") && reason.contains("263.378"))
        }
        // Any other fault in the same frame wins, so it still releases at once.
        XCTAssertThrowsError(try frame(["TCMz": 263.4, "TCMb": .nan]).validate(against: capabilities, now: 0)) {
            XCTAssertEqual($0 as? FanControlError, .invalid("Missing or invalid temperature: TCMb."))
        }
        var fans = base.fans; fans[1].mode = 7
        XCTAssertThrowsError(try frame(["TCMz": 263.4], fans: fans).validate(against: capabilities, now: 0)) {
            XCTAssertEqual($0 as? FanControlError, .invalid("Missing or invalid bounds/mode/RPM for fan 2."))
        }
        XCTAssertThrowsError(try frame(["TCMz": 263.4]).validate(against: capabilities, now: 3)) {
            XCTAssertEqual($0 as? FanControlError, .invalid("No complete fresh sensor snapshot for three seconds."))
        }
        let missing = FanSnapshot(capturedAt: 0, temperatures: ["TCMb": 75, "TCMz": 263.4], fans: base.fans,
                                  thermalPressure: .nominal, globalUnlock: base.globalUnlock)
        XCTAssertThrowsError(try missing.validate(against: capabilities, now: 0)) {
            XCTAssertEqual($0 as? FanControlError, .invalid("The contributing sensor set changed; re-enable to qualify it again."))
        }
    }

    func testSeparateAverageMaximumAppearInPolicyAndDiagnostics() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        hardware.temperature = 60; hardware.cpuMaximum = 90
        let controller = try controller(hardware, journal: journal)
        let started = begin(controller)
        // P-Q1: one reading at 90 °C leaves a cool average under Apple's control.
        XCTAssertEqual(started.mode, .automatic); XCTAssertTrue(hardware.operations.isEmpty)
        let session = try XCTUnwrap(started.sessionID)
        for time in 1...2 {
            hardware.clock.now = Double(time)
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            poll(controller)
        }
        let status = controller.status(observe: false)
        XCTAssertEqual(status.mode, .protection)
        XCTAssertEqual(status.smoothedCPU, 60)
        XCTAssertEqual(status.requestedRPM[0], 6000)
        XCTAssertEqual(status.requestedRPM[1], 5500)
        XCTAssertTrue(status.reason?.contains("TCMz") == true)
        XCTAssertTrue(status.diagnostics.contains { $0.contains("firmware CPU die average (TCMb) 60.0") })
        XCTAssertTrue(status.diagnostics.contains { $0.contains("firmware CPU die maximum (TCMz) 90.0") })
        XCTAssertTrue(status.diagnostics.contains { $0.contains("read duration") })
    }

    func testLegacyRecoveryRecordFailsClosedWithoutWritesOrDeletion() throws {
        let hardware = FakeFans(clock: TestClock()), journal = MemoryJournal()
        let record = FanRecoveryRecord(bootID: boot, serviceGeneration: generation, artifactIdentity: "test-artifact",
                                       ownerSession: UUID().uuidString, capabilities: hardware.capabilities,
                                       baseline: hardware.observation)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["version"] = 1
        journal.record = try JSONDecoder().decode(FanRecoveryRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try controller(hardware, journal: journal))
        XCTAssertNotNil(journal.record)
        XCTAssertTrue(hardware.operations.isEmpty)
    }

    func testRecoveryStorePreservesLegacySchemaAndReportsManualRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FanRecoveryStore(directory: directory, requiredUID: geteuid())
        let hardware = FakeFans(clock: TestClock())
        let record = FanRecoveryRecord(bootID: boot, serviceGeneration: generation, artifactIdentity: "old-artifact",
                                       ownerSession: UUID().uuidString, capabilities: hardware.capabilities, baseline: hardware.observation)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        let fixtureURL = try XCTUnwrap(Bundle.module.url(forResource: "m2-pro-first-read", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        json["version"] = 1; json["capabilities"] = fixture["capabilities"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let file = directory.appendingPathComponent("ownership.json")
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("manual recovery is required"))
        }
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
}
