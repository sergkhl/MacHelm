import XCTest
import IOKit
@testable import FanControlCore
@testable import FanControlHardware
@testable import FanControlRuntime

private final class TargetClock {
    var now: TimeInterval = 100
}

// Models the store's staged pending copy: it wins on load until a successful
// publication retires it or a newer durable pending intent supersedes it.
private final class TargetJournal: FanRecoveryPersistence {
    var record: FanRecoveryRecord?
    var marker: FanRecoveryRecord?
    var saved: [FanRecoveryRecord] = []
    var acknowledgements = 0, retirements = 0
    var onBoundedAcknowledgement: (() throws -> Void)?
    var afterBoundedSave: (() -> Void)?
    var onAcknowledged: ((FanOperation) -> Void)?
    var onSave: ((FanRecoveryRecord) -> Void)?
    var onRetire: (() -> Void)?
    var failRetirement = false
    func load() throws -> FanRecoveryRecord? { marker ?? record }
    func save(_ record: FanRecoveryRecord) throws {
        onSave?(record)
        self.record = record; saved.append(record)
        if record.pending != nil { marker = nil }
    }
    func remove() throws { record = nil; marker = nil }
    func acknowledgeManualMode(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                               validate: () throws -> Void) throws {
        guard record == pending else { throw FanControlError.ownership("Fake pending record changed") }
        try validate(); marker = pending; try save(acknowledged)
        do { try validate() } catch { record = pending; throw error }
    }
    func acknowledgeBoundedOperation(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                                     validate: () throws -> Void) throws {
        guard record == pending, marker == nil else { throw FanControlError.ownership("Fake pending record changed") }
        try validate(); try onBoundedAcknowledgement?(); try validate()
        marker = pending; try save(acknowledged); acknowledgements += 1
        afterBoundedSave?()
        try validate()
        if let operation = pending.pending { onAcknowledged?(operation) }
    }
    func retireAcknowledgementMarker(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord) throws {
        retirements += 1
        onRetire?()
        guard !failRetirement else { throw FanControlError.ownership("Fake pending-copy retirement failed") }
        guard marker == pending, record == acknowledged else { throw FanControlError.ownership("Fake marker changed") }
        marker = nil
    }
}

// Uses the transport's own encoder, independently of the actuator's correlation.
private func payloadHex(_ rpm: Double, encoding: String = "flt ") throws -> String {
    let template = SMCValue(encoding: encoding, bytes: Array(repeating: 0, count: encoding == "fpe2" ? 2 : 4))
    return try template.replacing(number: rpm).bytes.map { String(format: "%02x", $0) }.joined()
}

private func changed(_ receipt: FanNativeCallReceipt, key: String? = nil, command: UInt8? = nil,
                  startedAt: TimeInterval? = nil, returnedAt: TimeInterval? = nil, kernelResult: Int32? = nil,
                  requestedValueBytes: UInt32? = nil, returnedStructBytes: Int? = nil,
                  firmwareResult: UInt8? = nil, firmwareStatus: UInt8? = nil,
                  requestedValueHex: String? = nil) -> FanNativeCallReceipt {
    FanNativeCallReceipt(key: key ?? receipt.key, command: command ?? receipt.command,
        startedAt: startedAt ?? receipt.startedAt, returnedAt: returnedAt ?? receipt.returnedAt,
        kernelResult: kernelResult ?? receipt.kernelResult,
        requestedValueBytes: requestedValueBytes ?? receipt.requestedValueBytes,
        returnedStructBytes: returnedStructBytes ?? receipt.returnedStructBytes,
        firmwareResult: firmwareResult ?? receipt.firmwareResult,
        firmwareStatus: firmwareStatus ?? receipt.firmwareStatus,
        returnedValueHex: receipt.returnedValueHex, requestedValueHex: requestedValueHex ?? receipt.requestedValueHex)
}

// Manual mode writes become visible immediately, so the unchanged bounded
// manual-entry acknowledgement succeeds. Target writes stay invisible unless a
// test applies them or selects the read at which the firmware shows them;
// a mode release can be deferred the same way.
private final class TargetFans: FanHardware {
    let clock = TargetClock()
    var capabilities = FanPolicyTests.capabilities
    var state = FanPolicyTests.frame(75, at: 100).controlObservation
    var operations: [FanOperation] = []
    var readStarts: [TimeInterval] = []
    var probeStarts: [TimeInterval] = []
    var frameReads = 0
    var onFrameRead: ((Int) -> Void)?
    var frameAge: TimeInterval = 0
    var onRead: ((Int) throws -> Void)?
    var onPerform: ((FanOperation) throws -> Void)?
    var targetVisibleAtRead: Int?
    var applyTargets = false
    var pendingTarget: FanOperation?
    var deferRelease = false
    var releaseVisibleAtRead: Int?
    var pendingRelease: FanOperation?
    // Automatic firmware reports its own target; a zero release write does
    // not read back as zero.
    var firmwareAutomaticTarget: Double?
    var temperature = 75.0
    var cpuMaximum: Double?
    var recordReads = false
    var readKernelResult: ((Int) -> Int32)?
    var performDuration: TimeInterval = 0
    var wrapperDelay: TimeInterval = 0
    var receipts: [FanNativeCallReceipt] = []
    var receiptOverride: ((FanNativeCallReceipt) -> FanNativeCallReceipt?)?
    var capturing = false
    var captures = 0, captureEnds = 0
    var issuedCalls = 0, maximumIssuedCalls = 0
    var callsPerRead = 1, callsPerProbe = 1, callsPerWrite = 1
    var capturedAtOverride: ((Int) -> TimeInterval?)?
    var probeModel: String?
    var probeMetadata: [FanDescriptor]?

