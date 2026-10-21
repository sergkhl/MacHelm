import XCTest
@testable import FanControlCore
@testable import FanControlRuntime

private final class RecoveryClock {
    private let lock = NSLock()
    private var value: Double = 100
    var now: Double {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

private final class RecoveryJournal: FanRecoveryPersistence {
    var record: FanRecoveryRecord?
    var removals = 0
    var failRemoval = false
    var deleteThenFail = false
    var failAcknowledgement = false
    var failPendingAfterSave = false
    var onLoad: (() -> Void)?
    func load() throws -> FanRecoveryRecord? { onLoad?(); return record }
    func save(_ record: FanRecoveryRecord) throws {
        if failAcknowledgement && record.pending == nil { throw FanControlError.ownership("Receipt persistence failed") }
        self.record = record
        if failPendingAfterSave && record.pending != nil { throw FanControlError.ownership("Intent renamed before sync failed") }
    }
    func remove() throws {
        removals += 1
        if deleteThenFail { record = nil; throw FanControlError.ownership("Deletion acknowledgement failed") }
        if failRemoval { throw FanControlError.ownership("Deletion failed") }
        record = nil
    }
}

// Native fan behavior is replaced entirely. No SMC/XPC/service code is reached.
private final class RecoveryFans: FanHardware {
    let clock = RecoveryClock()
    var capabilities = FanPolicyTests.capabilities
    var state = FanPolicyTests.frame(75, at: 100).controlObservation
    var operations: [FanOperation] = []
    var deferred: FanOperation?
    var deferNextOperation = false
    var failAfterSubmission = false
    var failReadback = false
    var invalidTemperature = false
    var probes = 0
    var onProbe: ((Int, FanFanProbe) throws -> FanFanProbe)?

    init() {
        state.fans[0].targetRPM = 2317; state.fans[1].targetRPM = 2502
    }
    func discover() throws -> FanCapabilities { capabilities }
    func read(_ capabilities: FanCapabilities) throws -> FanSnapshot {
        if invalidTemperature { throw FanControlError.invalid("CPU channel missing") }
        return FanSnapshot(capturedAt: clock.now, temperatures: FanPolicyTests.frame(75).temperatures,
                           fans: state.fans, thermalPressure: .nominal, globalUnlock: state.globalUnlock)
    }
    func readControlState(_ capabilities: FanCapabilities) throws -> FanControlObservation {
        if failReadback && !operations.isEmpty { throw FanControlError.hardware("Readback failed") }
        return FanControlObservation(capturedAt: clock.now, fans: state.fans, globalUnlock: state.globalUnlock)
    }
    func probeFans() throws -> FanFanProbe {
        probes += 1; clock.now += 0.01
        let probe = FanFanProbe(model: capabilities.model, fans: capabilities.fans,
            observation: FanControlObservation(capturedAt: clock.now, fans: state.fans, globalUnlock: state.globalUnlock))
        return try onProbe?(probes, probe) ?? probe
    }
    func perform(_ operation: FanOperation, capabilities: FanCapabilities, cancelled: () -> Bool) throws {
        guard !cancelled() else { throw FanControlError.cancelled }
        operations.append(operation)
        if deferNextOperation { deferNextOperation = false; deferred = operation; return }
        apply(operation)
        if failAfterSubmission { throw FanControlError.hardware("Transport failed after submission") }
    }
    func apply(_ operation: FanOperation) {
        switch operation {
        case .mode(let fan, let manual): state.fans[fan].mode = manual ? 1 : 0
        case .target(let fan, let rpm): state.fans[fan].targetRPM = rpm
        case .globalUnlock(let enabled): state.globalUnlock = enabled ? 1 : 0
        }
    }
}

final class FanExternalRecoveryTests: XCTestCase {
    private let boot = UUID().uuidString
    private let generation = UUID().uuidString
    private let artifact = "private-test-artifact"

    private func pending(_ hardware: RecoveryFans, journal: RecoveryJournal) -> String {
        let session = UUID().uuidString
        var record = FanRecoveryRecord(bootID: boot, serviceGeneration: generation, artifactIdentity: artifact,
            ownerSession: session, capabilities: hardware.capabilities, baseline: hardware.state)
        record.pending = .mode(fan: 0, manual: true)
        journal.record = record
        return session
    }
    private func actuator(_ hardware: RecoveryFans, journal: RecoveryJournal,
                          bootID: String? = nil, artifactIdentity: String? = nil) throws -> FanActuator {
        try FanActuator(hardware: hardware, persistence: journal, bootID: bootID ?? boot,
                       serviceGeneration: generation, artifactIdentity: artifactIdentity ?? artifact)
    }
    private func controller(_ hardware: RecoveryFans, journal: RecoveryJournal,
                            conflict: @escaping () -> String? = { nil }) throws -> FanHelperController {
        try FanHelperController(hardware: hardware, persistence: journal, bootID: boot,
            artifactIdentity: artifact, conflict: conflict, clock: { hardware.clock.now }, startTimers: false)
    }
    private func reply(_ call: (@escaping (FanStatus) -> Void) -> Void) -> FanStatus {
        let done = expectation(description: "controller reply")
        var result = FanStatus(serviceGeneration: "none")
        call { result = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result
    }
    private func poll(_ controller: FanHelperController) {
        let done = expectation(description: "poll")
        controller.poll { done.fulfill() }; wait(for: [done], timeout: 2)
    }
    private func assertHeld(_ status: FanStatus, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(status.mode, .externalRecoveryRequired, file: file, line: line)
        XCTAssertTrue(status.externalRecoveryRequired, file: file, line: line)
        XCTAssertTrue(status.ownsOverride, file: file, line: line)
        XCTAssertFalse(status.releaseVerified, file: file, line: line)
        XCTAssertFalse(status.safeToUnregister, file: file, line: line)
        XCTAssertNil(status.sessionID, file: file, line: line)
        XCTAssertTrue(status.requestedRPM.isEmpty, file: file, line: line)
    }
    private func probe(_ original: FanFanProbe, at timestamp: Double? = nil,
                       change: (inout FanControlObservation) -> Void = { _ in }) -> FanFanProbe {
        var observation = FanControlObservation(capturedAt: timestamp ?? original.observation.capturedAt,
            fans: original.observation.fans, globalUnlock: original.observation.globalUnlock)
        change(&observation)
        return FanFanProbe(model: original.model, fans: original.fans, observation: observation)
    }

    func testDelayedEffectAfterEarlyAutomaticDoesNotRetireOrRetryIntent() throws {
        let hardware = RecoveryFans(), journal = RecoveryJournal()
        hardware.deferNextOperation = true
        let controller = try controller(hardware, journal: journal)
        let first = reply { controller.begin(owner: "owner", profile: .standard, completion: $0) }
        assertHeld(first)
        XCTAssertTrue(hardware.state.isFullyAutomatic)
        let intent = try XCTUnwrap(journal.record)
        XCTAssertEqual(intent.pending, .mode(fan: 0, manual: true))
        let submissions = hardware.operations
        _ = controller.status(observe: true); poll(controller)
        assertHeld(controller.status(observe: false))
        XCTAssertEqual(journal.record, intent)
        XCTAssertEqual(journal.removals, 0)
        hardware.clock.now += 50
        hardware.apply(try XCTUnwrap(hardware.deferred))
        _ = controller.status(observe: true); poll(controller)
        assertHeld(controller.status(observe: false))
        XCTAssertEqual(hardware.state.fans[0].mode, 1)
        XCTAssertEqual(hardware.operations, submissions)
        XCTAssertEqual(journal.record, intent)
    }

    func testPendingIntentSurvivesRestartBootAndArtifactWithAutomaticState() throws {
        for change in 0...2 {
            let hardware = RecoveryFans(), journal = RecoveryJournal()
            _ = pending(hardware, journal: journal)
            let retained = journal.record
            let restarted = try actuator(hardware, journal: journal,
                bootID: change == 1 ? UUID().uuidString : boot,
                artifactIdentity: change == 2 ? "replacement-artifact" : artifact)
            XCTAssertThrowsError(try restarted.restore(conflict: { nil }))
            XCTAssertThrowsError(try restarted.verifyOwnership(conflict: nil))
            for operation in [FanOperation.mode(fan: 1, manual: true), .target(fan: 0, rpm: 4000), .globalUnlock(true)] {
                XCTAssertThrowsError(try restarted.mutate(operation, cancelled: { false }))
            }
            XCTAssertTrue(restarted.requiresExternalRecovery)
            XCTAssertEqual(journal.record, retained)
            XCTAssertTrue(hardware.operations.isEmpty)
            assertHeld(try controller(hardware, journal: journal).status(observe: false))
        }
    }

    func testTransportReadbackAndReceiptPersistenceFailuresAllRetainIntent() throws {
        for failure in 0...2 {
            let hardware = RecoveryFans(), journal = RecoveryJournal()
            let actuator = try actuator(hardware, journal: journal)
            try actuator.establish(session: UUID().uuidString, capabilities: hardware.capabilities, baseline: hardware.state)
            hardware.failAfterSubmission = failure == 0
            hardware.failReadback = failure == 1
            journal.failAcknowledgement = failure == 2
            XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }))
            XCTAssertTrue(actuator.requiresExternalRecovery)
            XCTAssertEqual(journal.record?.pending, .mode(fan: 0, manual: true))
            XCTAssertEqual(hardware.operations, [.mode(fan: 0, manual: true)])
            XCTAssertThrowsError(try actuator.restore(conflict: { nil }))
            XCTAssertEqual(hardware.operations.count, 1)
        }
    }

