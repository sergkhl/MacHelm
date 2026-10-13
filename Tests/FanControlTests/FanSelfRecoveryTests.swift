import XCTest
@testable import FanControlCore
@testable import FanControlHardware
@testable import FanControlRuntime

// A write whose effect is withheld stays invisible until a test lands it, as
// firmware that applies a command late (or never) would.
private final class RigFans: FanHardware {
    var now: TimeInterval = 100
    var capabilities = FanPolicyTests.capabilities
    var state = FanPolicyTests.frame(75, at: 100).controlObservation
    var operations: [FanOperation] = []
    var reads = 0, probes = 0
    var probeStarts: [TimeInterval] = []
    var withheld: (FanOperation) -> Bool = { _ in false }
    var onRead: ((Int) throws -> Void)?
    var onProbe: ((Int) -> Void)?
    var onPerform: ((FanOperation) throws -> Void)?
    var probeModel: String?
    var probeMetadata: [FanDescriptor]?
    var receipts: [FanNativeCallReceipt] = []
    var capturing = false
    var temperature: Double = 75
    var failFrame: Error?
    // A clock that stops advancing while the helper waits.
    var clockFrozen = false

    func discover() throws -> FanCapabilities { capabilities }
    func read(_ capabilities: FanCapabilities) throws -> FanSnapshot {
        if let failFrame { throw failFrame }
        return FanSnapshot(capturedAt: now, temperatures: FanPolicyTests.frame(temperature).temperatures,
                           fans: state.fans, thermalPressure: .nominal, globalUnlock: state.globalUnlock)
    }
    func readControlState(_ capabilities: FanCapabilities) throws -> FanControlObservation {
        reads += 1
        try onRead?(reads)
        return FanControlObservation(capturedAt: now, fans: state.fans, globalUnlock: state.globalUnlock)
    }
    func readControlState(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanControlObservation {
        guard !cancelled() else { throw FanControlError.cancelled }
        return try readControlState(capabilities)
    }
    func probeFans() throws -> FanFanProbe { try probeFans(capabilities, cancelled: { false }) }
    func probeFans(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanFanProbe {
        guard !cancelled() else { throw FanControlError.cancelled }
        probes += 1; probeStarts.append(now)
        onProbe?(probes)
        return FanFanProbe(model: probeModel ?? capabilities.model, fans: probeMetadata ?? capabilities.fans,
                           observation: try readControlState(capabilities))
    }
    func perform(_ operation: FanOperation, capabilities: FanCapabilities, cancelled: () -> Bool) throws {
        guard !cancelled() else { throw FanControlError.cancelled }
        operations.append(operation)
        try onPerform?(operation)
        let key: String, hex: String
        switch operation {
        case .mode(let id, let manual): key = capabilities.fans[id].modeKey; hex = manual ? "01" : "00"
        case .target(let id, let rpm):
            key = "F\(id)Tg"; hex = FanActuator.targetPayloadHex(rpm, encoding: capabilities.fans[id].targetEncoding) ?? ""
        case .globalUnlock(let enabled): key = "Ftst"; hex = enabled ? "01" : "00"
        }
        if capturing {
            receipts.append(FanNativeCallReceipt(key: key, command: 6, startedAt: now, returnedAt: now, kernelResult: 0,
                requestedValueBytes: UInt32(hex.count / 2), returnedStructBytes: 80, firmwareResult: 0, firmwareStatus: 0,
                returnedValueHex: String(repeating: "0", count: hex.count), requestedValueHex: hex))
        }
        if !withheld(operation) { land(operation) }
    }
    func land(_ operation: FanOperation) {
        switch operation {
        case .mode(let fan, let manual): state.fans[fan].mode = manual ? 1 : 0
        case .target(let fan, let rpm): state.fans[fan].targetRPM = rpm
        case .globalUnlock(let enabled): state.globalUnlock = enabled ? 1 : 0
        }
    }
    func beginCommandDiagnosticCapture() { capturing = true; receipts = [] }
    func endCommandDiagnosticCapture() -> [FanNativeCallReceipt] { capturing = false; defer { receipts = [] }; return receipts }
    var commandDiagnosticCapacityRemaining: Int { Int.max }
    var commandDiagnosticWrite: FanNativeCallReceipt? { capturing ? receipts.last(where: { $0.command == 6 }) : nil }
}

// Mirrors the store's staged pending copy: it wins on load until retired or
// superseded by a newer durable pending intent.
private final class RigJournal: FanRecoveryPersistence {
    var record: FanRecoveryRecord?
    var marker: FanRecoveryRecord?
    var saved: [FanRecoveryRecord] = []
    var removals = 0
    var failSave: ((FanRecoveryRecord) -> Bool)?
    // The record becomes durable and the save then reports failure, as a
    // rename followed by a failed directory sync would.
    var failAfterStoring: ((FanRecoveryRecord) -> Bool)?
    var failRemove = false
    // The record is deleted and the removal then reports failure.
    var removeThenFail = false
    var onSave: ((FanRecoveryRecord) -> Void)?
    var onLoad: (() -> Void)?
    func load() throws -> FanRecoveryRecord? { onLoad?(); return marker ?? record }
    func save(_ record: FanRecoveryRecord) throws {
        if failSave?(record) == true { throw FanControlError.ownership("Fake journal save failed") }
        onSave?(record)
        self.record = record; saved.append(record)
        if record.pending != nil { marker = nil }
        if failAfterStoring?(record) == true { throw FanControlError.ownership("Fake journal sync failed") }
    }
    func remove() throws {
        if failRemove { throw FanControlError.ownership("Fake journal removal failed") }
        removals += 1; record = nil; marker = nil
        if removeThenFail { throw FanControlError.ownership("Fake journal removal sync failed") }
    }
    func acknowledgeManualMode(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                               validate: () throws -> Void) throws {
        try validate(); marker = pending; try save(acknowledged)
    }
    func acknowledgeBoundedOperation(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                                     validate: () throws -> Void) throws {
        try validate(); marker = pending; try save(acknowledged)
    }
    func retireAcknowledgementMarker(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord) throws { marker = nil }
}

final class FanSelfRecoveryTests: XCTestCase {
    private let boot = UUID().uuidString, artifact = "fake-recovery-artifact"
    private let release: [FanOperation] = [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .target(fan: 1, rpm: 0)]

    private func timing(_ fans: RigFans) -> FanModeDiagnosticTiming {
        FanModeDiagnosticTiming(clock: { fans.now }, pause: { if !fans.clockFrozen { fans.now += $0 } })
    }
    private func actuator(_ fans: RigFans, _ journal: FanRecoveryPersistence, boot: String? = nil,
                          artifact: String? = nil) throws -> FanActuator {
        try FanActuator(hardware: fans, persistence: journal, bootID: boot ?? self.boot,
            serviceGeneration: UUID().uuidString, artifactIdentity: artifact ?? self.artifact,
            modeDiagnosticTiming: timing(fans))
    }
    // Owns both fans' session with fan 0 in manual, then leaves a 4000 RPM
    // target unconfirmed until its one-second deadline.
    private func heldTarget(_ fans: RigFans, _ journal: FanRecoveryPersistence) throws -> FanActuator {
        let actuator = try actuator(fans, journal)
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.now) })
        fans.withheld = { if case .target(_, let rpm) = $0 { return rpm > 0 }; return false }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil }))
        XCTAssertEqual(actuator.lastTargetDiagnostic?.termination, "deadline")
        XCTAssertTrue(actuator.requiresExternalRecovery)
        return actuator
    }
    private func recover(_ actuator: FanActuator, _ trigger: FanSelfRecoveryTrigger = .automatic,
                         conflict: @escaping () -> String? = { nil }) throws -> FanSelfRecoveryReceipt {
        let command = actuator.unconfirmedCommand
        return try actuator.recoverOwnedFans(trigger: trigger, cause: command.cause, notBefore: command.deadline, conflict: conflict)
    }
    // The hold is exactly as it was: same pending command, nothing else armed.
    private func stillHeld(_ actuator: FanActuator, _ journal: RigJournal, pending: FanOperation) {
        XCTAssertTrue(actuator.requiresExternalRecovery)
        XCTAssertEqual(actuator.record?.pending, pending)
        XCTAssertEqual(try journal.load()?.pending, pending)
        XCTAssertEqual(try journal.load(), actuator.record, "Memory and journal agree, so explicit verification still works.")
        XCTAssertEqual(journal.removals, 0)
        XCTAssertNil(actuator.lastSelfRecoveryReceipt?.confirmedAt)
        XCTAssertNotNil(actuator.lastSelfRecoveryReceipt?.failure)
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 1, rpm: 3000), cancelled: { false }, acknowledgementConflict: { nil }))
        XCTAssertThrowsError(try actuator.restore(conflict: { nil }))
    }
    private func noSpeedOrRetry(_ fans: RigFans, after count: Int, unconfirmed: FanOperation) {
        for operation in fans.operations.dropFirst(count) {
            XCTAssertNotEqual(operation, unconfirmed, "The unconfirmed command is never re-sent.")
            switch operation {
            case .mode(_, let manual): XCTAssertFalse(manual)
            case .target(_, let rpm): XCTAssertEqual(rpm, 0, "Only the zero reset target is written.")
            case .globalUnlock(let enabled): XCTAssertFalse(enabled)
            }
        }
    }

    func testUnconfirmedTargetIsReleasedWithTheStopSequenceAndASettleCheck() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let session = try XCTUnwrap(actuator.record?.ownerSession)
        XCTAssertEqual(actuator.unconfirmedCommand.cause, "deadline")
        let saves = journal.saved.count, before = fans.operations.count
        let receipt = try recover(actuator)
        XCTAssertEqual(Array(fans.operations.dropFirst(before)), release)
        noSpeedOrRetry(fans, after: before, unconfirmed: .target(fan: 0, rpm: 4000))
        XCTAssertEqual(receipt.recoveryID, session); XCTAssertEqual(receipt.trigger, .automatic)
        XCTAssertEqual(receipt.cause, "deadline"); XCTAssertEqual(receipt.unconfirmed, .target(fan: 0, rpm: 4000))
        XCTAssertEqual(receipt.steps.map(\.operation), release)
        XCTAssertTrue(receipt.steps.allSatisfy { $0.termination == "acknowledged" && $0.acknowledgedAt != nil && $0.observations == 3 })
        // Each release write keeps its own fixed one-second deadline.
        for step in receipt.steps {
            XCTAssertLessThan(try XCTUnwrap(step.acknowledgedAt), try XCTUnwrap(step.nativeWriteReturnedAt) + 1)
        }
        let released = try XCTUnwrap(receipt.lastReleaseAcknowledgedAt)
        XCTAssertEqual(released, receipt.steps.last?.acknowledgedAt)
        XCTAssertEqual(receipt.settle.count, 2)
        XCTAssertTrue(receipt.settle.allSatisfy { $0.observation.isFullyAutomatic })
        XCTAssertGreaterThan(receipt.settle[1].observation.capturedAt, receipt.settle[0].observation.capturedAt)
        XCTAssertGreaterThanOrEqual(receipt.settle[1].observation.capturedAt, released + 1 - 0.000_001)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(receipt.confirmedAt), released + 1 - 0.000_001)
        XCTAssertNil(receipt.failure)
        // Only the attempt mark is journaled; release writes are not intents.
        XCTAssertEqual(journal.saved.count, saves + 1)
        XCTAssertEqual(journal.saved.last?.pending, .target(fan: 0, rpm: 4000))
        XCTAssertEqual(journal.saved.last?.recoveryAttempted, true)
        XCTAssertEqual(journal.removals, 1); XCTAssertNil(try journal.load())
        XCTAssertNil(actuator.record); XCTAssertFalse(actuator.requiresExternalRecovery)
        // Review round 1, S3. The release steps never replace the unconfirmed
        // command's own trace, and each step keeps the readbacks that decided it.
        XCTAssertEqual(actuator.lastTargetDiagnostic?.operation, .target(fan: 0, rpm: 4000))
        XCTAssertEqual(actuator.lastTargetDiagnostic?.termination, "deadline")
        // E-Q7: without the qualification flag neither trace model has the
        // injection's marker field. (This checks the two structs in this test
        // build; the frozen binaries are checked by the artifact inspection.)
        #if FAN_CONTROL_QUALIFICATION
        XCTAssertNil(actuator.lastTargetDiagnostic?.qualificationWithheld)
        XCTAssertNil(actuator.lastManualModeDiagnostic?.qualificationWithheld)
        #else
        let targetFields = Mirror(reflecting: try XCTUnwrap(actuator.lastTargetDiagnostic)).children.compactMap(\.label)
        let manualFields = Mirror(reflecting: try XCTUnwrap(actuator.lastManualModeDiagnostic)).children.compactMap(\.label)
        XCTAssertTrue(targetFields.contains("termination")); XCTAssertTrue(manualFields.contains("termination"))
        XCTAssertFalse((targetFields + manualFields).contains { $0.lowercased().contains("qualification") }, "\(targetFields) \(manualFields)")
        #endif
        XCTAssertEqual(actuator.lastRecoveryStepDiagnostic?.operation, .target(fan: 1, rpm: 0))
        XCTAssertEqual(actuator.lastRecoveryStepDiagnostic?.termination, "acknowledged")
        XCTAssertEqual(actuator.lastRecoveryStepDiagnostic?.pendingRetained, false)
        for step in receipt.steps {
            XCTAssertEqual(step.probes.count, 3); XCTAssertEqual(step.probes.map(\.index), [0, 1, 2])
            XCTAssertTrue(step.probes.dropFirst().allSatisfy { $0.operationConfirmed && $0.ownershipMatches && $0.observation != nil })
        }
        XCTAssertEqual(receipt.steps.last?.probes.last?.observation?.isFullyAutomatic, true)
        XCTAssertFalse(fans.capturing)
        XCTAssertNoThrow(try JSONEncoder().encode(receipt))
        // A new session can start.
        XCTAssertNoThrow(try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state))
    }

    // 8 October: the manual-mode command is not visible, so the fan still
    // reads automatic. The named fan is released anyway.
    func testUnconfirmedManualEntryThatStillReadsAutomaticIsReleasedAnyway() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try actuator(fans, journal)
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        fans.withheld = { $0 == .mode(fan: 0, manual: true) }
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
            manualModeCommit: { try $0(fans.now) }, acknowledgementConflict: { nil }))
        XCTAssertTrue(fans.state.isFullyAutomatic)
        XCTAssertEqual(actuator.unconfirmedCommand.cause, "deadline")
        let receipt = try recover(actuator)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)] + release)
        XCTAssertNotNil(receipt.confirmedAt); XCTAssertNil(actuator.record)
        noSpeedOrRetry(fans, after: 1, unconfirmed: .mode(fan: 0, manual: true))
    }

    func testAttemptNeverStartsBeforeTheUnconfirmedCommandsOwnDeadline() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let reads = fans.reads, start = fans.now
        var firstReadAt: TimeInterval?
        fans.onRead = { if $0 == reads + 1 { firstReadAt = fans.now } }
        let receipt = try actuator.recoverOwnedFans(trigger: .automatic, cause: "deadline", notBefore: start + 0.75, conflict: { nil })
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstReadAt), start + 0.75 - 0.000_001, "No read or write before the deadline.")
        XCTAssertEqual(receipt.startedAt, start)
        // A clock that cannot be trusted with the wait writes nothing.
        let other = RigFans(), otherJournal = RigJournal()
        let second = try heldTarget(other, otherJournal)
        let count = other.operations.count
        XCTAssertThrowsError(try second.recoverOwnedFans(trigger: .automatic, cause: "deadline", notBefore: other.now + 30, conflict: { nil }))
        XCTAssertEqual(other.operations.count, count)
        stillHeld(second, otherJournal, pending: .target(fan: 0, rpm: 4000))
    }

    // The unconfirmed command lands after the helper released its fan. The
    // settle check (or a release probe) sees it, and the hold stays.
    func testLateLandingCommandKeepsTheHoldAndAnExplicitRequestCanStillClearIt() throws {
        for landAtProbe in [6, 8] {
            let fans = RigFans(), journal = RigJournal()
            let actuator = try actuator(fans, journal)
            try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
            fans.withheld = { $0 == .mode(fan: 0, manual: true) }
            XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
                manualModeCommit: { try $0(fans.now) }, acknowledgementConflict: { nil }))
            let base = fans.probes
            fans.onProbe = { if $0 == base + landAtProbe { fans.land(.mode(fan: 0, manual: true)) } }
            XCTAssertThrowsError(try recover(actuator))
            XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)] + release)
            stillHeld(actuator, journal, pending: .mode(fan: 0, manual: true))
            let failed = try XCTUnwrap(actuator.lastSelfRecoveryReceipt)
            XCTAssertEqual(failed.steps.last?.termination, landAtProbe == 6 ? "unexpectedOwnership" : "acknowledged")
            XCTAssertEqual(failed.settle.count, landAtProbe == 6 ? 0 : 1)
            XCTAssertEqual(journal.record?.recoveryAttempted, true)
            // The automatic attempt is used.
            let count = fans.operations.count
            XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("already used")) }
            XCTAssertThrowsError(try recover(actuator, .startup))
            XCTAssertEqual(fans.operations.count, count)
            // The owner's explicit request is a new bounded attempt.
            fans.onProbe = nil
            let receipt = try recover(actuator, .explicit)
            XCTAssertEqual(Array(fans.operations.dropFirst(count)), release)
            XCTAssertEqual(receipt.trigger, .explicit); XCTAssertNotNil(receipt.confirmedAt)
            XCTAssertNil(actuator.record); XCTAssertTrue(fans.state.isFullyAutomatic)
        }
    }

    func testCompetingUtilityAtTheStartWritesNothingAndUsesTheAttempt() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let count = fans.operations.count, reads = fans.reads
        XCTAssertThrowsError(try recover(actuator, conflict: { "Macs Fan Control" })) {
            XCTAssertTrue($0.localizedDescription.contains("Macs Fan Control"))
        }
        XCTAssertEqual(fans.operations.count, count); XCTAssertEqual(fans.reads, reads)
        stillHeld(actuator, journal, pending: .target(fan: 0, rpm: 4000))
        XCTAssertEqual(journal.record?.recoveryAttempted, true)
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("already used")) }
        // The explicit request is refused the same way while it runs.
        XCTAssertThrowsError(try recover(actuator, .explicit, conflict: { "Macs Fan Control" }))
        XCTAssertEqual(fans.operations.count, count)
    }

    func testCompetingUtilityDuringTheAttemptStopsItAndKeepsTheHold() throws {
        // After the first release write; at a release probe; before the settle
        // probes; during the read that precedes the second release write;
        // between the settle probes; and at the last settle probe.
        for appearsAt in ["afterFirstWrite", "atProbe", "beforeSettle", "beforeAWrite", "duringSettle", "atLastSettleProbe"] {
            let fans = RigFans(), journal = RigJournal()
            let actuator = try heldTarget(fans, journal)
            let count = fans.operations.count, base = fans.probes
            var utility: String?, readBeforeWrite: Int?
            switch appearsAt {
            case "afterFirstWrite": fans.onPerform = { if $0 == .target(fan: 0, rpm: 0) { utility = "Macs Fan Control" } }
            case "atProbe": fans.onProbe = { if $0 == base + 1 { utility = "Macs Fan Control" } }
            case "beforeSettle": fans.onProbe = { if $0 == base + 6 { utility = "Macs Fan Control" } }
            case "beforeAWrite":
                fans.onProbe = { if $0 == base + 2 { readBeforeWrite = fans.reads + 2 } }
                fans.onRead = { if $0 == readBeforeWrite { utility = "Macs Fan Control" } }
            case "duringSettle": fans.onProbe = { if $0 == base + 7 { utility = "Macs Fan Control" } }
            default: fans.onProbe = { if $0 == base + 8 { utility = "Macs Fan Control" } }
            }
            XCTAssertThrowsError(try recover(actuator, conflict: { utility }), appearsAt)
            stillHeld(actuator, journal, pending: .target(fan: 0, rpm: 4000))
            noSpeedOrRetry(fans, after: count, unconfirmed: .target(fan: 0, rpm: 4000))
            XCTAssertLessThanOrEqual(fans.operations.count - count, release.count)
            let failed = try XCTUnwrap(actuator.lastSelfRecoveryReceipt)
            switch appearsAt {
            case "atProbe": XCTAssertEqual(failed.steps.last?.termination, "conflictingUtility")
            case "beforeAWrite":
                XCTAssertEqual(Array(fans.operations.dropFirst(count)), [.mode(fan: 0, manual: false)],
                               "The write the utility preceded was not issued.")
            case "duringSettle": XCTAssertEqual(failed.steps.count, 3); XCTAssertEqual(failed.settle.count, 1)
            case "atLastSettleProbe": XCTAssertEqual(failed.steps.count, 3); XCTAssertEqual(failed.settle.count, 2)
            default: break
            }
        }
    }

    func testFansThatNoLongerMatchTheRecordBlockTheAutomaticAttemptOnly() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        // Something else moved fan 1 into manual at its own speed.
        fans.state.fans[1].mode = 1; fans.state.fans[1].targetRPM = 2222
        let count = fans.operations.count
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("no longer match")) }
        XCTAssertEqual(fans.operations.count, count)
        stillHeld(actuator, journal, pending: .target(fan: 0, rpm: 4000))
        // The owner's explicit request is consent to release them anyway.
        let receipt = try recover(actuator, .explicit)
        XCTAssertEqual(Array(fans.operations.dropFirst(count)),
            [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .mode(fan: 1, manual: false), .target(fan: 1, rpm: 0)])
        XCTAssertNotNil(receipt.confirmedAt); XCTAssertTrue(fans.state.isFullyAutomatic)
    }

    func testARecordFromAnotherBootOrBuildNeverAuthorizesAWrite() throws {
        for (otherBoot, otherArtifact) in [(true, false), (false, true)] {
            let fans = RigFans(), journal = RigJournal()
            _ = try heldTarget(fans, journal)
            let restarted = try actuator(fans, journal, boot: otherBoot ? UUID().uuidString : nil,
                                         artifact: otherArtifact ? "another-build" : nil)
            XCTAssertFalse(restarted.recordIsFromThisBootAndBuild)
            let count = fans.operations.count, reads = fans.reads, saves = journal.saved.count
            for trigger in [FanSelfRecoveryTrigger.automatic, .startup, .explicit] {
                XCTAssertThrowsError(try restarted.recoverOwnedFans(trigger: trigger, cause: "helperRestart", notBefore: nil, conflict: { nil })) {
                    XCTAssertTrue($0.localizedDescription.contains("another boot or helper build"))
                }
            }
            XCTAssertEqual(fans.operations.count, count); XCTAssertEqual(fans.reads, reads)
            XCTAssertEqual(journal.saved.count, saves, "Not even the mark is written.")
            XCTAssertNil(journal.record?.recoveryAttempted)
            XCTAssertTrue(restarted.requiresExternalRecovery)
        }
    }

    func testAMarkThatCannotBeSavedWritesNothingAndIsStillUsed() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let count = fans.operations.count, reads = fans.reads
        journal.failSave = { $0.recoveryAttempted == true }
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("Fake journal save failed")) }
        XCTAssertEqual(fans.operations.count, count); XCTAssertEqual(fans.reads, reads)
        stillHeld(actuator, journal, pending: .target(fan: 0, rpm: 4000))
        XCTAssertNil(journal.record?.recoveryAttempted); XCTAssertNil(actuator.record?.recoveryAttempted)
        journal.failSave = nil
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("already used")) }
        XCTAssertEqual(fans.operations.count, count)
    }

    func testAReleaseWriteThatIsNeverConfirmedKeepsTheHold() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let count = fans.operations.count
        fans.withheld = { $0 == .mode(fan: 0, manual: false) }
        XCTAssertThrowsError(try recover(actuator))
        XCTAssertEqual(Array(fans.operations.dropFirst(count)), [.mode(fan: 0, manual: false)], "No second release write after a failed one.")
        stillHeld(actuator, journal, pending: .target(fan: 0, rpm: 4000))
        let failed = try XCTUnwrap(actuator.lastSelfRecoveryReceipt)
        XCTAssertEqual(failed.steps.map(\.termination), ["deadline"])
        XCTAssertNil(failed.lastReleaseAcknowledgedAt); XCTAssertTrue(failed.settle.isEmpty)
        // The unconfirmed command's own outcome is still the hold's cause, and
        // the failed step keeps its readbacks.
        XCTAssertEqual(actuator.unconfirmedCommand.cause, "deadline", "A release step does not replace the command's trace.")
        XCTAssertNotNil(actuator.unconfirmedCommand.deadline)
        XCTAssertFalse(try XCTUnwrap(failed.steps.first).probes.isEmpty)
        XCTAssertTrue(try XCTUnwrap(failed.steps.first).probes.allSatisfy { !$0.operationConfirmed })
    }

    func testOnlyEligibleCausesStartAnAutomaticAttempt() throws {
        for cause in ["deadline", "probeLimit", "nativeTraceCapacity", "readFailure", "invalidObservation", "nonDistinctObservation",
                      "cancelledOrPermissionRevoked", "invalidNativeWriteReceipt", "performFailure", "immediateReadFailure", "helperRestart"] {
            XCTAssertTrue(FanActuator.selfRecoveryEligible(cause: cause), cause)
        }
        for cause in ["conflictingUtility", "unexpectedOwnership", "invalidOrBackwardClock", "clockDidNotAdvance",
                      "acknowledgementPersistenceFailure", "acknowledgementPublicationFailure"] {
            XCTAssertFalse(FanActuator.selfRecoveryEligible(cause: cause), cause)
        }
        XCTAssertFalse(FanActuator.selfRecoveryEligible(cause: nil), "An unknown outcome is not eligible.")
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let count = fans.operations.count, saves = journal.saved.count
        for cause in ["unexpectedOwnership", nil] {
            XCTAssertThrowsError(try actuator.recoverOwnedFans(trigger: .automatic, cause: cause, notBefore: nil, conflict: { nil }))
        }
        XCTAssertEqual(fans.operations.count, count); XCTAssertEqual(journal.saved.count, saves)
        XCTAssertNil(journal.record?.recoveryAttempted, "An ineligible cause does not use the attempt mark.")
        // The owner's explicit request does not depend on the cause and leaves no mark.
        XCTAssertNoThrow(try actuator.recoverOwnedFans(trigger: .explicit, cause: "unexpectedOwnership", notBefore: nil, conflict: { nil }))
        XCTAssertNil(actuator.record)
        XCTAssertFalse(journal.saved.contains { $0.recoveryAttempted == true })
    }

    // The intent became durable but its save reported failure, so the write
    // was never issued and no acknowledgement trace exists for it. With no
    // known cause the helper does not try by itself (journal exclusion).
    func testAnIntentWhoseSaveFailedAfterBecomingDurableHasNoKnownCause() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try actuator(fans, journal)
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.now) })
        _ = try actuator.mutate(.target(fan: 0, rpm: 3000), cancelled: { false }, acknowledgementConflict: { nil })
        journal.failAfterStoring = { $0.pending == .target(fan: 0, rpm: 3500) }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 3500), cancelled: { false }, acknowledgementConflict: { nil }))
        journal.failAfterStoring = nil
        XCTAssertTrue(actuator.requiresExternalRecovery)
        XCTAssertEqual(fans.operations.last, .target(fan: 0, rpm: 3000), "The new target was never issued.")
        XCTAssertEqual(actuator.lastTargetDiagnostic?.operation, .target(fan: 0, rpm: 3000))
        XCTAssertNil(actuator.unconfirmedCommand.cause, "The previous acknowledged trace is not this command's outcome.")
        XCTAssertNil(actuator.unconfirmedCommand.deadline)
        let count = fans.operations.count
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("not eligible")) }
        XCTAssertEqual(fans.operations.count, count)
        XCTAssertNil(journal.record?.recoveryAttempted)
        // The owner can still ask for the release explicitly.
        XCTAssertNoThrow(try recover(actuator, .explicit))
        XCTAssertNil(actuator.record); XCTAssertTrue(fans.state.isFullyAutomatic)
    }

    func testAFailedRecordRemovalKeepsTheHold() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        journal.failRemove = true
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("removal failed")) }
        XCTAssertTrue(actuator.requiresExternalRecovery)
        XCTAssertEqual(try journal.load()?.pending, .target(fan: 0, rpm: 4000))
        XCTAssertEqual(try journal.load(), actuator.record)
        XCTAssertNil(actuator.lastSelfRecoveryReceipt?.confirmedAt)
    }

    func testSettleNeedsTwoDistinctFreshAutomaticProbesWithUnchangedMetadata() throws {
        // "lateNotDistinct": the first settle probe is itself more than a
        // second late, so only distinctness can reject its repeat.
        for fault in ["model", "metadata", "manual", "notDistinct", "lateNotDistinct"] {
            let fans = RigFans(), journal = RigJournal()
            let actuator = try heldTarget(fans, journal)
            let base = fans.probes
            var frozen: TimeInterval?
            fans.onProbe = { probe in
                guard probe == base + 8 else {
                    if probe == base + 7 { if fault == "lateNotDistinct" { fans.now += 1 }; frozen = fans.now }
                    return
                }
                switch fault {
                case "model": fans.probeModel = "Mac99,9"
                case "metadata": fans.probeMetadata = [fans.capabilities.fans[1], fans.capabilities.fans[0]]
                case "manual": fans.state.fans[1].mode = 1
                default: if let frozen { fans.now = frozen }
                }
            }
            XCTAssertThrowsError(try recover(actuator), fault)
            XCTAssertTrue(actuator.requiresExternalRecovery, fault)
            XCTAssertEqual(journal.removals, 0, fault)
            XCTAssertEqual(actuator.lastSelfRecoveryReceipt?.steps.count, 3, fault)
            XCTAssertNil(actuator.lastSelfRecoveryReceipt?.confirmedAt, fault)
        }
    }

    func testCancellationStopsTheExplicitAttemptBetweenWrites() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let count = fans.operations.count
        var cancelled = false
        fans.onPerform = { if $0 == .mode(fan: 0, manual: false) { cancelled = true } }
        XCTAssertThrowsError(try actuator.recoverOwnedFans(trigger: .explicit, cause: "deadline", notBefore: nil,
            conflict: { nil }, cancelled: { cancelled }))
        XCTAssertLessThanOrEqual(fans.operations.count - count, 1)
        stillHeld(actuator, journal, pending: .target(fan: 0, rpm: 4000))
        // The commit point can also refuse; nothing is removed then.
        cancelled = false; fans.onPerform = nil
        XCTAssertThrowsError(try actuator.recoverOwnedFans(trigger: .explicit, cause: "deadline", notBefore: nil,
            conflict: { nil }, commit: { throw FanControlError.cancelled }))
        XCTAssertTrue(actuator.requiresExternalRecovery); XCTAssertEqual(journal.removals, 0)
    }

    func testGlobalUnlockIsReleasedWithTheFans() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        fans.state.globalUnlock = 1
        // The record's baseline is locked (0); explicit consent covers the changed unlock.
        let count = fans.operations.count
        let receipt = try recover(actuator, .explicit)
        XCTAssertEqual(Array(fans.operations.dropFirst(count)), release + [.globalUnlock(false)])
        XCTAssertNotNil(receipt.confirmedAt); XCTAssertEqual(fans.state.globalUnlock, 0)
        // Self-review F8: the receipt names every release write, the unlock included.
        XCTAssertEqual(receipt.steps.map(\.operation), release + [.globalUnlock(false)])
        XCTAssertEqual(receipt.steps.last?.termination, "acknowledged")
        XCTAssertEqual(receipt.steps.last?.acknowledgedAt, receipt.lastReleaseAcknowledgedAt)
    }

    func testOlderRecordsDecodeWithoutTheMarkAndTheMarkIsOptionalOnDisk() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let unmarked = try XCTUnwrap(journal.record)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(unmarked), encoding: .utf8))
        XCTAssertFalse(json.contains("recoveryAttempted"), "An unmarked record is byte-compatible with the previous schema.")
        XCTAssertEqual(try JSONDecoder().decode(FanRecoveryRecord.self, from: Data(json.utf8)), unmarked)
        XCTAssertThrowsError(try recover(actuator, conflict: { "Macs Fan Control" }))
        let marked = try XCTUnwrap(journal.record)
        XCTAssertEqual(marked.version, 2); XCTAssertEqual(marked.recoveryAttempted, true)
        XCTAssertNoThrow(try marked.validate())
        XCTAssertTrue(marked.sameLineage(as: unmarked))
    }

    // The real store: a marked pending record supersedes nothing new, and the
    // cleared hold leaves no file behind.
    func testRealStoreKeepsTheMarkAndRemovesTheRecordOnSuccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fan-self-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FanRecoveryStore(directory: directory, requiredUID: geteuid())
        let fans = RigFans()
        let actuator = try heldTarget(fans, store)
        XCTAssertThrowsError(try recover(actuator, conflict: { "Macs Fan Control" }))
        XCTAssertEqual(try FanRecoveryStore(directory: directory, requiredUID: geteuid()).load()?.recoveryAttempted, true)
        XCTAssertEqual(try store.load()?.pending, .target(fan: 0, rpm: 4000))
        let receipt = try recover(actuator, .explicit)
        XCTAssertNotNil(receipt.confirmedAt)
        XCTAssertNil(try FanRecoveryStore(directory: directory, requiredUID: geteuid()).load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    // Review round 1, S6. An acknowledgement that was durably staged but never
    // published leaves a pending copy beside an acknowledged primary. That is
    // still the same unconfirmed command, so the store takes the mark over
    // it, and the attempt runs as for any other hold.
    private func stagedAcknowledgement(_ fans: RigFans) throws -> (FanRecoveryStore, URL, FanRecoveryRecord) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fan-self-recovery-\(UUID().uuidString)")
        let store = try FanRecoveryStore(directory: directory, requiredUID: geteuid())
        let first = try actuator(fans, store)
        try first.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        _ = try first.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.now) })
        var pending = try XCTUnwrap(first.record)
        pending.pending = .target(fan: 0, rpm: 4000)
        try store.save(pending)
        var acknowledged = pending
        acknowledged.pending = nil; acknowledged.acknowledged.fans[0].targetRPM = 4000
        try store.acknowledgeBoundedOperation(pending: pending, acknowledged: acknowledged, validate: {})
        fans.state.fans[0].targetRPM = 4000
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["ownership.json", "ownership-retiring.json"])
        return (store, directory, pending)
    }

    func testRealStoreTakesTheMarkOverAStagedAcknowledgementAndTheAttemptRuns() throws {
        let fans = RigFans()
        let (store, directory, pending) = try stagedAcknowledgement(fans)
        defer { try? FileManager.default.removeItem(at: directory) }
        let restarted = try actuator(fans, store)
        XCTAssertEqual(restarted.record, pending, "The staged pending copy is authoritative.")
        XCTAssertTrue(restarted.automaticRecoveryAvailable)
        let count = fans.operations.count
        // The mark replaces the acknowledged primary and supersedes the copy.
        var marked: FanRecoveryRecord?
        fans.onPerform = { _ in if marked == nil { marked = try? store.load() } }
        let receipt = try restarted.recoverOwnedFans(trigger: .startup, cause: "helperRestart", notBefore: nil, conflict: { nil })
        XCTAssertEqual(marked?.recoveryAttempted, true); XCTAssertEqual(marked?.pending, .target(fan: 0, rpm: 4000))
        XCTAssertTrue(try XCTUnwrap(marked).sameUncertainty(as: pending))
        XCTAssertNotNil(receipt.confirmedAt)
        XCTAssertEqual(Array(fans.operations.dropFirst(count)), [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .target(fan: 1, rpm: 0)])
        XCTAssertNil(try FanRecoveryStore(directory: directory, requiredUID: geteuid()).load())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testRealStoreJournalsADeclineOverAStagedAcknowledgement() throws {
        let fans = RigFans()
        let (store, directory, pending) = try stagedAcknowledgement(fans)
        defer { try? FileManager.default.removeItem(at: directory) }
        let live = try actuator(fans, store)
        let count = fans.operations.count
        XCTAssertTrue(live.declineAutomaticRecovery())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["ownership.json"])
        let declined = try XCTUnwrap(try store.load())
        XCTAssertEqual(declined.recoveryDeclined, true); XCTAssertTrue(declined.sameUncertainty(as: pending))
        XCTAssertEqual(declined, live.record)
        // A restart reads the decision, and the owner's request still clears the hold.
        let restarted = try actuator(fans, store)
        XCTAssertFalse(restarted.automaticRecoveryAvailable)
        XCTAssertThrowsError(try restarted.recoverOwnedFans(trigger: .startup, cause: "helperRestart", notBefore: nil, conflict: { nil }))
        XCTAssertEqual(fans.operations.count, count)
        XCTAssertNoThrow(try restarted.recoverOwnedFans(trigger: .explicit, cause: nil, notBefore: nil, conflict: { nil }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    // Review round 1, N1. The marked primary was renamed into place and the
    // step that deletes the older pending copy never completed, as after a
    // crash. The two files are one uncertainty, not an ambiguous pair: the
    // journal still loads, the mark stands, and the hold can be cleared.
    func testRealStoreLoadsAMarkedRecordBesideItsUnmarkedCopy() throws {
        for decision in ["mark", "decline"] {
            let fans = RigFans()
            let (store, directory, pending) = try stagedAcknowledgement(fans)
            defer { try? FileManager.default.removeItem(at: directory) }
            let live = try actuator(fans, store)
            let count = fans.operations.count
            var syncs = 0
            store.directorySync = { descriptor in syncs += 1; return syncs == 1 ? -1 : fsync(descriptor) }
            if decision == "mark" {
                XCTAssertThrowsError(try live.recoverOwnedFans(trigger: .startup, cause: "helperRestart", notBefore: nil, conflict: { nil }))
            } else {
                XCTAssertTrue(live.declineAutomaticRecovery(), "The decision became durable, so it is reported as journaled.")
            }
            store.directorySync = { fsync($0) }
            XCTAssertEqual(fans.operations.count, count, decision)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                           ["ownership.json", "ownership-retiring.json"], decision)
            let loaded = try XCTUnwrap(try store.load(), decision)
            XCTAssertTrue(loaded.automaticRecoveryClosed, decision); XCTAssertTrue(loaded.sameUncertainty(as: pending), decision)
            XCTAssertEqual(loaded, live.record, "Memory follows the journal.")
            // A restarted helper can load the journal, and does not try again by itself.
            let restarted = try actuator(fans, store)
            XCTAssertEqual(restarted.record, loaded, decision); XCTAssertFalse(restarted.automaticRecoveryAvailable, decision)
            XCTAssertThrowsError(try restarted.recoverOwnedFans(trigger: .startup, cause: "helperRestart", notBefore: nil, conflict: { nil }))
            XCTAssertEqual(fans.operations.count, count, decision)
            // Both recovery requests work, and clearing the hold removes both files.
            XCTAssertNoThrow(try restarted.recoverOwnedFans(trigger: .explicit, cause: nil, notBefore: nil, conflict: { nil }), decision)
            XCTAssertNil(restarted.record, decision)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [], decision)
        }
    }

    // Review round 2, N1. A newer pending intent was saved over the staged
    // pair and its clean-up was interrupted, so the older pending copy is
    // still on disk. The decision clause compares with what a restart would
    // load, so it does not let a decision on that older command replace the
    // newer intent. (The store's two earlier clauses are unchanged; review
    // round 3 notes what they still accept. The helper never offers the
    // store an older record.)
    func testRealStoreDecisionClauseDoesNotReplaceANewerIntentWithAnOlderOne() throws {
        let fans = RigFans()
        let (store, directory, older) = try stagedAcknowledgement(fans)
        defer { try? FileManager.default.removeItem(at: directory) }
        var newer = older
        newer.acknowledged.fans[0].targetRPM = 4000; newer.pending = .target(fan: 0, rpm: 4500)
        var syncs = 0
        store.directorySync = { descriptor in syncs += 1; return syncs == 1 ? -1 : fsync(descriptor) }
        XCTAssertThrowsError(try store.save(newer))
        store.directorySync = { fsync($0) }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["ownership.json", "ownership-retiring.json"])
        XCTAssertEqual(try store.load(), newer, "The newer intent is what a restart loads.")
        for field in ["attempted", "declined"] {
            var decided = older
            if field == "attempted" { decided.recoveryAttempted = true } else { decided.recoveryDeclined = true }
            XCTAssertTrue(decided.sameUncertainty(as: older))
            XCTAssertThrowsError(try store.save(decided), field) {
                XCTAssertTrue($0.localizedDescription.contains("cannot overwrite retained fan uncertainty"))
            }
            XCTAssertEqual(try store.load(), newer, field)
        }
        // A decision on the newer intent itself is accepted.
        var decided = newer; decided.recoveryDeclined = true
        XCTAssertNoThrow(try store.save(decided))
        XCTAssertEqual(try store.load(), decided)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["ownership.json"])
    }

    // Review round 2, N3. After a clearing removal was interrupted, only the
    // copy remains. It is still a pending record, so a restart on the same
    // boot and build gives it its one attempt, on fans that were just
    // verified automatic.
    func testARecordLeftAsOnlyItsCopyByAnInterruptedRemovalGetsItsAttempt() throws {
        let fans = RigFans()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fan-self-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try FanRecoveryStore(directory: directory, requiredUID: geteuid())
        let live = try heldTarget(fans, store)
        let pending = try XCTUnwrap(live.record)
        // The primary was unlinked; the step after it failed.
        var syncs = 0
        store.directorySync = { descriptor in syncs += 1; return syncs == 2 ? -1 : fsync(descriptor) }
        XCTAssertThrowsError(try store.remove())
        store.directorySync = { fsync($0) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["ownership-retiring.json"])
        fans.state.fans[0].mode = 0
        let restarted = try actuator(fans, store)
        XCTAssertEqual(restarted.record, pending); XCTAssertTrue(restarted.automaticRecoveryAvailable)
        let count = fans.operations.count
        let receipt = try restarted.recoverOwnedFans(trigger: .startup, cause: "helperRestart", notBefore: nil, conflict: { nil })
        XCTAssertNotNil(receipt.confirmedAt)
        XCTAssertEqual(Array(fans.operations.dropFirst(count)), release)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    // The store still refuses anything that is not that same uncertainty.
    func testRealStoreStillRefusesAnotherRecordOverAStagedAcknowledgement() throws {
        let fans = RigFans()
        let (store, directory, pending) = try stagedAcknowledgement(fans)
        defer { try? FileManager.default.removeItem(at: directory) }
        var otherOperation = pending; otherOperation.pending = .target(fan: 0, rpm: 3000); otherOperation.recoveryAttempted = true
        var cleared = pending; cleared.pending = nil; cleared.recoveryAttempted = true
        var otherState = pending; otherState.acknowledged.fans[1].mode = 1; otherState.recoveryDeclined = true
        for record in [otherOperation, cleared, otherState] {
            XCTAssertThrowsError(try store.save(record)) {
                XCTAssertTrue($0.localizedDescription.contains("cannot overwrite retained fan uncertainty"))
            }
        }
        XCTAssertEqual(try store.load(), pending)
        XCTAssertFalse(cleared.sameUncertainty(as: pending)); XCTAssertFalse(pending.sameUncertainty(as: cleared))
        // Two records with nothing pending are never "the same uncertainty".
        var idle = pending; idle.pending = nil
        var idleMarked = idle; idleMarked.recoveryAttempted = true
        XCTAssertFalse(idleMarked.sameUncertainty(as: idle)); XCTAssertFalse(idle.sameUncertainty(as: idleMarked))
        var marked = pending; marked.recoveryAttempted = true
        XCTAssertTrue(marked.sameUncertainty(as: pending)); XCTAssertTrue(pending.sameUncertainty(as: marked))
    }

    // Self-review F1. The unconfirmed manual-mode command lands after that
    // fan's mode release was confirmed and before its reset target is written.
    // A zero target is never written to a fan that reads manual, whoever asked.
    func testAResetTargetIsNeverWrittenToAFanThatReadsManual() throws {
        for trigger in [FanSelfRecoveryTrigger.automatic, .explicit] {
            let fans = RigFans(), journal = RigJournal()
            let actuator = try actuator(fans, journal)
            try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
            fans.withheld = { $0 == .mode(fan: 0, manual: true) }
            XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
                manualModeCommit: { try $0(fans.now) }, acknowledgementConflict: { nil }))
            let base = fans.probes
            // The read after the mode release's second probe is the reset step's own first read.
            var landAtRead: Int?
            fans.onProbe = { if $0 == base + 2 { landAtRead = fans.reads + 2 } }
            fans.onRead = { if $0 == landAtRead { fans.land(.mode(fan: 0, manual: true)) } }
            XCTAssertThrowsError(try recover(actuator, trigger), "\(trigger)")
            XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .mode(fan: 0, manual: false)],
                           "\(trigger): no reset target after the fan left automatic")
            XCTAssertEqual(fans.state.fans[0].mode, 1, "The late command did land.")
            stillHeld(actuator, journal, pending: .mode(fan: 0, manual: true))
        }
    }

    // Self-review F1. Something else changes a fan between two release writes.
    // The helper's own attempt stops there; the owner's explicit request goes on.
    func testFansChangedBetweenReleaseWritesStopTheAutomaticAttemptOnly() throws {
        for trigger in [FanSelfRecoveryTrigger.automatic, .explicit] {
            let fans = RigFans(), journal = RigJournal()
            let actuator = try heldTarget(fans, journal)
            let count = fans.operations.count, base = fans.probes
            var changeAtRead: Int?
            fans.onProbe = { if $0 == base + 2 { changeAtRead = fans.reads + 2 } }
            fans.onRead = { if $0 == changeAtRead { fans.state.fans[1].mode = 1; fans.state.fans[1].targetRPM = 2222 } }
            if trigger == .automatic {
                XCTAssertThrowsError(try recover(actuator))
                XCTAssertEqual(Array(fans.operations.dropFirst(count)), [.mode(fan: 0, manual: false)])
                XCTAssertEqual(fans.state.fans[1].mode, 1, "The changed fan was left as it is.")
                XCTAssertEqual(fans.state.fans[1].targetRPM, 2222)
                stillHeld(actuator, journal, pending: .target(fan: 0, rpm: 4000))
            } else {
                let receipt = try recover(actuator, .explicit)
                XCTAssertEqual(Array(fans.operations.dropFirst(count)),
                    [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .mode(fan: 1, manual: false), .target(fan: 1, rpm: 0)])
                XCTAssertNotNil(receipt.confirmedAt); XCTAssertTrue(fans.state.isFullyAutomatic)
            }
        }
    }

    // Self-review F2b. The mark became durable although its save reported
    // failure (a rename followed by a failed directory sync). Memory follows
    // the journal, so the owner can still clear the hold in this process.
    func testAMarkThatBecameDurableAlthoughItsSaveFailedStaysConsistent() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let count = fans.operations.count
        journal.failAfterStoring = { $0.recoveryAttempted == true }
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("Fake journal sync failed")) }
        journal.failAfterStoring = nil
        XCTAssertEqual(fans.operations.count, count, "Nothing is written when the mark's save reports failure.")
        XCTAssertEqual(journal.record?.recoveryAttempted, true)
        XCTAssertEqual(try journal.load(), actuator.record, "Memory follows what became durable.")
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("already used")) }
        XCTAssertEqual(fans.operations.count, count)
        XCTAssertNoThrow(try recover(actuator, .explicit))
        XCTAssertNil(actuator.record); XCTAssertNil(try journal.load())
    }

    // Self-review F5. A restarted helper has no trace of the unconfirmed
    // command and so no deadline. E-Q4 still holds: the attempt waits one
    // second from its own start before its first read or write.
    func testAnAttemptWithNoKnownDeadlineWaitsASecondBeforeItsFirstReadOrWrite() throws {
        let fans = RigFans(), journal = RigJournal()
        _ = try heldTarget(fans, journal)
        let restarted = try actuator(fans, journal)
        XCTAssertNil(restarted.unconfirmedCommand.cause); XCTAssertNil(restarted.unconfirmedCommand.deadline)
        let reads = fans.reads, start = fans.now
        var firstReadAt: TimeInterval?, firstWriteAt: TimeInterval?
        fans.onRead = { if $0 == reads + 1 { firstReadAt = fans.now } }
        fans.onPerform = { _ in if firstWriteAt == nil { firstWriteAt = fans.now } }
        let receipt = try restarted.recoverOwnedFans(trigger: .explicit, cause: nil, notBefore: nil, conflict: { nil })
        XCTAssertNotNil(receipt.confirmedAt)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstReadAt), start + 1 - 0.000_001)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstWriteAt), start + 1 - 0.000_001)
    }

    // The unconfirmed manual-mode command names fan 1 and lands between two
    // release writes. That is what the attempt exists for: the named fan is
    // still released, and the attempt completes.
    func testALateLandingOnTheNamedFanBetweenWritesIsStillReleased() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try actuator(fans, journal)
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        fans.withheld = { $0 == .mode(fan: 1, manual: true) }
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 1, manual: true), cancelled: { false },
            manualModeCommit: { try $0(fans.now) }, acknowledgementConflict: { nil }))
        let base = fans.probes
        // The read after fan 0's reset is confirmed is fan 1's mode step's own first read.
        var landAtRead: Int?
        fans.onProbe = { if $0 == base + 2 { landAtRead = fans.reads + 2 } }
        // Firmware may enter manual mode at a target of its own.
        fans.onRead = { if $0 == landAtRead { fans.land(.mode(fan: 1, manual: true)); fans.state.fans[1].targetRPM = 1800 } }
        let receipt = try recover(actuator)
        XCTAssertEqual(fans.operations, [.mode(fan: 1, manual: true), .target(fan: 0, rpm: 0),
                                         .mode(fan: 1, manual: false), .target(fan: 1, rpm: 0)])
        XCTAssertNotNil(receipt.confirmedAt); XCTAssertNil(actuator.record); XCTAssertTrue(fans.state.isFullyAutomatic)
        XCTAssertTrue(receipt.steps.allSatisfy { $0.termination == "acknowledged" })
    }

    // A release write refused before it was issued is recorded as such.
    func testARefusedReleaseWriteIsRecordedAsNotIssued() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let base = fans.probes
        var changeAtRead: Int?
        fans.onProbe = { if $0 == base + 2 { changeAtRead = fans.reads + 2 } }
        fans.onRead = { if $0 == changeAtRead { fans.state.fans[1].mode = 1; fans.state.fans[1].targetRPM = 2222 } }
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("changed during recovery")) }
        let failed = try XCTUnwrap(actuator.lastSelfRecoveryReceipt)
        XCTAssertEqual(failed.steps.map(\.operation), [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0)])
        XCTAssertEqual(failed.steps.map(\.termination), ["acknowledged", "notIssued"])
        XCTAssertNil(failed.steps.last?.nativeWriteReturnedAt); XCTAssertEqual(failed.steps.last?.observations, 0)
    }

    // E-Q1 made durable (self-review F3). Declining reads and writes no fan,
    // closes the automatic attempt, and leaves the owner's request open.
    func testDecliningIsJournaledAndClosesOnlyTheAutomaticAttempt() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let unmarked = try XCTUnwrap(journal.record)
        XCTAssertTrue(actuator.automaticRecoveryAvailable)
        let count = fans.operations.count, reads = fans.reads, saves = journal.saved.count
        XCTAssertTrue(actuator.declineAutomaticRecovery())
        XCTAssertEqual(fans.operations.count, count); XCTAssertEqual(fans.reads, reads)
        XCTAssertEqual(journal.saved.count, saves + 1)
        let declined = try XCTUnwrap(journal.record)
        XCTAssertEqual(declined.recoveryDeclined, true); XCTAssertNil(declined.recoveryAttempted)
        XCTAssertEqual(declined.pending, .target(fan: 0, rpm: 4000)); XCTAssertEqual(declined.version, 2)
        XCTAssertNoThrow(try declined.validate()); XCTAssertTrue(declined.sameLineage(as: unmarked))
        XCTAssertEqual(try journal.load(), actuator.record)
        XCTAssertFalse(actuator.automaticRecoveryAvailable)
        XCTAssertFalse(actuator.declineAutomaticRecovery(), "Declining twice journals nothing more.")
        XCTAssertEqual(journal.saved.count, saves + 1)
        for trigger in [FanSelfRecoveryTrigger.automatic, .startup] {
            XCTAssertThrowsError(try actuator.recoverOwnedFans(trigger: trigger, cause: "deadline", notBefore: nil, conflict: { nil })) {
                XCTAssertTrue($0.localizedDescription.contains("already used"))
            }
        }
        XCTAssertEqual(fans.operations.count, count)
        // A restarted helper reads the same decision from disk.
        let restarted = try self.actuator(fans, journal)
        XCTAssertFalse(restarted.automaticRecoveryAvailable)
        XCTAssertThrowsError(try restarted.recoverOwnedFans(trigger: .startup, cause: "helperRestart", notBefore: nil, conflict: { nil }))
        XCTAssertEqual(fans.operations.count, count)
        XCTAssertNoThrow(try restarted.recoverOwnedFans(trigger: .explicit, cause: nil, notBefore: nil, conflict: { nil }))
        XCTAssertNil(restarted.record); XCTAssertTrue(fans.state.isFullyAutomatic)
        // An older record without either field still decodes and is open.
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(unmarked), encoding: .utf8))
        XCTAssertFalse(json.contains("recoveryDeclined"))
        XCTAssertFalse(try JSONDecoder().decode(FanRecoveryRecord.self, from: Data(json.utf8)).automaticRecoveryClosed)
    }

    // A decision that cannot be saved holds for this process only; one that
    // became durable although its save failed is followed in memory.
    func testADeclineThatCannotBeSavedHoldsForThisProcessOnly() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let count = fans.operations.count
        journal.failSave = { $0.recoveryDeclined == true }
        XCTAssertFalse(actuator.declineAutomaticRecovery())
        journal.failSave = nil
        XCTAssertNil(journal.record?.recoveryDeclined); XCTAssertNil(actuator.record?.recoveryDeclined)
        XCTAssertEqual(try journal.load(), actuator.record)
        XCTAssertFalse(actuator.automaticRecoveryAvailable)
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("already used")) }
        XCTAssertEqual(fans.operations.count, count)
        // Known limit: nothing durable says "declined", so a restart is open again.
        XCTAssertTrue(try self.actuator(fans, journal).automaticRecoveryAvailable)

        let other = RigFans(), otherJournal = RigJournal()
        let second = try heldTarget(other, otherJournal)
        otherJournal.failAfterStoring = { $0.recoveryDeclined == true }
        XCTAssertTrue(second.declineAutomaticRecovery(), "The decision is durable, so it is reported as journaled.")
        otherJournal.failAfterStoring = nil
        XCTAssertEqual(otherJournal.record?.recoveryDeclined, true)
        XCTAssertEqual(try otherJournal.load(), second.record)
        XCTAssertNoThrow(try recover(second, .explicit))
    }

    // Nothing is declined, and nothing journaled, for a record this helper
    // may not write for, or when there is no hold.
    func testDecliningNeverTouchesARecordFromAnotherBootOrBuild() throws {
        let fans = RigFans(), journal = RigJournal()
        _ = try heldTarget(fans, journal)
        let saves = journal.saved.count
        for (otherBoot, otherArtifact) in [(true, false), (false, true)] {
            let restarted = try actuator(fans, journal, boot: otherBoot ? UUID().uuidString : nil,
                                         artifact: otherArtifact ? "another-build" : nil)
            XCTAssertFalse(restarted.automaticRecoveryAvailable)
            XCTAssertFalse(restarted.declineAutomaticRecovery())
        }
        XCTAssertEqual(journal.saved.count, saves); XCTAssertNil(journal.record?.recoveryDeclined)
        let idle = try actuator(RigFans(), RigJournal())
        XCTAssertFalse(idle.automaticRecoveryAvailable); XCTAssertFalse(idle.declineAutomaticRecovery())
    }

    // E-Q5 for the app (self-review F12): a session that ended with a
    // self-recovery attempt is not resumed after wake. The rule is a pure
    // function so that it can be checked here; the app only calls it.
    func testASessionEndedBySelfRecoveryIsRecognizedByItsOwnIdentityOnly() throws {
        let session = UUID().uuidString
        var status = FanStatus(serviceGeneration: UUID().uuidString)
        XCTAssertFalse(status.endedBySelfRecovery(session: session), "No receipt.")
        status.selfRecoveryReceipt = FanSelfRecoveryReceipt(recoveryID: session, trigger: .automatic, cause: "deadline",
            unconfirmed: .target(fan: 0, rpm: 4000), startedAt: 100)
        XCTAssertTrue(status.endedBySelfRecovery(session: session))
        XCTAssertFalse(status.endedBySelfRecovery(session: UUID().uuidString), "An earlier session's receipt.")
        XCTAssertFalse(status.endedBySelfRecovery(session: nil), "The app had no session.")
    }

    // The record is removed only if memory and journal still hold exactly the
    // record the attempt started with.
    func testAJournalRecordThatChangedDuringTheAttemptIsNotRemoved() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        let base = fans.probes
        fans.onProbe = { if $0 == base + 8 { journal.record?.restorationStarted = true } }
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("changed during recovery")) }
        XCTAssertTrue(actuator.requiresExternalRecovery); XCTAssertEqual(journal.removals, 0)
        XCTAssertEqual(try journal.load()?.pending, .target(fan: 0, rpm: 4000))
        XCTAssertEqual(actuator.lastSelfRecoveryReceipt?.settle.count, 2)
        XCTAssertNil(actuator.lastSelfRecoveryReceipt?.confirmedAt)
    }

    // A stalled journal read must not make the settle observations stale.
    func testASlowJournalReadBeforeTheCommitKeepsTheHold() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        var loads = 0
        journal.onLoad = { loads += 1; if loads == 1 { fans.now += 3 } }
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("did not stay automatic")) }
        journal.onLoad = nil
        XCTAssertEqual(loads, 1, "The stall was the read before the commit.")
        XCTAssertTrue(actuator.requiresExternalRecovery); XCTAssertEqual(journal.removals, 0)
        XCTAssertEqual(try journal.load(), actuator.record)
    }

    // A removal that deleted the record and then reported failure must not
    // leave the journal empty while memory still holds.
    func testARemovalThatDeletedThenFailedPutsTheRecordBack() throws {
        let fans = RigFans(), journal = RigJournal()
        let actuator = try heldTarget(fans, journal)
        journal.removeThenFail = true
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("removal sync failed")) }
        XCTAssertTrue(actuator.requiresExternalRecovery)
        XCTAssertEqual(try journal.load()?.pending, .target(fan: 0, rpm: 4000))
        XCTAssertEqual(try journal.load(), actuator.record)
        XCTAssertNil(actuator.lastSelfRecoveryReceipt?.confirmedAt)
    }

    // Review round 1, S4. When the unconfirmed command is itself a release
    // write, the release sequence contains that same write again. Nothing
    // that asks for manual mode or a speed is ever issued.
    func testAnUnconfirmedReleaseWriteIsFollowedByTheSameReleaseSequence() throws {
        for failing in [FanOperation.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0)] {
            let fans = RigFans(), journal = RigJournal()
            let actuator = try actuator(fans, journal)
            try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
            _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.now) })
            _ = try actuator.mutate(.target(fan: 0, rpm: 3000), cancelled: { false }, acknowledgementConflict: { nil })
            let count = fans.operations.count
            // A normal stop whose release write is not confirmed: the mode
            // release never lands, or the reset's first probe cannot be read.
            var withheldOnce = false, failReadAt: Int?
            fans.withheld = { operation in
                guard operation == failing, case .mode = operation, !withheldOnce else { return false }
                withheldOnce = true; return true
            }
            fans.onPerform = { operation in
                if operation == failing, case .target = operation, failReadAt == nil { failReadAt = fans.reads + 2 }
            }
            fans.onRead = { if $0 == failReadAt { throw FanControlError.hardware("Fake probe read failure") } }
            XCTAssertThrowsError(try actuator.restore(conflict: { nil }), "\(failing)")
            XCTAssertEqual(actuator.record?.pending, failing)
            let cause = try XCTUnwrap(actuator.unconfirmedCommand.cause)
            XCTAssertEqual(cause, failing == .mode(fan: 0, manual: false) ? "deadline" : "readFailure")
            let stopped = fans.operations.count
            let receipt = try recover(actuator)
            XCTAssertEqual(receipt.unconfirmed, failing)
            XCTAssertEqual(Array(fans.operations.dropFirst(stopped)),
                [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .target(fan: 1, rpm: 0)], "\(failing)")
            XCTAssertNotNil(receipt.confirmedAt); XCTAssertNil(actuator.record); XCTAssertTrue(fans.state.isFullyAutomatic)
            for operation in fans.operations.dropFirst(count) {
                switch operation {
                case .mode(_, let manual): XCTAssertFalse(manual)
                case .target(_, let rpm): XCTAssertEqual(rpm, 0)
                case .globalUnlock(let enabled): XCTAssertFalse(enabled)
                }
            }
        }
    }

    // Review round 1, N3 and S7. What the helper's own attempt accepts at its
    // start: the record's own states; fully automatic fans; and, for an
    // unconfirmed manual entry only, that fan in manual at any target.
    func testWhatTheAutomaticAttemptAcceptsAtItsStart() throws {
        // A manual entry that landed late at a target of the firmware's own.
        var fans = RigFans(), journal = RigJournal()
        var actuator = try actuator(fans, journal)
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        fans.withheld = { $0 == .mode(fan: 0, manual: true) }
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
            manualModeCommit: { try $0(fans.now) }, acknowledgementConflict: { nil }))
        fans.land(.mode(fan: 0, manual: true)); fans.state.fans[0].targetRPM = 1800
        XCTAssertFalse(try XCTUnwrap(actuator.record).matches(fans.state), "The record alone cannot predict that target.")
        XCTAssertNotNil(try recover(actuator).confirmedAt)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)] + release); XCTAssertTrue(fans.state.isFullyAutomatic)

        // The same hold, but it is the other fan that reads manual: refused.
        fans = RigFans(); journal = RigJournal(); actuator = try self.actuator(fans, journal)
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        fans.withheld = { $0 == .mode(fan: 0, manual: true) }
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
            manualModeCommit: { try $0(fans.now) }, acknowledgementConflict: { nil }))
        fans.state.fans[1].mode = 1; fans.state.fans[1].targetRPM = 1800
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("no longer match")) }
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])

        // An unconfirmed target is predictable, so its fan gets no such allowance.
        fans = RigFans(); journal = RigJournal(); actuator = try heldTarget(fans, journal)
        fans.state.fans[0].targetRPM = 2222
        var count = fans.operations.count
        XCTAssertThrowsError(try recover(actuator)) { XCTAssertTrue($0.localizedDescription.contains("no longer match")) }
        XCTAssertEqual(fans.operations.count, count)
        // ... but the target it asked for, landing late, is one of the record's own states.
        fans = RigFans(); journal = RigJournal(); actuator = try heldTarget(fans, journal)
        fans.state.fans[0].targetRPM = 4000
        XCTAssertNotNil(try recover(actuator).confirmedAt)

        // Fans that already read fully automatic, although the record says manual.
        fans = RigFans(); journal = RigJournal(); actuator = try heldTarget(fans, journal)
        fans.state.fans[0].mode = 0
        XCTAssertFalse(try XCTUnwrap(actuator.record).matches(fans.state))
        count = fans.operations.count
        XCTAssertNotNil(try recover(actuator).confirmedAt)
        XCTAssertEqual(Array(fans.operations.dropFirst(count)), release, "The named fan is still released.")
    }

    // Review round 1, S7. The command's deadline is its own native return
    // plus one second, also when it ended early or its write call failed.
    func testTheUnconfirmedCommandsDeadlineIsItsOwnReturnPlusOneSecond() throws {
        // Ended early: the first complete probe could not be read.
        var fans = RigFans(), journal = RigJournal()
        var actuator = try actuator(fans, journal)
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.now) })
        var writtenAt: TimeInterval?, failReadAt: Int?
        fans.onPerform = { if case .target = $0 { writtenAt = fans.now; failReadAt = fans.reads + 2 } }
        fans.onRead = { if $0 == failReadAt { throw FanControlError.hardware("Fake probe read failure") } }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil }))
        fans.onPerform = nil; fans.onRead = nil
        var command = actuator.unconfirmedCommand
        XCTAssertEqual(command.cause, "readFailure")
        XCTAssertEqual(try XCTUnwrap(command.deadline), try XCTUnwrap(writtenAt) + 1, accuracy: 0.000_001)
        XCTAssertLessThan(fans.now, try XCTUnwrap(command.deadline), "The command ended before its deadline.")
        var firstWriteAt: TimeInterval?
        fans.onPerform = { _ in if firstWriteAt == nil { firstWriteAt = fans.now } }
        XCTAssertNotNil(try recover(actuator).confirmedAt)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstWriteAt), try XCTUnwrap(writtenAt) + 1 - 0.000_001)

        // The write call itself failed: no native receipt, so the deadline
        // counts from the call's return.
        fans = RigFans(); journal = RigJournal(); actuator = try self.actuator(fans, journal)
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.now) })
        fans.onPerform = { if case .target = $0 { writtenAt = fans.now; throw FanControlError.hardware("Fake write failure") } }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil }))
        fans.onPerform = nil
        command = actuator.unconfirmedCommand
        XCTAssertEqual(command.cause, "performFailure")
        XCTAssertEqual(try XCTUnwrap(command.deadline), try XCTUnwrap(writtenAt) + 1, accuracy: 0.000_001)
    }

    // Review round 1, S3. A reply carrying both traces at their largest and
    // a receipt whose every step used every probe still fits the limit.
    func testAReplyWithTheLargestTracesAndReceiptFitsTheLimit() throws {
        let fans = RigFans()
        let observation = FanControlObservation(capturedAt: 123456.789012, fans: [
            FanReading(id: 0, actualRPM: 5999.123456, targetRPM: 5999.123456, mode: 1),
            FanReading(id: 1, actualRPM: 5499.123456, targetRPM: 5499.123456, mode: 1)], globalUnlock: 0)
        let probes = (0...10).map { FanDiagnosticProbe(index: $0, startedAt: 123456.789012, returnedAt: 123456.889012,
            observation: observation, error: nil, operationConfirmed: true, ownershipMatches: true,
            model: fans.capabilities.model, fanMetadata: fans.capabilities.fans) }
        let calls = (0..<256).map { _ in FanNativeCallReceipt(key: "F0Tg", command: 6, startedAt: 123456.789012,
            returnedAt: 123456.799012, kernelResult: 0, requestedValueBytes: 4, returnedStructBytes: 80,
            firmwareResult: 0, firmwareStatus: 0, returnedValueHex: "00000000", requestedValueHex: "00a07a45") }
        var manual = FanManualModeDiagnostic(operation: .mode(fan: 0, manual: true), before: observation, performStartedAt: 1,
            performReturnedAt: 2, firstMismatchAt: 3, deadline: 4, probes: probes, termination: "deadline",
            primaryFailure: String(repeating: "x", count: 600))
        manual.nativeCalls = calls
        var target = FanTargetDiagnostic(operation: .target(fan: 0, rpm: 5999.123456), before: observation, performStartedAt: 1,
            performReturnedAt: 2, probes: probes, termination: "deadline", primaryFailure: String(repeating: "x", count: 600))
        target.nativeCalls = calls; target.after = observation
        var receipt = FanSelfRecoveryReceipt(recoveryID: UUID().uuidString, trigger: .automatic, cause: "deadline",
            unconfirmed: .target(fan: 0, rpm: 5999.123456), startedAt: 123456.789012)
        receipt.steps = [FanOperation.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .mode(fan: 1, manual: false),
                         .target(fan: 1, rpm: 0)].map {
            FanSelfRecoveryStep(operation: $0, termination: "acknowledged", nativeWriteReturnedAt: 123456.789012,
                                acknowledgedAt: 123457.689012, observations: probes.count, probes: probes) }
        let settle = FanFanProbe(model: fans.capabilities.model, fans: fans.capabilities.fans, observation: observation)
        receipt.settle = [settle, settle]; receipt.failure = String(repeating: "x", count: 600)
        var status = FanStatus(serviceGeneration: UUID().uuidString)
        status.capabilities = fans.capabilities; status.fanProbe = settle
        status.manualModeDiagnostic = manual; status.targetDiagnostic = target; status.selfRecoveryReceipt = receipt
        // Every log line is a failed receipt of that size.
        let line = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        status.diagnostics = Array(repeating: line, count: 200)
        let structured = try JSONEncoder().encode({ () -> FanStatus in var bare = status; bare.diagnostics = []; return bare }())
        XCTAssertLessThan(structured.count, FanStatus.maximumReplyBytes * 3 / 4, "\(structured.count) bytes of structured evidence")
        let reply = try status.encodedReply()
        XCTAssertLessThanOrEqual(reply.count, FanStatus.maximumReplyBytes)
        let decoded = try JSONDecoder().decode(FanStatus.self, from: reply)
        XCTAssertEqual(decoded.selfRecoveryReceipt?.steps.count, 4)
        XCTAssertEqual(decoded.selfRecoveryReceipt?.steps.first?.probes.count, 11)
        XCTAssertEqual(decoded.targetDiagnostic?.nativeCalls.count, 256)
        XCTAssertGreaterThan(decoded.diagnosticsOmittedCount ?? 0, 0, "Only log lines are dropped to fit.")
    }
}

