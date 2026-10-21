import XCTest
@testable import FanControlCore
@testable import FanControlRuntime

private final class DiagnosticClock {
    var now: TimeInterval = 100
}

private final class DiagnosticJournal: FanRecoveryPersistence {
    var record: FanRecoveryRecord?
    var saved: [FanRecoveryRecord] = []
    var onAcknowledgement: (() throws -> Void)?
    func load() throws -> FanRecoveryRecord? { record }
    func save(_ record: FanRecoveryRecord) throws { self.record = record; saved.append(record) }
    func remove() throws { record = nil }
    func acknowledgeManualMode(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                               validate: () throws -> Void) throws {
        guard record == pending else { throw FanControlError.ownership("Fake pending record changed") }
        try validate(); try onAcknowledgement?(); try validate()
        try save(acknowledged)
        do { try validate() } catch { record = pending; throw error }
    }
    func acknowledgeBoundedOperation(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                                     validate: () throws -> Void) throws {
        guard record == pending else { throw FanControlError.ownership("Fake pending record changed") }
        try validate(); try save(acknowledged)
        do { try validate() } catch { record = pending; throw error }
    }
}

private final class DiagnosticFans: FanHardware {
    let clock = DiagnosticClock()
    let capabilities = FanPolicyTests.capabilities
    var state = FanPolicyTests.frame(75, at: 100).controlObservation
    var operations: [FanOperation] = []
    var readStarts: [TimeInterval] = []
    var onRead: ((Int) throws -> Void)?
    var onDiagnosticReadBoundary: (() -> Void)?
    var admittedDiagnosticBoundaries = 0
    var onPerform: (() throws -> Void)?
    var deferWrites = true
    var performDuration: TimeInterval = 0
    var capacity = Int.max
    var captures = 0
    var captureEnds = 0
    var capturedAtOverride: TimeInterval?
    var receipt: FanNativeCallReceipt?
    var receiptOverride: FanNativeCallReceipt?
    var probeModel: String?
    var probeMetadata: [FanDescriptor]?
    func discover() throws -> FanCapabilities { capabilities }
    func read(_ capabilities: FanCapabilities) throws -> FanSnapshot {
        FanSnapshot(capturedAt: clock.now, temperatures: FanPolicyTests.frame(75).temperatures,
            fans: state.fans, thermalPressure: .nominal, globalUnlock: state.globalUnlock)
    }
    func readControlState(_ capabilities: FanCapabilities) throws -> FanControlObservation {
        let startedAt = clock.now
        readStarts.append(startedAt)
        try onRead?(readStarts.count)
        return FanControlObservation(capturedAt: capturedAtOverride ?? startedAt, fans: state.fans, globalUnlock: state.globalUnlock)
    }
    func readControlState(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanControlObservation {
        guard !cancelled() else { throw FanControlError.cancelled }
        let observation = try readControlState(capabilities)
        if let boundary = onDiagnosticReadBoundary {
            boundary()
            guard !cancelled() else { throw FanControlError.cancelled }
            admittedDiagnosticBoundaries += 1
        }
        return observation
    }
    func perform(_ operation: FanOperation, capabilities: FanCapabilities, cancelled: () -> Bool) throws {
        guard !cancelled() else { throw FanControlError.cancelled }
        let startedAt = clock.now
        operations.append(operation); clock.now += performDuration
        switch operation {
        case .mode(let id, let manual):
            receipt = receiptOverride ?? FanNativeCallReceipt(key: capabilities.fans[id].modeKey, command: 6,
                startedAt: startedAt, returnedAt: clock.now, kernelResult: 0, requestedValueBytes: 1,
                returnedStructBytes: 80, firmwareResult: 0, firmwareStatus: 0, returnedValueHex: "00",
                requestedValueHex: manual ? "01" : "00")
        case .target(let id, let rpm):
            // Successor targets and release resets use bounded acknowledgement,
            // which correlates this command-6 receipt.
            let hex = FanActuator.targetPayloadHex(rpm, encoding: capabilities.fans[id].targetEncoding) ?? ""
            receipt = FanNativeCallReceipt(key: "F\(id)Tg", command: 6, startedAt: startedAt, returnedAt: clock.now,
                kernelResult: 0, requestedValueBytes: UInt32(hex.count / 2), returnedStructBytes: 80,
                firmwareResult: 0, firmwareStatus: 0, returnedValueHex: String(repeating: "0", count: hex.count),
                requestedValueHex: hex)
        case .globalUnlock: break
        }
        try onPerform?()
        if !deferWrites { apply(operation) }
    }
    func apply(_ operation: FanOperation) {
        switch operation {
        case .mode(let fan, let manual): state.fans[fan].mode = manual ? 1 : 0
        case .target(let fan, let rpm): state.fans[fan].targetRPM = rpm
        case .globalUnlock(let enabled): state.globalUnlock = enabled ? 1 : 0
        }
    }
    func beginCommandDiagnosticCapture() { captures += 1; receipt = nil }
    func endCommandDiagnosticCapture() -> [FanNativeCallReceipt] { captureEnds += 1; return receipt.map { [$0] } ?? [] }
    var commandDiagnosticCapacityRemaining: Int { capacity }
    var commandDiagnosticWrite: FanNativeCallReceipt? { receipt }
    func probeFans(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanFanProbe {
        FanFanProbe(model: probeModel ?? capabilities.model, fans: probeMetadata ?? capabilities.fans,
            observation: try readControlState(capabilities, cancelled: cancelled))
    }
}

final class FanModeDiagnosticTests: XCTestCase {
    private let boot = UUID().uuidString
    private let generation = UUID().uuidString
    private func timing(_ fans: DiagnosticFans, pause: ((TimeInterval) -> Void)? = nil) -> FanModeDiagnosticTiming {
        FanModeDiagnosticTiming(clock: { fans.clock.now }, pause: pause ?? { fans.clock.now += $0 })
    }
    private func actuator(_ fans: DiagnosticFans, _ journal: DiagnosticJournal,
                          timing: FanModeDiagnosticTiming? = nil) throws -> FanActuator {
        let actuator = try FanActuator(hardware: fans, persistence: journal, bootID: boot,
            serviceGeneration: generation, artifactIdentity: "fake-diagnostic-artifact",
            modeDiagnosticTiming: timing ?? self.timing(fans))
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        return actuator
    }
    @discardableResult
    private func mismatch(_ actuator: FanActuator, _ fans: DiagnosticFans, cancelled: () -> Bool = { false }) throws -> FanManualModeDiagnostic {
        var primary: String?
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: cancelled, manualModeCommit: { try $0(fans.clock.now) })) {
            primary = $0.localizedDescription
        }
        let diagnostic = try XCTUnwrap(actuator.lastManualModeDiagnostic)
        XCTAssertEqual(primary, diagnostic.primaryFailure)
        XCTAssertTrue(diagnostic.evidenceOnly); XCTAssertTrue(diagnostic.pendingRetained)
        return diagnostic
    }
    private func held(_ actuator: FanActuator, _ journal: DiagnosticJournal, _ fans: DiagnosticFans) {
        XCTAssertTrue(actuator.requiresExternalRecovery)
        XCTAssertEqual(journal.record?.pending, .mode(fan: 0, manual: true))
        XCTAssertEqual(journal.record?.acknowledged.fans.map(\.mode), [0, 0])
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])
        XCTAssertEqual(journal.saved.count, 2)
    }

    func testTwoLaterMatchingProbesAcknowledgeOneWriteAndPreserveFirstMismatch() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let actuator = try actuator(fans, journal)
        fans.onRead = { index in if index >= 3 { fans.apply(.mode(fan: 0, manual: true)) } }
        let observed = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
        let trace = try XCTUnwrap(actuator.lastManualModeDiagnostic)
        XCTAssertFalse(trace.probes[0].operationConfirmed)
        XCTAssertTrue(trace.probes.dropFirst().allSatisfy(\.operationConfirmed))
        XCTAssertEqual(trace.probes.count, 3)
        XCTAssertEqual(trace.firstMismatchAt, 100)
        XCTAssertEqual(trace.deadline, 101)
        XCTAssertEqual(trace.termination, "acknowledged")
        XCTAssertFalse(trace.evidenceOnly); XCTAssertFalse(trace.pendingRetained)
        XCTAssertNotNil(trace.acknowledgedAt); XCTAssertFalse(trace.primaryFailure.isEmpty)
        XCTAssertEqual(trace.nativeWriteReturnedAt, 100)
        XCTAssertNil(journal.record?.pending); XCTAssertFalse(actuator.requiresExternalRecovery)
        XCTAssertEqual(observed.fans[0].mode, 1)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])
        fans.deferWrites = false
        fans.onPerform = {
            XCTAssertEqual(journal.record?.pending, .target(fan: 0, rpm: 4000))
            XCTAssertEqual(journal.record?.acknowledged.fans[0].mode, 1)
            XCTAssertTrue(journal.saved.contains { $0.pending == nil && $0.acknowledged.fans[0].mode == 1 })
        }
        XCTAssertNoThrow(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false },
                                             acknowledgementConflict: { nil }))
        XCTAssertEqual(actuator.lastTargetDiagnostic?.termination, "acknowledged")
        XCTAssertEqual(actuator.lastManualModeDiagnostic, trace)
    }

    func testNeverVisibleStopsAtFixedDeadlineWithNoLateProbeStart() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let actuator = try actuator(fans, journal)
        let trace = try mismatch(actuator, fans)
        XCTAssertEqual(trace.termination, "deadline")
        XCTAssertTrue(fans.readStarts.allSatisfy { $0 < 101 })
        XCTAssertLessThanOrEqual(trace.probes.count, 11)
        XCTAssertEqual(try XCTUnwrap(trace.endedAt), 101, accuracy: 0.000_01)
        XCTAssertFalse(trace.probes.contains(where: \.operationConfirmed))
        held(actuator, journal, fans)
    }

    func testCancellationAtFirstMismatchPreventsAdditionalReads() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let actuator = try actuator(fans, journal)
        var revoked = false
        fans.onRead = { if $0 == 2 { revoked = true } }
        let trace = try mismatch(actuator, fans, cancelled: { revoked })
        XCTAssertEqual(trace.termination, "cancelledOrPermissionRevoked")
        XCTAssertEqual(trace.probes.count, 1); XCTAssertEqual(fans.readStarts.count, 2)
        held(actuator, journal, fans)
    }

    func testCancellationDuringShortWaitRetainsTheImmediateProbe() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        var revoked = false
        let timing = timing(fans) { interval in
            fans.clock.now += interval
            if fans.clock.now >= 100.04 { revoked = true }
        }
        let actuator = try actuator(fans, journal, timing: timing)
        let trace = try mismatch(actuator, fans, cancelled: { revoked })
        XCTAssertEqual(trace.termination, "cancelledOrPermissionRevoked")
        XCTAssertEqual(fans.readStarts.count, 2)
        XCTAssertLessThan(try XCTUnwrap(trace.endedAt), 100.1)
        held(actuator, journal, fans)
    }

    func testCancellationAfterReturnedProbeKeepsThatEvidenceAndStops() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let actuator = try actuator(fans, journal)
        var revoked = false
        fans.onRead = { index in
            if index == 3 { fans.apply(.mode(fan: 0, manual: true)); revoked = true }
        }
        let trace = try mismatch(actuator, fans, cancelled: { revoked })
        XCTAssertEqual(trace.termination, "cancelledOrPermissionRevoked")
        XCTAssertEqual(trace.probes.count, 2)
        XCTAssertTrue(try XCTUnwrap(trace.probes.last).operationConfirmed)
        XCTAssertEqual(fans.readStarts.count, 3)
        held(actuator, journal, fans)
    }

    func testSlowPermissionCheckCannotStartReadPastDeadline() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let actuator = try actuator(fans, journal)
        var consumedBudget = false
        let trace = try mismatch(actuator, fans, cancelled: {
            // Consume the budget after the mismatching immediate read, rather
            // than during the fake perform's own cancellation check.
            if fans.readStarts.count == 2 && !consumedBudget {
                consumedBudget = true; fans.clock.now += 1.1
            }
            return false
        })
        XCTAssertEqual(trace.termination, "deadline")
        XCTAssertTrue(trace.deadlineOverrun)
        XCTAssertEqual(fans.readStarts.count, 2)
        held(actuator, journal, fans)
    }

    func testSlowPermissionCheckWithinProbePreventsItsNextNativeBoundary() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let actuator = try actuator(fans, journal)
        var atBoundary = false, consumedBudget = false
        fans.onDiagnosticReadBoundary = { atBoundary = true }
        let trace = try mismatch(actuator, fans, cancelled: {
            if atBoundary && !consumedBudget {
                consumedBudget = true; fans.clock.now += 1.1
            }
            return false
        })
        XCTAssertTrue(consumedBudget)
        XCTAssertEqual(fans.admittedDiagnosticBoundaries, 0)
        XCTAssertEqual(fans.readStarts.count, 2)
        XCTAssertEqual(trace.probes.count, 1)
        XCTAssertNotNil(trace.probes.last?.error)
        XCTAssertNil(trace.probes.last?.observation)
        XCTAssertEqual(trace.termination, "deadline"); XCTAssertTrue(trace.deadlineOverrun)
        held(actuator, journal, fans)
    }

    func testTelemetryAndLeaseExpiryEndCollectionWithoutFresheningFanData() throws {
        for lease in [false, true] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal(), gate = FanSafetyGate()
            _ = try gate.begin(owner: "owner", now: 100)
            if lease {
                gate.fresh(at: 102, now: 102)
                fans.clock.now = 104.6
                gate.fresh(at: 104.6, now: 104.6)
            } else {
                gate.fresh(at: 97.5, now: 100)
                fans.performDuration = 0.8
            }
            let token = gate.check(now: fans.clock.now).generation
            let actuator = try actuator(fans, journal)
            let trace = try mismatch(actuator, fans, cancelled: { !gate.permits(token, now: fans.clock.now) })
            XCTAssertEqual(trace.termination, "cancelledOrPermissionRevoked")
            let expiry = lease ? 105.0 : 101.5
            XCTAssertTrue(fans.readStarts.allSatisfy { $0 < expiry })
            XCTAssertNotNil(gate.check(now: fans.clock.now).reason)
            XCTAssertLessThan(try XCTUnwrap(trace.endedAt), try XCTUnwrap(trace.deadline))
            held(actuator, journal, fans)
        }
    }

    func testUnexpectedFanTargetOrUnlockStopsAfterRetainingChangedProbe() throws {
        for change in 0...2 {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            let actuator = try actuator(fans, journal)
            fans.onRead = { index in
                guard index == 3 else { return }
                fans.apply(.mode(fan: 0, manual: true))
                if change == 0 { fans.state.fans[1].mode = 1 }
                if change == 1 { fans.state.fans[0].targetRPM = fans.capabilities.fans[0].maximumRPM + 1 }
                if change == 2 { fans.state.globalUnlock = 1 }
            }
            let trace = try mismatch(actuator, fans)
            // Z-Q2: the entered fan alone at a target the record cannot
            // predict is named apart; it keeps the helper's recovery attempt.
            XCTAssertEqual(trace.termination, change == 1 ? "unpredictedEntryTarget" : "unexpectedOwnership")
            XCTAssertEqual(FanActuator.selfRecoveryEligible(cause: trace.termination), change == 1)
            XCTAssertEqual(trace.probes.count, 2)
            XCTAssertNotNil(trace.probes.last?.observation)
            XCTAssertFalse(try XCTUnwrap(trace.probes.last).ownershipMatches)
            held(actuator, journal, fans)
        }
    }

    func testInvalidProbeAndReadFailureKeepPrimaryErrorAndAttempt() throws {
        for readFailure in [false, true] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            let actuator = try actuator(fans, journal)
            fans.onRead = { index in
                if index == 3 {
                    if readFailure { throw FanControlError.hardware("Fake read failed") }
                    fans.state.fans[0].actualRPM = .nan
                }
            }
            let trace = try mismatch(actuator, fans)
            XCTAssertEqual(trace.termination, readFailure ? "readFailure" : "invalidObservation")
            XCTAssertEqual(trace.probes.count, 2)
            XCTAssertNil(trace.probes.last?.observation)
            XCTAssertNotNil(trace.probes.last?.error)
            XCTAssertNoThrow(try JSONEncoder().encode(trace))
            held(actuator, journal, fans)
        }
    }

    func testLateNativeProbeReturnIsRetainedAndStopsFurtherReads() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let actuator = try actuator(fans, journal)
        fans.onRead = { if $0 == 3 { fans.clock.now += 2 } }
        let trace = try mismatch(actuator, fans)
        XCTAssertEqual(trace.termination, "deadline")
        XCTAssertTrue(trace.deadlineOverrun)
        XCTAssertEqual(trace.probes.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(trace.probes.last?.returnedAt), try XCTUnwrap(trace.deadline))
        XCTAssertEqual(fans.readStarts.count, 3)
        held(actuator, journal, fans)
    }

    func testFrozenBackwardAndNonfiniteClocksTerminateWithoutLooping() throws {
        for kind in 0...2 {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            let config = timing(fans) { _ in
                if kind == 1 { fans.clock.now -= 1 }
                if kind == 2 { fans.clock.now = .nan }
            }
            let actuator = try actuator(fans, journal, timing: config)
            let trace = try mismatch(actuator, fans)
            XCTAssertEqual(trace.termination, kind == 0 ? "clockDidNotAdvance" : "invalidOrBackwardClock")
            XCTAssertEqual(fans.readStarts.count, 2)
            XCTAssertNoThrow(try JSONEncoder().encode(trace))
            held(actuator, journal, fans)
        }
    }

    func testNativeCapacityPreventsStartingAnUnretainableProbe() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        fans.capacity = 1
        let actuator = try actuator(fans, journal)
        let trace = try mismatch(actuator, fans)
        XCTAssertEqual(trace.termination, "nativeTraceCapacity")
        XCTAssertEqual(trace.probes.count, 0); XCTAssertEqual(fans.readStarts.count, 1)
        held(actuator, journal, fans)
    }

    // Targets and mode release now use their own bounded acknowledgement and
    // trace; global unlock keeps its single immediate readback. None of them
    // touches the manual-entry trace or policy.
    func testOtherOperationsNeverUseOrChangeTheManualEntryTrace() throws {
        for operation in [FanOperation.target(fan: 0, rpm: 4000), .globalUnlock(true), .mode(fan: 0, manual: false)] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            let actuator = try actuator(fans, journal)
            if case .mode = operation {
                fans.deferWrites = false
                _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
                fans.deferWrites = true; fans.readStarts = []
            }
            let previous = actuator.lastManualModeDiagnostic
            XCTAssertThrowsError(try actuator.mutate(operation, cancelled: { false }, acknowledgementConflict: { nil }))
            if case .globalUnlock = operation {
                XCTAssertEqual(fans.readStarts.count, 2)
                XCTAssertNil(actuator.lastTargetDiagnostic)
            } else {
                // Never visible: complete probes run until the fixed deadline.
                XCTAssertGreaterThan(fans.readStarts.count, 2)
                XCTAssertEqual(actuator.lastTargetDiagnostic?.termination, "deadline")
                XCTAssertEqual(actuator.lastTargetDiagnostic?.operation, operation)
            }
            XCTAssertEqual(actuator.lastManualModeDiagnostic, previous)
        }
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        fans.deferWrites = false
        let actuator = try actuator(fans, journal)
        XCTAssertNoThrow(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) }))
        XCTAssertEqual(fans.readStarts.count, 3)
        XCTAssertEqual(actuator.lastManualModeDiagnostic?.termination, "acknowledged")
    }

    func testPerformAndInitialReadErrorsDoNotStartDiagnosticProbes() throws {
        for transportFailure in [false, true] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            let actuator = try actuator(fans, journal)
            if transportFailure { fans.onPerform = { throw FanControlError.hardware("Fake transport failure") } }
            else { fans.onRead = { if $0 == 2 { throw FanControlError.hardware("Fake immediate read failure") } } }
            XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) }))
            XCTAssertEqual(fans.readStarts.count, transportFailure ? 1 : 2)
            XCTAssertEqual(actuator.lastManualModeDiagnostic?.termination, transportFailure ? "performFailure" : "readFailure")
            XCTAssertGreaterThan(fans.captureEnds, 0)
            held(actuator, journal, fans)
        }
    }

    func testHistoricalPendingIntentCannotStartCaptureOrNewObservation() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let old = try actuator(fans, journal)
        _ = try mismatch(old, fans)
        let count = fans.readStarts.count, captureCount = fans.captures
        let record = journal.record
        let restarted = try FanActuator(hardware: fans, persistence: journal, bootID: UUID().uuidString,
            serviceGeneration: UUID().uuidString, artifactIdentity: "new-artifact", modeDiagnosticTiming: timing(fans))
        XCTAssertThrowsError(try restarted.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) }))
        XCTAssertThrowsError(try restarted.restore(conflict: { nil }))
        XCTAssertEqual(fans.readStarts.count, count); XCTAssertEqual(fans.captures, captureCount)
        XCTAssertEqual(journal.record, record)
        XCTAssertNil(restarted.lastManualModeDiagnostic)
    }

    // The mode became manual and the helper's one release attempt is never
    // seen to take effect in this fake, so the hold remains.
    func testControllerPublishesTraceAndOnlyAttemptsReleaseOnce() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        fans.onRead = { if $0 == 4 { fans.apply(.mode(fan: 0, manual: true)); fans.clock.now += 1.1 } }
        let controller = try FanHelperController(hardware: fans, persistence: journal, bootID: boot,
            artifactIdentity: "fake-artifact", conflict: { nil }, clock: { fans.clock.now }, startTimers: false,
            modeDiagnosticTiming: timing(fans))
        let done = expectation(description: "begin reply")
        var status = FanStatus(serviceGeneration: "none")
        controller.begin(owner: "owner", profile: .standard) { status = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(status.mode, .externalRecoveryRequired)
        XCTAssertTrue(status.externalRecoveryRequired); XCTAssertNil(status.sessionID)
        XCTAssertFalse(status.releaseVerified); XCTAssertFalse(status.safeToUnregister)
        XCTAssertTrue(status.requestedRPM.isEmpty)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .mode(fan: 0, manual: false)],
                       "One release attempt; no retry of the command and no target.")
        XCTAssertEqual(journal.record?.pending, .mode(fan: 0, manual: true))
        XCTAssertEqual(journal.record?.recoveryAttempted, true)
        XCTAssertNil(status.selfRecoveryReceipt?.confirmedAt); XCTAssertNotNil(status.selfRecoveryReceipt?.failure)
        let trace = try XCTUnwrap(status.manualModeDiagnostic)
        XCTAssertTrue(trace.probes.dropFirst().contains(where: \.operationConfirmed))
        XCTAssertTrue(status.diagnostics.contains { $0.contains(trace.primaryFailure) })
        let count = fans.readStarts.count
        controller.begin(owner: "other", profile: .standard) { XCTAssertNotNil($0.requestError) }
        XCTAssertEqual(fans.readStarts.count, count)
        // The automatic attempt is used: polling the hold writes nothing more.
        let polled = expectation(description: "hold polled")
        controller.poll { polled.fulfill() }
        wait(for: [polled], timeout: 1)
        XCTAssertEqual(fans.operations.count, 2)
        XCTAssertEqual(controller.status(observe: false).manualModeDiagnostic, trace)
        let encoded = try JSONEncoder().encode(status)
        XCTAssertLessThan(encoded.count, 262_144)
        XCTAssertEqual(try JSONDecoder().decode(FanStatus.self, from: encoded).manualModeDiagnostic, trace)
    }

    func testPendingAcknowledgementIsVisibleAndWatchdogCanRevokeBlockedRead() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let blocked = expectation(description: "additional fake read entered")
        let release = DispatchSemaphore(value: 0)
        fans.onRead = { index in
            if index == 4 { blocked.fulfill(); _ = release.wait(timeout: .now() + 2) }
        }
        let controller = try FanHelperController(hardware: fans, persistence: journal, bootID: boot,
            artifactIdentity: "fake-artifact", conflict: { nil }, clock: { fans.clock.now }, startTimers: false,
            modeDiagnosticTiming: timing(fans))
        let done = expectation(description: "begin finishes after release")
        controller.begin(owner: "owner", profile: .standard) { _ in done.fulfill() }
        wait(for: [blocked], timeout: 1)
        let whileBlocked = controller.status(observe: false)
        XCTAssertFalse(whileBlocked.externalRecoveryRequired)
        XCTAssertEqual(whileBlocked.mode, .acquiring)
        XCTAssertNotNil(whileBlocked.sessionID); XCTAssertFalse(whileBlocked.safeToUnregister)
        XCTAssertNotNil(controller.safety.check(now: fans.clock.now).session)
        let session = try XCTUnwrap(controller.safety.check(now: fans.clock.now).session)
        XCTAssertTrue(controller.renew(owner: "owner", session: session))
        XCTAssertTrue(whileBlocked.reason?.contains("confirm manual control") == true)
        controller.begin(owner: "other", profile: .standard) { XCTAssertNotNil($0.requestError) }
        fans.clock.now += 4.1
        controller.checkWatchdog()
        XCTAssertEqual(controller.status(observe: false).mode, .restoring)
        XCTAssertTrue(controller.status(observe: false).reason?.contains("four seconds") == true)
        release.signal()
        wait(for: [done], timeout: 1)
        // The entry stayed unconfirmed and still reads automatic. The helper
        // releases the named fan anyway, writes no reset target (Z-Q3), and
        // clears the hold only after the settle check.
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .mode(fan: 0, manual: false)])
        let after = controller.status(observe: false)
        XCTAssertFalse(after.externalRecoveryRequired); XCTAssertEqual(after.mode, .paused)
        XCTAssertEqual(after.selfRecoveryReceipt?.cause, "cancelledOrPermissionRevoked")
        XCTAssertNotNil(after.selfRecoveryReceipt?.confirmedAt)
        XCTAssertNil(journal.record)
        XCTAssertNotNil(after.manualModeDiagnostic)
    }

    func testMaximumTraceReplyFitsAndOldStatusRemainsDecodable() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let actuator = try actuator(fans, journal)
        var trace = try mismatch(actuator, fans)
        trace.nativeCalls = (0..<256).map { index in
            FanNativeCallReceipt(key: "F9Ac", command: 5, startedAt: 100 + Double(index) / 1000,
                returnedAt: 100.0001 + Double(index) / 1000, kernelResult: 0,
                requestedValueBytes: 32, returnedStructBytes: 80, firmwareResult: 0,
                firmwareStatus: 255, returnedValueHex: String(repeating: "ff", count: 32),
                requestedValueHex: String(repeating: "01", count: 32))
        }
        var status = FanStatus(serviceGeneration: generation)
        status.manualModeDiagnostic = trace
        status.mode = .externalRecoveryRequired; status.reason = FanActuator.externalRecoveryReason
        status.externalRecoveryRequired = true; status.externalRecoveryID = generation
        status.ownsOverride = true
        // Each line is within the admitted provenance character limit but JSON
        // escaping and multibyte text make the full reply much larger.
        status.diagnostics = (0..<200).map { "line-\($0):" + String(repeating: "\"\\\n風🔥", count: 700) }
        XCTAssertGreaterThan(try JSONEncoder().encode(status).count, FanStatus.maximumReplyBytes)
        let data = try status.encodedReply()
        XCTAssertLessThanOrEqual(data.count, FanStatus.maximumReplyBytes)
        let decoded = try JSONDecoder().decode(FanStatus.self, from: data)
        XCTAssertEqual(decoded.manualModeDiagnostic, trace)
        XCTAssertEqual(decoded.mode, .externalRecoveryRequired)
        XCTAssertTrue(decoded.externalRecoveryRequired); XCTAssertTrue(decoded.ownsOverride)
        XCTAssertEqual(decoded.externalRecoveryID, generation)
        XCTAssertEqual(decoded.reason, FanActuator.externalRecoveryReason)
        XCTAssertFalse(decoded.safeToUnregister); XCTAssertFalse(decoded.releaseVerified)
        XCTAssertGreaterThan(try XCTUnwrap(decoded.diagnosticsOmittedCount), 0)
        XCTAssertEqual(decoded.diagnosticsOmittedCount, 200 - decoded.diagnostics.count)
        XCTAssertEqual(decoded.diagnostics.last, status.diagnostics.last)
        XCTAssertEqual(decoded.diagnostics, Array(status.diagnostics.suffix(decoded.diagnostics.count)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "manualModeDiagnostic")
        object.removeValue(forKey: "diagnosticsOmittedCount")
        XCTAssertNil(try JSONDecoder().decode(FanStatus.self, from: JSONSerialization.data(withJSONObject: object)).manualModeDiagnostic)
    }

    func testOneMatchAndInterruptedMatchesCannotAcknowledgeManualEntry() throws {
        for isolated in [true, false] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            let actuator = try actuator(fans, journal)
            fans.onRead = { index in
                guard index >= 2 else { return }
                fans.apply(.mode(fan: 0, manual: isolated ? index == 3 : index.isMultiple(of: 2)))
            }
            let trace = try mismatch(actuator, fans)
            XCTAssertTrue(trace.probes.contains(where: \.operationConfirmed))
            XCTAssertNil(trace.acknowledgedAt)
            XCTAssertEqual(trace.termination, "deadline")
            held(actuator, journal, fans)
        }
    }

    func testDuplicateOrStaleProbeCannotSupplyTheSecondMatch() throws {
        for capturedAt in [100.0, 99.0] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            fans.deferWrites = false
            let actuator = try actuator(fans, journal)
            fans.onRead = { if $0 == 3 { fans.capturedAtOverride = capturedAt } }
            let trace = try mismatch(actuator, fans)
            XCTAssertEqual(trace.termination, "invalidObservation")
            XCTAssertEqual(trace.probes.count, 2)
            XCTAssertTrue(trace.probes[0].operationConfirmed)
            XCTAssertNil(trace.probes[1].observation)
            held(actuator, journal, fans)
        }
    }

    func testChangedCompleteProbeMetadataOrModelCannotAcknowledge() throws {
        for modelChanged in [true, false] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            fans.deferWrites = false
            let actuator = try actuator(fans, journal)
            if modelChanged { fans.probeModel = "Mac14,10" }
            else { fans.probeMetadata = Array(fans.capabilities.fans.prefix(1)) }
            let trace = try mismatch(actuator, fans)
            XCTAssertEqual(trace.termination, "invalidObservation")
            XCTAssertEqual(trace.probes.count, 1)
            XCTAssertNil(trace.probes[0].observation)
            XCTAssertEqual(trace.probes[0].model, fans.probeModel ?? fans.capabilities.model)
            XCTAssertEqual(trace.probes[0].fanMetadata, fans.probeMetadata ?? fans.capabilities.fans)
            held(actuator, journal, fans)
        }
    }

    func testAutomaticFanTargetDriftAndMeasuredRPMDoNotPreventModeAcknowledgement() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        fans.deferWrites = false
        let actuator = try actuator(fans, journal)
        fans.onRead = { index in
            if index >= 2 {
                fans.state.fans[1].targetRPM = Double(index) * 100
                fans.state.fans[0].actualRPM = 1200
            }
        }
        let observation = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
        XCTAssertEqual(observation.fans[0].actualRPM, 1200)
        XCTAssertEqual(observation.fans[0].targetRPM, 0)
        XCTAssertEqual(observation.fans[1].mode, 0)
        XCTAssertEqual(observation.fans[1].targetRPM, 300)
        XCTAssertEqual(actuator.lastManualModeDiagnostic?.probes.count, 2)
        XCTAssertNil(journal.record?.pending)
    }

    func testFirmwareSelectedEntryTargetIsAcknowledgedOnlyAfterTwoStableProbes() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        fans.state.fans[0].targetRPM = 2633
        let actuator = try actuator(fans, journal)
        fans.onRead = { index in
            guard index >= 3 else { return }
            fans.apply(.mode(fan: 0, manual: true))
            // The first visible manual target differs from the pre-write
            // automatic value; it then settles while the other fan stays auto.
            fans.state.fans[0].targetRPM = index == 3 ? 2642 : 2650
            fans.state.fans[1].targetRPM = Double(index) * 100
        }
        let observed = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
                                          manualModeCommit: { try $0(fans.clock.now) })
        let trace = try XCTUnwrap(actuator.lastManualModeDiagnostic)
        XCTAssertEqual(trace.termination, "acknowledged")
        XCTAssertEqual(trace.probes.count, 4, "A changing entry target cannot count as two stable confirmations.")
        XCTAssertEqual(observed.fans[0].targetRPM, 2650)
        XCTAssertEqual(actuator.record?.acknowledged, observed)
        XCTAssertNil(actuator.record?.pending)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)], "No retry or target write during entry.")
        fans.onRead = nil
        fans.state.fans[0].targetRPM += 10
        XCTAssertThrowsError(try actuator.verifyOwnership(conflict: nil), "Once acknowledged, target drift is still a conflict.")
    }

    // Z-Q3: the hold of 2026-10-19. Fan 0 read automatic while still showing
    // its last manual target of 2322.57 RPM, and its next manual entry landed
    // at 0 RPM. That entry target is admitted like a firmware-selected one;
    // the controller writes its own target in the same cycle. Any other
    // target outside the fan's range is not; the acknowledgement names it
    // apart so that the helper's recovery attempt stays open (Z-Q2).
    func testZeroEntryTargetIsAcknowledgedAndAnyOtherOutOfRangeOneIsNamedApart() throws {
        for entryTarget in [0.0, 500] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            fans.state.fans[0].targetRPM = 2322.56884765625
            let actuator = try actuator(fans, journal)
            fans.onRead = { index in
                guard index >= 3 else { return }
                fans.apply(.mode(fan: 0, manual: true)); fans.state.fans[0].targetRPM = entryTarget
            }
            guard entryTarget == 0 else {
                let trace = try mismatch(actuator, fans)
                XCTAssertEqual(trace.termination, "unpredictedEntryTarget")
                XCTAssertTrue(FanActuator.selfRecoveryEligible(cause: trace.termination))
                XCTAssertTrue(actuator.requiresExternalRecovery)
                continue
            }
            let observed = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
                                              manualModeCommit: { try $0(fans.clock.now) })
            let trace = try XCTUnwrap(actuator.lastManualModeDiagnostic)
            XCTAssertEqual(trace.termination, "acknowledged")
            XCTAssertTrue(trace.probes.dropFirst().allSatisfy(\.ownershipMatches))
            XCTAssertEqual(observed.fans[0].mode, 1); XCTAssertEqual(observed.fans[0].targetRPM, 0)
            XCTAssertEqual(actuator.record?.acknowledged, observed); XCTAssertNil(actuator.record?.pending)
            // The journal store's own check of the published pair agrees.
            let pending = try XCTUnwrap(journal.saved.first { $0.pending == .mode(fan: 0, manual: true) })
            let acknowledged = try XCTUnwrap(actuator.record)
            XCTAssertTrue(acknowledged.acknowledgesManualMode(in: pending))
            var unpredicted = acknowledged; unpredicted.acknowledged.fans[0].targetRPM = 500
            XCTAssertFalse(unpredicted.acknowledgesManualMode(in: pending))
        }
    }

    // Z-Q2 needs no known fan utility: one seen at the probe that finds the
    // unpredicted target makes the outcome a competing utility, which keeps
    // the helper from trying by itself.
    func testUnpredictedEntryTargetWithACompetingUtilityIsNotEligible() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let actuator = try actuator(fans, journal)
        var utility: String?
        // Read 1 is the pre-write observation; probes read from 2.
        fans.onRead = { index in
            guard index >= 2 else { return }
            fans.apply(.mode(fan: 0, manual: true)); fans.state.fans[0].targetRPM = 500
            utility = "Macs Fan Control"
        }
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
            confirmationCancelled: { false }, manualModeCommit: { try $0(fans.clock.now) },
            acknowledgementConflict: { utility }))
        let trace = try XCTUnwrap(actuator.lastManualModeDiagnostic)
        XCTAssertEqual(trace.termination, "conflictingUtility")
        XCTAssertEqual(trace.cancellationCause, "Macs Fan Control appeared.")
        XCTAssertFalse(FanActuator.selfRecoveryEligible(cause: trace.termination))
        XCTAssertFalse(try XCTUnwrap(trace.probes.last).ownershipMatches)
        XCTAssertTrue(actuator.requiresExternalRecovery)
    }

    func testEntryTargetAllowanceDoesNotMaskChangesToAnAlreadyOwnedFan() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        fans.deferWrites = false
        let actuator = try actuator(fans, journal)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
                                manualModeCommit: { try $0(fans.clock.now) })
        let first = fans.readStarts.count
        fans.onRead = { index in
            if index >= first + 2 {
                fans.state.fans[0].targetRPM = 4000
                fans.state.fans[1].targetRPM = 2600
            }
        }
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 1, manual: true), cancelled: { false },
                                                 manualModeCommit: { try $0(fans.clock.now) }))
        XCTAssertEqual(actuator.lastManualModeDiagnostic?.termination, "unexpectedOwnership")
        XCTAssertEqual(actuator.record?.pending, .mode(fan: 1, manual: true))
    }

    func testMissingMismatchedFailedOrStaleNativeReceiptCannotStartAcknowledgement() throws {
        for kind in 0..<8 {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            fans.deferWrites = false
            let actuator = try actuator(fans, journal)
            fans.onPerform = {
                if kind == 0 { fans.receipt = nil; return }
                fans.receipt = FanNativeCallReceipt(key: kind == 1 ? "F1md" : "F0md",
                    command: kind == 2 ? 5 : 6, startedAt: kind == 3 ? 99 : 100,
                    returnedAt: kind == 4 ? 101 : 100, kernelResult: kind == 5 ? 1 : 0,
                    requestedValueBytes: 1, returnedStructBytes: 80, firmwareResult: 0,
                    firmwareStatus: kind == 6 ? 127 : 0, returnedValueHex: "00",
                    requestedValueHex: kind == 7 ? "00" : "01")
            }
            let trace = try mismatch(actuator, fans)
            XCTAssertEqual(trace.termination, "invalidNativeWriteReceipt")
            XCTAssertTrue(trace.probes.isEmpty)
            XCTAssertEqual(fans.readStarts.count, 1)
            held(actuator, journal, fans)
        }
    }

    func testWrapperDelayCannotExtendTheActualNativeReturnDeadline() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        fans.deferWrites = false
        let actuator = try actuator(fans, journal)
        fans.onPerform = { fans.clock.now += 1.1 }
        let trace = try mismatch(actuator, fans)
        XCTAssertEqual(trace.nativeWriteReturnedAt, 100)
        XCTAssertEqual(trace.performReturnedAt, 101.1)
        XCTAssertEqual(trace.deadline, 101)
        XCTAssertEqual(trace.termination, "deadline")
        XCTAssertTrue(trace.probes.isEmpty)
        held(actuator, journal, fans)
    }

    func testMatchingSecondProbeReturningExactlyAtDeadlineRemainsPending() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        fans.deferWrites = false
        let actuator = try actuator(fans, journal)
        fans.onRead = { if $0 == 3 { fans.clock.now = 101 } }
        let trace = try mismatch(actuator, fans)
        XCTAssertEqual(trace.termination, "deadline")
        XCTAssertTrue(trace.probes.allSatisfy(\.operationConfirmed))
        XCTAssertEqual(trace.probes.count, 2)
        XCTAssertNil(trace.acknowledgedAt)
        held(actuator, journal, fans)
    }

    func testRevocationOnTheSecondMatchingProbeAndBeforeCommitCannotAcknowledge() throws {
        for beforeCommit in [true, false] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            fans.deferWrites = false
            let actuator = try actuator(fans, journal)
            var revoked = false
            if beforeCommit { journal.onAcknowledgement = { revoked = true } }
            else { fans.onRead = { if $0 == 3 { revoked = true } } }
            let trace = try mismatch(actuator, fans, cancelled: { revoked })
            XCTAssertEqual(trace.termination, "cancelledOrPermissionRevoked")
            XCTAssertEqual(trace.probes.count, 2)
            XCTAssertTrue(trace.probes.allSatisfy(\.operationConfirmed))
            held(actuator, journal, fans)
        }
    }

    func testOriginalTraceDecodesWithoutAdditiveAcknowledgementFields() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let trace = try mismatch(actuator(fans, journal), fans)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(trace)) as? [String: Any])
        for key in ["nativeWriteReturnedAt", "acknowledgedAt", "acknowledgementError"] { object.removeValue(forKey: key) }
        var probes = try XCTUnwrap(object["probes"] as? [[String: Any]])
        for index in probes.indices { probes[index].removeValue(forKey: "model"); probes[index].removeValue(forKey: "fanMetadata") }
        object["probes"] = probes
        var calls = try XCTUnwrap(object["nativeCalls"] as? [[String: Any]])
        for index in calls.indices { calls[index].removeValue(forKey: "requestedValueHex") }
        object["nativeCalls"] = calls
        let decoded = try JSONDecoder().decode(FanManualModeDiagnostic.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.nativeWriteReturnedAt); XCTAssertNil(decoded.acknowledgedAt)
        XCTAssertTrue(decoded.evidenceOnly); XCTAssertTrue(decoded.pendingRetained)
        XCTAssertNil(decoded.probes.first?.model); XCTAssertNil(decoded.nativeCalls.first?.requestedValueHex)
    }

    func testTimedManualEntryWithoutAtomicPublisherFailsBeforeNativeWrite() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        let actuator = try actuator(fans, journal)
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }))
        XCTAssertTrue(fans.operations.isEmpty); XCTAssertTrue(fans.readStarts.isEmpty)
        XCTAssertNil(journal.record?.pending); XCTAssertEqual(journal.saved.count, 1)
        XCTAssertNil(actuator.lastManualModeDiagnostic)
    }

    func testControllerRevokesPendingAcknowledgementForLifecycleProfileAndConflictChanges() throws {
        for beforeCommit in [true, false] {
            for change in 0..<6 {
                let fans = DiagnosticFans(), journal = DiagnosticJournal()
                fans.deferWrites = false
                var utility: String?, controller: FanHelperController!
                controller = try FanHelperController(hardware: fans, persistence: journal, bootID: boot,
                    artifactIdentity: "fake-artifact", conflict: { utility }, clock: { fans.clock.now },
                    startTimers: false, modeDiagnosticTiming: timing(fans))
                let done = expectation(description: "begin returns with pending recovery")
                let action = [0, 2, 3, 4].contains(change) ? expectation(description: "queued lifecycle action finishes") : nil
                let revoke = {
                    switch change {
                    case 0: controller.stop(owner: "owner", reason: "Owner stopped") { _ in action?.fulfill() }
                    case 1: controller.disconnected(owner: "owner")
                    case 2: controller.systemWillSleep { action?.fulfill() }
                    case 3: controller.prepareRemoval(owner: "owner") { _ in action?.fulfill() }
                    case 4:
                        guard let session = controller.status(observe: false).sessionID else { XCTFail("Missing pending owner"); return }
                        controller.updateProfile(owner: "owner", session: session, profile: FanProfile(start: 50, maximum: 85)) { _ in action?.fulfill() }
                    default: utility = "Macs Fan Control"
                    }
                }
                if beforeCommit { journal.onAcknowledgement = revoke }
                else { fans.onRead = { if $0 == 4 { revoke() } } }
                controller.begin(owner: "owner", profile: .standard) { status in
                    // A competing utility keeps the hold; a lifecycle
                    // revocation is followed by the helper's own release.
                    XCTAssertEqual(status.externalRecoveryRequired, change == 5)
                    XCTAssertEqual(status.selfRecoveryReceipt?.confirmedAt != nil, change != 5)
                    // Lifecycle permission is checked before every native call;
                    // the competing utility only at probe boundaries and before
                    // publication, where it is named as the cause.
                    let trace = status.manualModeDiagnostic
                    XCTAssertEqual(trace?.termination, change == 5 ? "conflictingUtility" : "cancelledOrPermissionRevoked")
                    XCTAssertEqual(trace?.cancellationCause, change == 5 ? "Macs Fan Control appeared." : nil)
                    XCTAssertNil(trace?.acknowledgedAt)
                    XCTAssertNil(status.sessionID); XCTAssertEqual(status.safeToUnregister, change != 5)
                    done.fulfill()
                }
                wait(for: [done] + (action.map { [$0] } ?? []), timeout: 1)
                if change != 5 {
                    // A revocation during the durable save is marked and
                    // released too. This fake journal stages no pending copy;
                    // the real store's handling of the mark over its staged
                    // copy is asserted in FanSelfRecoveryTests.
                    XCTAssertNil(journal.record)
                    XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .mode(fan: 0, manual: false)])
                    continue
                }
                // A competing utility is an excluded cause (E-Q1): the helper
                // does not try by itself and journals that decision, so the
                // pending intent is on disk with it. When the utility appeared
                // during the durable save, this fake journal had completed
                // that save without a staged pending copy; the decline puts
                // the pending intent back. The real store's handling of a
                // decline over its staged copy is asserted in
                // FanSelfRecoveryTests.
                XCTAssertEqual(journal.record?.pending, .mode(fan: 0, manual: true))
                XCTAssertEqual(journal.record?.recoveryDeclined, true); XCTAssertNil(journal.record?.recoveryAttempted)
                XCTAssertEqual(controller.status(observe: false).externalRecoveryRequired, true)
                XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])
            }
        }
    }

    func testOversizedStructuredReceiptIsRejectedWithoutDroppingEvidence() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        var trace = try mismatch(actuator(fans, journal), fans)
        let original = trace
        trace.probes.append(FanDiagnosticProbe(index: 11, startedAt: nil, returnedAt: nil,
            observation: nil, error: String(repeating: "oversized fake failure", count: 20_000),
            operationConfirmed: false, ownershipMatches: false))
        var status = FanStatus(serviceGeneration: generation)
        status.manualModeDiagnostic = trace; status.externalRecoveryRequired = true
        XCTAssertThrowsError(try status.encodedReply())
        XCTAssertEqual(status.manualModeDiagnostic?.primaryFailure, original.primaryFailure)
        XCTAssertEqual(status.manualModeDiagnostic?.probes.count, original.probes.count + 1)
    }

    func testConflictEnumerationCannotPermitCommandAfterTelemetryOrLeaseExpiry() throws {
        for lease in [false, true] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            var consumedBudget = false
            var controller: FanHelperController!
            controller = try FanHelperController(hardware: fans, persistence: journal, bootID: boot,
                artifactIdentity: "fake-artifact", conflict: {
                    // The fake perform's final native admission check runs
                    // after ownership and pre-write observations (two reads).
                    if fans.readStarts.count == 2 && !consumedBudget {
                        consumedBudget = true
                        if lease {
                            fans.clock.now += 2.5
                            // Simulate an independently completed fresh frame
                            // so lease expiry precedes telemetry expiry.
                            controller.safety.fresh(at: fans.clock.now, now: fans.clock.now)
                            fans.clock.now += 2.6
                        } else { fans.clock.now += 4.1 }
                    }
                    return nil
                }, clock: { fans.clock.now }, startTimers: false, modeDiagnosticTiming: timing(fans))
            let done = expectation(description: "cancelled begin finishes")
            controller.begin(owner: "owner", profile: .standard) { _ in done.fulfill() }
            wait(for: [done], timeout: 1)
            XCTAssertTrue(consumedBudget)
            // The journaled manual entry was never issued. The helper cannot
            // tell from its journal, so it releases its fans and clears the
            // hold; no manual mode and no speed is ever written.
            XCTAssertFalse(fans.operations.contains(.mode(fan: 0, manual: true)))
            XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: false)])
            XCTAssertNil(journal.record)
            XCTAssertEqual(controller.status(observe: false).selfRecoveryReceipt?.cause, "performFailure")
            XCTAssertNotNil(controller.status(observe: false).selfRecoveryReceipt?.confirmedAt)
        }
    }

    // With a separate conflict check, the full admission check (with process
    // enumeration) runs only before the write; confirmation checks lifecycle
    // permission per native call and the utility only at probe boundaries.
    func testManualEntryChecksTheCompetingUtilityOnlyAtProbeBoundariesAndPublication() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        fans.deferWrites = false
        let actuator = try actuator(fans, journal)
        var admissions = 0, lifecycle = 0, checks = 0
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { admissions += 1; return false },
            confirmationCancelled: { lifecycle += 1; return false }, manualModeCommit: { try $0(fans.clock.now) },
            acknowledgementConflict: { checks += 1; return nil })
        let trace = try XCTUnwrap(actuator.lastManualModeDiagnostic)
        XCTAssertEqual(trace.termination, "acknowledged"); XCTAssertEqual(trace.probes.count, 2)
        // Before and after each of the two probes, and once before publication.
        XCTAssertEqual(checks, 5)
        XCTAssertEqual(admissions, 2, "Before the write and at the native write boundary only.")
        XCTAssertGreaterThan(lifecycle, 0)
        XCTAssertNil(trace.cancellationCause)
    }

    func testManualEntryCompetingUtilityAtAProbeBoundaryKeepsTheHold() throws {
        for read in [2, 3] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            fans.deferWrites = false
            let actuator = try actuator(fans, journal)
            var utility: String?
            // Read 1 is the pre-write observation; probes read from 2.
            fans.onRead = { if $0 == read { utility = "Macs Fan Control" } }
            XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
                confirmationCancelled: { false }, manualModeCommit: { try $0(fans.clock.now) },
                acknowledgementConflict: { utility }))
            let trace = try XCTUnwrap(actuator.lastManualModeDiagnostic)
            XCTAssertEqual(trace.termination, "conflictingUtility")
            XCTAssertEqual(trace.cancellationCause, "Macs Fan Control appeared.")
            XCTAssertEqual(trace.probes.count, read - 1, "The returned probe is kept; no further probe starts.")
            XCTAssertTrue(trace.probes.allSatisfy(\.operationConfirmed))
            XCTAssertEqual(fans.readStarts.count, read)
            held(actuator, journal, fans)
        }
    }

    // Mac14,9's native shape: 29 receipts precede probe 0 and each probe uses
    // 43 of its 48 reserved, so five fit. Three fast probes precede the final
    // pair, which starts late only while no match is pending.
    func testManualEntryMac149ReceiptShapeKeepsThreeFastProbesBeforeTheFinalPair() throws {
        for (visible, expected) in [(0.15, [0, 0.1, 0.2, 0.3]), (0.65, [0, 0.1, 0.2, 0.7, 0.8])] {
            let fans = DiagnosticFans(), journal = DiagnosticJournal()
            fans.capacity = 256 - 29
            let actuator = try actuator(fans, journal)
            fans.onRead = { index in
                if index >= 2 { fans.capacity -= 43 }
                if fans.clock.now >= 100 + visible { fans.apply(.mode(fan: 0, manual: true)) }
            }
            _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
            let trace = try XCTUnwrap(actuator.lastManualModeDiagnostic)
            XCTAssertEqual(trace.termination, "acknowledged", "\(visible)")
            let starts = trace.probes.compactMap(\.startedAt).map { $0 - 100 }
            XCTAssertEqual(starts.count, expected.count, "\(visible)")
            for (start, value) in zip(starts, expected) { XCTAssertEqual(start, value, accuracy: 0.000_001, "\(visible)") }
        }
    }

    // Each probe uses its full reservation, so four fit. With no match pending
    // and two left, the final pair starts late and acknowledges a mode first
    // visible at +0.65 s, with time left to save it before +1 s.
    func testManualEntryFinalPairStartsLateWhenOnlyTwoProbesRemain() throws {
        let fans = DiagnosticFans(), journal = DiagnosticJournal()
        fans.capacity = 4 * 48
        let actuator = try actuator(fans, journal)
        fans.onRead = { index in
            if index >= 2 { fans.capacity -= 48 }
            if fans.clock.now >= 100.65 { fans.apply(.mode(fan: 0, manual: true)) }
        }
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
        let trace = try XCTUnwrap(actuator.lastManualModeDiagnostic)
        XCTAssertEqual(trace.termination, "acknowledged")
        let starts = trace.probes.compactMap(\.startedAt).map { $0 - 100 }
        XCTAssertEqual(starts.count, 4)
        for (start, expected) in zip(starts, [0, 0.1, 0.7, 0.8]) { XCTAssertEqual(start, expected, accuracy: 0.000_001) }
        XCTAssertEqual(trace.probes.map(\.operationConfirmed), [false, false, true, true])
        XCTAssertLessThanOrEqual(try XCTUnwrap(trace.acknowledgedAt), 101 - FanActuator.finalPairSaveMargin + 0.000_001)
        XCTAssertEqual(fans.capacity, 0)
    }
}