    func discover() throws -> FanCapabilities { capabilities }
    func read(_ capabilities: FanCapabilities) throws -> FanSnapshot {
        frameReads += 1
        onFrameRead?(frameReads)
        return FanSnapshot(capturedAt: clock.now - frameAge,
            temperatures: FanPolicyTests.frame(temperature, cpuMaximum: cpuMaximum).temperatures,
            fans: state.fans, thermalPressure: .nominal, globalUnlock: state.globalUnlock)
    }
    func readControlState(_ capabilities: FanCapabilities) throws -> FanControlObservation {
        let startedAt = clock.now
        readStarts.append(startedAt)
        issue(callsPerRead)
        if let visible = targetVisibleAtRead, readStarts.count >= visible, let pending = pendingTarget {
            apply(pending); pendingTarget = nil
        }
        if let visible = releaseVisibleAtRead, readStarts.count >= visible, let pending = pendingRelease {
            apply(pending); pendingRelease = nil
        }
        defer {
            // One synthetic native receipt per read, retained even when the
            // read fails or returns after the deadline.
            if capturing && recordReads {
                receipts.append(FanNativeCallReceipt(key: "F0Tg", command: 5, startedAt: startedAt,
                    returnedAt: clock.now, kernelResult: readKernelResult?(readStarts.count) ?? 0,
                    requestedValueBytes: 4, returnedStructBytes: 80, firmwareResult: 0, firmwareStatus: 0,
                    returnedValueHex: "00000000"))
            }
        }
        try onRead?(readStarts.count)
        return FanControlObservation(capturedAt: capturedAtOverride?(readStarts.count) ?? startedAt,
                                     fans: state.fans, globalUnlock: state.globalUnlock)
    }
    func readControlState(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanControlObservation {
        guard !cancelled() else { throw FanControlError.cancelled }
        return try readControlState(capabilities)
    }
    func probeFans(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanFanProbe {
        guard !cancelled() else { throw FanControlError.cancelled }
        probeStarts.append(clock.now)
        issue(callsPerProbe - callsPerRead)
        return FanFanProbe(model: probeModel ?? capabilities.model, fans: probeMetadata ?? capabilities.fans,
            observation: try readControlState(capabilities, cancelled: cancelled))
    }
    func perform(_ operation: FanOperation, capabilities: FanCapabilities, cancelled: () -> Bool) throws {
        guard !cancelled() else { throw FanControlError.cancelled }
        issue(callsPerWrite)
        let startedAt = clock.now
        operations.append(operation); clock.now += performDuration
        let receipt: FanNativeCallReceipt
        switch operation {
        case .mode(let id, let manual):
            receipt = FanNativeCallReceipt(key: capabilities.fans[id].modeKey, command: 6, startedAt: startedAt,
                returnedAt: clock.now, kernelResult: 0, requestedValueBytes: 1, returnedStructBytes: 80,
                firmwareResult: 0, firmwareStatus: 0, returnedValueHex: "00", requestedValueHex: manual ? "01" : "00")
        case .target(let id, let rpm):
            let hex = try payloadHex(rpm, encoding: capabilities.fans[id].targetEncoding)
            receipt = FanNativeCallReceipt(key: "F\(id)Tg", command: 6, startedAt: startedAt, returnedAt: clock.now,
                kernelResult: 0, requestedValueBytes: UInt32(hex.count / 2), returnedStructBytes: 80,
                firmwareResult: 0, firmwareStatus: 0, returnedValueHex: String(repeating: "0", count: hex.count),
                requestedValueHex: hex)
        case .globalUnlock(let enabled):
            receipt = FanNativeCallReceipt(key: "Ftst", command: 6, startedAt: startedAt, returnedAt: clock.now,
                kernelResult: 0, requestedValueBytes: 1, returnedStructBytes: 80, firmwareResult: 0,
                firmwareStatus: 0, returnedValueHex: "00", requestedValueHex: enabled ? "01" : "00")
        }
        if capturing, let adjusted = receiptOverride.map({ $0(receipt) }) ?? receipt { receipts.append(adjusted) }
        clock.now += wrapperDelay
        try onPerform?(operation)
        switch operation {
        case .target where !applyTargets: pendingTarget = operation
        case .mode(_, false) where deferRelease: pendingRelease = operation
        default: apply(operation)
        }
    }
    func apply(_ operation: FanOperation) {
        switch operation {
        case .mode(let fan, let manual): state.fans[fan].mode = manual ? 1 : 0
        case .target(let fan, let rpm):
            if rpm == 0, state.fans[fan].isAutomatic, let firmware = firmwareAutomaticTarget {
                state.fans[fan].targetRPM = firmware
            } else { state.fans[fan].targetRPM = rpm }
        case .globalUnlock(let enabled): state.globalUnlock = enabled ? 1 : 0
        }
    }
    private func issue(_ calls: Int) {
        guard capturing else { return }
        issuedCalls += calls; maximumIssuedCalls = max(maximumIssuedCalls, issuedCalls)
    }
    func beginCommandDiagnosticCapture() { captures += 1; capturing = true; receipts = []; issuedCalls = 0 }
    func endCommandDiagnosticCapture() -> [FanNativeCallReceipt] {
        captureEnds += 1; capturing = false
        defer { receipts = [] }
        return receipts
    }
    var commandDiagnosticCapacityRemaining: Int { capturing ? 256 - issuedCalls : Int.max }
    var commandDiagnosticWrite: FanNativeCallReceipt? { capturing ? receipts.last(where: { $0.command == 6 }) : nil }
}

final class FanTargetDiagnosticTests: XCTestCase {
    private let boot = UUID().uuidString, generation = UUID().uuidString
    private func timing(_ fans: TargetFans, pause: ((TimeInterval) -> Void)? = nil) -> FanModeDiagnosticTiming {
        FanModeDiagnosticTiming(clock: { fans.clock.now }, pause: pause ?? { fans.clock.now += $0 })
    }
    // Ownership and manual entry follow the unchanged bounded acknowledgement,
    // as the controller does before its first ordinary target write.
    private func manualOwner(_ fans: TargetFans, _ journal: FanRecoveryPersistence,
                             timing: FanModeDiagnosticTiming? = nil,
                             session: String = UUID().uuidString) throws -> FanActuator {
        let actuator = try FanActuator(hardware: fans, persistence: journal, bootID: boot,
            serviceGeneration: generation, artifactIdentity: "fake-target-artifact",
            modeDiagnosticTiming: timing ?? self.timing(fans))
        try actuator.establish(session: session, capabilities: fans.capabilities, baseline: fans.state)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false },
                                manualModeCommit: { try $0(fans.clock.now) })
        XCTAssertEqual(actuator.lastManualModeDiagnostic?.termination, "acknowledged")
        XCTAssertNil(actuator.lastTargetDiagnostic)
        fans.readStarts = []; fans.probeStarts = []
        return actuator
    }
    private func acknowledged(_ actuator: FanActuator, _ fans: TargetFans, _ journal: TargetJournal,
                              rpm: Double = 4000, conflict: @escaping () -> String? = { nil },
                              cancelled: () -> Bool = { false }) throws -> FanTargetDiagnostic {
        let saves = journal.saved.count
        let observed = try actuator.mutate(.target(fan: 0, rpm: rpm), cancelled: cancelled, acknowledgementConflict: conflict)
        let trace = try XCTUnwrap(actuator.lastTargetDiagnostic)
        XCTAssertEqual(trace.termination, "acknowledged")
        XCTAssertFalse(trace.evidenceOnly); XCTAssertFalse(trace.pendingRetained)
        XCTAssertEqual(trace.confirmationRule, "requestedTargetWithin2RPM")
        XCTAssertEqual(trace.acknowledgementMarkerRetired, true)
        let deadline = try XCTUnwrap(trace.deadline), at = try XCTUnwrap(trace.acknowledgedAt)
        XCTAssertLessThan(at, deadline)
        XCTAssertEqual(trace.endedAt, at, "An acknowledged trace ends at its publication.")
        XCTAssertFalse(trace.deadlineOverrun)
        XCTAssertGreaterThanOrEqual(at, try XCTUnwrap(trace.probes.last?.returnedAt))
        XCTAssertTrue(trace.probes.suffix(2).allSatisfy(\.operationConfirmed), "Two consecutive complete matches.")
        XCTAssertTrue(trace.probes.dropFirst().allSatisfy { $0.model != nil && $0.fanMetadata != nil })
        XCTAssertEqual(observed, trace.probes.last?.observation)
        XCTAssertEqual(actuator.record?.acknowledged, observed)
        XCTAssertNil(actuator.record?.pending); XCTAssertFalse(actuator.requiresExternalRecovery)
        XCTAssertEqual(try journal.load(), actuator.record, "Durable before publication; staged copy retired after it.")
        XCTAssertEqual(journal.saved.count, saves + 2, "One pending intent, then one durable acknowledgement.")
        XCTAssertFalse(fans.capturing); XCTAssertEqual(fans.captures, fans.captureEnds)
        XCTAssertNoThrow(try JSONEncoder().encode(trace))
        return trace
    }
    private func unconfirmed(_ actuator: FanActuator, _ fans: TargetFans, _ journal: TargetJournal, rpm: Double = 4000,
                             durablyStaged: Bool = false, conflict: @escaping () -> String? = { nil },
                             cancelled: () -> Bool = { false }) throws -> FanTargetDiagnostic {
        var primary: String?
        let saves = journal.saved.count
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: rpm), cancelled: cancelled,
            acknowledgementConflict: conflict)) { primary = $0.localizedDescription }
        let trace = try XCTUnwrap(actuator.lastTargetDiagnostic)
        XCTAssertEqual(primary, trace.primaryFailure)
        XCTAssertTrue(trace.evidenceOnly); XCTAssertTrue(trace.pendingRetained)
        XCTAssertNil(trace.acknowledgedAt); XCTAssertNil(trace.acknowledgementMarkerRetired)
        XCTAssertEqual(trace.operation, .target(fan: 0, rpm: rpm))
        XCTAssertEqual(journal.saved.count, saves + (durablyStaged ? 2 : 1),
                       "The pending intent, plus a staged acknowledgement only when its publication failed.")
        XCTAssertFalse(fans.capturing); XCTAssertEqual(fans.captures, fans.captureEnds)
        XCTAssertNoThrow(try JSONEncoder().encode(trace))
        return trace
    }
    // The durable pending intent stays authoritative and disarms every successor.
    private func held(_ actuator: FanActuator, _ journal: TargetJournal, _ fans: TargetFans, rpm: Double = 4000) {
        XCTAssertTrue(actuator.requiresExternalRecovery)
        XCTAssertEqual(actuator.record?.pending, .target(fan: 0, rpm: rpm))
        XCTAssertEqual(try journal.load()?.pending, .target(fan: 0, rpm: rpm))
        XCTAssertEqual(try journal.load()?.acknowledged.fans[0].mode, 1)
        XCTAssertNotEqual(try journal.load()?.acknowledged.fans[0].targetRPM, rpm)
        let reads = fans.readStarts.count
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: rpm), cancelled: { false }, acknowledgementConflict: { nil }))
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 1, rpm: 3000), cancelled: { false }, acknowledgementConflict: { nil }))
        XCTAssertThrowsError(try actuator.mutate(.globalUnlock(true), cancelled: { false }))
        XCTAssertThrowsError(try actuator.restore(conflict: { nil }))
        XCTAssertEqual(fans.readStarts.count, reads)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: rpm)])
    }

    func testTwoConsecutiveCompleteProbesAcknowledgeAfterAnImmediateMismatch() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        let manual = actuator.lastManualModeDiagnostic
        fans.targetVisibleAtRead = 3
        let trace = try acknowledged(actuator, fans, journal)
        XCTAssertEqual(trace.probes.count, 3); XCTAssertEqual(fans.probeStarts.count, 2)
        let immediate = trace.probes[0]
        XCTAssertEqual(immediate.index, 0)
        XCTAssertFalse(immediate.operationConfirmed); XCTAssertTrue(immediate.ownershipMatches)
        XCTAssertNil(immediate.model, "The immediate readback is not a complete probe.")
        XCTAssertEqual(trace.after, immediate.observation)
        XCTAssertEqual(trace.after?.fans[0].targetRPM, 0)
        XCTAssertEqual(trace.firstMismatchAt, immediate.returnedAt)
        XCTAssertTrue(trace.primaryFailure.contains("not confirmed by readback"), "The first mismatch is retained.")
        XCTAssertEqual(trace.probes.map(\.index), [0, 1, 2])
        XCTAssertNil(trace.holdPublishedAt)
        // Complete probes start at least 100 ms after the previous observation.
        let returns = trace.probes.compactMap(\.returnedAt), starts = trace.probes.compactMap(\.startedAt)
        for index in 1..<starts.count { XCTAssertGreaterThanOrEqual(starts[index] - returns[index - 1], 0.1 - 0.000_001) }
        XCTAssertEqual(trace.nativeWrite?.key, "F0Tg")
        XCTAssertEqual(try XCTUnwrap(trace.deadline), try XCTUnwrap(trace.nativeWrite?.returnedAt) + 1, accuracy: 0.000_001)
        XCTAssertEqual(actuator.lastManualModeDiagnostic, manual)
        XCTAssertEqual(journal.acknowledgements, 1); XCTAssertEqual(journal.retirements, 1)
        // The acknowledged write makes the next successor eligible.
        fans.applyTargets = true
        XCTAssertNoThrow(try actuator.mutate(.target(fan: 0, rpm: 4500), cancelled: { false }, acknowledgementConflict: { nil }))
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: 4000), .target(fan: 0, rpm: 4500)])
    }

    func testMatchingImmediateReadbackNeverCountsTowardTheTwoProbes() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        fans.applyTargets = true
        let trace = try acknowledged(actuator, fans, journal)
        XCTAssertTrue(trace.probes[0].operationConfirmed)
        XCTAssertNil(trace.firstMismatchAt); XCTAssertTrue(trace.primaryFailure.isEmpty)
        XCTAssertEqual(trace.probes.count, 3, "Two complete probes still follow a matching immediate readback.")
        XCTAssertEqual(fans.probeStarts.count, 2)
    }

    func testInterruptedOrSingleMatchesCannotAcknowledge() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        fans.targetVisibleAtRead = 3
        // The firmware shows the target, then the old one, then the target again.
        fans.onRead = { index in
            if index == 4 { fans.state.fans[0].targetRPM = 0 }
            if index == 5 { fans.state.fans[0].targetRPM = 4000 }
        }
        let flapping = try acknowledged(actuator, fans, journal)
        XCTAssertEqual(flapping.probes.map(\.operationConfirmed), [false, true, false, true, true])
        XCTAssertEqual(flapping.firstMismatchAt, flapping.probes[0].returnedAt)

        let single = TargetFans(), singleJournal = TargetJournal()
        let other = try manualOwner(single, singleJournal)
        single.targetVisibleAtRead = 3
        single.onRead = { if $0 >= 4 { single.state.fans[0].targetRPM = 0 } }
        let trace = try unconfirmed(other, single, singleJournal)
        XCTAssertEqual(trace.termination, "deadline")
        XCTAssertEqual(trace.probes.filter(\.operationConfirmed).count, 1)
        held(other, singleJournal, single)
    }

    func testCorrelatedReceiptAnchorsTheFixedDeadlineForEveryEncoding() throws {
        for encoding in ["flt ", "fpe2"] {
            for visible in [false, true] {
                let fans = TargetFans(), journal = TargetJournal()
                if encoding == "fpe2" {
                    fans.capabilities = FanCapabilities(model: "Mac14,9", sensors: FanPolicyTests.capabilities.sensors, fans: [
                        FanDescriptor(id: 0, minimumRPM: 1000, maximumRPM: 6000, modeKey: "F0md", targetEncoding: "fpe2"),
                        FanPolicyTests.capabilities.fans[1]], hasGlobalUnlock: true)
                }
                let actuator = try manualOwner(fans, journal)
                fans.performDuration = 0.002; fans.wrapperDelay = 0.3
                if visible { fans.targetVisibleAtRead = 3 }
                let trace = visible ? try acknowledged(actuator, fans, journal) : try unconfirmed(actuator, fans, journal)
                let write = try XCTUnwrap(trace.nativeWrite)
                XCTAssertEqual(write.key, "F0Tg"); XCTAssertEqual(write.command, 6)
                // 4000 RPM: IEEE-754 0x457A0000 little-endian, or 16000 big-endian fixed point.
                XCTAssertEqual(write.requestedValueHex, encoding == "flt " ? "00007a45" : "3e80")
                XCTAssertEqual(write.requestedValueBytes, encoding == "flt " ? 4 : 2)
                XCTAssertEqual(trace.nativeWriteReturnedAt, write.returnedAt)
                XCTAssertEqual(write.returnedAt - write.startedAt, 0.002, accuracy: 0.000_001)
                XCTAssertEqual(try XCTUnwrap(trace.deadline), write.returnedAt + 1, accuracy: 0.000_001)
                XCTAssertEqual(try XCTUnwrap(trace.performReturnedAt), write.returnedAt + 0.3, accuracy: 0.000_001)
                XCTAssertEqual(trace.nativeCalls.filter { $0.command == 6 }, [write])
                XCTAssertTrue(fans.probeStarts.allSatisfy { $0 < write.returnedAt + 1 })
                if visible {
                    XCTAssertLessThan(try XCTUnwrap(trace.acknowledgedAt), write.returnedAt + 1)
                } else {
                    XCTAssertEqual(trace.termination, "deadline")
                    XCTAssertEqual(try XCTUnwrap(trace.endedAt), write.returnedAt + 1, accuracy: 0.000_01)
                    held(actuator, journal, fans)
                }
            }
        }
    }

    func testMissingMismatchedOrFailedReceiptCannotAcknowledgeAVisibleTarget() throws {
        let variants: [(FanNativeCallReceipt) -> FanNativeCallReceipt?] = [
            { _ in nil }, { changed($0, key: "F1Tg") }, { changed($0, key: "F0md") }, { changed($0, command: 5) },
            { changed($0, requestedValueHex: "0000fa45") }, { changed($0, requestedValueBytes: 2) },
            { changed($0, kernelResult: KERN_FAILURE) }, { changed($0, returnedStructBytes: 79) },
            { changed($0, firmwareResult: 0x84) }, { changed($0, firmwareStatus: 127) },
            { changed($0, startedAt: $0.startedAt - 1) }, { changed($0, returnedAt: $0.returnedAt + 5) },
            { changed($0, startedAt: $0.returnedAt + 0.001) }
        ]
        for (index, variant) in variants.enumerated() {
            let fans = TargetFans(), journal = TargetJournal()
            let actuator = try manualOwner(fans, journal)
            fans.applyTargets = true
            fans.receiptOverride = { $0.command == 6 && $0.key.hasSuffix("Tg") ? variant($0) : $0 }
            let trace = try unconfirmed(actuator, fans, journal)
            XCTAssertEqual(trace.termination, "invalidNativeWriteReceipt", "variant \(index)")
            XCTAssertNil(trace.nativeWrite); XCTAssertNil(trace.nativeWriteReturnedAt); XCTAssertNil(trace.deadline)
            XCTAssertTrue(trace.probes[0].operationConfirmed, "Even a matching readback cannot replace the receipt.")
            XCTAssertEqual(trace.probes.count, 1); XCTAssertEqual(fans.readStarts.count, 2)
            XCTAssertTrue(fans.probeStarts.isEmpty)
            XCTAssertEqual(trace.nativeCalls.count, index == 0 ? 0 : 1, "Raw failed/mismatched receipts stay retained.")
            XCTAssertFalse(trace.deadlineOverrun)
            XCTAssertTrue(actuator.requiresExternalRecovery)
            XCTAssertEqual(try journal.load()?.pending, .target(fan: 0, rpm: 4000))
        }
    }

    func testTransportFailureRetainsReceiptWithoutReadbackOrProbe() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        fans.receiptOverride = { changed($0, kernelResult: KERN_FAILURE) }
        fans.onPerform = { if case .target = $0 { throw FanControlError.hardware("Fake AppleSMC IOKit request failed") } }
        let trace = try unconfirmed(actuator, fans, journal)
        XCTAssertEqual(trace.termination, "performFailure")
        XCTAssertEqual(trace.nativeCalls.map(\.kernelResult), [KERN_FAILURE])
        XCTAssertNil(trace.nativeWrite); XCTAssertNil(trace.after); XCTAssertTrue(trace.probes.isEmpty)
        XCTAssertEqual(fans.readStarts.count, 1)
        held(actuator, journal, fans)
    }

    func testImmediateReadbackFailureOrUnexpectedOwnershipEndsAtOnce() throws {
        for kind in 0..<2 {
            let fans = TargetFans(), journal = TargetJournal()
            let actuator = try manualOwner(fans, journal)
            fans.targetVisibleAtRead = 2
            fans.onRead = { index in
                guard index == 2 else { return }
                if kind == 0 { throw FanControlError.hardware("Fake immediate target readback failure") }
                fans.state.fans[1].mode = 1
            }
            let trace = try unconfirmed(actuator, fans, journal)
            XCTAssertEqual(trace.termination, kind == 0 ? "immediateReadFailure" : "unexpectedOwnership")
            XCTAssertEqual(trace.probes.count, 1); XCTAssertEqual(fans.readStarts.count, 2)
            XCTAssertTrue(fans.probeStarts.isEmpty)
            XCTAssertNotNil(trace.nativeWrite); XCTAssertNotNil(trace.deadline)
            if kind == 0 {
                XCTAssertEqual(trace.primaryFailure, "Fake immediate target readback failure")
                XCTAssertNil(trace.after); XCTAssertNil(trace.probes[0].observation)
                XCTAssertEqual(trace.probes[0].error, trace.primaryFailure)
            } else {
                XCTAssertFalse(trace.probes[0].ownershipMatches)
                XCTAssertEqual(trace.after?.fans[1].mode, 1)
            }
            XCTAssertTrue(actuator.requiresExternalRecovery)
        }
    }

    func testInvalidPartialStaleAndFutureObservationsCannotAcknowledge() throws {
        for kind in 0..<4 {
            for immediate in [false, true] {
                let fans = TargetFans(), journal = TargetJournal()
                let actuator = try manualOwner(fans, journal)
                fans.targetVisibleAtRead = 3
                let at = immediate ? 2 : 4
                fans.onRead = { index in
                    guard index == at else { return }
                    if kind == 0 { fans.state.fans[1].actualRPM = immediate ? 20_001 : .nan }
                    if kind == 1 { fans.state.fans.removeLast() }
                }
                fans.capturedAtOverride = { index in
                    guard index == at else { return nil }
                    return kind == 2 ? fans.clock.now - 0.5 : kind == 3 ? fans.clock.now + 0.5 : nil
                }
                let trace = try unconfirmed(actuator, fans, journal)
                XCTAssertEqual(trace.termination, immediate ? "invalidImmediateObservation" : "invalidObservation", "kind \(kind)")
                XCTAssertEqual(trace.probes.count, immediate ? 1 : 3)
                let rejected = try XCTUnwrap(trace.probes.last)
                XCTAssertNil(rejected.observation); XCTAssertNotNil(rejected.error)
                XCTAssertFalse(rejected.operationConfirmed); XCTAssertFalse(rejected.ownershipMatches)
                XCTAssertEqual(fans.readStarts.count, at)
                if !immediate { XCTAssertTrue(trace.probes[1].operationConfirmed, "One prior match is not enough.") }
                // The raw immediate readback stays retained when encodable.
                if immediate && kind == 0 { XCTAssertNotNil(trace.after) }
                if immediate && kind == 1 { XCTAssertEqual(trace.after?.fans.count, 1) }
                held(actuator, journal, fans)
            }
        }
    }

    func testNonFiniteImmediateReadbackIsDescribedButKeepsTheTraceEncodable() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        fans.onRead = { if $0 == 2 { fans.state.fans[1].actualRPM = .nan } }
        let trace = try unconfirmed(actuator, fans, journal)
        XCTAssertEqual(trace.termination, "invalidImmediateObservation")
        XCTAssertNil(trace.after)
        XCTAssertTrue(trace.probes[0].error?.contains("nan") == true)
        var status = FanStatus(serviceGeneration: generation); status.targetDiagnostic = trace
        XCTAssertNoThrow(try status.encodedReply())
        held(actuator, journal, fans)
    }

    func testChangedModelMetadataModeOrUnlockCannotAcknowledge() throws {
        for change in 0..<5 {
            let fans = TargetFans(), journal = TargetJournal()
            let actuator = try manualOwner(fans, journal)
            fans.targetVisibleAtRead = 3
            if change == 0 { fans.probeModel = "Mac14,10" }
            if change == 1 {
                fans.probeMetadata = [fans.capabilities.fans[0],
                    FanDescriptor(id: 1, minimumRPM: 1500, maximumRPM: 5400, modeKey: "F1md", targetEncoding: "flt ")]
            }
            fans.onRead = { index in
                guard index == 3 else { return }
                if change == 2 { fans.state.fans[0].mode = 0 }
                if change == 3 { fans.state.fans[1].mode = 1 }
                if change == 4 { fans.state.globalUnlock = 1 }
            }
            let trace = try unconfirmed(actuator, fans, journal)
            XCTAssertEqual(trace.termination, change < 2 ? "invalidObservation" : "unexpectedOwnership", "change \(change)")
            XCTAssertEqual(trace.probes.count, 2); XCTAssertEqual(fans.readStarts.count, 3)
            let changed = trace.probes[1]
            XCTAssertFalse(changed.ownershipMatches)
            if change < 2 {
                XCTAssertNil(changed.observation)
                XCTAssertEqual(changed.model, fans.probeModel ?? fans.capabilities.model)
                XCTAssertEqual(changed.fanMetadata, fans.probeMetadata ?? fans.capabilities.fans)
            } else {
                XCTAssertNotNil(changed.observation)
                XCTAssertEqual(changed.observation?.fans[0].targetRPM, 4000)
            }
            held(actuator, journal, fans)
        }
    }

    // Stop, profile revision, sleep, removal, session end and lease/telemetry
    // expiry block further writes, but not confirmation of the returned write.
    func testLifecycleRevocationBlocksSuccessorsButNotConfirmation() throws {
        for change in 0..<7 {
            let gate = FanSafetyGate()
            // Change 5: with no frame since a begin at 96.25, the four-second
            // complete-frame window ends at 100.25. Change 6: the lease ends at 100.2.
            let session = try gate.begin(owner: "owner", now: change == 6 ? 95.2 : (change == 5 ? 96.25 : 100))
            if change == 6 { gate.fresh(at: 98, now: 98) } else if change != 5 { gate.fresh(at: 100, now: 100) }
            let token = gate.check(now: 100).generation
            let fans = TargetFans(), journal = TargetJournal()
            let actuator = try manualOwner(fans, journal, session: session)
            fans.targetVisibleAtRead = 3
            var revokedAt: TimeInterval?
            fans.onRead = { index in
                guard index == 3, revokedAt == nil else { return }
                revokedAt = fans.clock.now
                switch change {
                case 0: gate.stop(owner: "owner", reason: "Owner stopped during confirmation")
                case 1: XCTAssertTrue(gate.revise(owner: "owner", session: session, now: fans.clock.now))
                case 2: gate.suspendForSleep()
                case 3: XCTAssertTrue(gate.prepareRemoval(owner: "owner"))
                case 4: gate.finish()
                default: break // telemetry (100.25) or lease (100.2) expires between probes
                }
            }
            let permitted: () -> Bool = { gate.permits(token, now: fans.clock.now) }
            let trace = try acknowledged(actuator, fans, journal, cancelled: { !permitted() })
            XCTAssertEqual(trace.probes.count, 3, "change \(change)")
            XCTAssertFalse(permitted(), "change \(change): the write window itself was revoked")
            let reads = fans.readStarts.count
            XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4500), cancelled: { !permitted() },
                                                     acknowledgementConflict: { nil })) {
                XCTAssertEqual($0 as? FanControlError, .cancelled)
            }
            XCTAssertEqual(fans.readStarts.count, reads)
            XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: 4000)])
            XCTAssertNil(try journal.load()?.pending)
        }
    }

    func testCompetingUtilityAtAProbeBoundaryOrPublicationKeepsTheHold() throws {
        for stage in 0..<3 {
            let fans = TargetFans(), journal = TargetJournal()
            let actuator = try manualOwner(fans, journal)
            fans.targetVisibleAtRead = 3
            var utility: String?
            if stage < 2 { fans.onRead = { if $0 == (stage == 0 ? 2 : 3) { utility = "Macs Fan Control" } } }
            else { journal.onBoundedAcknowledgement = { utility = "Macs Fan Control" } }
            let trace = try unconfirmed(actuator, fans, journal, durablyStaged: stage == 2, conflict: { utility })
            XCTAssertEqual(trace.termination, "conflictingUtility", "stage \(stage)")
            XCTAssertEqual(trace.cancellationCause, "Macs Fan Control appeared.")
            XCTAssertEqual(trace.probes.count, [1, 2, 3][stage])
            XCTAssertEqual(fans.readStarts.count, [2, 3, 4][stage])
            if stage == 2 {
                XCTAssertTrue(trace.probes.suffix(2).allSatisfy(\.operationConfirmed))
                XCTAssertNotNil(trace.acknowledgementError)
                XCTAssertEqual(journal.acknowledgements, 1, "Durable before the failed publication.")
                XCTAssertEqual(journal.retirements, 0)
            }
            held(actuator, journal, fans)
        }
    }

    func testCompetingUtilityIsCheckedAtProbeBoundariesNotEveryNativeCall() throws {
        let fans = TargetFans(), journal = TargetJournal()
        fans.callsPerRead = 22; fans.callsPerProbe = 48; fans.callsPerWrite = 7
        let actuator = try manualOwner(fans, journal)
        fans.targetVisibleAtRead = 3
        var checks = 0
        let trace = try acknowledged(actuator, fans, journal, conflict: { checks += 1; return nil })
        XCTAssertEqual(trace.probes.count, 3)
        // Before and after each of the two probes, and once at publication.
        XCTAssertEqual(checks, 5)
        XCTAssertLessThanOrEqual(fans.maximumIssuedCalls, 51 + 2 * 48)
    }

    func testNeverVisibleTargetStopsAtTheFixedDeadlineWithoutLateProbeStart() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        let trace = try unconfirmed(actuator, fans, journal)
        XCTAssertNil(trace.cancellationCause)
        let deadline = try XCTUnwrap(trace.deadline)
        XCTAssertEqual(trace.termination, "deadline")
        XCTAssertTrue(fans.readStarts.allSatisfy { $0 < deadline })
        XCTAssertLessThanOrEqual(trace.probes.count, 11)
        XCTAssertFalse(trace.probes.contains(where: \.operationConfirmed))
        XCTAssertEqual(try XCTUnwrap(trace.endedAt), deadline, accuracy: 0.000_01)
        XCTAssertFalse(trace.deadlineOverrun)
        held(actuator, journal, fans)
    }

    func testLateOrDeadlineProbeReturnCannotSupplyTheSecondMatch() throws {
        for exact in [false, true] {
            let fans = TargetFans(), journal = TargetJournal()
            let actuator = try manualOwner(fans, journal)
            fans.targetVisibleAtRead = 3
            var deadline = 0.0
            fans.onPerform = { _ in deadline = fans.clock.now + 1 }
            fans.onRead = { if $0 == 4 { fans.clock.now = exact ? deadline : deadline + 1 } }
            let trace = try unconfirmed(actuator, fans, journal)
            XCTAssertEqual(trace.termination, "deadline")
            XCTAssertEqual(trace.deadlineOverrun, !exact)
            XCTAssertEqual(trace.probes.count, 3); XCTAssertEqual(fans.readStarts.count, 4)
            let late = try XCTUnwrap(trace.probes.last)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(late.returnedAt), try XCTUnwrap(trace.deadline))
            XCTAssertNotNil(late.observation); XCTAssertTrue(late.operationConfirmed)
            XCTAssertTrue(trace.probes[1].operationConfirmed)
            held(actuator, journal, fans)
        }
    }

    func testSlowImmediateReadbackPastTheDeadlineAdmitsNoProbe() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        fans.applyTargets = true
        fans.onRead = { if $0 == 2 { fans.clock.now += 1.2 } }
        let trace = try unconfirmed(actuator, fans, journal)
        XCTAssertEqual(trace.termination, "deadline"); XCTAssertTrue(trace.deadlineOverrun)
        XCTAssertEqual(trace.probes.count, 1); XCTAssertTrue(fans.probeStarts.isEmpty)
        held(actuator, journal, fans)
    }

    func testTenAdditionalProbesAreTheMaximum() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal, timing: timing(fans) { _ in fans.clock.now += 0.001 })
        let trace = try unconfirmed(actuator, fans, journal)
        XCTAssertEqual(trace.termination, "probeLimit")
        XCTAssertEqual(trace.probes.count, 11); XCTAssertEqual(fans.probeStarts.count, 10)
        XCTAssertEqual(fans.readStarts.count, 12)
        XCTAssertLessThan(try XCTUnwrap(trace.endedAt), try XCTUnwrap(trace.deadline))
        held(actuator, journal, fans)
    }

    func testNativeReceiptCapacityPreventsAnUnretainableProbe() throws {
        let fans = TargetFans(), journal = TargetJournal()
        fans.callsPerRead = 22; fans.callsPerProbe = 48; fans.callsPerWrite = 7
        let actuator = try manualOwner(fans, journal)
        // Matches only alternate, so no two consecutive probes ever confirm.
        fans.targetVisibleAtRead = 3
        fans.onRead = { index in if index >= 3 { fans.state.fans[0].targetRPM = index % 2 == 1 ? 4000 : 0 } }
        let trace = try unconfirmed(actuator, fans, journal)
        XCTAssertEqual(trace.termination, "nativeTraceCapacity")
        // 22 + 7 + 22 calls precede the probes; four 48-call probes then fit.
        XCTAssertEqual(trace.probes.count, 5); XCTAssertEqual(fans.probeStarts.count, 4)
        XCTAssertLessThanOrEqual(fans.maximumIssuedCalls, 256)
        held(actuator, journal, fans)
    }

    func testFrozenBackwardAndNonfiniteClocksTerminateWithoutLooping() throws {
        for kind in 0...2 {
            let fans = TargetFans(), journal = TargetJournal()
            var armed = false
            let config = timing(fans) { interval in
                guard armed else { fans.clock.now += interval; return }
                if kind == 1 { fans.clock.now -= 1 }
                if kind == 2 { fans.clock.now = .nan }
            }
            let actuator = try manualOwner(fans, journal, timing: config)
            armed = true
            fans.applyTargets = true
            let trace = try unconfirmed(actuator, fans, journal)
            XCTAssertEqual(trace.termination, kind == 0 ? "clockDidNotAdvance" : "invalidOrBackwardClock")
            XCTAssertEqual(fans.readStarts.count, 2)
            held(actuator, journal, fans)
        }
    }

    func testFailedOrLateDurableAcknowledgementKeepsPending() throws {
        for late in [false, true] {
            let fans = TargetFans(), journal = TargetJournal()
            let actuator = try manualOwner(fans, journal)
            fans.targetVisibleAtRead = 3
            journal.onBoundedAcknowledgement = {
                if late { fans.clock.now += 1 } else { throw FanControlError.ownership("Fake durable acknowledgement failure") }
            }
            let trace = try unconfirmed(actuator, fans, journal)
            XCTAssertEqual(trace.termination, late ? "deadline" : "acknowledgementPersistenceFailure")
            XCTAssertNotNil(trace.acknowledgementError)
            XCTAssertTrue(trace.probes.suffix(2).allSatisfy(\.operationConfirmed))
            XCTAssertEqual(journal.acknowledgements, 0)
            held(actuator, journal, fans)
        }
    }

    func testLateDurableSaveOrPublicationAfterStagingKeepsPending() throws {
        for stage in 0..<2 {
            let fans = TargetFans(), journal = TargetJournal()
            let actuator = try manualOwner(fans, journal)
            fans.targetVisibleAtRead = 3
            var deadline = 0.0, checks = 0
            fans.onPerform = { _ in deadline = fans.clock.now + 1 }
            // Stage 0: the store's final check after the durable save is late.
            // Stage 1: the clock passes the deadline during the publication's
            // competing-utility check (the fifth: before/after both probes).
            if stage == 0 { journal.afterBoundedSave = { fans.clock.now = deadline } }
            let trace = try unconfirmed(actuator, fans, journal, durablyStaged: true, conflict: {
                checks += 1
                if stage == 1 && checks == 5 { fans.clock.now = deadline }
                return nil
            })
            XCTAssertEqual(trace.termination, "deadline", "stage \(stage)")
            XCTAssertNotNil(trace.acknowledgementError)
            XCTAssertTrue(trace.probes.suffix(2).allSatisfy(\.operationConfirmed))
            XCTAssertEqual(journal.retirements, 0)
            held(actuator, journal, fans)
        }
    }

    func testZeroTargetOnAManualFanWithZeroMinimumMustReadBackAsWritten() throws {
        let fans = TargetFans(), journal = TargetJournal()
        fans.capabilities = FanCapabilities(model: "Mac14,9", sensors: FanPolicyTests.capabilities.sensors, fans: [
            FanDescriptor(id: 0, minimumRPM: 0, maximumRPM: 6000, modeKey: "F0md", targetEncoding: "flt "),
            FanPolicyTests.capabilities.fans[1]], hasGlobalUnlock: true)
        fans.state.fans[0].targetRPM = 1500
        let actuator = try manualOwner(fans, journal)
        fans.applyTargets = true; fans.firmwareAutomaticTarget = 2317
        // An ordinary zero target on a manual fan is not a release reset.
        let trace = try acknowledged(actuator, fans, journal, rpm: 0)
        XCTAssertTrue(trace.probes.allSatisfy { $0.observation?.fans[0].mode == 1 && $0.observation?.fans[0].targetRPM == 0 })
        XCTAssertEqual(actuator.record?.acknowledged.fans[0].targetRPM, 0)
        XCTAssertEqual(actuator.record?.acknowledged.fans[0].mode, 1)
    }

    func testSlowPendingCopyRetirementAfterPublicationDoesNotMoveTheTraceEnd() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        fans.targetVisibleAtRead = 3
        // Retirement runs after publication; a stalled unlink must not make an
        // acknowledged trace look as if it ended after its deadline.
        journal.onRetire = { fans.clock.now += 0.9 }
        let trace = try acknowledged(actuator, fans, journal)
        XCTAssertGreaterThan(fans.clock.now, try XCTUnwrap(trace.deadline))
    }

    func testFailedPendingCopyRetirementKeepsTheLiveAcknowledgementAndAConservativeRestart() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        fans.targetVisibleAtRead = 3
        journal.failRetirement = true
        _ = try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil })
        let trace = try XCTUnwrap(actuator.lastTargetDiagnostic)
        XCTAssertEqual(trace.termination, "acknowledged")
        XCTAssertEqual(trace.acknowledgementMarkerRetired, false)
        XCTAssertEqual(trace.acknowledgementMarkerError, "Fake pending-copy retirement failed")
        XCTAssertNil(actuator.record?.pending); XCTAssertFalse(actuator.requiresExternalRecovery)
        // A restart before the next durable intent conservatively holds.
        XCTAssertEqual(try journal.load()?.pending, .target(fan: 0, rpm: 4000))
        journal.failRetirement = false
        fans.applyTargets = true
        XCTAssertNoThrow(try actuator.mutate(.target(fan: 0, rpm: 4500), cancelled: { false }, acknowledgementConflict: { nil }))
        XCTAssertNil(try journal.load()?.pending, "The newer durable intent superseded the retained copy.")
    }

    func testBoundedWriteWithoutConflictCheckFailsClosedBeforeAnyRead() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        let captures = fans.captures, saves = journal.saved.count
        for operation in [FanOperation.target(fan: 0, rpm: 4000), .target(fan: 1, rpm: 0), .mode(fan: 0, manual: false)] {
            XCTAssertThrowsError(try actuator.mutate(operation, cancelled: { false })) {
                XCTAssertTrue($0.localizedDescription.contains("competing-utility check"))
            }
        }
        XCTAssertEqual(fans.captures, captures); XCTAssertEqual(journal.saved.count, saves)
        XCTAssertTrue(fans.readStarts.isEmpty)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])
        XCTAssertNil(actuator.record?.pending)
    }

    func testWithoutTimingEveryOperationKeepsTheImmediateReadback() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try FanActuator(hardware: fans, persistence: journal, bootID: boot,
            serviceGeneration: generation, artifactIdentity: "fake-target-artifact")
        XCTAssertFalse(actuator.boundedAcknowledgement)
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }))
        XCTAssertNil(actuator.lastTargetDiagnostic); XCTAssertEqual(fans.captures, 0)
        XCTAssertEqual(fans.readStarts.count, 2)
        XCTAssertEqual(try journal.load()?.pending, .target(fan: 0, rpm: 4000))
    }

    func testGlobalUnlockKeepsItsImmediateReadbackWithTiming() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        let captures = fans.captures
        XCTAssertNoThrow(try actuator.mutate(.globalUnlock(true), cancelled: { false }))
        XCTAssertEqual(fans.captures, captures); XCTAssertEqual(fans.readStarts.count, 2)
        XCTAssertNil(actuator.lastTargetDiagnostic); XCTAssertNil(actuator.record?.pending)
    }

    func testTargetPayloadMatchesTheTransportEncoder() throws {
        for rpm in [0.0, 1000, 2317, 2666.666666, 3445.4472896575926, 4000, 5228.409603691101, 6800] {
            XCTAssertEqual(FanActuator.targetPayloadHex(rpm, encoding: "flt "), try payloadHex(rpm))
            XCTAssertEqual(FanActuator.targetPayloadHex(rpm, encoding: "fpe2"), try payloadHex(rpm, encoding: "fpe2"))
        }
        // The latest native trial's correlated F0Tg payload.
        XCTAssertEqual(FanActuator.targetPayloadHex(3445.4472896575926, encoding: "flt "), "28575745")
        XCTAssertEqual(FanActuator.targetPayloadHex(0, encoding: "flt "), "00000000")
        XCTAssertEqual(FanActuator.targetPayloadHex(0, encoding: "fpe2"), "0000")
        for rpm in [-1, .nan, .infinity, 20_001] { XCTAssertNil(FanActuator.targetPayloadHex(rpm, encoding: "flt ")) }
        XCTAssertNil(FanActuator.targetPayloadHex(16_384, encoding: "fpe2"))
        XCTAssertNil(FanActuator.targetPayloadHex(4000, encoding: "ui8 "))
    }

    func testBothStructuredTracesSurviveReplyBoundingAndOlderTracesDecode() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try manualOwner(fans, journal)
        fans.targetVisibleAtRead = 3
        var target = try acknowledged(actuator, fans, journal)
        var manual = try XCTUnwrap(actuator.lastManualModeDiagnostic)
        func calls(_ key: String) -> [FanNativeCallReceipt] {
            (0..<256).map { index in
                FanNativeCallReceipt(key: key, command: 5, startedAt: 100 + Double(index) / 1000,
                    returnedAt: 100.0001 + Double(index) / 1000, kernelResult: 0, requestedValueBytes: 32,
                    returnedStructBytes: 80, firmwareResult: 0, firmwareStatus: 255,
                    returnedValueHex: String(repeating: "ff", count: 32), requestedValueHex: String(repeating: "01", count: 32))
            }
        }
        manual.nativeCalls = calls("F9Ac"); target.nativeCalls = calls("F9Tg")
        target.acknowledgementMarkerError = String(repeating: "Cannot retire ", count: 20)
        var probe = try XCTUnwrap(target.probes.last)
        let fourFans = (0..<4).map { FanDescriptor(id: $0, minimumRPM: 2317, maximumRPM: 6800,
                                                   modeKey: "F\($0)Md", targetEncoding: "flt ") }
        probe = FanDiagnosticProbe(index: probe.index, startedAt: probe.startedAt, returnedAt: probe.returnedAt,
            observation: FanControlObservation(capturedAt: 100.123456789, fans: (0..<4).map {
                FanReading(id: $0, actualRPM: 5236.74462890625, targetRPM: 5228.40966796875, mode: 1) }, globalUnlock: 1),
            error: String(repeating: "Invalid native diagnostic observation ", count: 8),
            operationConfirmed: true, ownershipMatches: true, model: "Mac14,9", fanMetadata: fourFans)
        while manual.probes.count < 11 { manual.probes.append(probe) }
        while target.probes.count < 11 { target.probes.append(probe) }
        var status = FanStatus(serviceGeneration: generation)
        status.manualModeDiagnostic = manual; status.targetDiagnostic = target
        status.mode = .externalRecoveryRequired; status.reason = FanActuator.externalRecoveryReason
        status.externalRecoveryRequired = true; status.externalRecoveryID = journal.record?.ownerSession
        status.ownsOverride = true
        status.diagnostics = (0..<200).map { "line-\($0):" + String(repeating: "\"\\\n風🔥", count: 700) }
        XCTAssertGreaterThan(try JSONEncoder().encode(status).count, FanStatus.maximumReplyBytes)
        let data = try status.encodedReply()
        XCTAssertLessThanOrEqual(data.count, FanStatus.maximumReplyBytes)
        let decoded = try JSONDecoder().decode(FanStatus.self, from: data)
        XCTAssertEqual(decoded.manualModeDiagnostic, manual)
        XCTAssertEqual(decoded.targetDiagnostic, target)
        XCTAssertEqual(decoded.mode, .externalRecoveryRequired)
        XCTAssertTrue(decoded.externalRecoveryRequired); XCTAssertTrue(decoded.ownsOverride)
        XCTAssertGreaterThan(try XCTUnwrap(decoded.diagnosticsOmittedCount), 0)
        XCTAssertEqual(decoded.diagnostics, Array(status.diagnostics.suffix(decoded.diagnostics.count)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // An evidence-only trace from the earlier design lacks every new field.
        var older = try XCTUnwrap(object["targetDiagnostic"] as? [String: Any])
        for key in ["confirmationRule", "acknowledgedAt", "acknowledgementError", "acknowledgementMarkerRetired",
                    "acknowledgementMarkerError"] { older.removeValue(forKey: key) }
        older["holdPublishedAt"] = 100.5; older["evidenceOnly"] = true; older["pendingRetained"] = true
        let olderTrace = try JSONDecoder().decode(FanTargetDiagnostic.self, from: JSONSerialization.data(withJSONObject: older))
        XCTAssertNil(olderTrace.confirmationRule); XCTAssertNil(olderTrace.acknowledgedAt)
        XCTAssertEqual(olderTrace.holdPublishedAt, 100.5); XCTAssertTrue(olderTrace.evidenceOnly)
        object.removeValue(forKey: "targetDiagnostic")
        let olderStatus = try JSONDecoder().decode(FanStatus.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(olderStatus.targetDiagnostic); XCTAssertEqual(olderStatus.manualModeDiagnostic, manual)
    }

    // Mac14,9-shaped receipts fit four complete probes. With no match pending
    // and only two left, the final pair starts late, so a target first visible
    // at +0.65 s is still acknowledged with time to save it before +1 s.
    func testFinalPairStartsLateWhenOnlyTwoProbesRemainAndNoMatchIsPending() throws {
        let fans = TargetFans(), journal = TargetJournal()
        fans.callsPerRead = 22; fans.callsPerProbe = 48; fans.callsPerWrite = 7
        let actuator = try manualOwner(fans, journal)
        var returned = 0.0
        fans.onPerform = { _ in returned = fans.clock.now }
        fans.onRead = { _ in
            if fans.clock.now >= returned + 0.65, let pending = fans.pendingTarget { fans.apply(pending); fans.pendingTarget = nil }
        }
        let trace = try acknowledged(actuator, fans, journal)
        let starts = trace.probes.dropFirst().compactMap(\.startedAt).map { $0 - returned }
        XCTAssertEqual(starts.count, 4)
        for (start, expected) in zip(starts, [0.1, 0.2, 0.7, 0.8]) { XCTAssertEqual(start, expected, accuracy: 0.000_001) }
        XCTAssertEqual(trace.probes.map(\.operationConfirmed), [false, false, false, true, true])
        XCTAssertLessThanOrEqual(try XCTUnwrap(trace.acknowledgedAt),
                                 try XCTUnwrap(trace.deadline) - FanActuator.finalPairSaveMargin + 0.000_001)
        XCTAssertLessThanOrEqual(fans.maximumIssuedCalls, 256)
    }

    // Slower probes move the final pair earlier: the lead covers two probe
    // durations (including their boundary checks), the spacing and the margin.
    func testFinalPairLeadGrowsWithTheMeasuredProbeDuration() throws {
        let fans = TargetFans(), journal = TargetJournal()
        fans.callsPerRead = 22; fans.callsPerProbe = 48; fans.callsPerWrite = 7
        let actuator = try manualOwner(fans, journal)
        var returned = 0.0
        fans.onPerform = { _ in returned = fans.clock.now }
        // Each complete probe takes 0.1 s; the target shows from +0.5 s.
        fans.onRead = { index in
            guard index >= 3 else { return }
            if fans.clock.now >= returned + 0.5, let pending = fans.pendingTarget { fans.apply(pending); fans.pendingTarget = nil }
            fans.clock.now += 0.1
        }
        let trace = try acknowledged(actuator, fans, journal)
        let starts = trace.probes.dropFirst().compactMap(\.startedAt).map { $0 - returned }
        XCTAssertEqual(starts.count, 4)
        for (start, expected) in zip(starts, [0.1, 0.3, 0.55, 0.75]) { XCTAssertEqual(start, expected, accuracy: 0.000_001) }
        XCTAssertEqual(trace.probes.map(\.operationConfirmed), [false, false, false, true, true])
        XCTAssertLessThanOrEqual(try XCTUnwrap(trace.acknowledgedAt),
                                 try XCTUnwrap(trace.deadline) - FanActuator.finalPairSaveMargin + 0.000_001)
    }

    // Mac14,9's native shape: 51 receipts precede the first complete probe and
    // each probe uses 43 of its 48 reserved, so four fit and the final pair
    // starts late after the second.
    func testMac149ReceiptShapeStartsTheFinalPairAfterTheSecondProbe() throws {
        let fans = TargetFans(), journal = TargetJournal()
        fans.callsPerRead = 22; fans.callsPerProbe = 43; fans.callsPerWrite = 7
        let actuator = try manualOwner(fans, journal)
        var returned = 0.0
        fans.onPerform = { _ in returned = fans.clock.now }
        fans.onRead = { _ in
            if fans.clock.now >= returned + 0.65, let pending = fans.pendingTarget { fans.apply(pending); fans.pendingTarget = nil }
        }
        let trace = try acknowledged(actuator, fans, journal)
        let starts = trace.probes.dropFirst().compactMap(\.startedAt).map { $0 - returned }
        for (start, expected) in zip(starts, [0.1, 0.2, 0.7, 0.8]) { XCTAssertEqual(start, expected, accuracy: 0.000_001) }
        XCTAssertEqual(starts.count, 4)
        XCTAssertEqual(fans.maximumIssuedCalls, 51 + 4 * 43)
    }

    func testFinalPairKeepsTheFastScheduleWhileAMatchIsPending() throws {
        let fans = TargetFans(), journal = TargetJournal()
        fans.callsPerRead = 22; fans.callsPerProbe = 48; fans.callsPerWrite = 7
        let actuator = try manualOwner(fans, journal)
        // Reads: before 1, immediate 2, complete probes from 3; visible from 4.
        fans.targetVisibleAtRead = 4
        var returned = 0.0
        fans.onPerform = { _ in returned = fans.clock.now }
        let trace = try acknowledged(actuator, fans, journal)
        let starts = trace.probes.dropFirst().compactMap(\.startedAt).map { $0 - returned }
        XCTAssertEqual(trace.probes.map(\.operationConfirmed), [false, false, true, true])
        for (start, expected) in zip(starts, [0.1, 0.2, 0.3]) { XCTAssertEqual(start, expected, accuracy: 0.000_001) }
        XCTAssertEqual(starts.count, 3)
    }
}

final class FanReleaseAcknowledgementTests: XCTestCase {
    private let boot = UUID().uuidString, generation = UUID().uuidString
    // Fan 0 manual at an acknowledged 4000 RPM target, fan 1 still automatic.
    private func owner(_ fans: TargetFans, _ journal: TargetJournal) throws -> FanActuator {
        let actuator = try FanActuator(hardware: fans, persistence: journal, bootID: boot,
            serviceGeneration: generation, artifactIdentity: "fake-release-artifact",
            modeDiagnosticTiming: FanModeDiagnosticTiming(clock: { fans.clock.now }, pause: { fans.clock.now += $0 }))
        try actuator.establish(session: UUID().uuidString, capabilities: fans.capabilities, baseline: fans.state)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
        fans.applyTargets = true
        _ = try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil })
        fans.firmwareAutomaticTarget = 2317
        fans.readStarts = []; fans.probeStarts = []
        return actuator
    }

    func testModeReleaseIsAcknowledgedOnlyAfterTwoAutomaticCompleteProbes() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try owner(fans, journal)
        // Reads: before 1, immediate 2, complete probes from 3; the firmware
        // shows automatic mode from read 4.
        fans.deferRelease = true; fans.releaseVisibleAtRead = 4
        let observed = try actuator.mutate(.mode(fan: 0, manual: false), cancelled: { false }, acknowledgementConflict: { nil })
        XCTAssertTrue(observed.fans[0].isAutomatic)
        let trace = try XCTUnwrap(actuator.lastTargetDiagnostic)
        XCTAssertEqual(trace.operation, .mode(fan: 0, manual: false))
        XCTAssertEqual(trace.termination, "acknowledged"); XCTAssertEqual(trace.confirmationRule, "fanAutomatic")
        XCTAssertEqual(trace.probes.map(\.operationConfirmed), [false, false, true, true])
        XCTAssertEqual(trace.nativeWrite?.key, "F0md"); XCTAssertEqual(trace.nativeWrite?.requestedValueHex, "00")
        XCTAssertEqual(trace.nativeWrite?.requestedValueBytes, 1)
        XCTAssertEqual(try XCTUnwrap(trace.deadline), try XCTUnwrap(trace.nativeWrite?.returnedAt) + 1, accuracy: 0.000_001)
        XCTAssertNil(actuator.record?.pending); XCTAssertEqual(try journal.load(), actuator.record)
    }

    func testRestoreAcknowledgesEachReleaseWriteBeforeIssuingTheNext() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try owner(fans, journal)
        var events: [String] = []
        fans.onPerform = { events.append("write \($0)") }
        journal.onAcknowledged = { events.append("acknowledged \($0)") }
        let restored = try XCTUnwrap(actuator.restore(conflict: { nil }))
        XCTAssertTrue(restored.isFullyAutomatic)
        XCTAssertNil(actuator.record); XCTAssertNil(try journal.load())
        let release: [FanOperation] = [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .target(fan: 1, rpm: 0)]
        XCTAssertEqual(events, release.flatMap { ["write \($0)", "acknowledged \($0)"] })
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: 4000)] + release)
        let zero = try XCTUnwrap(actuator.lastTargetDiagnostic)
        XCTAssertEqual(zero.operation, .target(fan: 1, rpm: 0))
        XCTAssertEqual(zero.termination, "acknowledged"); XCTAssertEqual(zero.confirmationRule, "fanAutomatic")
        XCTAssertEqual(zero.nativeWrite?.requestedValueHex, "00000000")
        // Automatic firmware reports its own target; the trace keeps it.
        XCTAssertTrue(zero.probes.dropFirst().allSatisfy { $0.operationConfirmed && $0.observation?.fans[1].targetRPM == 2317 })
        XCTAssertEqual(journal.acknowledgements, 4); XCTAssertEqual(journal.retirements, 4)
    }

    // A mode release first visible at +0.65 s is acknowledged by the late
    // final pair instead of exhausting four front-loaded probes.
    func testDelayedModeReleaseIsAcknowledgedByTheLateFinalPair() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try owner(fans, journal)
        fans.callsPerRead = 22; fans.callsPerProbe = 48; fans.callsPerWrite = 7
        fans.deferRelease = true
        var releasedAt: TimeInterval?
        fans.onPerform = { operation in if operation == .mode(fan: 0, manual: false) { releasedAt = fans.clock.now } }
        fans.onRead = { _ in
            if let at = releasedAt, fans.clock.now >= at + 0.65, let pending = fans.pendingRelease {
                fans.apply(pending); fans.pendingRelease = nil
            }
        }
        let restored = try XCTUnwrap(actuator.restore(conflict: { nil }))
        XCTAssertTrue(restored.isFullyAutomatic)
        XCTAssertNil(actuator.record); XCTAssertNil(try journal.load())
        let at = try XCTUnwrap(releasedAt)
        let starts = fans.probeStarts.filter { $0 > at }.prefix(4).map { $0 - at }
        XCTAssertEqual(starts.count, 4)
        for (start, expected) in zip(starts, [0.1, 0.2, 0.7, 0.8]) { XCTAssertEqual(start, expected, accuracy: 0.000_001) }
        XCTAssertEqual(Array(fans.operations.suffix(3)), [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .target(fan: 1, rpm: 0)])
    }

    func testAFailureBeforeAnyNewTraceKeepsTheMostRecentTrace() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try owner(fans, journal)
        _ = try actuator.mutate(.mode(fan: 0, manual: false), cancelled: { false }, acknowledgementConflict: { nil })
        let release = try XCTUnwrap(actuator.lastTargetDiagnostic)
        XCTAssertEqual(release.operation, .mode(fan: 0, manual: false)); XCTAssertEqual(release.termination, "acknowledged")
        // The next release write fails at its before-read: no new trace exists.
        let reads = fans.readStarts.count
        fans.onRead = { if $0 == reads + 1 { throw FanControlError.hardware("Fake before-read failure") } }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 0), cancelled: { false }, acknowledgementConflict: { nil }))
        XCTAssertEqual(actuator.lastTargetDiagnostic, release)
        XCTAssertNil(actuator.record?.pending, "Nothing was written or made pending.")
    }

    func testUnconfirmedModeReleaseKeepsTheHoldWithoutAZeroTarget() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try owner(fans, journal)
        fans.deferRelease = true
        XCTAssertThrowsError(try actuator.restore(conflict: { nil }))
        let trace = try XCTUnwrap(actuator.lastTargetDiagnostic)
        XCTAssertEqual(trace.operation, .mode(fan: 0, manual: false))
        XCTAssertEqual(trace.termination, "deadline"); XCTAssertTrue(trace.evidenceOnly)
        XCTAssertTrue(actuator.requiresExternalRecovery)
        XCTAssertEqual(try journal.load()?.pending, .mode(fan: 0, manual: false))
        XCTAssertEqual(try journal.load()?.restorationStarted, true)
        XCTAssertEqual(fans.operations.last, .mode(fan: 0, manual: false))
        XCTAssertFalse(fans.operations.contains(.target(fan: 0, rpm: 0)))
        let reads = fans.readStarts.count
        XCTAssertThrowsError(try actuator.restore(conflict: { nil }))
        XCTAssertEqual(fans.readStarts.count, reads)
    }

    func testZeroTargetIsNotConfirmedByAManualFanOrACompetingUtility() throws {
        for competing in [false, true] {
            let fans = TargetFans(), journal = TargetJournal()
            let actuator = try owner(fans, journal)
            var utility: String?
            // Reads: ownership 1, mode before 2, immediate 3, probes 4-5;
            // zero-target before 6, immediate 7, first complete probe 8.
            fans.onRead = { index in
                guard index == 8 else { return }
                if competing { utility = "Macs Fan Control" } else { fans.state.fans[0].mode = 1 }
            }
            XCTAssertThrowsError(try actuator.restore(conflict: { utility }))
            let trace = try XCTUnwrap(actuator.lastTargetDiagnostic)
            XCTAssertEqual(trace.operation, .target(fan: 0, rpm: 0))
            XCTAssertEqual(trace.termination, competing ? "conflictingUtility" : "unexpectedOwnership")
            XCTAssertTrue(actuator.requiresExternalRecovery)
            XCTAssertEqual(try journal.load()?.pending, .target(fan: 0, rpm: 0))
            XCTAssertFalse(fans.operations.contains(.target(fan: 1, rpm: 0)))
        }
    }

    func testOlderManualOnlyRetirementLogicRejectsAStagedTargetPair() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let actuator = try owner(fans, journal)
        var pending = try XCTUnwrap(actuator.record)
        pending.pending = .target(fan: 0, rpm: 4500)
        var acknowledged = pending
        acknowledged.pending = nil; acknowledged.acknowledged.fans[0].targetRPM = 4500
        XCTAssertTrue(acknowledged.acknowledgesPendingOperation(in: pending))
        // The installed predecessor recognized only manual-entry pairs, so it
        // refuses this pair: safe refusal rather than transparent downgrade.
        XCTAssertFalse(acknowledged.acknowledgesManualMode(in: pending))
        var unlock = pending; unlock.pending = .globalUnlock(true)
        var unlocked = unlock; unlocked.pending = nil; unlocked.acknowledged.globalUnlock = 1
        XCTAssertFalse(unlocked.acknowledgesPendingOperation(in: unlock), "Unlock writes stage no pending copy.")
    }
}