final class FanSelfRecoveryControllerTests: XCTestCase {
    private let boot = UUID().uuidString, artifact = "fake-recovery-artifact"
    private let release: [FanOperation] = [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .target(fan: 1, rpm: 0)]

    private func controller(_ fans: RigFans, _ journal: FanRecoveryPersistence, boot: String? = nil,
                            conflict: @escaping () -> String? = { nil }) throws -> FanHelperController {
        try FanHelperController(hardware: fans, persistence: journal, bootID: boot ?? self.boot,
            artifactIdentity: artifact, conflict: conflict, clock: { fans.now }, startTimers: false,
            modeDiagnosticTiming: FanModeDiagnosticTiming(clock: { fans.now }, pause: { if !fans.clockFrozen { fans.now += $0 } }))
    }
    private func begin(_ controller: FanHelperController, owner: String = "owner") -> FanStatus {
        let done = expectation(description: "begin reply")
        var status = FanStatus(serviceGeneration: "none")
        controller.begin(owner: owner, profile: .standard) { status = $0; done.fulfill() }
        wait(for: [done], timeout: 4)
        return status
    }
    private func poll(_ controller: FanHelperController) {
        let done = expectation(description: "poll")
        controller.poll { done.fulfill() }
        wait(for: [done], timeout: 4)
    }
    private func restore(_ controller: FanHelperController, owner: String = "owner", id: String) -> FanStatus {
        let done = expectation(description: "restore reply")
        var status = FanStatus(serviceGeneration: "none")
        controller.restoreAutomatic(owner: owner, recoveryID: id) { status = $0; done.fulfill() }
        wait(for: [done], timeout: 4)
        return status
    }
    private func stop(_ controller: FanHelperController, owner: String = "owner") -> FanStatus {
        let done = expectation(description: "stop reply")
        var status = FanStatus(serviceGeneration: "none")
        controller.stop(owner: owner, reason: "Fan Control was turned off by the app.") { status = $0; done.fulfill() }
        wait(for: [done], timeout: 4)
        return status
    }
    private func sleepAndWake(_ controller: FanHelperController) {
        let done = expectation(description: "sleep acknowledged")
        controller.systemWillSleep { done.fulfill() }
        wait(for: [done], timeout: 4)
        controller.systemDidWake()
    }
    // A pending target left on disk by an earlier helper process.
    private func heldOnDisk(_ fans: RigFans, _ journal: RigJournal) throws {
        let actuator = try FanActuator(hardware: fans, persistence: journal, bootID: boot,
            serviceGeneration: UUID().uuidString, artifactIdentity: artifact,
            modeDiagnosticTiming: FanModeDiagnosticTiming(clock: { fans.now }, pause: { fans.now += $0 }))
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.now) })
        fans.withheld = { if case .target(_, let rpm) = $0 { return rpm > 0 }; return false }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil }))
    }

    func testAFailedTargetIsReleasedAndFanControlStaysOffUntilReenabled() throws {
        let fans = RigFans(), journal = RigJournal()
        fans.withheld = { if case .target(_, let rpm) = $0 { return rpm > 0 }; return false }
        let controller = try controller(fans, journal)
        let status = begin(controller)
        XCTAssertEqual(status.mode, .paused); XCTAssertEqual(status.reason, FanActuator.selfRecoveredReason)
        XCTAssertFalse(status.externalRecoveryRequired); XCTAssertNil(status.externalRecoveryID)
        XCTAssertNil(status.sessionID); XCTAssertFalse(status.ownsOverride); XCTAssertTrue(status.requestedRPM.isEmpty)
        XCTAssertTrue(status.releaseVerified); XCTAssertTrue(status.safeToUnregister)
        XCTAssertEqual(status.fanProbe?.observation.isFullyAutomatic, true)
        let receipt = try XCTUnwrap(status.selfRecoveryReceipt)
        XCTAssertEqual(receipt.trigger, .automatic); XCTAssertEqual(receipt.cause, "deadline")
        XCTAssertNotNil(receipt.confirmedAt); XCTAssertEqual(receipt.steps.map(\.operation), release)
        guard case .target(0, let rpm) = receipt.unconfirmed else { return XCTFail("Missing unconfirmed target") }
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: rpm)] + release)
        XCTAssertNil(journal.record); XCTAssertNil(controller.safety.check(now: fans.now).session)
        XCTAssertTrue(status.diagnostics.contains { $0.contains("Target acknowledgement failed: deadline") })
        XCTAssertTrue(status.diagnostics.contains { $0.contains("Self-recovery (automatic) returned the fans to automatic") })
        // Status keeps the unconfirmed command's own trace beside the receipt.
        XCTAssertEqual(status.targetDiagnostic?.operation, receipt.unconfirmed)
        XCTAssertEqual(status.targetDiagnostic?.termination, "deadline")
        XCTAssertEqual(status.targetDiagnostic?.evidenceOnly, true)
        XCTAssertTrue(receipt.steps.allSatisfy { $0.probes.count == $0.observations && !$0.probes.isEmpty })
        XCTAssertNil(status.restoreAutomaticOffered)
        XCTAssertNoThrow(try status.encodedReply())
        // Nothing resumes by itself: polling stays off and writes nothing.
        let count = fans.operations.count
        fans.now += 1; poll(controller)
        XCTAssertEqual(controller.status(observe: false).mode, .paused)
        XCTAssertEqual(fans.operations.count, count)
        XCTAssertFalse(controller.renew(owner: "owner", session: UUID().uuidString))
        // Turning it on again starts a new session.
        fans.withheld = { _ in false }
        let again = begin(controller)
        XCTAssertNil(again.requestError); XCTAssertNotNil(again.sessionID)
        XCTAssertEqual(fans.operations.dropFirst(count).first, .mode(fan: 0, manual: true))
        XCTAssertNil(again.selfRecoveryReceipt, "A new session does not show the previous session's receipt.")
    }

    func testARestartOnTheSameBootAttemptsOnceOnTheFirstPoll() throws {
        let fans = RigFans(), journal = RigJournal()
        try heldOnDisk(fans, journal)
        let count = fans.operations.count
        let controller = try controller(fans, journal)
        let started = fans.now
        let initial = controller.status(observe: false)
        XCTAssertTrue(initial.externalRecoveryRequired); XCTAssertEqual(initial.mode, .externalRecoveryRequired)
        XCTAssertEqual(initial.restoreAutomaticOffered, true); XCTAssertEqual(initial.reason, FanActuator.externalRecoveryReason)
        XCTAssertEqual(fans.operations.count, count, "Nothing is written at construction.")
        var firstWriteAt: TimeInterval?
        fans.onPerform = { _ in if firstWriteAt == nil { firstWriteAt = fans.now } }
        poll(controller)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstWriteAt), started + 1 - 0.000_001, "At least one second after helper start.")
        let status = controller.status(observe: false)
        XCTAssertEqual(status.mode, .paused); XCTAssertFalse(status.externalRecoveryRequired)
        XCTAssertEqual(status.selfRecoveryReceipt?.trigger, .startup)
        XCTAssertEqual(status.selfRecoveryReceipt?.cause, "helperRestart")
        XCTAssertEqual(Array(fans.operations.dropFirst(count)), release)
        XCTAssertNil(journal.record); XCTAssertTrue(status.safeToUnregister)
    }

    func testARestartHoldsForAnotherBootAUsedMarkOrACompetingUtility() throws {
        for reason in ["otherBoot", "marked", "utility"] {
            let fans = RigFans(), journal = RigJournal()
            try heldOnDisk(fans, journal)
            if reason == "marked" { journal.record?.recoveryAttempted = true }
            let count = fans.operations.count
            let controller = try controller(fans, journal, boot: reason == "otherBoot" ? UUID().uuidString : nil,
                                            conflict: { reason == "utility" ? "Macs Fan Control" : nil })
            XCTAssertEqual(controller.status(observe: false).restoreAutomaticOffered, reason != "otherBoot", reason)
            XCTAssertEqual(controller.status(observe: false).reason,
                reason == "otherBoot" ? FanActuator.externalRecoveryOnlyReason : FanActuator.externalRecoveryReason, reason)
            for _ in 0..<3 { fans.now += 1; poll(controller) }
            let status = controller.status(observe: false)
            XCTAssertTrue(status.externalRecoveryRequired, reason); XCTAssertEqual(status.mode, .externalRecoveryRequired, reason)
            XCTAssertEqual(fans.operations.count, count, reason)
            XCTAssertEqual(journal.record?.pending, .target(fan: 0, rpm: 4000), reason)
            XCTAssertEqual(journal.record?.recoveryAttempted, reason == "otherBoot" ? nil : true, reason)
            // Review round 1, S1. Only a record this helper may release is
            // offered Restore automatic now; the texts differ accordingly.
            let text = reason == "otherBoot" ? FanActuator.externalRecoveryOnlyReason : FanActuator.externalRecoveryReason
            XCTAssertEqual(status.reason, text, reason)
            XCTAssertEqual(status.restoreAutomaticOffered, reason != "otherBoot", reason)
            XCTAssertEqual(begin(controller).requestError, text, reason)
            XCTAssertFalse(FanActuator.externalRecoveryOnlyReason.contains("Restore automatic now"))
        }
    }

    func testTheOwnersExplicitRequestClearsAHoldAndIsRefusedWhenItShouldBe() throws {
        let fans = RigFans(), journal = RigJournal()
        try heldOnDisk(fans, journal)
        journal.record?.recoveryAttempted = true
        var utility: String?
        let controller = try controller(fans, journal, conflict: { utility })
        poll(controller)
        let id = try XCTUnwrap(controller.status(observe: false).externalRecoveryID)
        let count = fans.operations.count
        // Wrong or malformed identity, and a competing utility: refused, nothing written.
        for bad in [UUID().uuidString, "not-a-uuid"] {
            XCTAssertNotNil(restore(controller, id: bad).requestError)
        }
        utility = "Macs Fan Control"
        let refused = restore(controller, id: id)
        XCTAssertTrue(refused.requestError?.contains("Macs Fan Control") == true)
        XCTAssertTrue(refused.externalRecoveryRequired)
        XCTAssertEqual(refused.selfRecoveryReceipt?.trigger, .explicit); XCTAssertNotNil(refused.selfRecoveryReceipt?.failure)
        XCTAssertEqual(fans.operations.count, count)
        // Review round 1, S2. A failed attempt's receipt is in the log, once;
        // requests refused before any attempt add none.
        let logged = { (status: FanStatus) in status.diagnostics.filter { $0.contains("did not clear the hold") && $0.contains("; receipt {") }.count }
        XCTAssertEqual(logged(refused), 1)
        XCTAssertEqual(logged(restore(controller, id: UUID().uuidString)), 1)
        XCTAssertEqual(refused.selfRecoveryReceipt?.recoveryID, id)
        utility = nil
        // The reservation is released each time, so a later request can run.
        let status = restore(controller, id: id)
        XCTAssertNil(status.requestError)
        XCTAssertEqual(status.mode, .off); XCTAssertNil(status.reason)
        XCTAssertFalse(status.externalRecoveryRequired); XCTAssertTrue(status.releaseVerified); XCTAssertTrue(status.safeToUnregister)
        XCTAssertEqual(status.selfRecoveryReceipt?.trigger, .explicit); XCTAssertNotNil(status.selfRecoveryReceipt?.confirmedAt)
        XCTAssertEqual(Array(fans.operations.dropFirst(count)), release)
        XCTAssertNil(journal.record)
        // With no hold there is nothing to restore.
        XCTAssertNotNil(restore(controller, id: id).requestError)
        fans.withheld = { _ in false }
        XCTAssertNil(begin(controller).requestError)
    }

    func testAnExplicitRequestIsRefusedForAnotherBootAndWhileAnotherReservationRuns() throws {
        let fans = RigFans(), journal = RigJournal()
        try heldOnDisk(fans, journal)
        let controller = try controller(fans, journal, boot: UUID().uuidString)
        poll(controller)
        let id = try XCTUnwrap(controller.status(observe: false).externalRecoveryID)
        let count = fans.operations.count
        let refused = restore(controller, id: id)
        XCTAssertTrue(refused.requestError?.contains("another boot or helper build") == true)
        XCTAssertEqual(fans.operations.count, count); XCTAssertTrue(refused.externalRecoveryRequired)
        XCTAssertEqual(refused.restoreAutomaticOffered, false); XCTAssertEqual(refused.reason, FanActuator.externalRecoveryOnlyReason)
        XCTAssertNil(refused.selfRecoveryReceipt, "A refusal before any attempt leaves no receipt.")
        XCTAssertFalse(refused.diagnostics.contains { $0.contains("; receipt {") })
        // Another connection's reservation makes the request busy.
        _ = try controller.safety.reserveExternalRecovery(owner: "someone else")
        XCTAssertEqual(restore(controller, id: id).requestError, FanControlError.busy.localizedDescription)
        XCTAssertEqual(fans.operations.count, count)
    }

    // Self-review F2. "Once" is once per hold, not once per helper process.
    func testEveryHoldGetsItsOwnAutomaticAttempt() throws {
        let fans = RigFans(), journal = RigJournal()
        fans.withheld = { if case .target(_, let rpm) = $0 { return rpm > 0 }; return false }
        let controller = try controller(fans, journal)
        var sessions: Set<String> = []
        for round in 1...3 {
            let status = begin(controller)
            XCTAssertEqual(status.mode, .paused, "round \(round)")
            XCTAssertEqual(status.reason, FanActuator.selfRecoveredReason, "round \(round)")
            XCTAssertFalse(status.externalRecoveryRequired, "round \(round)")
            let receipt = try XCTUnwrap(status.selfRecoveryReceipt)
            XCTAssertEqual(receipt.trigger, .automatic); XCTAssertNotNil(receipt.confirmedAt, "round \(round)")
            sessions.insert(receipt.recoveryID)
            XCTAssertNil(journal.record, "round \(round)"); XCTAssertTrue(fans.state.isFullyAutomatic, "round \(round)")
            fans.now += 1
        }
        XCTAssertEqual(sessions.count, 3, "Each hold belonged to its own session.")
    }

    // Self-review F3. Macs Fan Control appears while a target is being
    // confirmed, so the helper does not try by itself (E-Q1). A restart no
    // longer knows why the command is unconfirmed; it must not try either.
    func testADeclinedAutomaticAttemptStaysDeclinedAfterARestart() throws {
        let fans = RigFans(), journal = RigJournal()
        var utility: String?
        let first = try controller(fans, journal, conflict: { utility })
        fans.onPerform = { if case .target(_, let rpm) = $0, rpm > 0 { utility = "Macs Fan Control" } }
        let held = begin(first)
        XCTAssertTrue(held.externalRecoveryRequired)
        XCTAssertEqual(held.targetDiagnostic?.termination, "conflictingUtility")
        XCTAssertNil(held.selfRecoveryReceipt, "No attempt was made.")
        XCTAssertEqual(journal.record?.recoveryDeclined, true); XCTAssertNil(journal.record?.recoveryAttempted)
        XCTAssertTrue(held.diagnostics.contains { $0.contains("No automatic recovery: the unconfirmed fan command ended as conflictingUtility. The hold remains.") })
        let count = fans.operations.count
        let pending = try XCTUnwrap(journal.record?.pending)
        // The utility quits and the helper restarts on the same boot and build.
        utility = nil; fans.onPerform = nil
        let restarted = try controller(fans, journal)
        for _ in 0..<3 { fans.now += 1; poll(restarted) }
        let status = restarted.status(observe: false)
        XCTAssertTrue(status.externalRecoveryRequired); XCTAssertEqual(status.mode, .externalRecoveryRequired)
        XCTAssertEqual(fans.operations.count, count, "No automatic attempt for an excluded cause, before or after a restart.")
        XCTAssertEqual(journal.record?.pending, pending)
        XCTAssertNil(status.selfRecoveryReceipt)
        // The owner's explicit request still clears it.
        let cleared = restore(restarted, id: try XCTUnwrap(status.externalRecoveryID))
        XCTAssertNil(cleared.requestError); XCTAssertFalse(cleared.externalRecoveryRequired)
        XCTAssertTrue(fans.state.isFullyAutomatic); XCTAssertNil(journal.record)
    }

    // Guard for F3's fix: a request that reaches a restarted helper before its
    // first poll must not use up or decline the startup attempt.
    func testAStopBeforeTheFirstPollLeavesTheStartupAttemptForThatPoll() throws {
        let fans = RigFans(), journal = RigJournal()
        try heldOnDisk(fans, journal)
        let count = fans.operations.count
        let controller = try controller(fans, journal)
        let stopped = stop(controller)
        XCTAssertTrue(stopped.externalRecoveryRequired)
        XCTAssertEqual(fans.operations.count, count)
        XCTAssertNil(journal.record?.recoveryDeclined); XCTAssertNil(journal.record?.recoveryAttempted)
        poll(controller)
        let status = controller.status(observe: false)
        XCTAssertEqual(status.mode, .paused); XCTAssertFalse(status.externalRecoveryRequired)
        XCTAssertEqual(status.selfRecoveryReceipt?.trigger, .startup)
        XCTAssertEqual(Array(fans.operations.dropFirst(count)), release)
    }

    // Guard for F4: the startup attempt belongs to the record found at start.
    // Once the owner has cleared that record, a later hold in the same process
    // is an ordinary live hold with its own automatic attempt.
    func testAStartupAttemptNeverCarriesOverToALaterHold() throws {
        let fans = RigFans(), journal = RigJournal()
        try heldOnDisk(fans, journal)
        let controller = try controller(fans, journal)
        // The owner clears the hold before the first poll.
        let id = try XCTUnwrap(controller.status(observe: false).externalRecoveryID)
        let cleared = restore(controller, id: id)
        XCTAssertNil(cleared.requestError); XCTAssertEqual(cleared.selfRecoveryReceipt?.trigger, .explicit)
        // A new session's target then stays unconfirmed.
        fans.now += 1
        let status = begin(controller)
        XCTAssertEqual(status.mode, .paused); XCTAssertEqual(status.reason, FanActuator.selfRecoveredReason)
        XCTAssertEqual(status.selfRecoveryReceipt?.trigger, .automatic)
        XCTAssertEqual(status.selfRecoveryReceipt?.cause, "deadline")
        fans.now += 1; poll(controller)
        XCTAssertEqual(controller.status(observe: false).selfRecoveryReceipt?.trigger, .automatic)
    }

    // Self-review F12. E-Q5: the explanation stays until Fan Control is turned
    // on again. A later stop or system sleep does not replace it.
    func testTheSelfRecoveryExplanationSurvivesALaterStopOrSleep() throws {
        let fans = RigFans(), journal = RigJournal()
        fans.withheld = { if case .target(_, let rpm) = $0 { return rpm > 0 }; return false }
        let controller = try controller(fans, journal)
        XCTAssertEqual(begin(controller).reason, FanActuator.selfRecoveredReason)
        let count = fans.operations.count
        let stopped = stop(controller)
        XCTAssertNil(stopped.requestError)
        XCTAssertEqual(stopped.mode, .paused); XCTAssertEqual(stopped.reason, FanActuator.selfRecoveredReason)
        XCTAssertTrue(stopped.safeToUnregister)
        sleepAndWake(controller)
        let woken = controller.status(observe: false)
        XCTAssertEqual(woken.mode, .paused); XCTAssertEqual(woken.reason, FanActuator.selfRecoveredReason)
        XCTAssertEqual(fans.operations.count, count, "Neither request writes anything.")
        // Turning Fan Control on again ends it.
        fans.withheld = { _ in false }; fans.now += 1
        let again = begin(controller)
        XCTAssertNil(again.requestError); XCTAssertNotNil(again.sessionID)
        XCTAssertNotEqual(again.reason, FanActuator.selfRecoveredReason)
        let off = stop(controller)
        XCTAssertEqual(off.reason, "Fan Control was turned off by the app.")
    }

    // Self-review F10. A hold whose mark could not be saved has used its
    // attempt for this process. Later stops must not present "restoring".
    func testAUsedAttemptWithoutADurableMarkDoesNotPresentRestoringAgain() throws {
        let fans = RigFans(), journal = RigJournal()
        fans.withheld = { if case .target(_, let rpm) = $0 { return rpm > 0 }; return false }
        journal.failSave = { $0.recoveryAttempted == true }
        let controller = try controller(fans, journal)
        let held = begin(controller)
        XCTAssertTrue(held.externalRecoveryRequired)
        let count = fans.operations.count
        let transitions = held.diagnostics.filter { $0.contains("→ restoring") }.count
        for _ in 0..<2 { _ = stop(controller) }
        let status = controller.status(observe: false)
        XCTAssertEqual(status.mode, .externalRecoveryRequired)
        XCTAssertEqual(status.diagnostics.filter { $0.contains("→ restoring") }.count, transitions)
        XCTAssertEqual(fans.operations.count, count)
    }

    // The decision could not be journaled: the log says so, and this process
    // still does not try. (After a restart the attempt is open again; that
    // limit is pinned at the actuator level.)
    func testAnUnjournaledDeclineIsLoggedAndStillHoldsInThisProcess() throws {
        let fans = RigFans(), journal = RigJournal()
        var utility: String?
        let controller = try controller(fans, journal, conflict: { utility })
        fans.onPerform = { if case .target(_, let rpm) = $0, rpm > 0 { utility = "Macs Fan Control" } }
        journal.failSave = { $0.recoveryDeclined == true }
        let held = begin(controller)
        XCTAssertTrue(held.externalRecoveryRequired)
        XCTAssertTrue(held.diagnostics.contains { $0.contains("this decision could not be journaled") })
        XCTAssertNil(journal.record?.recoveryDeclined)
        let count = fans.operations.count
        utility = nil; fans.onPerform = nil; journal.failSave = nil
        for _ in 0..<3 { fans.now += 1; poll(controller); _ = stop(controller) }
        XCTAssertTrue(controller.status(observe: false).externalRecoveryRequired)
        XCTAssertEqual(fans.operations.count, count)
    }

    // The owner's request holds a reservation. Sleep or a lost connection
    // revokes it, and the attempt stops before its next write.
    func testSleepOrDisconnectDuringTheExplicitAttemptStopsItAndKeepsTheHold() throws {
        for event in ["sleep", "disconnect"] {
            let fans = RigFans(), journal = RigJournal()
            try heldOnDisk(fans, journal)
            journal.record?.recoveryAttempted = true
            let controller = try controller(fans, journal)
            poll(controller)
            let id = try XCTUnwrap(controller.status(observe: false).externalRecoveryID)
            let count = fans.operations.count
            fans.onPerform = { operation in
                guard operation == .mode(fan: 0, manual: false) else { return }
                if event == "sleep" { controller.systemWillSleep {} } else { controller.disconnected(owner: "owner") }
            }
            let status = restore(controller, id: id)
            fans.onPerform = nil
            XCTAssertNotNil(status.requestError, event); XCTAssertTrue(status.externalRecoveryRequired, event)
            XCTAssertEqual(Array(fans.operations.dropFirst(count)), [.mode(fan: 0, manual: false)], event)
            XCTAssertEqual(journal.record?.pending, .target(fan: 0, rpm: 4000), event)
            XCTAssertNil(status.selfRecoveryReceipt?.confirmedAt, event)
            controller.systemDidWake(); poll(controller)
            XCTAssertTrue(controller.status(observe: false).externalRecoveryRequired, event)
            // The owner can ask again.
            let again = restore(controller, id: id)
            XCTAssertNil(again.requestError, event); XCTAssertFalse(again.externalRecoveryRequired, event)
            XCTAssertTrue(fans.state.isFullyAutomatic, event)
        }
    }

    // Review round 1, M1. Permission is lost after a write's intent is saved
    // and before its native call. The intent is pending, so the helper acts
    // at once: it releases, or (utility running) uses its attempt without
    // writing. It must not leave the attempt open for a later sleep.
    func testAWriteCancelledAfterItsIntentIsHandledAtOnceNotAtALaterSleep() throws {
        for revocation in ["profile", "utility"] {
            let fans = RigFans(), journal = RigJournal()
            var utility: String?
            let controller = try controller(fans, journal, conflict: { utility })
            let started = begin(controller)
            XCTAssertNil(started.requestError, revocation)
            let session = try XCTUnwrap(started.sessionID)
            // Fan 1 enters on the next cycle.
            var fired = false
            journal.onSave = { record in
                guard record.pending == .mode(fan: 1, manual: true), !fired else { return }
                fired = true
                if revocation == "profile" {
                    controller.updateProfile(owner: "owner", session: session, profile: FanProfile(start: 50, maximum: 85)) { _ in }
                } else { utility = "Macs Fan Control" }
            }
            let count = fans.operations.count
            fans.now += 1; poll(controller)
            journal.onSave = nil
            XCTAssertTrue(fired, revocation)
            XCTAssertFalse(fans.operations.contains(.mode(fan: 1, manual: true)), "The cancelled write was never issued.")
            let status = controller.status(observe: false)
            if revocation == "profile" {
                XCTAssertEqual(status.mode, .paused); XCTAssertEqual(status.reason, FanActuator.selfRecoveredReason)
                XCTAssertFalse(status.externalRecoveryRequired)
                XCTAssertEqual(status.selfRecoveryReceipt?.trigger, .automatic)
                XCTAssertEqual(status.selfRecoveryReceipt?.cause, "performFailure")
                XCTAssertEqual(Array(fans.operations.dropFirst(count)),
                    [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .mode(fan: 1, manual: false), .target(fan: 1, rpm: 0)])
                XCTAssertNil(journal.record); XCTAssertTrue(fans.state.isFullyAutomatic)
            } else {
                XCTAssertTrue(status.externalRecoveryRequired); XCTAssertEqual(status.mode, .externalRecoveryRequired)
                XCTAssertEqual(fans.operations.count, count, "Nothing is written while the utility runs.")
                XCTAssertEqual(journal.record?.recoveryAttempted, true, "The attempt is used now.")
                utility = nil
                sleepAndWake(controller); fans.now += 1; poll(controller)
                XCTAssertEqual(fans.operations.count, count, "No attempt at a later sleep.")
                XCTAssertTrue(controller.status(observe: false).externalRecoveryRequired)
            }
        }
    }

    // Review round 1, M2. The startup attempt clears the hold while another
    // connection holds the exclusive recovery reservation. That reservation
    // must still end normally, or Fan Control stays busy.
    func testAStartupAttemptDoesNotStrandAnotherConnectionsReservation() throws {
        let fans = RigFans(), journal = RigJournal()
        try heldOnDisk(fans, journal)
        let controller = try controller(fans, journal)
        let reservation = try controller.safety.reserveExternalRecovery(owner: "owner")
        poll(controller)
        XCTAssertEqual(controller.status(observe: false).mode, .paused)
        XCTAssertEqual(controller.status(observe: false).selfRecoveryReceipt?.trigger, .startup)
        controller.safety.endExternalRecovery(owner: "owner", generation: reservation)
        fans.withheld = { _ in false }; fans.now += 1
        let again = begin(controller)
        XCTAssertNil(again.requestError); XCTAssertNotNil(again.sessionID)
    }

    // Review round 1, M2. A request that arrives while the helper's own
    // attempt is running leaves nothing behind either way.
    func testARequestDuringTheHelpersOwnAttemptLeavesFanControlUsable() throws {
        for request in ["restore", "verify"] {
            let fans = RigFans(), journal = RigJournal()
            try heldOnDisk(fans, journal)
            let controller = try controller(fans, journal)
            let id = try XCTUnwrap(controller.status(observe: false).externalRecoveryID)
            let replied = expectation(description: "request reply \(request)")
            var reply: FanStatus?, sent = false
            fans.onPerform = { operation in
                guard operation == .mode(fan: 0, manual: false), !sent else { return }
                sent = true
                if request == "restore" {
                    controller.restoreAutomatic(owner: "owner", recoveryID: id) { reply = $0; replied.fulfill() }
                } else {
                    controller.confirmExternalRecovery(owner: "owner", recoveryID: id) { reply = $0; replied.fulfill() }
                }
            }
            poll(controller)
            wait(for: [replied], timeout: 4)
            fans.onPerform = nil
            // It is refused at once, not queued behind the attempt.
            XCTAssertEqual(reply?.requestError, FanHelperController.attemptRunningReason, request)
            XCTAssertEqual(reply?.mode, .restoring, request)
            let status = controller.status(observe: false)
            XCTAssertEqual(status.mode, .paused, request); XCTAssertEqual(status.selfRecoveryReceipt?.trigger, .startup, request)
            fans.withheld = { _ in false }; fans.now += 1
            let again = begin(controller)
            XCTAssertNil(again.requestError, request); XCTAssertNotNil(again.sessionID, request)
        }
    }

    // Review round 1, S4 and S7. A release write that stays unconfirmed during
    // a stop or at sleep is followed at once by the helper's own attempt.
    func testAFailedReleaseWriteAtStopOrSleepIsFollowedByTheAttempt() throws {
        for event in ["stop", "sleep"] {
            let fans = RigFans(), journal = RigJournal()
            let controller = try controller(fans, journal)
            XCTAssertNil(begin(controller).requestError, event)
            let count = fans.operations.count
            var withheldOnce = false
            fans.withheld = { operation in
                guard operation == .mode(fan: 0, manual: false), !withheldOnce else { return false }
                withheldOnce = true; return true
            }
            let status: FanStatus
            if event == "stop" { status = stop(controller) } else { sleepAndWake(controller); status = controller.status(observe: false) }
            XCTAssertEqual(status.mode, .paused, event); XCTAssertEqual(status.reason, FanActuator.selfRecoveredReason, event)
            XCTAssertFalse(status.externalRecoveryRequired, event); XCTAssertTrue(status.safeToUnregister, event)
            let receipt = try XCTUnwrap(status.selfRecoveryReceipt, event)
            XCTAssertEqual(receipt.trigger, .automatic, event); XCTAssertEqual(receipt.cause, "deadline", event)
            XCTAssertEqual(receipt.unconfirmed, .mode(fan: 0, manual: false), event)
            XCTAssertEqual(Array(fans.operations.dropFirst(count)),
                [.mode(fan: 0, manual: false)] + release, event)
            XCTAssertTrue(status.diagnostics.contains { $0.contains("Release acknowledgement failed: deadline") }, event)
            XCTAssertNil(journal.record, event); XCTAssertTrue(fans.state.isFullyAutomatic, event)
        }
    }

    // The same when the ramp itself lets go: the session cooled below its
    // release point and the release write stayed unconfirmed.
    func testAFailedReleaseWriteAtARampReleaseIsFollowedByTheAttempt() throws {
        let fans = RigFans(), journal = RigJournal()
        let controller = try controller(fans, journal)
        XCTAssertNil(begin(controller).requestError)
        fans.now += 1; poll(controller)
        XCTAssertEqual(controller.status(observe: false).mode, .custom)
        var withheldOnce = false
        fans.withheld = { operation in
            guard case .mode(_, false) = operation, !withheldOnce else { return false }
            withheldOnce = true; return true
        }
        fans.temperature = 50
        var status = controller.status(observe: false)
        for _ in 0..<20 where status.mode != .paused {
            XCTAssertTrue(controller.renew(owner: "owner", session: try XCTUnwrap(status.sessionID)))
            fans.now += 1; poll(controller); status = controller.status(observe: false)
        }
        XCTAssertTrue(withheldOnce)
        XCTAssertEqual(status.mode, .paused); XCTAssertEqual(status.reason, FanActuator.selfRecoveredReason)
        XCTAssertNil(status.sessionID, "Fan Control is off, although only the ramp released.")
        let receipt = try XCTUnwrap(status.selfRecoveryReceipt)
        XCTAssertEqual(receipt.trigger, .automatic); XCTAssertNotNil(receipt.confirmedAt)
        guard case .mode(_, false) = receipt.unconfirmed else { return XCTFail("The unconfirmed command was not a mode release.") }
        XCTAssertNil(journal.record); XCTAssertTrue(fans.state.isFullyAutomatic)
    }

    // Review round 1, S7. Each E-Q1 exclusion end to end: the command ends
    // that way, nothing is released, and the decision is journaled.
    func testEachExcludedCauseEndsInAJournaledDeclineWithNoRelease() throws {
        for cause in ["unexpectedOwnership", "clockDidNotAdvance", "acknowledgementPersistenceFailure"] {
            let fans = RigFans(), journal = RigJournal()
            let controller = try controller(fans, journal)
            switch cause {
            case "unexpectedOwnership":
                fans.onPerform = { if case .target(_, let rpm) = $0, rpm > 0 { fans.state.fans[1].mode = 1; fans.state.fans[1].targetRPM = 2222 } }
            case "clockDidNotAdvance":
                fans.onPerform = { if case .target(_, let rpm) = $0, rpm > 0 { fans.clockFrozen = true } }
            default:
                journal.failSave = { $0.pending == nil && $0.acknowledged.fans[0].targetRPM > 1000 }
            }
            let held = begin(controller)
            fans.clockFrozen = false; fans.onPerform = nil; journal.failSave = nil
            XCTAssertTrue(held.externalRecoveryRequired, cause); XCTAssertEqual(held.targetDiagnostic?.termination, cause, cause)
            XCTAssertEqual(fans.operations.count, 2, cause)
            guard case .target(0, let rpm)? = fans.operations.last, rpm > 0 else { return XCTFail("Missing target: \(cause)") }
            XCTAssertNil(held.selfRecoveryReceipt, cause)
            XCTAssertEqual(journal.record?.recoveryDeclined, true, cause); XCTAssertNil(journal.record?.recoveryAttempted, cause)
            XCTAssertEqual(try journal.load()?.pending, .target(fan: 0, rpm: rpm), cause)
            XCTAssertTrue(held.diagnostics.contains { $0.contains("No automatic recovery: the unconfirmed fan command ended as \(cause). The hold remains.") }, cause)
            XCTAssertEqual(held.restoreAutomaticOffered, true, cause)
            for _ in 0..<2 { fans.now += 1; poll(controller); _ = stop(controller) }
            XCTAssertEqual(fans.operations.count, 2, cause)
            // A restart does not try either.
            let restarted = try self.controller(fans, journal)
            for _ in 0..<2 { fans.now += 1; poll(restarted) }
            XCTAssertEqual(fans.operations.count, 2, cause)
            XCTAssertTrue(restarted.status(observe: false).externalRecoveryRequired, cause)
        }
    }

    // Review round 1, S7. A command that ended early is still followed by the
    // attempt no sooner than its own one-second deadline.
    func testAnEarlyEndedCommandIsNotFollowedBeforeItsDeadline() throws {
        let fans = RigFans(), journal = RigJournal()
        let controller = try controller(fans, journal)
        var writtenAt: TimeInterval?, failReadAt: Int?, firstReleaseAt: TimeInterval?
        fans.onPerform = { operation in
            switch operation {
            case .target(_, let rpm) where rpm > 0: writtenAt = fans.now; failReadAt = fans.reads + 2
            case .mode(_, false): if firstReleaseAt == nil { firstReleaseAt = fans.now }
            default: break
            }
        }
        fans.onRead = { if $0 == failReadAt { throw FanControlError.hardware("Fake probe read failure") } }
        let status = begin(controller)
        XCTAssertEqual(status.mode, .paused); XCTAssertEqual(status.targetDiagnostic?.termination, "readFailure")
        let receipt = try XCTUnwrap(status.selfRecoveryReceipt)
        XCTAssertEqual(receipt.cause, "readFailure"); XCTAssertNotNil(receipt.confirmedAt)
        let deadline = try XCTUnwrap(writtenAt) + 1
        XCTAssertLessThan(receipt.startedAt, deadline, "The attempt was decided before the deadline and waited for it.")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(firstReleaseAt), deadline - 0.000_001)
    }

    // Review round 1, N6 and S7. Neither a helper removal request nor a
    // failed idle observation replaces the self-recovery explanation.
    func testTheExplanationSurvivesAFailedIdleObservationAndARemovalRequest() throws {
        let fans = RigFans(), journal = RigJournal()
        fans.withheld = { if case .target(_, let rpm) = $0 { return rpm > 0 }; return false }
        let controller = try controller(fans, journal)
        XCTAssertEqual(begin(controller).reason, FanActuator.selfRecoveredReason)
        fans.failFrame = FanControlError.invalid("Fake telemetry failure")
        _ = controller.status(observe: true)
        fans.now += 1; poll(controller)
        var status = controller.status(observe: false)
        XCTAssertEqual(status.mode, .paused); XCTAssertEqual(status.reason, FanActuator.selfRecoveredReason)
        XCTAssertNil(status.snapshot)
        fans.failFrame = nil
        let removal = expectation(description: "removal reply")
        controller.prepareRemoval(owner: "owner") { status = $0; removal.fulfill() }
        wait(for: [removal], timeout: 4)
        XCTAssertNil(status.requestError)
        XCTAssertEqual(status.mode, .paused); XCTAssertEqual(status.reason, FanActuator.selfRecoveredReason)
        XCTAssertTrue(status.safeToUnregister)
        // An ordinary fault is still replaced by a failed idle observation, as before.
        let other = RigFans(), otherJournal = RigJournal()
        let ordinary = try self.controller(other, otherJournal)
        XCTAssertNil(begin(ordinary).requestError)
        XCTAssertEqual(stop(ordinary).mode, .paused)
        other.failFrame = FanControlError.invalid("Fake telemetry failure")
        _ = ordinary.status(observe: true)
        other.now += 1; poll(ordinary)
        XCTAssertEqual(ordinary.status(observe: false).mode, .unavailable)
    }

    // Review round 2, N2. A request refused before any attempt publishes no
    // receipt, so an earlier session's receipt never appears beside a hold.
    func testARefusedRequestNeverShowsAnEarlierSessionsReceipt() throws {
        let fans = RigFans(), journal = RigJournal()
        var utility: String?
        let controller = try controller(fans, journal, conflict: { utility })
        fans.withheld = { if case .target(_, let rpm) = $0 { return rpm > 0 }; return false }
        let first = begin(controller)
        XCTAssertNotNil(first.selfRecoveryReceipt?.confirmedAt, "The first session ended with a cleared hold.")
        // The second session's target ends on a competing utility: declined, no attempt.
        fans.withheld = { _ in false }; fans.now += 1
        fans.onPerform = { if case .target(_, let rpm) = $0, rpm > 0 { utility = "Macs Fan Control" } }
        let held = begin(controller)
        fans.onPerform = nil; utility = nil
        XCTAssertTrue(held.externalRecoveryRequired); XCTAssertNil(held.selfRecoveryReceipt)
        for bad in [UUID().uuidString, "not-a-uuid"] {
            let refused = restore(controller, id: bad)
            XCTAssertNotNil(refused.requestError); XCTAssertNil(refused.selfRecoveryReceipt, bad)
        }
        // Later stops and polls publish none either. (They do not reach the
        // same condition in the helper's own attempt, which has no test.)
        for _ in 0..<2 { _ = stop(controller); fans.now += 1; poll(controller) }
        XCTAssertNil(controller.status(observe: false).selfRecoveryReceipt)
    }
}