    func testNoOwnerActionCanRearmAnUnconfirmedOperation() throws {
        let hardware = RecoveryFans(), journal = RecoveryJournal()
        let id = pending(hardware, journal: journal)
        let controller = try controller(hardware, journal: journal)
        let initial = journal.record
        XCTAssertNotNil(reply { controller.begin(owner: "second", profile: .standard, completion: $0) }.requestError)
        XCTAssertNotNil(reply { controller.updateProfile(owner: "owner", session: id, profile: .standard, completion: $0) }.requestError)
        XCTAssertNotNil(reply { controller.prepareRemoval(owner: "owner", completion: $0) }.requestError)
        assertHeld(reply { controller.stop(owner: "owner", reason: "off", completion: $0) })
        controller.disconnected(owner: "owner"); controller.checkWatchdog()
        hardware.clock.now += 10; poll(controller)
        let slept = expectation(description: "sleep while held")
        controller.systemWillSleep { slept.fulfill() }; wait(for: [slept], timeout: 1)
        controller.systemDidWake(); poll(controller)
        XCTAssertFalse(controller.renew(owner: "owner", session: id))
        assertHeld(controller.status(observe: false))
        XCTAssertEqual(journal.record, initial)
        XCTAssertTrue(hardware.operations.isEmpty)
    }