final class FanTargetDiagnosticControllerTests: XCTestCase {
    private let boot = UUID().uuidString
    private func controller(_ fans: TargetFans, _ journal: FanRecoveryPersistence,
                            conflict: @escaping () -> String? = { nil }) throws -> FanHelperController {
        try FanHelperController(hardware: fans, persistence: journal, bootID: boot,
            artifactIdentity: "fake-target-artifact", conflict: conflict, clock: { fans.clock.now },
            startTimers: false, modeDiagnosticTiming: FanModeDiagnosticTiming(clock: { fans.clock.now },
                pause: { fans.clock.now += $0 }))
    }
    private func begin(_ controller: FanHelperController, owner: String = "owner") -> FanStatus {
        let done = expectation(description: "begin reply")
        var status = FanStatus(serviceGeneration: "none")
        controller.begin(owner: owner, profile: .standard) { status = $0; done.fulfill() }
        wait(for: [done], timeout: 4)
        return status
    }
    private func poll(_ controller: FanHelperController, _ fans: TargetFans, after seconds: TimeInterval = 1) {
        fans.clock.now += seconds
        let done = expectation(description: "poll")
        controller.poll { done.fulfill() }
        wait(for: [done], timeout: 4)
    }
    private func settle(_ controller: FanHelperController) {
        let done = expectation(description: "worker settled")
        controller.poll { done.fulfill() }
        wait(for: [done], timeout: 4)
    }
    private func target(_ fan: Int, _ temperature: Double) -> Double {
        FanPolicyTests.capabilities.fans[fan].target(demand: FanProfile.standard.demand(at: temperature))
    }
    // Both fans under acknowledged control: cycle 1 enters fan 0, cycle 2
    // enters fan 1 first; fan 0's unchanged request stays within the deadband.
    private func steady(_ controller: FanHelperController, _ fans: TargetFans) throws -> String {
        fans.applyTargets = true
        let initial = begin(controller)
        let session = try XCTUnwrap(initial.sessionID)
        poll(controller, fans)
        XCTAssertEqual(controller.status(observe: false).mode, .custom)
        return session
    }