#if FAN_CONTROL_QUALIFICATION
// E-Q7: the private qualification artifact can make the helper treat one real
// write's acknowledgement as unconfirmed. Nothing here exists in a production
// binary.
final class FanSelfRecoveryQualificationTests: XCTestCase {
    private let boot = UUID().uuidString, artifact = "fake-recovery-artifact"
    private let release: [FanOperation] = [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .target(fan: 1, rpm: 0)]

    private func wrapper(_ fans: RigFans, _ scenario: FanQualificationScenario?, run: @escaping () -> UUID,
                         expires: TimeInterval? = nil) -> FanQualificationHardware {
        FanQualificationHardware(delegating: fans, plan: { _ in
            scenario.map { FanQualificationPlan(runID: run(), scenario: $0, expiresAtUptime: expires ?? fans.now + 30) }
        }, clock: { fans.now })
    }

    func testTheWrapperWithholdsOncePerRunForItsScenariosKindOnly() throws {
        let fans = RigFans()
        var run = UUID()
        let manual = wrapper(fans, .unconfirmedManualEntry, run: { run })
        XCTAssertFalse(manual.withholdsAcknowledgement(of: .target(fan: 0, rpm: 3000)))
        XCTAssertFalse(manual.withholdsAcknowledgement(of: .mode(fan: 0, manual: false)))
        XCTAssertFalse(manual.withholdsAcknowledgement(of: .globalUnlock(true)))
        XCTAssertTrue(manual.withholdsAcknowledgement(of: .mode(fan: 0, manual: true)))
        XCTAssertFalse(manual.withholdsAcknowledgement(of: .mode(fan: 1, manual: true)), "One write per run.")
        let note = try XCTUnwrap(manual.provenance)
        XCTAssertTrue(note.contains("withheld-acknowledgement")); XCTAssertTrue(note.contains(run.uuidString))
        XCTAssertTrue(note.contains("native-unmodified"))
        // Later frames keep the note, so the controller's next logged frame shows it.
        _ = try manual.read(fans.capabilities)
        XCTAssertTrue(try XCTUnwrap(manual.provenance).contains("withheld the acknowledgement"))
        XCTAssertEqual(try manual.readControlState(fans.capabilities).fans, fans.state.fans, "Observations stay native.")
        run = UUID()
        XCTAssertTrue(manual.withholdsAcknowledgement(of: .mode(fan: 1, manual: true)), "A new run arms it again.")

        let target = wrapper(fans, .unconfirmedTarget, run: { run })
        XCTAssertFalse(target.withholdsAcknowledgement(of: .mode(fan: 0, manual: true)))
        XCTAssertFalse(target.withholdsAcknowledgement(of: .target(fan: 0, rpm: 0)), "A zero release target is never withheld.")
        XCTAssertTrue(target.withholdsAcknowledgement(of: .target(fan: 0, rpm: 3000)))
        XCTAssertFalse(target.withholdsAcknowledgement(of: .target(fan: 1, rpm: 3000)))

        // No input, another scenario, or an expired input withholds nothing.
        XCTAssertFalse(wrapper(fans, nil, run: { run }).withholdsAcknowledgement(of: .mode(fan: 0, manual: true)))
        XCTAssertFalse(wrapper(fans, .cpuAverage75, run: { UUID() }).withholdsAcknowledgement(of: .mode(fan: 0, manual: true)))
        XCTAssertFalse(wrapper(fans, .unconfirmedTarget, run: { UUID() }, expires: fans.now - 1)
            .withholdsAcknowledgement(of: .target(fan: 0, rpm: 3000)))
        let rejected = FanQualificationHardware(delegating: fans, plan: { _ in throw FanControlError.invalid("bad input") },
                                                clock: { fans.now })
        XCTAssertFalse(rejected.withholdsAcknowledgement(of: .mode(fan: 0, manual: true)))
        XCTAssertTrue(fans.operations.isEmpty, "The wrapper issues no fan operation of its own.")
    }