    func testExplicitRecoveryClearsOnlyAfterDistinctNativeReadsAndRemainsOff() throws {
        let hardware = RecoveryFans(), journal = RecoveryJournal()
        let id = pending(hardware, journal: journal)
        hardware.invalidTemperature = true
        let controller = try controller(hardware, journal: journal)
        let result = reply { controller.confirmExternalRecovery(owner: "owner", recoveryID: id, completion: $0) }
        XCTAssertNil(result.requestError); XCTAssertNil(journal.record)
        XCTAssertEqual(hardware.probes, 2); XCTAssertTrue(hardware.operations.isEmpty)
        XCTAssertFalse(result.externalRecoveryRequired); XCTAssertNil(result.externalRecoveryID)
        XCTAssertFalse(result.ownsOverride); XCTAssertNil(result.sessionID)
        XCTAssertTrue(result.releaseVerified); XCTAssertTrue(result.safeToUnregister)
        XCTAssertEqual(result.mode, .off)
        XCTAssertEqual(result.fanProbe?.observation.fans.map(\.targetRPM), [2317, 2502])
        let retainedReceipt = try XCTUnwrap(result.externalRecoveryReceipt)
        XCTAssertEqual(retainedReceipt.recoveryID, id)
        XCTAssertLessThan(retainedReceipt.first.observation.capturedAt, retainedReceipt.second.observation.capturedAt)
        XCTAssertEqual(retainedReceipt.first.observation.fans.map(\.targetRPM), [2317, 2502])
        poll(controller)
        XCTAssertEqual(controller.status(observe: false).mode, .off)
        XCTAssertTrue(hardware.operations.isEmpty)
        XCTAssertNotNil(reply { controller.confirmExternalRecovery(owner: "owner", recoveryID: id, completion: $0) }.requestError)
    }