    func testFirstCycleEntersOneFanAndTheNextCycleCompletesEntry() throws {
        let fans = TargetFans(), journal = TargetJournal()
        fans.applyTargets = true
        let controller = try controller(fans, journal)
        let first = begin(controller)
        XCTAssertNotNil(first.sessionID); XCTAssertFalse(first.externalRecoveryRequired)
        XCTAssertEqual(first.mode, .acquiring, "Fan 1 waits for the next cycle.")
        XCTAssertTrue(first.reason?.contains("fan 2") == true)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: target(0, 75))])
        XCTAssertEqual(first.requestedRPM, [0: target(0, 75)])
        XCTAssertEqual(first.snapshot?.fans[0].targetRPM, first.requestedRPM[0])
        XCTAssertEqual(first.snapshot?.fans[1].mode, 0, "A deferred fan stays automatic.")
        XCTAssertEqual(first.manualModeDiagnostic?.termination, "acknowledged")
        XCTAssertEqual(first.targetDiagnostic?.termination, "acknowledged")
        XCTAssertTrue(first.diagnostics.contains { $0.contains("deferred fans 1") })
        XCTAssertTrue(first.diagnostics.contains { $0.contains("F0 target acknowledged") })
        XCTAssertNil(try journal.load()?.pending)

        poll(controller, fans)
        let second = controller.status(observe: false)
        XCTAssertEqual(second.mode, .custom)
        // Fan 0's unchanged request stays within the deadband and is not rewritten.
        XCTAssertEqual(Array(fans.operations.dropFirst(2)), [.mode(fan: 1, manual: true),
            .target(fan: 1, rpm: target(1, 75))])
        XCTAssertEqual(second.requestedRPM, [0: target(0, 75), 1: target(1, 75)])
        for fan in 0..<2 { XCTAssertEqual(try XCTUnwrap(second.snapshot?.fans[fan].targetRPM), second.requestedRPM[fan]!, accuracy: 2) }
        XCTAssertEqual(second.targetDiagnostic?.operation, .target(fan: 1, rpm: target(1, 75)))
        XCTAssertTrue(second.diagnostics.last?.contains("deadband-held fans 0") == true)
        XCTAssertNil(try journal.load()?.pending)
    }

    func testAtMostOneFanEntersManualModePerCycleEvenWithTimeToSpare() throws {
        let fans = TargetFans(), journal = TargetJournal()
        fans.applyTargets = true
        // Short fake waits leave fan 1's entry well inside its 2.75 s budget;
        // only the one-entry-per-cycle rule defers it.
        let controller = try FanHelperController(hardware: fans, persistence: journal, bootID: boot,
            artifactIdentity: "fake-target-artifact", conflict: { nil }, clock: { fans.clock.now },
            startTimers: false, modeDiagnosticTiming: FanModeDiagnosticTiming(clock: { fans.clock.now },
                pause: { fans.clock.now += $0 / 10 }))
        let first = begin(controller)
        XCTAssertLessThan(fans.clock.now - 100, 0.25)
        XCTAssertEqual(first.mode, .acquiring)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: target(0, 75))])
        XCTAssertTrue(first.diagnostics.contains { $0.contains("deferred fans 1") })
    }

    func testEntryWhoseFirstTargetCannotFitKeepsTheEntryTargetUntilTheNextCycle() throws {
        let fans = TargetFans(), journal = TargetJournal()
        fans.applyTargets = true
        // A slow manual-entry intent save and slow entry probes: a one-second
        // old frame leaves 3 s of the four-second window, so entry is
        // admitted, but less than 1.5 s remains for its target.
        fans.frameAge = 1
        journal.onSave = { record in if record.pending == .mode(fan: 0, manual: true) { fans.clock.now += 0.6 } }
        fans.onRead = { index in if index == 3 || index == 4 { fans.clock.now += 0.42 } }
        let controller = try controller(fans, journal)
        let first = begin(controller)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])
        XCTAssertEqual(first.manualModeDiagnostic?.termination, "acknowledged")
        XCTAssertEqual(first.mode, .acquiring); XCTAssertTrue(first.requestedRPM.isEmpty)
        XCTAssertEqual(first.snapshot?.fans[0].mode, 1, "Manual at the firmware's entry target until the next cycle.")
        XCTAssertTrue(first.diagnostics.contains { $0.contains("deferred fans 0,1") })
        fans.onRead = nil; journal.onSave = nil
        XCTAssertTrue(controller.renew(owner: "owner", session: try XCTUnwrap(first.sessionID)))
        poll(controller, fans)
        XCTAssertEqual(Array(fans.operations.dropFirst()), [.mode(fan: 1, manual: true),
            .target(fan: 1, rpm: target(1, 75)), .target(fan: 0, rpm: target(0, 75))])
        XCTAssertEqual(controller.status(observe: false).mode, .custom)
    }

    func testCancellationBeforeTheNextWriteStartsReportsNoStaleTraceAsAFailure() throws {
        let fans = TargetFans(), journal = TargetJournal()
        var calls = 0, armed = false
        // After fan 0's durable acknowledgement: its publication check (1),
        // fan 1's loop check (2), then the admission check inside fan 1's
        // write (3), which sees the competing utility once.
        let controller = try controller(fans, journal, conflict: {
            guard armed else { return nil }
            calls += 1
            return calls == 3 ? "Macs Fan Control" : nil
        })
        _ = try steady(controller, fans)
        fans.temperature = 80
        // Fan 0's target appears only at its first complete probe, so its
        // acknowledged trace carries a retained immediate mismatch. Reads:
        // ownership 1, fan 0 before 2, immediate 3, probes 4-5.
        fans.applyTargets = false; fans.readStarts = []; fans.targetVisibleAtRead = 4
        journal.onAcknowledged = { if case .target(0, _) = $0 { armed = true } }
        let before = fans.operations.count
        poll(controller, fans)
        XCTAssertEqual(calls, 3)
        XCTAssertFalse(try XCTUnwrap(controller.status(observe: false).targetDiagnostic?.primaryFailure).isEmpty)
        let status = controller.status(observe: false)
        XCTAssertEqual(fans.operations.count, before + 1, "Only fan 0's target was issued.")
        XCTAssertFalse(status.externalRecoveryRequired); XCTAssertNotNil(status.sessionID)
        XCTAssertFalse(status.diagnostics.contains { $0.contains("Target acknowledgement failed") })
        XCTAssertFalse(status.diagnostics.contains { $0.contains("First target mismatch retained") })
        XCTAssertEqual(status.targetDiagnostic?.termination, "acknowledged")
        XCTAssertNil(try journal.load()?.pending)
    }

    func testRevocationDuringTheLastFansConfirmationIsNotPresentedAsOrdinaryControl() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let controller = try controller(fans, journal)
        _ = try steady(controller, fans)
        fans.temperature = 80; fans.firmwareAutomaticTarget = 2317
        fans.readStarts = []
        // Reads: ownership 1; fan 0 2-5; fan 1 before 6, immediate 7, probes 8-9.
        fans.onRead = { if $0 == 8 { controller.disconnected(owner: "owner") } }
        poll(controller, fans)
        settle(controller)
        let status = controller.status(observe: false)
        XCTAssertTrue(status.diagnostics.contains { $0.contains("Mode: custom → restoring") })
        XCTAssertFalse(status.diagnostics.contains { $0.contains("Mode: restoring → custom") })
        XCTAssertFalse(status.externalRecoveryRequired); XCTAssertTrue(status.releaseVerified)
        XCTAssertNil(try journal.load())
    }

    func testHysteresisReleaseIsBoundedKeepsTheSessionAndReentersFanByFan() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let controller = try controller(fans, journal)
        let session = try steady(controller, fans)
        fans.firmwareAutomaticTarget = 2317
        // Cooler frames once a second lower the smoothed average to the 65 °C
        // release point within a few cycles; protection stays clear.
        fans.temperature = 40
        let before = fans.operations.count
        var released = controller.status(observe: false)
        for _ in 0..<5 where released.mode != .automatic {
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            poll(controller, fans)
            released = controller.status(observe: false)
        }
        XCTAssertEqual(released.mode, .automatic); XCTAssertEqual(released.sessionID, session)
        XCTAssertTrue(released.releaseVerified); XCTAssertTrue(released.requestedRPM.isEmpty)
        XCTAssertEqual(Array(fans.operations.suffix(4)), [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0),
            .mode(fan: 1, manual: false), .target(fan: 1, rpm: 0)])
        XCTAssertGreaterThan(fans.operations.count, before + 4, "Bounded ramp-down targets preceded the release.")
        XCTAssertEqual(released.targetDiagnostic?.operation, .target(fan: 1, rpm: 0))
        XCTAssertEqual(released.targetDiagnostic?.termination, "acknowledged")
        XCTAssertNil(try journal.load())
        // Heating again re-enters one fan per cycle under the same session.
        fans.temperature = 89
        let reentry = fans.operations.count
        var first = controller.status(observe: false)
        for _ in 0..<5 where fans.operations.count == reentry {
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            poll(controller, fans)
            first = controller.status(observe: false)
        }
        XCTAssertEqual(Array(fans.operations.dropFirst(reentry).prefix(1)), [.mode(fan: 0, manual: true)])
        XCTAssertEqual(fans.operations.count, reentry + 2)
        XCTAssertEqual(first.mode, .acquiring); XCTAssertEqual(first.sessionID, session)
        XCTAssertTrue(controller.renew(owner: "owner", session: session))
        poll(controller, fans)
        XCTAssertEqual(Array(fans.operations.dropFirst(reentry + 2).prefix(1)), [.mode(fan: 1, manual: true)])
        XCTAssertEqual(controller.status(observe: false).mode, .custom)
    }

    func testFailedBeginDoesNotRepublishAnEarlierSessionsTrace() throws {
        let fans = TargetFans(), journal = TargetJournal()
        var utility: String?
        let controller = try controller(fans, journal, conflict: { utility })
        _ = try steady(controller, fans)
        fans.firmwareAutomaticTarget = 2317
        let stopped = expectation(description: "stop")
        controller.stop(owner: "owner", reason: "Owner stopped") { _ in stopped.fulfill() }
        wait(for: [stopped], timeout: 4)
        XCTAssertNotNil(controller.status(observe: false).targetDiagnostic)
        utility = "Macs Fan Control"; fans.clock.now += 1
        let failed = begin(controller)
        XCTAssertNil(failed.sessionID); XCTAssertNotNil(failed.reason)
        XCTAssertNil(failed.targetDiagnostic, "An earlier session's trace is not republished.")
    }

    func testRequestIsPublishedWithItsReadbackWhileTheNextFanIsPending() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let controller = try controller(fans, journal)
        _ = try steady(controller, fans)
        let previous = controller.status(observe: false).requestedRPM
        fans.temperature = 80
        fans.readStarts = []
        // Reads: ownership 1; fan 0 before 2, immediate 3, probes 4-5; fan 1
        // before 6, immediate 7, probes 8-9.
        var during: FanStatus?
        fans.onRead = { if $0 == 8 { during = controller.status(observe: false) } }
        poll(controller, fans)
        let pending = try XCTUnwrap(during), done = controller.status(observe: false)
        XCTAssertEqual(pending.mode, .custom, "A pending write never flickers the presentation.")
        let fan0 = try XCTUnwrap(pending.requestedRPM[0]), fan1 = try XCTUnwrap(previous[1])
        XCTAssertNotEqual(fan0, previous[0]); XCTAssertEqual(fan0, done.requestedRPM[0])
        XCTAssertEqual(try XCTUnwrap(pending.snapshot?.fans[0].targetRPM), fan0, accuracy: 2)
        XCTAssertEqual(pending.requestedRPM[1], fan1)
        XCTAssertEqual(try XCTUnwrap(pending.snapshot?.fans[1].targetRPM), fan1, accuracy: 2)
        XCTAssertEqual(pending.targetDiagnostic?.operation, .target(fan: 0, rpm: fan0))
        XCTAssertNotEqual(done.requestedRPM[1], fan1)
        XCTAssertEqual(try XCTUnwrap(done.snapshot?.fans[1].targetRPM), try XCTUnwrap(done.requestedRPM[1]), accuracy: 2)
    }

    func testWritesThatCannotFitTheLeaseOrTelemetryWindowAreNeverIssued() throws {
        // Entry needs 2.75 s: a 1.3 s old frame leaves 2.7 s, so nothing is written.
        let fans = TargetFans(), journal = TargetJournal()
        fans.applyTargets = true; fans.frameAge = 1.3
        let controller = try controller(fans, journal)
        let first = begin(controller)
        XCTAssertNotNil(first.sessionID); XCTAssertEqual(first.mode, .acquiring)
        XCTAssertTrue(fans.operations.isEmpty); XCTAssertTrue(first.requestedRPM.isEmpty)
        XCTAssertTrue(first.diagnostics.contains { $0.contains("deferred fans 0,1") })
        fans.frameAge = 0
        poll(controller, fans)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: target(0, 75))])

        // Targets need 1.5 s: a 2.4 s old frame leaves 1.6 s, and fan 0's
        // acknowledgement leaves too little for fan 1, which keeps its
        // acknowledged target. The frame still follows the previous one.
        let steadyFans = TargetFans(), steadyJournal = TargetJournal()
        let steadyController = try self.controller(steadyFans, steadyJournal)
        let session = try steady(steadyController, steadyFans)
        XCTAssertTrue(steadyController.renew(owner: "owner", session: session))
        let previous = steadyController.status(observe: false).requestedRPM
        steadyFans.temperature = 80; steadyFans.frameAge = 2.4
        let before = steadyFans.operations.count
        poll(steadyController, steadyFans, after: 3)
        let status = steadyController.status(observe: false)
        XCTAssertEqual(Array(steadyFans.operations.dropFirst(before)), [.target(fan: 0, rpm: try XCTUnwrap(status.requestedRPM[0]))])
        XCTAssertEqual(status.mode, .custom)
        XCTAssertNotEqual(status.requestedRPM[0], previous[0]); XCTAssertEqual(status.requestedRPM[1], previous[1])
        XCTAssertTrue(status.diagnostics.last?.contains("deferred fans 1") == true)
        XCTAssertNil(try steadyJournal.load()?.pending)

        // Lease: without renewal the begin lease (105) leaves under 1.5 s at
        // about 104.1, while a fresh frame leaves the full 4 s of telemetry.
        // A warmer frame moves both requests beyond the deadband.
        let leaseFans = TargetFans(), leaseJournal = TargetJournal()
        let leaseController = try self.controller(leaseFans, leaseJournal)
        _ = try steady(leaseController, leaseFans)
        let leaseBefore = leaseFans.operations.count
        leaseFans.temperature = 80
        poll(leaseController, leaseFans, after: 2.3)
        let leased = leaseController.status(observe: false)
        XCTAssertEqual(leaseFans.operations.count, leaseBefore)
        XCTAssertNotNil(leased.sessionID); XCTAssertEqual(leased.mode, .custom)
        XCTAssertTrue(leased.diagnostics.last?.contains("deferred fans 0,1") == true)
    }

    // Stop, disconnect, sleep and removal arriving while a returned target is
    // pending block every later write; its confirmation still finishes, and
    // bounded release then verifies automatic control without a hold.
    func testLifecycleStopDuringAPendingTargetLetsConfirmationFinishThenReleases() throws {
        for change in 0..<4 {
            let fans = TargetFans(), journal = TargetJournal()
            let controller = try controller(fans, journal)
            _ = try steady(controller, fans)
            fans.temperature = 80; fans.firmwareAutomaticTarget = 2317
            fans.readStarts = []
            let before = fans.operations.count
            let queued = change == 1 ? nil : expectation(description: "queued lifecycle reply \(change)")
            var acknowledgedBeforeRelease: FanTargetDiagnostic?
            fans.onPerform = { operation in
                if operation == .mode(fan: 0, manual: false) {
                    acknowledgedBeforeRelease = controller.status(observe: false).targetDiagnostic
                }
            }
            fans.onRead = { index in
                guard index == 4 else { return }
                switch change {
                case 0: controller.stop(owner: "owner", reason: "Owner stopped") { _ in queued?.fulfill() }
                case 1: controller.disconnected(owner: "owner")
                case 2: controller.systemWillSleep { queued?.fulfill() }
                default: controller.prepareRemoval(owner: "owner") { _ in queued?.fulfill() }
                }
            }
            poll(controller, fans)
            if let queued { wait(for: [queued], timeout: 4) }
            settle(controller)
            let issued = Array(fans.operations.dropFirst(before))
            guard case .target(0, let rpm)? = issued.first else { return XCTFail("change \(change): no fan 0 target") }
            XCTAssertEqual(acknowledgedBeforeRelease?.operation, .target(fan: 0, rpm: rpm), "change \(change)")
            XCTAssertEqual(acknowledgedBeforeRelease?.termination, "acknowledged")
            XCTAssertEqual(Array(issued.dropFirst()), [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0),
                .mode(fan: 1, manual: false), .target(fan: 1, rpm: 0)], "No successor target after revocation.")
            let status = controller.status(observe: false)
            XCTAssertFalse(status.externalRecoveryRequired)
            XCTAssertTrue(status.releaseVerified); XCTAssertTrue(status.safeToUnregister)
            XCTAssertNil(status.sessionID); XCTAssertTrue(status.requestedRPM.isEmpty)
            XCTAssertEqual(status.targetDiagnostic?.operation, .target(fan: 1, rpm: 0))
            XCTAssertEqual(status.targetDiagnostic?.termination, "acknowledged")
            XCTAssertNil(try journal.load())
            XCTAssertTrue(fans.state.fans.allSatisfy(\.isAutomatic))
        }
    }

    func testProfileRevisionDuringAPendingTargetDefersOnlyTheRestOfThatCycle() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let controller = try controller(fans, journal)
        let session = try steady(controller, fans)
        fans.temperature = 80
        fans.readStarts = []
        let before = fans.operations.count
        let revised = expectation(description: "profile reply")
        let profile = FanProfile(start: 60, maximum: 85)
        fans.onRead = { index in
            guard index == 4 else { return }
            controller.updateProfile(owner: "owner", session: session, profile: profile) {
                XCTAssertNil($0.requestError); revised.fulfill()
            }
        }
        poll(controller, fans)
        wait(for: [revised], timeout: 4)
        let issued = Array(fans.operations.dropFirst(before))
        XCTAssertEqual(issued.count, 1)
        guard case .target(0, _)? = issued.first else { return XCTFail("Fan 0's returned target was expected") }
        let status = controller.status(observe: false)
        XCTAssertFalse(status.externalRecoveryRequired); XCTAssertEqual(status.sessionID, session)
        XCTAssertNil(try journal.load()?.pending)
        fans.onRead = nil
        XCTAssertTrue(controller.renew(owner: "owner", session: session))
        poll(controller, fans)
        let next = controller.status(observe: false)
        let demand = profile.demand(at: try XCTUnwrap(next.smoothedCPU))
        XCTAssertEqual(Array(fans.operations.suffix(2)), [
            .target(fan: 0, rpm: FanPolicyTests.capabilities.fans[0].target(demand: demand)),
            .target(fan: 1, rpm: FanPolicyTests.capabilities.fans[1].target(demand: demand))])
        XCTAssertEqual(next.mode, .custom)
    }

    func testCompetingUtilityDuringAPendingTargetKeepsTheHold() throws {
        let fans = TargetFans(), journal = TargetJournal()
        var utility: String?
        let controller = try controller(fans, journal, conflict: { utility })
        let session = try steady(controller, fans)
        fans.temperature = 80
        fans.readStarts = []
        fans.onRead = { if $0 == 4 { utility = "Macs Fan Control" } }
        poll(controller, fans)
        let status = controller.status(observe: false)
        XCTAssertTrue(status.externalRecoveryRequired); XCTAssertEqual(status.mode, .externalRecoveryRequired)
        let trace = try XCTUnwrap(status.targetDiagnostic)
        XCTAssertEqual(trace.termination, "conflictingUtility")
        XCTAssertEqual(trace.cancellationCause, "Macs Fan Control appeared.")
        XCTAssertTrue(status.diagnostics.contains { $0.contains("Target acknowledgement failed: conflictingUtility (Macs Fan Control appeared.)") })
        guard case .target(0, let rpm)? = fans.operations.last else { return XCTFail("Fan 0's target was expected last") }
        XCTAssertEqual(trace.operation, .target(fan: 0, rpm: rpm))
        XCTAssertEqual(try journal.load()?.pending, .target(fan: 0, rpm: rpm))
        XCTAssertFalse(controller.renew(owner: "owner", session: session))
    }

    // The helper's own release attempt follows a failed acknowledgement (see
    // FanSelfRecoveryTests). Here a competing utility appears as that attempt
    // starts, so nothing is written and the hold stays exactly as before.
    func testFailedTargetAcknowledgementPublishesTheHoldOnlyAfterItsDeadline() throws {
        let fans = TargetFans(), journal = TargetJournal()
        var utility: String?
        journal.onSave = { if $0.recoveryAttempted == true { utility = "Macs Fan Control" } }
        let controller = try controller(fans, journal, conflict: { utility })
        // Cycle 1 reads: ownership 1, manual before 2, probes 3-4, target
        // before 5, immediate 6, complete probes from 7. Never visible.
        var during: FanStatus?, renewed: Bool?
        fans.onRead = { index in
            guard index == 7 else { return }
            during = controller.status(observe: false)
            renewed = controller.renew(owner: "owner", session: controller.safety.check(now: fans.clock.now).session ?? "")
        }
        let status = begin(controller)
        let pending = try XCTUnwrap(during)
        XCTAssertFalse(pending.externalRecoveryRequired, "A pending write is not yet a hold.")
        XCTAssertEqual(pending.mode, .acquiring); XCTAssertNotNil(pending.sessionID)
        XCTAssertEqual(renewed, true)
        XCTAssertEqual(status.mode, .externalRecoveryRequired); XCTAssertTrue(status.externalRecoveryRequired)
        XCTAssertNil(status.sessionID); XCTAssertTrue(status.requestedRPM.isEmpty)
        XCTAssertFalse(status.releaseVerified); XCTAssertFalse(status.safeToUnregister)
        XCTAssertEqual(status.externalRecoveryID, journal.record?.ownerSession)
        let trace = try XCTUnwrap(status.targetDiagnostic)
        XCTAssertEqual(trace.termination, "deadline"); XCTAssertTrue(trace.evidenceOnly)
        XCTAssertTrue(status.diagnostics.contains { $0.contains("First target mismatch retained") })
        XCTAssertTrue(status.diagnostics.contains { $0.contains("Target acknowledgement failed: deadline") })
        guard case .target(0, let rpm) = trace.operation else { return XCTFail("Missing target operation") }
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: rpm)])
        XCTAssertEqual(try journal.load()?.pending, .target(fan: 0, rpm: rpm))
        XCTAssertEqual(try journal.load()?.recoveryAttempted, true, "The one automatic attempt is marked used.")
        XCTAssertNil(status.selfRecoveryReceipt?.confirmedAt)
        XCTAssertEqual(status.selfRecoveryReceipt?.steps.count, 0, "A competing utility stops the attempt before any write.")
        XCTAssertTrue(status.selfRecoveryReceipt?.failure?.contains("Macs Fan Control") == true)
        XCTAssertTrue(status.diagnostics.contains { $0.contains("Automatic recovery did not clear the hold") })
        let decoded = try JSONDecoder().decode(FanStatus.self, from: status.encodedReply())
        XCTAssertEqual(decoded.targetDiagnostic, trace)
        utility = nil

        // Later matches, polling, stop, begin, profile, removal and renewal
        // cannot clear the hold or admit another write.
        fans.applyTargets = true; fans.apply(trace.operation)
        let reads = fans.readStarts.count
        poll(controller, fans)
        let stopped = expectation(description: "stop")
        controller.stop(owner: "owner", reason: "Owner stopped") { reply in
            XCTAssertTrue(reply.externalRecoveryRequired); stopped.fulfill()
        }
        wait(for: [stopped], timeout: 1)
        XCTAssertEqual(begin(controller).requestError, FanActuator.externalRecoveryReason)
        controller.updateProfile(owner: "owner", session: UUID().uuidString, profile: .standard) {
            XCTAssertEqual($0.requestError, FanActuator.externalRecoveryReason)
        }
        controller.prepareRemoval(owner: "owner") { XCTAssertEqual($0.requestError, FanActuator.externalRecoveryReason) }
        XCTAssertFalse(controller.renew(owner: "owner", session: UUID().uuidString))
        XCTAssertEqual(fans.readStarts.count, reads)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: rpm)])
        XCTAssertEqual(controller.status(observe: false).targetDiagnostic, trace)
    }

    func testWatchdogDuringABlockedConfirmationReadEndsUnconfirmedAndIsReleased() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let blocked = expectation(description: "confirmation read entered")
        let release = DispatchSemaphore(value: 0)
        fans.onRead = { index in
            if index == 7 { blocked.fulfill(); _ = release.wait(timeout: .now() + 2) }
        }
        let controller = try controller(fans, journal)
        let done = expectation(description: "begin finishes after release")
        var status = FanStatus(serviceGeneration: "none")
        controller.begin(owner: "owner", profile: .standard) { status = $0; done.fulfill() }
        wait(for: [blocked], timeout: 1)
        XCTAssertEqual(controller.status(observe: false).mode, .acquiring)
        fans.clock.now += 4.1
        controller.checkWatchdog()
        XCTAssertEqual(controller.status(observe: false).mode, .restoring)
        release.signal()
        wait(for: [done], timeout: 1)
        // The blocked read returned after the deadline, so the target stayed
        // unconfirmed. The helper then released its fans by itself.
        XCTAssertTrue(status.diagnostics.contains { $0.contains("Target acknowledgement failed: deadline") })
        let receipt = try XCTUnwrap(status.selfRecoveryReceipt)
        XCTAssertEqual(receipt.cause, "deadline"); XCTAssertEqual(receipt.trigger, .automatic)
        XCTAssertNotNil(receipt.confirmedAt); XCTAssertNil(receipt.failure)
        guard case .target(0, let rpm) = receipt.unconfirmed else { return XCTFail("Missing unconfirmed target") }
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: rpm),
            .mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .target(fan: 1, rpm: 0)])
        XCTAssertFalse(status.externalRecoveryRequired); XCTAssertEqual(status.mode, .paused)
        XCTAssertEqual(status.reason, FanActuator.selfRecoveredReason)
        XCTAssertNil(try journal.load())
    }

    func testRequestDuringARunningPollRunsOneFollowUpPollImmediately() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let controller = try controller(fans, journal)
        _ = controller.status(observe: true)
        let entered = expectation(description: "first frame read entered")
        let release = DispatchSemaphore(value: 0)
        let followed = expectation(description: "follow-up frame read")
        fans.onFrameRead = { count in
            if count == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 2) }
            if count == 2 { followed.fulfill() }
        }
        controller.schedulePoll()
        wait(for: [entered], timeout: 1)
        controller.schedulePoll(); controller.schedulePoll()
        release.signal()
        wait(for: [followed], timeout: 1)
        let settled = expectation(description: "worker idle")
        controller.poll { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(fans.frameReads, 3, "Two requests during one poll add exactly one follow-up poll.")
    }

    func testOrdinaryStopAfterAcknowledgedControlVerifiesBoundedRelease() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let controller = try controller(fans, journal)
        _ = try steady(controller, fans)
        fans.firmwareAutomaticTarget = 2317; fans.deferRelease = true
        fans.readStarts = []
        // Restoration reads: ownership 1, fan 0 release before 2, immediate 3,
        // probes from 4; automatic appears from read 5 (fan 1 at once).
        fans.releaseVisibleAtRead = 5
        let stopped = expectation(description: "stop")
        var reply = FanStatus(serviceGeneration: "none")
        controller.stop(owner: "owner", reason: "Owner stopped") { reply = $0; stopped.fulfill() }
        wait(for: [stopped], timeout: 4)
        XCTAssertFalse(reply.externalRecoveryRequired)
        XCTAssertTrue(reply.releaseVerified); XCTAssertTrue(reply.safeToUnregister); XCTAssertNil(reply.sessionID)
        XCTAssertTrue(try XCTUnwrap(reply.fanProbe).observation.isFullyAutomatic)
        XCTAssertEqual(reply.targetDiagnostic?.operation, .target(fan: 1, rpm: 0))
        XCTAssertEqual(reply.targetDiagnostic?.termination, "acknowledged")
        XCTAssertTrue(reply.diagnostics.contains { $0.contains("Automatic restoration readback confirmed") })
        XCTAssertNil(try journal.load())
    }

    func testOrdinaryTargetsInsideTheDeadbandAreNotRewritten() throws {
        let fans = TargetFans(), journal = TargetJournal()
        let controller = try controller(fans, journal)
        let session = try steady(controller, fans)
        let requested = controller.status(observe: false).requestedRPM
        let writes = fans.operations.count
        // A 0.2 °C step moves the smoothed requests by about 12 and 10 RPM.
        fans.temperature = 75.2
        XCTAssertTrue(controller.renew(owner: "owner", session: session))
        poll(controller, fans)
        let held = controller.status(observe: false)
        XCTAssertEqual(fans.operations.count, writes)
        XCTAssertEqual(held.requestedRPM, requested); XCTAssertEqual(held.mode, .custom)
        XCTAssertTrue(held.diagnostics.last?.contains("deadband-held fans 0,1") == true)
        // A larger step moves both requests by at least the deadband.
        fans.temperature = 80
        XCTAssertTrue(controller.renew(owner: "owner", session: session))
        poll(controller, fans)
        let moved = controller.status(observe: false)
        XCTAssertEqual(fans.operations.count, writes + 2)
        for fan in 0..<2 {
            let change = abs(try XCTUnwrap(moved.requestedRPM[fan]) - (try XCTUnwrap(requested[fan])))
            XCTAssertGreaterThanOrEqual(change, FanHelperController.targetDeadbandRPM)
            XCTAssertLessThan(change, 400)
        }
        XCTAssertEqual(FanHelperController.targetDeadbandRPM, 50)
    }

    func testDeadbandBoundaryAndEndpointTolerance() {
        XCTAssertTrue(FanHelperController.writesTarget(4000, acknowledged: nil, endpoint: false), "First target after entry")
        XCTAssertTrue(FanHelperController.writesTarget(4050, acknowledged: 4000, endpoint: false), "Exactly 50 RPM")
        XCTAssertTrue(FanHelperController.writesTarget(3950, acknowledged: 4000, endpoint: false))
        XCTAssertFalse(FanHelperController.writesTarget(4049.999, acknowledged: 4000, endpoint: false))
        XCTAssertFalse(FanHelperController.writesTarget(4000, acknowledged: 4000, endpoint: false))
        XCTAssertTrue(FanHelperController.writesTarget(6000, acknowledged: 5997.99, endpoint: true), "Endpoint beyond 2 RPM")
        XCTAssertFalse(FanHelperController.writesTarget(6000, acknowledged: 5998, endpoint: true), "Endpoint within 2 RPM")
        XCTAssertFalse(FanHelperController.writesTarget(5960, acknowledged: 5970, endpoint: false))
    }

    // The exact maximum (ramp or protection) and minimum are written even when
    // they lie inside the deadband, and not rewritten once read back.
    func testEndpointsAndProtectionAreWrittenInsideTheDeadband() throws {
        for (start, next, protection) in [(84.9, 86.0, false), (84.9, 90.0, true), (70.1, 69.0, false)] {
            let fans = TargetFans(), journal = TargetJournal()
            fans.temperature = start
            let controller = try controller(fans, journal)
            let session = try steady(controller, fans)
            let before = controller.status(observe: false).requestedRPM
            let writes = fans.operations.count
            if protection {
                // P-Q1: the average stays where it was and only the die
                // maximum is hot. Its first two readings leave the ramp's
                // request, inside the deadband of the maximum, as it is.
                fans.cpuMaximum = next
                for _ in 0..<2 {
                    XCTAssertTrue(controller.renew(owner: "owner", session: session))
                    poll(controller, fans)
                    XCTAssertEqual(controller.status(observe: false).mode, .custom)
                    XCTAssertEqual(fans.operations.count, writes)
                }
            } else { fans.temperature = next }
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            poll(controller, fans)
            let status = controller.status(observe: false)
            XCTAssertEqual(status.mode, protection ? .protection : .custom, "\(next)")
            for fan in fans.capabilities.fans {
                let endpoint = next < start ? fan.minimumRPM : fan.maximumRPM
                XCTAssertLessThan(abs(endpoint - (try XCTUnwrap(before[fan.id]))), FanHelperController.targetDeadbandRPM)
                XCTAssertEqual(status.requestedRPM[fan.id], endpoint, "\(next)")
            }
            XCTAssertEqual(fans.operations.count, writes + 2, "\(next)")
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            poll(controller, fans)
            XCTAssertEqual(fans.operations.count, writes + 2, "Already at the endpoint: \(next)")
        }
    }
}