    // The fan really enters manual mode and every probe shows it; only the
    // helper's decision is withheld. The helper then releases its fans.
    func testAWithheldManualEntryStaysUnconfirmedAlthoughObservedThenIsReleased() throws {
        let fans = RigFans(), journal = RigJournal()
        let run = UUID()
        let hardware = wrapper(fans, .unconfirmedManualEntry, run: { run })
        let actuator = try FanActuator(hardware: hardware, persistence: journal, bootID: boot,
            serviceGeneration: UUID().uuidString, artifactIdentity: artifact,
            modeDiagnosticTiming: FanModeDiagnosticTiming(clock: { fans.now }, pause: { fans.now += $0 }))
        actuator.qualificationWithholdsAcknowledgement = { hardware.withholdsAcknowledgement(of: $0) }
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
            manualModeCommit: { try $0(fans.now) }, acknowledgementConflict: { nil }))
        let trace = try XCTUnwrap(actuator.lastManualModeDiagnostic)
        XCTAssertEqual(fans.state.fans[0].mode, 1, "The native write took effect.")
        XCTAssertTrue(trace.probes.allSatisfy { !$0.operationConfirmed })
        XCTAssertTrue(trace.probes.dropFirst().allSatisfy { $0.observation?.fans[0].mode == 1 }, "Probes report the real state.")
        XCTAssertTrue(["deadline", "probeLimit"].contains(trace.termination))
        XCTAssertEqual(trace.qualificationWithheld, true, "The trace says why matching probes did not count.")
        XCTAssertTrue(actuator.requiresExternalRecovery)
        // Release writes are never withheld, even within the same run.
        let command = actuator.unconfirmedCommand
        let receipt = try actuator.recoverOwnedFans(trigger: .automatic, cause: command.cause, notBefore: command.deadline, conflict: { nil })
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)] + release)
        XCTAssertNotNil(receipt.confirmedAt); XCTAssertNil(actuator.record); XCTAssertTrue(fans.state.isFullyAutomatic)
    }

    func testAWithheldTargetThroughTheControllerEndsReleasedAndOff() throws {
        let fans = RigFans(), journal = RigJournal()
        let run = UUID()
        let hardware = wrapper(fans, .unconfirmedTarget, run: { run })
        let controller = try FanHelperController(hardware: hardware, persistence: journal, bootID: boot,
            artifactIdentity: artifact, conflict: { nil }, clock: { fans.now }, startTimers: false,
            qualificationProvenance: { hardware.provenance },
            modeDiagnosticTiming: FanModeDiagnosticTiming(clock: { fans.now }, pause: { fans.now += $0 }))
        controller.setQualificationAcknowledgementWithholder { hardware.withholdsAcknowledgement(of: $0) }
        let done = expectation(description: "begin reply")
        var status = FanStatus(serviceGeneration: "none")
        controller.begin(owner: "owner", profile: .standard) { status = $0; done.fulfill() }
        wait(for: [done], timeout: 4)
        XCTAssertEqual(status.mode, .paused); XCTAssertEqual(status.reason, FanActuator.selfRecoveredReason)
        XCTAssertFalse(status.externalRecoveryRequired); XCTAssertTrue(status.releaseVerified)
        let receipt = try XCTUnwrap(status.selfRecoveryReceipt)
        XCTAssertNotNil(receipt.confirmedAt); XCTAssertEqual(receipt.trigger, .automatic)
        guard case .target(0, let rpm) = receipt.unconfirmed else { return XCTFail("Missing unconfirmed target") }
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: rpm)] + release)
        XCTAssertEqual(status.manualModeDiagnostic?.termination, "acknowledged", "Manual entry was not the withheld write.")
        XCTAssertNil(status.manualModeDiagnostic?.qualificationWithheld)
        XCTAssertEqual(status.targetDiagnostic?.qualificationWithheld, true)
        XCTAssertEqual(status.targetDiagnostic?.operation, receipt.unconfirmed)
        XCTAssertTrue(receipt.steps.allSatisfy { $0.probes.dropFirst().allSatisfy(\.operationConfirmed) }, "Release writes are judged normally.")
        XCTAssertTrue(fans.state.isFullyAutomatic); XCTAssertNil(journal.record)
    }

    // Review round 1, N8. A write refused before its intent exists does not
    // use up the run's one withheld acknowledgement.
    func testAWriteRefusedBeforeItsIntentDoesNotUseTheWithhold() throws {
        let fans = RigFans(), journal = RigJournal()
        let run = UUID()
        let hardware = wrapper(fans, .unconfirmedManualEntry, run: { run })
        let actuator = try FanActuator(hardware: hardware, persistence: journal, bootID: boot,
            serviceGeneration: UUID().uuidString, artifactIdentity: artifact,
            modeDiagnosticTiming: FanModeDiagnosticTiming(clock: { fans.now }, pause: { fans.now += $0 }))
        var asked = 0
        actuator.qualificationWithholdsAcknowledgement = { asked += 1; return hardware.withholdsAcknowledgement(of: $0) }
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { true },
            manualModeCommit: { try $0(fans.now) }, acknowledgementConflict: { nil }))
        XCTAssertEqual(asked, 0); XCTAssertNil(actuator.record?.pending); XCTAssertTrue(fans.operations.isEmpty)
        XCTAssertThrowsError(try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
            manualModeCommit: { try $0(fans.now) }, acknowledgementConflict: { nil }))
        XCTAssertEqual(asked, 1); XCTAssertEqual(actuator.lastManualModeDiagnostic?.qualificationWithheld, true)
        XCTAssertEqual(fans.state.fans[0].mode, 1, "The write was issued and took effect.")
    }
}
#endif