    func testRecoveryIDCannotBeStaleMalformedOrReplayed() throws {
        for wrong in ["", "invalid", UUID().uuidString] {
            let hardware = RecoveryFans(), journal = RecoveryJournal()
            _ = pending(hardware, journal: journal)
            let retained = journal.record
            let actuator = try actuator(hardware, journal: journal)
            XCTAssertThrowsError(try actuator.confirmExternalRecovery(recoveryID: wrong, conflict: { nil }, clock: { hardware.clock.now }))
            XCTAssertEqual(hardware.probes, 0); XCTAssertEqual(journal.record, retained)
        }
    }

    func testManualUnlockAndInvalidFanReadbacksRetainUncertainty() throws {
        let faults: [(inout FanControlObservation) -> Void] = [
            { $0.fans[0].mode = 1 }, { $0.fans[1].mode = 2 }, { $0.globalUnlock = 1 }, { $0.globalUnlock = nil },
            { $0.fans[0].actualRPM = .nan }, { $0.fans[1].targetRPM = .infinity },
            { $0.fans[0].targetRPM = -1 }, { $0.fans[0].actualRPM = 20_001 },
            { $0.fans.removeLast() }, { $0.fans[1] = $0.fans[0] }
        ]
        for fault in faults {
            let hardware = RecoveryFans(), journal = RecoveryJournal()
            let id = pending(hardware, journal: journal), retained = journal.record
            hardware.onProbe = { _, original in self.probe(original, change: fault) }
            let actuator = try actuator(hardware, journal: journal)
            XCTAssertThrowsError(try actuator.confirmExternalRecovery(recoveryID: id, conflict: { nil }, clock: { hardware.clock.now }))
            XCTAssertEqual(journal.record, retained); XCTAssertTrue(hardware.operations.isEmpty)
        }
    }

    func testEachNativeReadMustMatchRetainedModelAndFanMetadata() throws {
        for index in [1, 2] {
            for changedModel in [true, false] {
                let hardware = RecoveryFans(), journal = RecoveryJournal()
                let id = pending(hardware, journal: journal), retained = journal.record
                hardware.onProbe = { count, probe in
                    guard count == index else { return probe }
                    return FanFanProbe(model: changedModel ? "Mac99,1" : probe.model,
                        fans: changedModel ? probe.fans : Array(probe.fans.reversed()), observation: probe.observation)
                }
                let actuator = try actuator(hardware, journal: journal)
                XCTAssertThrowsError(try actuator.confirmExternalRecovery(recoveryID: id, conflict: { nil }, clock: { hardware.clock.now }))
                XCTAssertEqual(journal.record, retained); XCTAssertTrue(hardware.operations.isEmpty)
            }
        }
    }

    func testStaleFutureNonfiniteAndRepeatedNativeTimestampsCannotClear() throws {
        for invalidTime in [97.0, 200, Double.nan, .infinity, 100.01] {
            let hardware = RecoveryFans(), journal = RecoveryJournal()
            let id = pending(hardware, journal: journal), retained = journal.record
            hardware.onProbe = { index, probe in index == 2 ? self.probe(probe, at: invalidTime) : probe }
            let actuator = try actuator(hardware, journal: journal)
            XCTAssertThrowsError(try actuator.confirmExternalRecovery(recoveryID: id, conflict: { nil }, clock: { hardware.clock.now }))
            XCTAssertEqual(journal.record, retained)
        }
        let hardware = RecoveryFans(), journal = RecoveryJournal()
        let id = pending(hardware, journal: journal), retained = journal.record
        hardware.onProbe = { index, probe in
            if index == 2 { hardware.clock.now += 3; return self.probe(probe, at: hardware.clock.now) }
            return probe
        }
        let actuator = try actuator(hardware, journal: journal)
        XCTAssertThrowsError(try actuator.confirmExternalRecovery(recoveryID: id, conflict: { nil }, clock: { hardware.clock.now }))
        XCTAssertEqual(journal.record, retained)
    }