final class FanTargetDiagnosticStoreTests: XCTestCase {
    private let boot = UUID().uuidString, generation = UUID().uuidString
    private func actuator(_ fans: TargetFans, _ store: FanRecoveryStore) throws -> FanActuator {
        try FanActuator(hardware: fans, persistence: store, bootID: boot, serviceGeneration: generation,
            artifactIdentity: "fake-durable-target-artifact", modeDiagnosticTiming: FanModeDiagnosticTiming(
                clock: { fans.clock.now }, pause: { fans.clock.now += $0 }))
    }
    private func owner(_ directory: URL, session: String = UUID().uuidString) throws -> (TargetFans, FanRecoveryStore, FanActuator) {
        let fans = TargetFans()
        let store = try FanRecoveryStore(directory: directory, requiredUID: geteuid())
        let actuator = try actuator(fans, store)
        try actuator.establish(session: session, capabilities: fans.capabilities, baseline: fans.state)
        _ = try actuator.mutate(.mode(fan: 0, manual: true), cancelled: { false }, manualModeCommit: { try $0(fans.clock.now) })
        fans.readStarts = []
        return (fans, store, actuator)
    }
    private func marker(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("ownership-retiring.json").path)
    }

    func testAcknowledgedTargetRetiresItsPendingCopyAndRestartReconcilesAsBefore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try owner(directory)
        fans.targetVisibleAtRead = 3
        var stagedBeforeBothMatched = false
        fans.onRead = { [self] index in if index == 4 { stagedBeforeBothMatched = marker(directory) } }
        _ = try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil })
        XCTAssertFalse(stagedBeforeBothMatched, "Nothing is staged before both probes match.")
        XCTAssertEqual(actuator.lastTargetDiagnostic?.acknowledgementMarkerRetired, true)
        XCTAssertFalse(marker(directory))
        let retained = try XCTUnwrap(store.load())
        XCTAssertNil(retained.pending); XCTAssertEqual(retained, actuator.record)
        XCTAssertEqual(retained.acknowledged.fans[0].targetRPM, 4000)
        let controller = try FanHelperController(hardware: fans, persistence: store, bootID: boot,
            artifactIdentity: "fake-durable-target-artifact", conflict: { nil }, clock: { fans.clock.now },
            startTimers: false, modeDiagnosticTiming: FanModeDiagnosticTiming(clock: { fans.clock.now }))
        let restarted = controller.status(observe: false)
        XCTAssertFalse(restarted.externalRecoveryRequired)
        XCTAssertEqual(restarted.mode, .restoring)
    }

    func testStagingSyncFailuresRetainThePendingTargetOnRestart() throws {
        for failingStage in [1, 2] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let (fans, store, actuator) = try owner(directory)
            fans.targetVisibleAtRead = 3
            var syncs = 0, armed = false
            fans.onRead = { index in if index == 4 { armed = true } }
            store.directorySync = { fd in
                guard armed else { return fsync(fd) }
                syncs += 1
                if syncs == failingStage { errno = EIO; return -1 }
                return fsync(fd)
            }
            XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false },
                                                     acknowledgementConflict: { nil }))
            XCTAssertEqual(actuator.lastTargetDiagnostic?.termination, "acknowledgementPersistenceFailure")
            XCTAssertTrue(actuator.requiresExternalRecovery)
            store.directorySync = { fsync($0) }
            XCTAssertEqual(try store.load()?.pending, .target(fan: 0, rpm: 4000))
            XCTAssertTrue(try self.actuator(fans, store).requiresExternalRecovery)
        }
    }

    func testFailedPublicationAfterTheDurableSaveRestartsAsTheHold() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try owner(directory)
        fans.targetVisibleAtRead = 3
        var utility: String?, syncs = 0, armed = false
        fans.onRead = { index in if index == 4 { armed = true } }
        // The primary acknowledgement is durable at the second sync; the
        // competing utility appears just before in-memory publication.
        store.directorySync = { fd in
            if armed { syncs += 1; if syncs == 2 { utility = "Macs Fan Control" } }
            return fsync(fd)
        }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false },
                                                 acknowledgementConflict: { utility }))
        XCTAssertEqual(actuator.lastTargetDiagnostic?.termination, "conflictingUtility")
        XCTAssertTrue(actuator.requiresExternalRecovery)
        XCTAssertTrue(marker(directory))
        XCTAssertEqual(try store.load()?.pending, .target(fan: 0, rpm: 4000))
        let restarted = try self.actuator(fans, store)
        XCTAssertTrue(restarted.requiresExternalRecovery)
        XCTAssertThrowsError(try restarted.restore(conflict: { nil }))
    }

    func testExternalRecoveryRetiresAStagedPairAfterAFailedPublication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID().uuidString
        let (fans, store, actuator) = try owner(directory, session: session)
        fans.targetVisibleAtRead = 3
        var utility: String?, syncs = 0, armed = false
        fans.onRead = { index in if index == 4 { armed = true } }
        store.directorySync = { fd in
            if armed { syncs += 1; if syncs == 2 { utility = "Macs Fan Control" } }
            return fsync(fd)
        }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false },
                                                 acknowledgementConflict: { utility }))
        XCTAssertTrue(marker(directory)); XCTAssertTrue(actuator.requiresExternalRecovery)
        // The owner returns both fans to Auto and quits the utility.
        utility = nil; armed = false; store.directorySync = { fsync($0) }
        fans.state.fans[0].mode = 0; fans.state.fans[1].mode = 0
        fans.onRead = { _ in fans.clock.now += 0.01 }
        let receipt = try actuator.confirmExternalRecovery(recoveryID: session, conflict: { nil }, clock: { fans.clock.now })
        XCTAssertEqual(receipt.recoveryID, session)
        XCTAssertNil(actuator.record); XCTAssertNil(try store.load()); XCTAssertFalse(marker(directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ownership.json").path))
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: 4000)])
    }

    func testRetirementSyncFailureKeepsAConservativeCopyUntilTheNextIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try owner(directory)
        fans.targetVisibleAtRead = 3
        var syncs = 0, armed = false
        fans.onRead = { index in if index == 4 { armed = true } }
        store.directorySync = { fd in
            if armed { syncs += 1; if syncs == 3 { errno = EIO; return -1 } }
            return fsync(fd)
        }
        _ = try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil })
        XCTAssertEqual(actuator.lastTargetDiagnostic?.termination, "acknowledged")
        XCTAssertEqual(actuator.lastTargetDiagnostic?.acknowledgementMarkerRetired, false)
        XCTAssertFalse(actuator.requiresExternalRecovery)
        store.directorySync = { fsync($0) }
        // The unlink itself succeeded; only its sync failed. A fresh failure to
        // unlink leaves the copy, which the next durable intent supersedes.
        fans.applyTargets = true
        _ = try actuator.mutate(.target(fan: 0, rpm: 4500), cancelled: { false }, acknowledgementConflict: { nil })
        XCTAssertFalse(marker(directory)); XCTAssertNil(try store.load()?.pending)
    }

    func testUndeletablePendingCopyHoldsOnRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { chmod(directory.path, 0o700); try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try owner(directory)
        fans.targetVisibleAtRead = 3
        var syncs = 0, armed = false, locked = false
        fans.onRead = { index in if index == 4 { armed = true } }
        // Once the acknowledged primary is durable (second staging sync), make
        // the directory read-only so the pending copy cannot be unlinked.
        store.directorySync = { fd in
            let result = fsync(fd)
            if armed { syncs += 1; if syncs == 2 { locked = chmod(directory.path, 0o500) == 0 } }
            return result
        }
        _ = try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil })
        XCTAssertTrue(locked)
        XCTAssertEqual(actuator.lastTargetDiagnostic?.termination, "acknowledged")
        XCTAssertEqual(actuator.lastTargetDiagnostic?.acknowledgementMarkerRetired, false)
        XCTAssertNotNil(actuator.lastTargetDiagnostic?.acknowledgementMarkerError)
        XCTAssertFalse(actuator.requiresExternalRecovery)
        XCTAssertTrue(marker(directory))
        chmod(directory.path, 0o700)
        store.directorySync = { fsync($0) }
        XCTAssertEqual(try store.load()?.pending, .target(fan: 0, rpm: 4000))
        XCTAssertTrue(try self.actuator(fans, store).requiresExternalRecovery)
    }

    func testDurablePendingTargetSurvivesFailedConfirmationStopAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID().uuidString
        let (fans, store, actuator) = try owner(directory, session: session)
        // Any persistence attempted while confirming would fail here.
        var syncsDuringConfirmation = 0
        fans.onRead = { index in
            guard index == 3 else { return }
            store.directorySync = { _ in syncsDuringConfirmation += 1; errno = EIO; return -1 }
        }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false },
                                                 acknowledgementConflict: { nil }))
        XCTAssertEqual(syncsDuringConfirmation, 0)
        XCTAssertEqual(actuator.lastTargetDiagnostic?.termination, "deadline")
        store.directorySync = { fsync($0) }
        let retained = try XCTUnwrap(store.load())
        XCTAssertEqual(retained.pending, .target(fan: 0, rpm: 4000))
        XCTAssertFalse(marker(directory))
        let restarted = try self.actuator(fans, store)
        XCTAssertEqual(restarted.record, retained); XCTAssertTrue(restarted.requiresExternalRecovery)
        XCTAssertThrowsError(try restarted.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil }))
        XCTAssertThrowsError(try restarted.restore(conflict: { nil }))
        let controller = try FanHelperController(hardware: fans, persistence: store, bootID: boot,
            artifactIdentity: "fake-durable-target-artifact", conflict: { nil }, clock: { fans.clock.now },
            startTimers: false, modeDiagnosticTiming: FanModeDiagnosticTiming(clock: { fans.clock.now }))
        let initial = controller.status(observe: false)
        XCTAssertTrue(initial.externalRecoveryRequired); XCTAssertEqual(initial.externalRecoveryID, session)
        let reads = fans.readStarts.count
        let stopped = expectation(description: "stop after restart")
        controller.stop(owner: "owner", reason: "Stop after restart") { reply in
            XCTAssertTrue(reply.externalRecoveryRequired); stopped.fulfill()
        }
        wait(for: [stopped], timeout: 1)
        XCTAssertEqual(fans.readStarts.count, reads)
        XCTAssertEqual(try store.load(), retained)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true), .target(fan: 0, rpm: 4000)])
    }

    func testIntentSyncFailureBeforeTargetWriteRetainsPendingWithoutWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try owner(directory)
        store.directorySync = { _ in errno = EIO; return -1 }
        XCTAssertThrowsError(try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false },
                                                 acknowledgementConflict: { nil }))
        XCTAssertNil(actuator.lastTargetDiagnostic)
        XCTAssertEqual(fans.operations, [.mode(fan: 0, manual: true)])
        XCTAssertTrue(actuator.requiresExternalRecovery)
        store.directorySync = { fsync($0) }
        XCTAssertEqual(try store.load()?.pending, .target(fan: 0, rpm: 4000))
        XCTAssertTrue(try self.actuator(fans, store).requiresExternalRecovery)
    }

    func testBoundedReleaseWithTheRealStoreRetiresEachCopyAndRemovesTheRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (fans, store, actuator) = try owner(directory)
        fans.applyTargets = true
        _ = try actuator.mutate(.target(fan: 0, rpm: 4000), cancelled: { false }, acknowledgementConflict: { nil })
        fans.firmwareAutomaticTarget = 2317
        var pendingAtWrites: [FanOperation?] = []
        fans.onPerform = { _ in pendingAtWrites.append(try? store.load()?.pending) }
        XCTAssertTrue(try XCTUnwrap(actuator.restore(conflict: { nil })).isFullyAutomatic)
        XCTAssertEqual(pendingAtWrites, [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .target(fan: 1, rpm: 0)])
        XCTAssertNil(actuator.record); XCTAssertNil(try store.load()); XCTAssertFalse(marker(directory))
    }
}