final class FanManualAcknowledgementStoreTests: XCTestCase {
    private let boot = UUID().uuidString, generation = UUID().uuidString
    private func make(_ directory: URL, session: String? = nil) throws -> (DiagnosticFans, FanRecoveryStore, FanActuator) {
        let fans = DiagnosticFans()
        fans.deferWrites = false
        let store = try FanRecoveryStore(directory: directory, requiredUID: geteuid())
        let actuator = try restart(fans, store)
        try actuator.establish(session: session ?? UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        return (fans, store, actuator)
    }
    private func restart(_ fans: DiagnosticFans, _ store: FanRecoveryStore) throws -> FanActuator {
        try FanActuator(hardware: fans, persistence: store, bootID: boot, serviceGeneration: generation,
            artifactIdentity: "fake-durable-ack-artifact", modeDiagnosticTiming: FanModeDiagnosticTiming(
                clock: { fans.clock.now }, pause: { fans.clock.now += $0 }))
    }
    private func assertRetained(_ fans: DiagnosticFans, _ store: FanRecoveryStore, _ actuator: FanActuator) throws {
        XCTAssertTrue(actuator.requiresExternalRecovery)
        let retained = try XCTUnwrap(store.load())
        XCTAssertEqual(retained.pending, .mode(fan: 0, manual: true))
        XCTAssertEqual(retained.acknowledged.fans.map(\.mode), [0, 0])
        let restarted = try restart(fans, store)
        XCTAssertEqual(restarted.record, retained)
        XCTAssertThrowsError(try restarted.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }))
        XCTAssertThrowsError(try restarted.restore(conflict: { nil }))
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])
    }

    func testMarkerAndPrimaryRenameSyncFailuresRetainPendingOnRestart() throws {
        for failingStage in [2, 3] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let (fans, store, actuator) = try make(directory)
            var syncs = 0
            store.directorySync = { fd in
                syncs += 1
                if syncs == failingStage { errno = EIO; return -1 }
                return fsync(fd)
            }
            XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) }))
            XCTAssertEqual(syncs, failingStage)
            XCTAssertEqual(actuator.lastManualModeDiagnostic?.termination, "acknowledgementPersistenceFailure")
            XCTAssertNotNil(actuator.lastManualModeDiagnostic?.acknowledgementError)
            try assertRetained(fans, store, actuator)
        }
    }

    func testFinalAtomicPublicationRejectsRevocationExpiryAndLateTimeAfterDurableSave() throws {
        for change in 0..<9 {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let gate = FanSafetyGate()
            // Change 6: with no frame since a begin at 96.15, the four-second
            // complete-frame window ends at 100.15. Change 7: the lease ends at 100.2.
            let session = try gate.begin(owner: "owner", now: change == 7 ? 95.2 : (change == 6 ? 96.15 : 100))
            if change == 7 {
                gate.fresh(at: 97, now: 97); gate.fresh(at: 98.5, now: 98.5)
            } else if change != 6 { gate.fresh(at: 100, now: 100) }
            let token = gate.check(now: 100).generation
            let (fans, store, actuator) = try make(directory, session: session)
            var reachedPublication = false, published = false
            XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true),
                cancelled: { !gate.permits(token, now: fans.clock.now) }, manualModeCommit: { publish in
                    reachedPublication = true
                    XCTAssertEqual(try store.load()?.pending, .mode(fan: 0, manual: true))
                    switch change {
                    case 0: gate.stop(owner: "owner", reason: "Owner stopped at final publication")
                    case 1: gate.suspendForSleep()
                    case 2: XCTAssertTrue(gate.revise(owner: "owner", session: session, now: fans.clock.now))
                    case 3: XCTAssertTrue(gate.prepareRemoval(owner: "owner"))
                    case 4: fans.clock.now = 103
                    case 5: fans.clock.now = 99
                    case 6: fans.clock.now = 100.16
                    case 7: fans.clock.now = 100.21
                    default: break
                    }
                    try gate.commitManualModeAcknowledgement(generation: token,
                        session: change == 8 ? UUID().uuidString : session, clock: { fans.clock.now }) { timestamp in
                        try publish(timestamp); published = true
                    }
                }))
            XCTAssertTrue(reachedPublication); XCTAssertFalse(published)
            XCTAssertNil(actuator.lastManualModeDiagnostic?.acknowledgedAt)
            XCTAssertTrue(actuator.lastManualModeDiagnostic?.pendingRetained == true)
            try assertRetained(fans, store, actuator)
        }
    }

    func testAtomicPublicationWithTheExactLeaseMakesSuccessorEligible() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = FanSafetyGate(), session = try gate.begin(owner: "owner", now: 100)
        let token = gate.check(now: 100).generation
        let (fans, store, actuator) = try make(directory, session: session)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { !gate.permits(token, now: fans.clock.now) },
            manualModeCommit: { publish in
                try gate.commitManualModeAcknowledgement(generation: token, session: session,
                    clock: { fans.clock.now }, publish: publish)
            })
        XCTAssertNil(actuator.record?.pending); XCTAssertNotNil(actuator.lastManualModeDiagnostic?.acknowledgedAt)
        _ = try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { !gate.permits(token, now: fans.clock.now) },
                                acknowledgementConflict: { nil })
        XCTAssertEqual(try store.load(), actuator.record)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: 4000)])
    }

    func testConfirmedManualEntryAllowsSlowPublicationAndRetainsCrashIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try make(directory)
        var syncs = 0
        store.fileSync = { fd in
            syncs += 1
            if syncs == 2 { fans.clock.now += 1 }
            return fsync(fd)
        }
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
                                manualModeCommit: { try $0(fans.clock.now) })
        let trace = try XCTUnwrap(actuator.lastManualModeDiagnostic)
        XCTAssertEqual(trace.termination, "acknowledged")
        XCTAssertLessThan(try XCTUnwrap(trace.readbackConfirmedAt), try XCTUnwrap(trace.deadline))
        XCTAssertGreaterThan(try XCTUnwrap(trace.acknowledgedAt), try XCTUnwrap(trace.deadline))
        XCTAssertLessThan(try XCTUnwrap(trace.acknowledgedAt), try XCTUnwrap(trace.publicationDeadline))
        XCTAssertFalse(trace.deadlineOverrun); XCTAssertEqual(trace.publicationDeadlineOverrun, false)
        XCTAssertNil(actuator.record?.pending)
        XCTAssertEqual(try store.load()?.pending, .mode(fan: 0, manual: true), "Restart keeps the conservative pending intent.")
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])
    }

    func testLateOrCancelledJournalPublicationCannotLosePending() throws {
        for late in [true, false] {
            for interruptedStage in [2, 3] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let (fans, store, actuator) = try make(directory)
                var syncs = 0, revoked = false
                store.directorySync = { fd in
                    syncs += 1
                    if syncs == interruptedStage {
                        if late { fans.clock.now = 103.2 } else { revoked = true }
                    }
                    return fsync(fd)
                }
                XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { revoked }, manualModeCommit: { try $0(fans.clock.now) }))
                XCTAssertEqual(syncs, interruptedStage)
                XCTAssertEqual(actuator.lastManualModeDiagnostic?.termination, late ? "publicationDeadline" : "cancelledOrPermissionRevoked")
                XCTAssertNil(actuator.lastManualModeDiagnostic?.acknowledgedAt)
                try assertRetained(fans, store, actuator)
            }
        }
    }

    func testSuccessfulLiveAcknowledgementRetainsCrashCopyUntilNextDurableIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try make(directory)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
        XCTAssertNil(actuator.record?.pending); XCTAssertFalse(actuator.requiresExternalRecovery)
        XCTAssertEqual(actuator.lastManualModeDiagnostic?.termination, "acknowledged")
        XCTAssertEqual(try restart(fans, store).record?.pending, .mode(fan: 0, manual: true))
        fans.onPerform = {
            XCTAssertEqual(try store.load()?.pending, .target(fan: 0, rpm: 4000))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ownership-retiring.json").path))
        }
        _ = try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil })
        XCTAssertEqual(try store.load(), actuator.record)
        // The target's own staged copy is retired after its publication.
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ownership-retiring.json").path))
        XCTAssertNil(try restart(fans, store).record?.pending)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: 4000)])
    }

    func testSuccessorCleanupSyncFailureRetainsNewIntentBeforeAnyTargetWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try make(directory)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
        var syncs = 0
        store.directorySync = { fd in
            syncs += 1
            if syncs == 2 { errno = EIO; return -1 }
            return fsync(fd)
        }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false },
                                                 acknowledgementConflict: { nil }))
        XCTAssertEqual(syncs, 2)
        XCTAssertEqual(try store.load()?.pending, .target(fan: 0, rpm: 4000))
        XCTAssertTrue(try restart(fans, store).requiresExternalRecovery)
        XCTAssertTrue(actuator.requiresExternalRecovery)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])
    }

    func testOrdinaryRestoreAfterAcknowledgementKeepsMarkerUntilAutomaticIntentIsDurable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try make(directory)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
        var syncs = 0
        store.directorySync = { fd in
            syncs += 1
            if syncs == 1 {
                XCTAssertEqual(try? store.load()?.pending, .mode(fan: 0, manual: true))
                XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ownership-retiring.json").path))
            }
            return fsync(fd)
        }
        fans.onPerform = {
            XCTAssertEqual(try store.load()?.pending, fans.operations.last)
        }
        XCTAssertTrue(try XCTUnwrap(actuator.restore(conflict: { nil })).isFullyAutomatic)
        XCTAssertNil(actuator.record); XCTAssertNil(try store.load())
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .mode(fan: 0, manual: false)])
    }

    func testRetirementFailureSelectsPendingCopyOfPublishedAcknowledgement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try make(directory)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
        var syncs = 0
        store.directorySync = { fd in
            syncs += 1
            if syncs == 2 { errno = EIO; return -1 }
            return fsync(fd)
        }
        XCTAssertThrowsError(try store.remove())
        XCTAssertEqual(try store.load()?.pending, .mode(fan: 0, manual: true))
        XCTAssertTrue(try restart(fans, store).requiresExternalRecovery)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])
        store.directorySync = { fsync($0) }
        try store.remove(); XCTAssertNil(try store.load())
    }

    func testUnrelatedOrMalformedAcknowledgementPairIsRejected() throws {
        for changedLineage in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let (fans, store, actuator) = try make(directory)
            _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
            let acknowledged = try XCTUnwrap(actuator.record)
            var bad = acknowledged
            if changedLineage {
                bad = FanRecoveryRecord(bootID: boot, serviceGeneration: generation,
                    artifactIdentity: "another-artifact", ownerSession: acknowledged.ownerSession,
                    capabilities: acknowledged.capabilities, baseline: acknowledged.baseline)
                bad.acknowledged = acknowledged.acknowledged
            } else { bad.acknowledged.fans[0].mode = 99 }
            let primary = directory.appendingPathComponent("ownership.json")
            try JSONEncoder().encode(bad).write(to: primary)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(acknowledged))
            XCTAssertThrowsError(try store.remove())
            XCTAssertThrowsError(try restart(fans, store))
            XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])
        }
    }

    // A competing utility found after the durable acknowledgement and before
    // publication keeps the hold: the staged pending copy wins on restart.
    func testCompetingUtilityBeforeManualPublicationKeepsTheStagedPendingCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try make(directory)
        var utility: String?, syncs = 0, published = false
        // Syncs: pending intent 1, staged pending copy 2, acknowledged primary 3.
        store.directorySync = { fd in
            syncs += 1
            if syncs == 3 { utility = "Macs Fan Control" }
            return fsync(fd)
        }
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
            confirmationCancelled: { false }, manualModeCommit: { publish in try publish(fans.clock.now); published = true },
            acknowledgementConflict: { utility }))
        XCTAssertEqual(syncs, 3); XCTAssertFalse(published)
        let trace = try XCTUnwrap(actuator.lastManualModeDiagnostic)
        XCTAssertEqual(trace.termination, "conflictingUtility")
        XCTAssertEqual(trace.cancellationCause, "Macs Fan Control appeared.")
        XCTAssertTrue(trace.pendingRetained); XCTAssertNil(trace.acknowledgedAt)
        try assertRetained(fans, store, actuator)
    }
}