    func testAbsentUnlockRemainsAbsentAndAutomaticModeThreeIsAccepted() throws {
        let hardware = RecoveryFans(), journal = RecoveryJournal()
        hardware.capabilities = FanCapabilities(model: hardware.capabilities.model, sensors: hardware.capabilities.sensors,
            fans: hardware.capabilities.fans, hasGlobalUnlock: false)
        hardware.state.globalUnlock = nil; hardware.state.fans[1].mode = 3
        let id = pending(hardware, journal: journal)
        let actuator = try actuator(hardware, journal: journal)
        let result = try actuator.confirmExternalRecovery(recoveryID: id, conflict: { nil }, clock: { hardware.clock.now })
        XCTAssertNil(result.first.observation.globalUnlock); XCTAssertNil(result.second.observation.globalUnlock)
        XCTAssertNil(journal.record)
        XCTAssertTrue(hardware.operations.isEmpty)
    }

    func testKnownConflictBeforeBetweenOrAfterProbesCannotClear() throws {
        for conflictAt in 1...3 {
            let hardware = RecoveryFans(), journal = RecoveryJournal()
            let id = pending(hardware, journal: journal), retained = journal.record
            var checks = 0
            let actuator = try actuator(hardware, journal: journal)
            XCTAssertThrowsError(try actuator.confirmExternalRecovery(recoveryID: id, conflict: {
                checks += 1; return checks == conflictAt ? "Macs Fan Control" : nil
            }, clock: { hardware.clock.now }))
            XCTAssertEqual(journal.record, retained); XCTAssertEqual(hardware.probes, conflictAt - 1)
            XCTAssertTrue(hardware.operations.isEmpty)
        }
    }

    func testChangedPersistedIntentAndFailedProbeCannotClear() throws {
        for changed in [true, false] {
            let hardware = RecoveryFans(), journal = RecoveryJournal()
            let id = pending(hardware, journal: journal)
            hardware.onProbe = { index, probe in
                if index == 2 {
                    if changed { journal.record?.pending = .target(fan: 0, rpm: 4000) }
                    else { throw FanControlError.hardware("Native probe failed") }
                }
                return probe
            }
            let actuator = try actuator(hardware, journal: journal)
            XCTAssertThrowsError(try actuator.confirmExternalRecovery(recoveryID: id, conflict: { nil }, clock: { hardware.clock.now }))
            XCTAssertNotNil(journal.record); XCTAssertEqual(journal.removals, 0)
            XCTAssertTrue(hardware.operations.isEmpty)
        }
    }

    func testFailedRemovalIncludingDeleteThenThrowRetainsRecordOnRestart() throws {
        for deleted in [true, false] {
            let hardware = RecoveryFans(), journal = RecoveryJournal()
            let id = pending(hardware, journal: journal), retained = journal.record
            journal.failRemoval = !deleted; journal.deleteThenFail = deleted
            let controller = try controller(hardware, journal: journal)
            let rejected = reply { controller.confirmExternalRecovery(owner: "owner", recoveryID: id, completion: $0) }
            XCTAssertNotNil(rejected.requestError); assertHeld(rejected)
            XCTAssertEqual(journal.record, retained)
            assertHeld(try self.controller(hardware, journal: journal).status(observe: false))
            journal.failRemoval = false; journal.deleteThenFail = false
            XCTAssertNil(reply { controller.confirmExternalRecovery(owner: "owner", recoveryID: id, completion: $0) }.requestError)
            XCTAssertNil(journal.record); XCTAssertTrue(hardware.operations.isEmpty)
        }
    }