// Mirrors the observed Mac14,9 layout: upper-case mode keys, no global
// unlock. The fake firmware shows a target only after later F0Tg reads.
private final class NativeFirmware {
    var values: [String: (encoding: String, value: Double)] = [
        "FNum": ("ui8 ", 2), "F0Md": ("ui8 ", 0), "F1Md": ("ui8 ", 0),
        "F0Mn": ("flt ", 1000), "F0Mx": ("flt ", 6000), "F1Mn": ("flt ", 1500), "F1Mx": ("flt ", 5500),
        "F0Tg": ("flt ", 1000), "F1Tg": ("flt ", 1500), "F0Ac": ("flt ", 1000), "F1Ac": ("flt ", 1500),
        "TCMb": ("flt ", 75), "TCMz": ("flt ", 75), "Tg0f": ("flt ", 40)
    ]
    var writes: [String] = []
    private let visibleAfterTargetReads: Int?
    private var targetReadsSinceWrite: Int?, pendingTarget: Double?

    init(visibleAfterTargetReads: Int?) { self.visibleAfterTargetReads = visibleAfterTargetReads }

    func smc() -> AppleSMC {
        AppleSMC(invoke: { [self] input in
            let key = String(bytes: (0..<4).reversed().map { UInt8(truncatingIfNeeded: input.key >> (8 * $0)) },
                             encoding: .ascii)!
            var reply = SMCMessage()
            if input.command == 6 {
                let bytes = withUnsafeBytes(of: input.bytes) { Array($0.prefix(Int(input.info.size))) }
                writes.append(key)
                let number = try! SMCValue(encoding: values[key]!.encoding, bytes: bytes).number()
                if key == "F0Tg" { pendingTarget = number; targetReadsSinceWrite = 0 } else { values[key]!.value = number }
                return (KERN_SUCCESS, reply, 80)
            }
            guard let entry = values[key] else { reply.result = 0x84; return (KERN_SUCCESS, reply, 80) }
            let size = entry.encoding == "ui8 " ? 1 : 4
            reply.info.size = UInt32(size)
            reply.info.type = entry.encoding.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if input.command == 5 {
                if key == "F0Tg", let reads = targetReadsSinceWrite, let target = pendingTarget {
                    targetReadsSinceWrite = reads + 1
                    if let visible = visibleAfterTargetReads, reads + 1 >= visible {
                        values["F0Tg"]!.value = target; pendingTarget = nil
                    }
                }
                let value = try! SMCValue(encoding: entry.encoding, bytes: Array(repeating: 0, count: size))
                    .replacing(number: values[key]!.value)
                withUnsafeMutableBytes(of: &reply.bytes) { $0.copyBytes(from: value.bytes) }
            }
            return (KERN_SUCCESS, reply, 80)
        })
    }
}