    func testRecoveryReservationRejectsSecondOwnerAndCompetingRecovery() throws {
        let gate = FanSafetyGate()
        let token = try gate.reserveExternalRecovery(owner: "recoverer")
        gate.holdForExternalRecovery()
        XCTAssertTrue(gate.permitsExternalRecovery(owner: "recoverer", generation: token))
        XCTAssertThrowsError(try gate.begin(owner: "second", now: 100))
        XCTAssertFalse(gate.prepareRemoval(owner: "second"))
        XCTAssertThrowsError(try gate.reserveExternalRecovery(owner: "second"))
        gate.cancelExternalRecovery(owner: "wrong owner")
        XCTAssertTrue(gate.permitsExternalRecovery(owner: "recoverer", generation: token))
        try gate.commitExternalRecovery(owner: "recoverer", generation: token)
        gate.cancelExternalRecovery(owner: "recoverer")
        XCTAssertThrowsError(try gate.begin(owner: "second", now: 100))
        gate.endExternalRecovery(owner: "recoverer", generation: token)
        XCTAssertNoThrow(try gate.begin(owner: "second", now: 100))
    }

    func testSleepOrDisconnectDuringProbeInvalidatesRecoveryTransaction() throws {
        for sleeping in [true, false] {
            let hardware = RecoveryFans(), journal = RecoveryJournal()
            let id = pending(hardware, journal: journal), retained = journal.record
            let controller = try controller(hardware, journal: journal)
            let blocked = expectation(description: "native probe blocked")
            let done = expectation(description: "confirmation returned")
            let unblock = DispatchSemaphore(value: 0)
            hardware.onProbe = { index, probe in
                if index == 2 { blocked.fulfill(); _ = unblock.wait(timeout: .now() + 2) }
                return probe
            }
            controller.confirmExternalRecovery(owner: "recoverer", recoveryID: id) { status in
                XCTAssertNotNil(status.requestError); self.assertHeld(status); done.fulfill()
            }
            wait(for: [blocked], timeout: 1)
            XCTAssertNotNil(reply { controller.begin(owner: "second", profile: .standard, completion: $0) }.requestError)
            XCTAssertNotNil(reply { controller.confirmExternalRecovery(owner: "second", recoveryID: id, completion: $0) }.requestError)
            if sleeping { controller.systemWillSleep {} }
            else { controller.disconnected(owner: "recoverer") }
            unblock.signal(); wait(for: [done], timeout: 1)
            XCTAssertEqual(journal.record, retained); XCTAssertEqual(journal.removals, 0)
            XCTAssertTrue(hardware.operations.isEmpty)
        }
    }

    func testActiveOwnerCannotConfirmAnotherPendingRecord() throws {
        let hardware = RecoveryFans(), journal = RecoveryJournal()
        let controller = try controller(hardware, journal: journal)
        let healthy = reply { controller.begin(owner: "owner", profile: .standard, completion: $0) }
        let session = try XCTUnwrap(healthy.sessionID), operations = hardware.operations
        let response = reply { controller.confirmExternalRecovery(owner: "second", recoveryID: session, completion: $0) }
        XCTAssertNotNil(response.requestError); XCTAssertEqual(response.sessionID, session)
        XCTAssertTrue(controller.renew(owner: "owner", session: session))
        XCTAssertEqual(hardware.operations, operations)
    }

    func testIdleStopDoesNotInventAutomaticReadbackReceipt() throws {
        let hardware = RecoveryFans(), journal = RecoveryJournal()
        let controller = try controller(hardware, journal: journal)
        let stopped = reply { controller.stop(owner: "owner", reason: "off", completion: $0) }
        XCTAssertTrue(stopped.safeToUnregister); XCTAssertFalse(stopped.releaseVerified)
        XCTAssertNil(stopped.fanProbe); XCTAssertEqual(hardware.probes, 0)
        XCTAssertTrue(hardware.operations.isEmpty)
    }