final class FanTargetNativeTransportTests: XCTestCase {
    private func controller(_ firmware: NativeFirmware, _ journal: TargetJournal) throws -> FanHelperController {
        try FanHelperController(hardware: try AppleFanHardware(model: "Mac14,9", smc: firmware.smc()),
            persistence: journal, bootID: UUID().uuidString,
            artifactIdentity: "fake-native-target-artifact", conflict: { nil }, startTimers: false,
            modeDiagnosticTiming: FanModeDiagnosticTiming())
    }
    private func begin(_ controller: FanHelperController) -> FanStatus {
        let done = expectation(description: "native begin returns")
        var status = FanStatus(serviceGeneration: "none")
        controller.begin(owner: "owner", profile: .standard) { status = $0; done.fulfill() }
        wait(for: [done], timeout: 6)
        return status
    }
    private func run(visibleAfterTargetReads: Int?) throws -> (FanStatus, [String], FanRecoveryRecord?) {
        let firmware = NativeFirmware(visibleAfterTargetReads: visibleAfterTargetReads), journal = TargetJournal()
        let status = begin(try controller(firmware, journal))
        return (status, firmware.writes, try journal.load())
    }

    // P-Q1 through the production reader and the real transport. Inside a
    // session an out-of-range TCMz surfaces from the reader's own frame read.
    // Two hot readings and that skipped frame write nothing, and neither does
    // a third hot reading that comes at once, before the run spans 1.9 s. The
    // next one, two seconds later, takes the first fan to maximum.
    func testThreeHotReadingsStartProtectionAcrossASkippedNativeFrame() throws {
        try XCTSkipIf(ProcessInfo.processInfo.thermalState.rawValue >= 2, "Thermal pressure starts protection at once.")
        let firmware = NativeFirmware(visibleAfterTargetReads: 1)
        firmware.values["TCMb"]!.value = 60; firmware.values["TCMz"]!.value = 92
        let controller = try controller(firmware, TargetJournal())
        let started = begin(controller)
        let session = try XCTUnwrap(started.sessionID)
        func poll() -> FanStatus {
            XCTAssertTrue(controller.renew(owner: "owner", session: session))
            let done = expectation(description: "native poll")
            controller.poll { done.fulfill() }
            wait(for: [done], timeout: 6)
            return controller.status(observe: false)
        }
        XCTAssertEqual(started.mode, .automatic)
        XCTAssertEqual(poll().mode, .automatic)
        firmware.values["TCMz"]!.value = 255.97
        let skipped = poll()
        XCTAssertEqual(skipped.mode, .automatic); XCTAssertEqual(skipped.sessionID, session)
        XCTAssertEqual(skipped.diagnostics.filter { $0.contains("Unusable frame skipped") && $0.contains("TCMz") }.count, 1)
        XCTAssertTrue(firmware.writes.isEmpty, "Two hot readings and a skipped frame write nothing.")
        firmware.values["TCMz"]!.value = 92
        // A third reading at once is hot too, but the run does not span 1.9 s yet.
        XCTAssertEqual(poll().mode, .automatic); XCTAssertTrue(firmware.writes.isEmpty)
        Thread.sleep(forTimeInterval: 2)
        let sustained = poll()
        XCTAssertEqual(firmware.writes, ["F0Md", "F0Tg"], "One fan enters per cycle.")
        XCTAssertEqual(sustained.requestedRPM[0], 6000)
        XCTAssertTrue(sustained.reason?.contains("(TCMz) ≥90 °C for three readings in a row") == true)
        XCTAssertFalse(sustained.externalRecoveryRequired); XCTAssertEqual(sustained.sessionID, session)
    }

    func testNativeTargetIsAcknowledgedOnceTwoCompleteProbesShowIt() throws {
        // F0Tg reads after the write: immediate 1, probe 1 metadata 2 and
        // state 3, probe 2 metadata 4 (now visible) and state 5.
        let (status, writes, record) = try run(visibleAfterTargetReads: 4)
        XCTAssertEqual(writes, ["F0Md", "F0Tg"], "One manual write, one target write, no retry or unlock.")
        XCTAssertFalse(status.externalRecoveryRequired); XCTAssertNotNil(status.sessionID)
        XCTAssertEqual(status.mode, .acquiring)
        XCTAssertEqual(status.manualModeDiagnostic?.termination, "acknowledged")
        let trace = try XCTUnwrap(status.targetDiagnostic)
        guard case .target(0, let rpm) = trace.operation else { return XCTFail("Missing target operation") }
        XCTAssertEqual(trace.termination, "acknowledged")
        XCTAssertEqual(trace.probes.map(\.operationConfirmed), [false, false, true, true])
        let write = try XCTUnwrap(trace.nativeWrite)
        XCTAssertEqual(write.requestedValueHex, try payloadHex(rpm))
        XCTAssertEqual(trace.nativeCalls.filter { $0.command == 6 }, [write])
        // 51 calls precede the probes; each Mac14,9 complete probe uses 43.
        XCTAssertEqual(trace.nativeCalls.count, 51 + 3 * 43)
        XCTAssertEqual(trace.deadline, write.returnedAt + 1)
        XCTAssertLessThan(try XCTUnwrap(trace.acknowledgedAt), write.returnedAt + 1)
        XCTAssertTrue(trace.probes.dropFirst().allSatisfy { $0.model == "Mac14,9" && $0.fanMetadata?.count == 2 })
        XCTAssertEqual(try XCTUnwrap(status.requestedRPM[0]), rpm)
        XCTAssertNil(record?.pending); XCTAssertEqual(record?.capabilities.hasGlobalUnlock, false)
        XCTAssertNoThrow(try status.encodedReply())
    }

    // Through the real transport: a target that never appears stays
    // unconfirmed, and the helper then releases its own fans with the stop
    // sequence (automatic mode, then the zero reset targets) and no retry.
    func testNativeTargetThatNeverAppearsIsReleasedByTheHelper() throws {
        let (status, writes, record) = try run(visibleAfterTargetReads: nil)
        XCTAssertEqual(writes, ["F0Md", "F0Tg", "F0Md", "F0Tg", "F1Tg"])
        XCTAssertFalse(status.externalRecoveryRequired); XCTAssertNil(status.sessionID)
        XCTAssertEqual(status.mode, .paused); XCTAssertEqual(status.reason, FanActuator.selfRecoveredReason)
        XCTAssertTrue(status.requestedRPM.isEmpty)
        let receipt = try XCTUnwrap(status.selfRecoveryReceipt)
        XCTAssertTrue(["nativeTraceCapacity", "deadline"].contains(receipt.cause ?? ""))
        XCTAssertNotNil(receipt.confirmedAt)
        XCTAssertEqual(receipt.steps.map(\.operation), [.mode(fan: 0, manual: false), .target(fan: 0, rpm: 0), .target(fan: 1, rpm: 0)])
        XCTAssertTrue(receipt.steps.allSatisfy { $0.termination == "acknowledged" })
        XCTAssertEqual(receipt.settle.count, 2)
        // Status keeps the unconfirmed target's own trace; the release steps
        // are in the receipt with their readbacks.
        let trace = try XCTUnwrap(status.targetDiagnostic)
        XCTAssertEqual(trace.operation, receipt.unconfirmed); XCTAssertTrue(trace.evidenceOnly)
        XCTAssertLessThanOrEqual(trace.nativeCalls.count, AppleSMC.maximumDiagnosticCalls)
        XCTAssertTrue(receipt.steps.allSatisfy { !$0.probes.isEmpty && $0.probes.count == $0.observations })
        XCTAssertNoThrow(try status.encodedReply())
        XCTAssertNil(record, "The cleared hold leaves no ownership record.")
    }
}