    func testDirectorySyncFailureAfterDeletionKeepsStartupVisibleIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FanRecoveryStore(directory: directory, requiredUID: geteuid())
        let hardware = RecoveryFans(), memory = RecoveryJournal()
        _ = pending(hardware, journal: memory)
        let retained = try XCTUnwrap(memory.record)
        try store.save(retained)
        var syncs = 0
        store.directorySync = { fd in
            syncs += 1
            if syncs == 2 { errno = EIO; return -1 }
            return fsync(fd)
        }
        XCTAssertThrowsError(try store.remove())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ownership.json").path))
        XCTAssertEqual(try FanRecoveryStore(directory: directory, requiredUID: geteuid()).load(), retained)
        store.directorySync = { fsync($0) }
        try store.remove(); XCTAssertNil(try store.load())
    }

    func testPartiallySavedPendingIntentDisarmsControllerAndSurvivesRestart() throws {
        let hardware = RecoveryFans(), journal = RecoveryJournal()
        journal.failPendingAfterSave = true
        let controller = try controller(hardware, journal: journal)
        let result = reply { controller.begin(owner: "owner", profile: .standard, completion: $0) }
        assertHeld(result)
        XCTAssertEqual(journal.record?.pending, .mode(fan: 0, manual: true))
        XCTAssertTrue(hardware.operations.isEmpty)
        poll(controller)
        assertHeld(controller.status(observe: false))
        assertHeld(try self.controller(hardware, journal: journal).status(observe: false))
        XCTAssertEqual(journal.removals, 0)
        XCTAssertTrue(hardware.operations.isEmpty)
    }

    func testRealStoreIntentRenameThenSyncFailureCannotIssueRestorationWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FanRecoveryStore(directory: directory, requiredUID: geteuid())
        let hardware = RecoveryFans()
        let actuator = try FanActuator(hardware: hardware, persistence: store, bootID: boot,
            serviceGeneration: generation, artifactIdentity: artifact)
        try actuator.establish(session: UUID().uuidString, capabilities: hardware.capabilities, baseline: hardware.state)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false })
        store.directorySync = { _ in errno = EIO; return -1 }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }))
        XCTAssertEqual(try store.load()?.pending, .target(fan: 0, rpm: 4000))
        XCTAssertTrue(actuator.requiresExternalRecovery)
        XCTAssertThrowsError(try actuator.restore(conflict: { nil }))
        XCTAssertEqual(hardware.operations, [.mode(fan: 0, manual: true)])
        let restarted = try FanActuator(hardware: hardware, persistence: store, bootID: boot,
            serviceGeneration: generation, artifactIdentity: artifact)
        XCTAssertThrowsError(try restarted.restore(conflict: { nil }))
        XCTAssertEqual(hardware.operations, [.mode(fan: 0, manual: true)])
    }

    func testSlowJournalOrConflictAppearingDuringLoadPreventsRecoveryCommit() throws {
        for slow in [true, false] {
            let hardware = RecoveryFans(), journal = RecoveryJournal()
            let id = pending(hardware, journal: journal), retained = journal.record
            let actuator = try actuator(hardware, journal: journal)
            var utility: String?
            journal.onLoad = {
                if slow { hardware.clock.now += 3 }
                else { utility = "Macs Fan Control" }
            }
            XCTAssertThrowsError(try actuator.confirmExternalRecovery(recoveryID: id,
                conflict: { utility }, clock: { hardware.clock.now }))
            XCTAssertEqual(journal.record, retained); XCTAssertEqual(journal.removals, 0)
            XCTAssertEqual(hardware.probes, 2); XCTAssertTrue(hardware.operations.isEmpty)
        }
    }

    func testWakeCannotUseAutomaticTelemetryToClearRecoveryHold() throws {
        var qualifier = FanWakeQualification()
        var status = FanStatus(serviceGeneration: generation)
        status.capabilities = FanPolicyTests.capabilities
        status.snapshot = FanPolicyTests.frame(40, at: 100)
        status.externalRecoveryRequired = true
        XCTAssertThrowsError(try qualifier.observe(status, now: 100, conflict: nil))
        status.externalRecoveryRequired = false; status.mode = .externalRecoveryRequired
        XCTAssertThrowsError(try qualifier.observe(status, now: 100, conflict: nil))
        XCTAssertEqual(qualifier.consecutiveHealthyFrames, 0)
    }
}
