import Foundation
#if canImport(FanControlCore)
import FanControlCore
#endif

public protocol FanRecoveryPersistence {
    func load() throws -> FanRecoveryRecord?
    func save(_ record: FanRecoveryRecord) throws
    func remove() throws
    func acknowledgeManualMode(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                               validate: () throws -> Void) throws
    func acknowledgeBoundedOperation(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                                     validate: () throws -> Void) throws
    func retireAcknowledgementMarker(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord) throws
}

public extension FanRecoveryPersistence {
    func acknowledgeManualMode(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                               validate: () throws -> Void) throws {
        throw FanControlError.ownership("The recovery store cannot durably acknowledge a pending manual-mode operation.")
    }
    func acknowledgeBoundedOperation(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord,
                                     validate: () throws -> Void) throws {
        throw FanControlError.ownership("The recovery store cannot durably acknowledge a pending fan operation.")
    }
    // A store that stages no pending copy has nothing to retire.
    func retireAcknowledgementMarker(pending: FanRecoveryRecord, acknowledged: FanRecoveryRecord) throws {}
}

public struct FanRecoveryRecord: Codable, Equatable {
    public let version: Int
    public let bootID: String
    public let serviceGeneration: String
    public let artifactIdentity: String
    public let ownerSession: String
    public let capabilities: FanCapabilities
    public let baseline: FanControlObservation
    public var acknowledged: FanControlObservation
    public var pending: FanOperation?
    public var restorationStarted: Bool
    // Set durably before the helper's one automatic attempt to return its own
    // fans to automatic while `pending` is unconfirmed, so a restart or crash
    // loop cannot repeat it. Absent in records written before that existed.
    public var recoveryAttempted: Bool?
    // Set durably when the helper decided not to try by itself for this hold
    // (decision E-Q1). A restart no longer knows why the command is
    // unconfirmed, so without this it would try. Absent in older records.
    public var recoveryDeclined: Bool?
    var automaticRecoveryClosed: Bool { recoveryAttempted == true || recoveryDeclined == true }

    // A persisted intent may have reached firmware even if the process died
    // before recording its receipt. No other intent ever overwrites it. It is
    // retired only by explicit external recovery, or after this helper's own
    // bounded release attempt has passed its settle check.
    public var requiresExternalRecovery: Bool { pending != nil }

    public init(bootID: String, serviceGeneration: String, artifactIdentity: String, ownerSession: String,
                capabilities: FanCapabilities, baseline: FanControlObservation) {
        version = 2; self.bootID = bootID; self.serviceGeneration = serviceGeneration
        self.artifactIdentity = artifactIdentity; self.ownerSession = ownerSession; self.capabilities = capabilities
        self.baseline = baseline; acknowledged = baseline; pending = nil; restorationStarted = false
    }

    public func validate() throws {
        try capabilities.validate()
        guard version == 2, UUID(uuidString: bootID) != nil, UUID(uuidString: serviceGeneration) != nil,
              UUID(uuidString: ownerSession) != nil, !artifactIdentity.isEmpty, baseline.isFullyAutomatic,
              Set(baseline.fans.map(\.id)) == Set(capabilities.fans.map(\.id)),
              Set(acknowledged.fans.map(\.id)) == Set(capabilities.fans.map(\.id)) else {
            throw FanControlError.ownership("The fan recovery record is invalid; manual recovery is required.")
        }
        if let pending {
            switch pending {
            case .globalUnlock: guard capabilities.hasGlobalUnlock else { throw FanControlError.invalid("Invalid recovery unlock.") }
            case .mode(let id, _):
                guard capabilities.fans.contains(where: { $0.id == id }) else { throw FanControlError.invalid("Invalid recovery fan.") }
            case .target(let id, let rpm):
                guard let fan = capabilities.fans.first(where: { $0.id == id }), rpm.isFinite,
                      rpm == 0 || (fan.minimumRPM...fan.maximumRPM).contains(rpm) else {
                    throw FanControlError.invalid("Invalid recovery target.")
                }
            }
        }
    }

    public func matches(_ observation: FanControlObservation) -> Bool {
        Self.matches(acknowledged, observation) || pending.map {
            Self.matches(Self.predict($0, from: acknowledged), observation)
        } == true
    }

    // A manual-mode write does not choose a target. Firmware can advance its
    // automatic target between the pre-write read and the mode taking effect.
    // Admit that entry target only for the fan whose automatic mode we are
    // changing; every other owned fan and the global unlock must still match.
    fileprivate func matchesManualEntry(_ observation: FanControlObservation) -> Bool {
        guard case .mode(let id, true) = pending,
              acknowledged.fans.first(where: { $0.id == id })?.isAutomatic == true,
              let fan = capabilities.fans.first(where: { $0.id == id }),
              let observed = observation.fans.first(where: { $0.id == id }),
              observed.mode == 1, observed.targetRPM.isFinite,
              (fan.minimumRPM...fan.maximumRPM).contains(observed.targetRPM) else { return false }
        var expected = Self.predict(.mode(fan: id, manual: true), from: acknowledged)
        expected.fans[expected.fans.firstIndex(where: { $0.id == id })!].targetRPM = observed.targetRPM
        return Self.matches(expected, observation)
    }

    static func matches(_ expected: FanControlObservation, _ observed: FanControlObservation) -> Bool {
        guard expected.globalUnlock == observed.globalUnlock, expected.fans.count == observed.fans.count else { return false }
        return expected.fans.allSatisfy { fan in
            guard let other = observed.fans.first(where: { $0.id == fan.id }) else { return false }
            if fan.isAutomatic && other.isAutomatic { return true }
            return fan.mode == other.mode && abs(fan.targetRPM - other.targetRPM) <= 2
        }
    }

    static func predict(_ operation: FanOperation, from state: FanControlObservation) -> FanControlObservation {
        var next = state
        switch operation {
        case .globalUnlock(let enabled): next.globalUnlock = enabled ? 1 : 0
        case .mode(let id, let manual):
            if let index = next.fans.firstIndex(where: { $0.id == id }) { next.fans[index].mode = manual ? 1 : 0 }
        case .target(let id, let rpm):
            if let index = next.fans.firstIndex(where: { $0.id == id }) { next.fans[index].targetRPM = rpm }
        }
        return next
    }

    // The same retained uncertainty: an operation is pending, and the two
    // records are equal apart from the self-recovery decisions.
    func sameUncertainty(as other: FanRecoveryRecord) -> Bool {
        guard pending != nil else { return false }
        var mine = self, theirs = other
        mine.recoveryAttempted = nil; mine.recoveryDeclined = nil
        theirs.recoveryAttempted = nil; theirs.recoveryDeclined = nil
        return mine == theirs
    }

    func sameLineage(as other: FanRecoveryRecord) -> Bool {
        version == other.version && bootID == other.bootID && serviceGeneration == other.serviceGeneration
            && artifactIdentity == other.artifactIdentity && ownerSession == other.ownerSession
            && capabilities == other.capabilities && baseline == other.baseline
            && (!other.restorationStarted || restorationStarted)
    }

    // Ordinary targets, zero release targets and mode releases; manual entry
    // keeps its own acknowledgement and global unlock its immediate readback.
    static func usesBoundedAcknowledgement(_ operation: FanOperation) -> Bool {
        switch operation {
        case .mode(_, let manual): return !manual
        case .target: return true
        case .globalUnlock: return false
        }
    }

    func acknowledgesManualMode(in pendingRecord: FanRecoveryRecord) -> Bool {
        guard case .mode(_, true)? = pendingRecord.pending else { return false }
        return acknowledgesPendingOperation(in: pendingRecord)
    }

    // True only for the exact acknowledged successor of a staged pending copy
    // of manual entry or a bounded operation; unlock writes stage no copy.
    func acknowledgesPendingOperation(in pendingRecord: FanRecoveryRecord) -> Bool {
        guard sameLineage(as: pendingRecord), let operation = pendingRecord.pending else { return false }
        if case .globalUnlock = operation { return false }
        func valid(_ state: FanControlObservation) -> Bool {
            state.capturedAt.isFinite && state.capturedAt >= 0
                && state.fans.count == capabilities.fans.count
                && Set(state.fans.map(\.id)) == Set(capabilities.fans.map(\.id))
                && state.fans.allSatisfy { $0.actualRPM.isFinite && $0.targetRPM.isFinite
                    && (0...20_000).contains($0.actualRPM) && (0...20_000).contains($0.targetRPM)
                    && [0, 1, 3].contains($0.mode) }
                && (capabilities.hasGlobalUnlock ? [0, 1].contains(state.globalUnlock ?? -1) : state.globalUnlock == nil)
        }
        return valid(pendingRecord.acknowledged) && valid(acknowledged)
            && (Self.matches(Self.predict(operation, from: pendingRecord.acknowledged), acknowledged)
                || pendingRecord.matchesManualEntry(acknowledged))
    }
}

// Runs exclusively on the serialized hardware executor. Every intent is made
// durable before mutation, and every receipt is read back before acknowledgement.
public struct FanModeDiagnosticTiming {
    public let clock: () -> TimeInterval
    public let pause: (TimeInterval) -> Void
    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.clock = clock; self.pause = pause
    }
}

// The controller supplies an atomic, lock-only safety publication. Unsupported
// callers fail closed before a timed manual entry can issue a native write.
public typealias FanManualModeCommit = (_ publish: (TimeInterval) throws -> Void) throws -> Void

public final class FanActuator {
    public private(set) var record: FanRecoveryRecord?
    public private(set) var lastManualModeDiagnostic: FanManualModeDiagnostic?
    // The most recent bounded acknowledgement trace: ordinary target, zero
    // release target or mode release. A write that fails before producing its
    // own trace leaves the previous one in place.
    public private(set) var lastTargetDiagnostic: FanTargetDiagnostic?
    // The most recent release write of a self-recovery attempt. Such a write
    // is confirmed by the same probes but is not journaled, and it never
    // replaces the unconfirmed command's own trace above.
    public private(set) var lastRecoveryStepDiagnostic: FanTargetDiagnostic?
    public var requiresExternalRecovery: Bool { record?.requiresExternalRecovery == true }
    // The most recent self-recovery attempt, cleared hold or not, and how
    // many attempts have produced a receipt. A request refused before any
    // attempt began changes neither.
    public private(set) var lastSelfRecoveryReceipt: FanSelfRecoveryReceipt?
    public private(set) var selfRecoveryAttempts = 0
    // The session whose automatic attempt this process has used or declined,
    // so a mark that could not be saved still closes it. Per hold: a later
    // session's hold has its own attempt.
    private var automaticRecoveryClosedSession: String?
    #if FAN_CONTROL_QUALIFICATION
    // Private qualification artifact only (E-Q7). When this returns true for a
    // journaled write, that write's acknowledgement is treated as unconfirmed.
    // The write and every observation stay native. Asked once per write;
    // release writes of a recovery attempt are never asked.
    public var qualificationWithholdsAcknowledgement: ((FanOperation) -> Bool)?
    private var withholdingAcknowledgement = false
    #endif
    // The helper always configures timing. Without it (fake tests only) every
    // operation keeps the original single immediate readback.
    public var boundedAcknowledgement: Bool { modeDiagnosticTiming != nil }
    public static let externalRecoveryReason = "A recorded fan operation is unconfirmed. Choose Restore automatic now, or set both fans to Auto in your independent fan utility, quit that utility, then verify external recovery here."
    // A record from another boot or helper build never authorizes a write,
    // so only external recovery applies to it.
    public static let externalRecoveryOnlyReason = "A fan operation recorded before the Mac restarted or by another helper version is unconfirmed. Set both fans to Auto in your independent fan utility, quit that utility, then verify external recovery here."
    public var holdReason: String { recordIsFromThisBootAndBuild ? Self.externalRecoveryReason : Self.externalRecoveryOnlyReason }
    public static let selfRecoveredReason = "A fan command could not be confirmed. The fans were returned to automatic and checked. Turn Fan Control on again to resume."
    // Acknowledgement outcomes after which the helper does not try by itself:
    // a known competing utility, fans that no longer match its record, a clock
    // it cannot trust, or a journal it could not write. An unknown outcome
    // (the intent could not be saved before the write) is treated the same.
    static let selfRecoveryExcludedCauses: Set<String> = [
        "conflictingUtility", "unexpectedOwnership", "invalidOrBackwardClock", "clockDidNotAdvance",
        "acknowledgementPersistenceFailure", "acknowledgementPublicationFailure"]
    public static func selfRecoveryEligible(cause: String?) -> Bool {
        cause.map { !selfRecoveryExcludedCauses.contains($0) } ?? false
    }
    // The settle check's second probe starts at least this long after the last
    // release acknowledgement.
    public static let selfRecoverySettleSeconds: TimeInterval = 1
    private let hardware: FanHardware
    private let persistence: FanRecoveryPersistence
    private let bootID: String
    private let serviceGeneration: String
    private let artifactIdentity: String
    private let modeDiagnosticTiming: FanModeDiagnosticTiming?

    public init(hardware: FanHardware, persistence: FanRecoveryPersistence, bootID: String,
                serviceGeneration: String, artifactIdentity: String,
                modeDiagnosticTiming: FanModeDiagnosticTiming? = nil) throws {
        self.hardware = hardware; self.persistence = persistence; self.bootID = bootID
        self.serviceGeneration = serviceGeneration; self.artifactIdentity = artifactIdentity
        self.modeDiagnosticTiming = modeDiagnosticTiming
        record = try persistence.load()
        try record?.validate()
    }

    public func establish(session: String, capabilities: FanCapabilities, baseline: FanControlObservation) throws {
        guard record == nil else { throw FanControlError.ownership("Resolve the interrupted fan session before enabling control.") }
        guard baseline.isFullyAutomatic else {
            throw FanControlError.ownership("Fans are already in custom control. Return them to automatic in your existing utility first.")
        }
        let next = FanRecoveryRecord(bootID: bootID, serviceGeneration: serviceGeneration,
                                    artifactIdentity: artifactIdentity, ownerSession: session,
                                    capabilities: capabilities, baseline: baseline)
        try next.validate()
        try persistence.save(next)
        record = next
        lastManualModeDiagnostic = nil
        lastTargetDiagnostic = nil
    }

    // `cancelled` admits native writes. `acknowledgementConflict` reports a
    // known competing utility at acknowledgement probe boundaries and before
    // publication. Once a bounded write has returned, nothing else cancels its
    // read-only confirmation before the fixed deadline. Manual entry checks
    // `confirmationCancelled` (lifecycle permission) before every native call
    // only when `acknowledgementConflict` is also supplied; otherwise it keeps
    // the combined `cancelled` check.
    public func mutate(_ operation: FanOperation, cancelled: () -> Bool,
                       confirmationCancelled: (() -> Bool)? = nil,
                       manualModePending: () -> Void = {},
                       manualModeCommit: FanManualModeCommit? = nil,
                       acknowledgementConflict: (() -> String?)? = nil) throws -> FanControlObservation {
        guard var next = record else { throw FanControlError.ownership("No recorded fan ownership.") }
        guard !next.requiresExternalRecovery else {
            throw FanControlError.ownership(Self.externalRecoveryReason)
        }
        guard !cancelled() else { throw FanControlError.cancelled }
        let timing: FanModeDiagnosticTiming?
        if case .mode(_, true) = operation { timing = modeDiagnosticTiming } else { timing = nil }
        // Ordinary targets, zero release targets and mode releases stay pending
        // until two complete probes confirm them. Global unlock is immediate.
        let boundedTiming = FanRecoveryRecord.usesBoundedAcknowledgement(operation) ? modeDiagnosticTiming : nil
        guard timing == nil || manualModeCommit != nil else {
            throw FanControlError.ownership("Manual-mode acknowledgement requires an atomic safety publication.")
        }
        guard boundedTiming == nil || acknowledgementConflict != nil else {
            throw FanControlError.ownership("Bounded fan acknowledgement requires a competing-utility check.")
        }
        if timing != nil || boundedTiming != nil { hardware.beginCommandDiagnosticCapture() }
        var captureOpen = timing != nil || boundedTiming != nil
        defer { if captureOpen { _ = hardware.endCommandDiagnosticCapture() } }
        let before = try hardware.readControlState(next.capabilities)
        guard next.matches(before) else {
            throw FanControlError.ownership("Fan mode or target changed unexpectedly. Control stopped without reasserting a target.")
        }
        let previous = next
        next.acknowledged = before; next.pending = operation
        try next.validate()
        // A save may rename the pending primary and then fail its sync. Latch
        // uncertainty before calling it, so failure cannot restore/overwrite a
        // potentially durable intent. Only an exact old record proves that
        // this intent was not published; perform has not been called yet.
        record = next
        do { try persistence.save(next) }
        catch {
            if let persisted = try? persistence.load(), persisted == previous { record = previous }
            throw error
        }
        #if FAN_CONTROL_QUALIFICATION
        // Asked once the intent is durable, immediately before the native
        // write, so a write refused earlier does not use up the run's one
        // withheld acknowledgement.
        withholdingAcknowledgement = qualificationWithholdsAcknowledgement?(operation) ?? false
        defer { withholdingAcknowledgement = false }
        #endif
        let performStartedAt = instant(timing ?? boundedTiming)
        do { try hardware.perform(operation, capabilities: next.capabilities, cancelled: cancelled) }
        catch {
            if let timing {
                var trace = FanManualModeDiagnostic(operation: operation, before: before,
                    performStartedAt: performStartedAt, performReturnedAt: instant(timing),
                    firstMismatchAt: nil, deadline: nil, probes: [], termination: "performFailure",
                    primaryFailure: error.localizedDescription)
                trace.endedAt = instant(timing)
                trace.nativeCalls = hardware.endCommandDiagnosticCapture(); captureOpen = false
                lastManualModeDiagnostic = trace
            }
            if let boundedTiming {
                var trace = FanTargetDiagnostic(operation: operation, before: before,
                    performStartedAt: performStartedAt, performReturnedAt: instant(boundedTiming),
                    probes: [], termination: "performFailure", primaryFailure: error.localizedDescription)
                trace.confirmationRule = confirmationRule(operation, record: next)
                trace.endedAt = instant(boundedTiming)
                trace.nativeCalls = hardware.endCommandDiagnosticCapture(); captureOpen = false
                lastTargetDiagnostic = trace
            }
            throw error
        }
        let performReturnedAt = instant(timing ?? boundedTiming)
        if let timing, let manualModeCommit {
            if let confirmationCancelled, acknowledgementConflict != nil {
                return try acknowledgeManualEntry(operation, pending: next, before: before,
                    performStartedAt: performStartedAt, performReturnedAt: performReturnedAt,
                    timing: timing, cancelled: confirmationCancelled, conflict: acknowledgementConflict,
                    manualModePending: manualModePending, commit: manualModeCommit, captureOpen: &captureOpen)
            }
            return try acknowledgeManualEntry(operation, pending: next, before: before,
                performStartedAt: performStartedAt, performReturnedAt: performReturnedAt,
                timing: timing, cancelled: cancelled, conflict: acknowledgementConflict,
                manualModePending: manualModePending, commit: manualModeCommit, captureOpen: &captureOpen)
        }
        if let boundedTiming, let acknowledgementConflict {
            return try acknowledgeBounded(operation, pending: next, before: before,
                performStartedAt: performStartedAt, performReturnedAt: performReturnedAt,
                timing: boundedTiming, conflict: acknowledgementConflict, captureOpen: &captureOpen)
        }
        let after = try hardware.readControlState(next.capabilities)
        guard operationConfirmed(operation, observation: after), next.matches(after) else {
            throw FanControlError.hardware(mismatch(operation, before: before, after: after))
        }
        next.acknowledged = after; next.pending = nil
        try next.validate()
        try persistence.save(next); record = next
        return after
    }

    private func instant(_ timing: FanModeDiagnosticTiming?) -> TimeInterval? {
        guard let value = timing?.clock(), value.isFinite else { return nil }
        return value
    }

    private func diagnosticProbe(_ operation: FanOperation, record: FanRecoveryRecord,
                                 index: Int, startedAt: TimeInterval?, returnedAt: TimeInterval?,
                                 probe: FanFanProbe?, error: String? = nil,
                                 manualEntry: Bool = false) -> FanDiagnosticProbe {
        let observation = probe?.observation
        let valid = observation.map { validDiagnosticObservation($0, record: record,
            startedAt: startedAt, returnedAt: returnedAt) } == true
            && probe?.model == record.capabilities.model && probe?.fans == record.capabilities.fans
        var confirmed = valid && observation.map { acknowledgementConfirmed(operation, observation: $0, record: record) } == true
        #if FAN_CONTROL_QUALIFICATION
        if withholdingAcknowledgement { confirmed = false }
        #endif
        return FanDiagnosticProbe(index: index, startedAt: startedAt, returnedAt: returnedAt,
            observation: valid ? observation : nil,
            error: error ?? (valid ? nil : "Invalid native diagnostic observation: \(String(describing: observation))"),
            operationConfirmed: confirmed,
            ownershipMatches: valid && observation.map {
                record.matches($0) || (manualEntry && record.matchesManualEntry($0))
            } == true,
            model: probe?.model, fanMetadata: probe?.fans)
    }

    private func validDiagnosticObservation(_ state: FanControlObservation, record: FanRecoveryRecord,
                                            startedAt: TimeInterval?, returnedAt: TimeInterval?) -> Bool {
        guard let start = startedAt, let end = returnedAt, end >= start,
              state.capturedAt.isFinite, state.capturedAt >= start, state.capturedAt <= end,
              end - state.capturedAt < 3,
              state.fans.count == record.capabilities.fans.count,
              Set(state.fans.map(\.id)) == Set(record.capabilities.fans.map(\.id)),
              state.fans.allSatisfy({ $0.actualRPM.isFinite && $0.targetRPM.isFinite
                  && (0...20_000).contains($0.actualRPM) && (0...20_000).contains($0.targetRPM)
                  && [0, 1, 3].contains($0.mode) }),
              (record.capabilities.hasGlobalUnlock ? [0, 1].contains(state.globalUnlock ?? -1) : state.globalUnlock == nil)
        else { return false }
        return true
    }

    // Complete probes start at least 100 ms apart and are front-loaded. When
    // receipts and the probe cap leave room for only a final pair and no match
    // is pending, that pair starts late: an effect first visible up to about
    // native return + 0.7 s can then still be acknowledged and saved before
    // the unchanged deadline. The pair keeps 100 ms spacing and leaves about
    // 0.15 s after its second probe's boundary checks; the durable save and
    // the publication check (about 15–20 ms on Mac14,9) come out of that.
    // A probe's duration includes its competing-utility boundary checks.
    static let minimumProbeSpacing: TimeInterval = 0.1
    static let finalPairLead: TimeInterval = 0.3
    static let finalPairSaveMargin: TimeInterval = 0.15

    private func nextProbeStart(after latest: TimeInterval, deadline: TimeInterval, consecutive: Int,
                                remainingProbes: Int, lastProbeDuration: TimeInterval) -> TimeInterval {
        let spaced = latest + Self.minimumProbeSpacing
        guard consecutive == 0, remainingProbes == 2 else { return spaced }
        let lead = max(Self.finalPairLead, Self.minimumProbeSpacing + 2 * lastProbeDuration + Self.finalPairSaveMargin)
        return max(spaced, deadline - lead)
    }

    // Complete probes that still fit the receipt capacity and the probe cap,
    // assuming each uses what the previous one did (its reservation before).
    private func probesRemaining(needed: Int, perProbe: Int, cap: Int) -> Int {
        var capacity = hardware.commandDiagnosticCapacityRemaining, count = 0
        while count < cap && capacity >= needed { count += 1; capacity -= max(1, perProbe) }
        return count
    }

    // Short pauses keep each stop check close to its clock; a late final pair
    // needs proportionally more of them than the usual 100 ms spacing.
    private static func waitSteps(from latest: TimeInterval, until next: TimeInterval) -> Int {
        let steps = ((next - latest) / 0.01).rounded(.up)
        guard steps.isFinite else { return 12 }
        return max(12, Int(min(118, max(0, steps))) + 2)
    }

    private func acknowledgeManualEntry(_ operation: FanOperation, pending: FanRecoveryRecord,
                                        before: FanControlObservation, performStartedAt: TimeInterval?,
                                        performReturnedAt: TimeInterval?, timing: FanModeDiagnosticTiming,
                                        cancelled: () -> Bool, conflict: (() -> String?)?,
                                        manualModePending: () -> Void,
                                        commit: FanManualModeCommit,
                                        captureOpen: inout Bool) throws -> FanControlObservation {
        let write = hardware.commandDiagnosticWrite
        let deadline = write.flatMap { $0.returnedAt.isFinite ? $0.returnedAt + 1 : nil }
        var diagnostic = FanManualModeDiagnostic(operation: operation, before: before,
            performStartedAt: performStartedAt, performReturnedAt: performReturnedAt,
            firstMismatchAt: nil, deadline: deadline, probes: [],
            termination: "probeLimit", primaryFailure: "")
        diagnostic.nativeWriteReturnedAt = write.flatMap { $0.returnedAt.isFinite ? $0.returnedAt : nil }
        #if FAN_CONTROL_QUALIFICATION
        if withholdingAcknowledgement { diagnostic.qualificationWithheld = true }
        #endif
        defer {
            diagnostic.endedAt = instant(timing)
            diagnostic.deadlineOverrun = diagnostic.endedAt.flatMap { end in deadline.map { end > $0 } } ?? false
            diagnostic.nativeCalls = hardware.endCommandDiagnosticCapture(); captureOpen = false
            lastManualModeDiagnostic = diagnostic
        }
        guard let write, let deadline, deadline.isFinite,
              let start = performStartedAt, let returned = performReturnedAt,
              case .mode(let fan, true) = operation,
              write.command == 6, write.key == pending.capabilities.fans.first(where: { $0.id == fan })?.modeKey,
              write.requestedValueBytes == 1, write.requestedValueHex == "01",
              write.kernelResult == 0, write.returnedStructBytes == 80,
              write.firmwareResult == 0, write.firmwareStatus == 0,
              write.startedAt.isFinite, write.returnedAt.isFinite,
              start <= write.startedAt, write.startedAt <= write.returnedAt, write.returnedAt <= returned else {
            diagnostic.termination = "invalidNativeWriteReceipt"
            diagnostic.primaryFailure = "The returned manual-mode write has no valid correlated native receipt; recovery remains pending."
            throw FanControlError.hardware(diagnostic.primaryFailure)
        }
        var latest = returned
        func stopReason() -> String? {
            guard let now = instant(timing), now >= latest else { return "invalidOrBackwardClock" }
            latest = now
            let revoked = cancelled()
            guard let checkedAt = instant(timing), checkedAt >= latest else { return "invalidOrBackwardClock" }
            latest = checkedAt
            if revoked { return "cancelledOrPermissionRevoked" }
            if checkedAt + 0.000_001 >= deadline { return "deadline" }
            return nil
        }
        // With a separate competing-utility check, process enumeration runs
        // only before and after each probe and before publication.
        func competingUtility() -> String? {
            guard let conflict, let utility = conflict() else { return nil }
            diagnostic.cancellationCause = "\(utility) appeared."
            return utility
        }
        manualModePending()
        var consecutive = 0
        var previousCapture: TimeInterval?
        var previousMatch: FanControlObservation?
        var accepted: FanControlObservation?
        var probeCalls = 8 + pending.capabilities.fans.count * 20
        var probeDuration: TimeInterval = 0
        // The immediate probe plus at most ten extra attempts fit the same
        // fixed budget. Full probes include metadata and never freshen sensors.
        for index in 0...10 {
            if let reason = stopReason() { diagnostic.termination = reason; break }
            let neededCalls = 8 + pending.capabilities.fans.count * 20
            guard hardware.commandDiagnosticCapacityRemaining >= neededCalls else {
                diagnostic.termination = "nativeTraceCapacity"; break
            }
            if index > 0 {
                let nextProbeAt = nextProbeStart(after: latest, deadline: deadline, consecutive: consecutive,
                    remainingProbes: probesRemaining(needed: neededCalls, perProbe: probeCalls, cap: 11 - index),
                    lastProbeDuration: probeDuration)
                var waitStopped = false
                for _ in 0..<Self.waitSteps(from: latest, until: min(nextProbeAt, deadline)) {
                    if let reason = stopReason() { diagnostic.termination = reason; waitStopped = true; break }
                    let remaining = min(nextProbeAt, deadline) - latest
                    if remaining <= 0.000_001 { break }
                    let prior = latest
                    timing.pause(min(0.01, remaining))
                    if let reason = stopReason() { diagnostic.termination = reason; waitStopped = true; break }
                    if latest <= prior { diagnostic.termination = "clockDidNotAdvance"; waitStopped = true; break }
                }
                if waitStopped { break }
                if let reason = stopReason() { diagnostic.termination = reason; break }
            }
            let boundaryStartedAt = instant(timing)
            if conflict != nil {
                if competingUtility() != nil { diagnostic.termination = "conflictingUtility"; break }
                if let reason = stopReason() { diagnostic.termination = reason; break }
            }
            let capacityBefore = hardware.commandDiagnosticCapacityRemaining
            let startedAt = instant(timing)
            do {
                let native = try hardware.probeFans(pending.capabilities, cancelled: { stopReason() != nil })
                let probe = diagnosticProbe(operation, record: pending, index: index,
                    startedAt: startedAt, returnedAt: instant(timing), probe: native, manualEntry: true)
                diagnostic.probes.append(probe)
                probeCalls = capacityBefore - hardware.commandDiagnosticCapacityRemaining
                if !probe.operationConfirmed && diagnostic.firstMismatchAt == nil {
                    diagnostic.firstMismatchAt = probe.returnedAt
                    diagnostic.primaryFailure = mismatch(operation, before: before, after: native.observation)
                }
                if let reason = stopReason() { diagnostic.termination = reason; break }
                if probe.error != nil { diagnostic.termination = "invalidObservation"; break }
                if !probe.ownershipMatches { diagnostic.termination = "unexpectedOwnership"; break }
                guard previousCapture.map({ native.observation.capturedAt > $0 }) ?? true else {
                    diagnostic.termination = "nonDistinctObservation"; break
                }
                previousCapture = native.observation.capturedAt
                if competingUtility() != nil { diagnostic.termination = "conflictingUtility"; break }
                if let begin = boundaryStartedAt, let end = instant(timing) { probeDuration = max(0, end - begin) }
                if probe.operationConfirmed {
                    // The firmware-selected entry target must agree in two
                    // distinct probes before it becomes our owned baseline.
                    consecutive = previousMatch.map { FanRecoveryRecord.matches($0, native.observation) } == true
                        ? consecutive + 1 : 1
                    previousMatch = native.observation
                } else {
                    consecutive = 0; previousMatch = nil
                }
                if consecutive == 2 {
                    accepted = native.observation; diagnostic.termination = "probesConfirmed"; break
                }
            } catch {
                diagnostic.probes.append(diagnosticProbe(operation, record: pending, index: index,
                    startedAt: startedAt, returnedAt: instant(timing), probe: nil,
                    error: error.localizedDescription))
                diagnostic.termination = stopReason() ?? "readFailure"
                break
            }
        }
        guard let accepted else {
            if diagnostic.primaryFailure.isEmpty {
                diagnostic.primaryFailure = "Manual-mode acknowledgement failed: \(diagnostic.termination); the pending operation is retained."
            }
            throw FanControlError.hardware(diagnostic.primaryFailure)
        }
        var acknowledged = pending
        acknowledged.acknowledged = accepted; acknowledged.pending = nil
        var publishing = false
        do {
            try acknowledged.validate()
            try persistence.acknowledgeManualMode(pending: pending, acknowledged: acknowledged, validate: {
                guard self.record == pending else { throw FanControlError.ownership("Pending fan ownership changed during acknowledgement.") }
                if let reason = stopReason() { throw FanControlError.hardware(reason) }
            })
            if let reason = stopReason() { throw FanControlError.hardware(reason) }
            publishing = true
            if let utility = competingUtility() {
                throw FanControlError.ownership("\(utility) appeared before manual-mode acknowledgement publication.")
            }
            try commit { committedAt in
                guard self.record == pending else {
                    throw FanControlError.ownership("Pending fan ownership changed at acknowledgement publication.")
                }
                guard committedAt.isFinite, committedAt >= latest else {
                    throw FanControlError.hardware("invalidOrBackwardClock")
                }
                latest = committedAt
                guard committedAt + 0.000_001 < deadline else { throw FanControlError.hardware("deadline") }
                self.record = acknowledged
                diagnostic.acknowledgedAt = committedAt
                diagnostic.termination = "acknowledged"
                diagnostic.evidenceOnly = false; diagnostic.pendingRetained = false
            }
        } catch {
            record = pending
            diagnostic.acknowledgedAt = nil
            diagnostic.evidenceOnly = true; diagnostic.pendingRetained = true
            let conflicted = publishing && diagnostic.cancellationCause != nil ? "conflictingUtility" : nil
            diagnostic.termination = stopReason() ?? conflicted
                ?? (publishing ? "acknowledgementPublicationFailure" : "acknowledgementPersistenceFailure")
            diagnostic.acknowledgementError = error.localizedDescription
            if diagnostic.primaryFailure.isEmpty { diagnostic.primaryFailure = error.localizedDescription }
            throw FanControlError.hardware(diagnostic.primaryFailure)
        }
        return accepted
    }

    // Expected command-6 payload for a target, matching the transport's
    // little-endian `flt ` and big-endian `fpe2` encodings. Zero is the
    // release target written after automatic mode is confirmed.
    static func targetPayloadHex(_ rpm: Double, encoding: String) -> String? {
        guard rpm.isFinite, rpm >= 0 else { return nil }
        let bytes: [UInt8]
        switch encoding {
        case "flt " where rpm <= 20_000:
            let bits = Float(rpm).bitPattern
            bytes = (0..<4).map { UInt8(truncatingIfNeeded: bits >> (8 * $0)) }
        case "fpe2" where rpm <= 16_383.75:
            let fixed = UInt16((rpm * 4).rounded())
            bytes = [UInt8(fixed >> 8), UInt8(truncatingIfNeeded: fixed)]
        default: return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // The key and exact payload a bounded write must have been sent with.
    private func expectedWrite(_ operation: FanOperation, record: FanRecoveryRecord) -> (key: String, payload: String)? {
        switch operation {
        case .target(let id, let rpm):
            guard let fan = record.capabilities.fans.first(where: { $0.id == id }),
                  let payload = Self.targetPayloadHex(rpm, encoding: fan.targetEncoding) else { return nil }
            return ("F\(id)Tg", payload)
        case .mode(let id, let manual):
            guard let fan = record.capabilities.fans.first(where: { $0.id == id }) else { return nil }
            return (fan.modeKey, manual ? "01" : "00")
        case .globalUnlock: return nil
        }
    }

    // Accept only the capture's last command-6 receipt for this fan's key and
    // exact payload, returned successfully inside the perform window.
    private func correlateWrite(_ trace: inout FanTargetDiagnostic, record: FanRecoveryRecord) {
        guard let write = hardware.commandDiagnosticWrite,
              let expected = expectedWrite(trace.operation, record: record),
              let start = trace.performStartedAt, let returned = trace.performReturnedAt,
              write.command == 6, write.key == expected.key,
              write.requestedValueBytes == UInt32(expected.payload.count / 2),
              write.requestedValueHex == expected.payload,
              write.kernelResult == 0, write.returnedStructBytes == 80,
              write.firmwareResult == 0, write.firmwareStatus == 0,
              write.startedAt.isFinite, write.returnedAt.isFinite,
              start <= write.startedAt, write.startedAt <= write.returnedAt, write.returnedAt <= returned else { return }
        trace.nativeWrite = write
        trace.nativeWriteReturnedAt = write.returnedAt
        trace.deadline = write.returnedAt + 1
    }

    private func immediateProbe(_ operation: FanOperation, record: FanRecoveryRecord,
                                startedAt: TimeInterval?, returnedAt: TimeInterval?,
                                observation: FanControlObservation?, error: String? = nil) -> FanDiagnosticProbe {
        // The immediate readback has no model/metadata; the raw observation
        // stays in the trace's `after` field even when this label rejects it.
        let valid = observation.map { validDiagnosticObservation($0, record: record,
            startedAt: startedAt, returnedAt: returnedAt) } == true
        var confirmed = valid && observation.map { acknowledgementConfirmed(operation, observation: $0, record: record) } == true
        #if FAN_CONTROL_QUALIFICATION
        if withholdingAcknowledgement { confirmed = false }
        #endif
        return FanDiagnosticProbe(index: 0, startedAt: startedAt, returnedAt: returnedAt,
            observation: valid ? observation : nil,
            error: error ?? (valid ? nil : "Invalid immediate readback: \(String(describing: observation))"),
            operationConfirmed: confirmed,
            ownershipMatches: valid && observation.map { record.matches($0) } == true)
    }

    // Runs after one returned ordinary target, zero release target or mode
    // release. Probe 0, the immediate readback, is evidence only. Complete
    // probes start at least 100 ms apart, and two consecutive distinct matches
    // must be durable and published before the fixed deadline: correlated
    // native return + 1 s, never reset or extended. Lifecycle revocation has
    // already blocked every later write and does not cancel these read-only
    // probes; a known competing utility, a changed or invalid observation, a
    // clock fault, receipt capacity or the deadline does. An issued synchronous
    // call can still return late; it is retained and admits no further call.
    private func acknowledgeBounded(_ operation: FanOperation, pending: FanRecoveryRecord,
                                    before: FanControlObservation, performStartedAt: TimeInterval?,
                                    performReturnedAt: TimeInterval?, timing: FanModeDiagnosticTiming,
                                    conflict: () -> String?, captureOpen: inout Bool,
                                    journal: Bool = true) throws -> FanControlObservation {
        var diagnostic = FanTargetDiagnostic(operation: operation, before: before,
            performStartedAt: performStartedAt, performReturnedAt: performReturnedAt,
            probes: [], termination: "probeLimit", primaryFailure: "")
        diagnostic.confirmationRule = confirmationRule(operation, record: pending)
        #if FAN_CONTROL_QUALIFICATION
        if withholdingAcknowledgement { diagnostic.qualificationWithheld = true }
        #endif
        defer {
            // An acknowledged trace ends at its publication; retiring the
            // staged pending copy follows and is reported separately.
            if diagnostic.endedAt == nil { diagnostic.endedAt = instant(timing) }
            diagnostic.deadlineOverrun = diagnostic.endedAt.flatMap { end in diagnostic.deadline.map { end > $0 } } ?? false
            diagnostic.nativeCalls = hardware.endCommandDiagnosticCapture(); captureOpen = false
            // A recovery step never replaces the unconfirmed command's trace.
            if journal { lastTargetDiagnostic = diagnostic } else { lastRecoveryStepDiagnostic = diagnostic }
        }
        func failure(_ termination: String, _ text: String? = nil) -> FanControlError {
            diagnostic.termination = termination
            if diagnostic.primaryFailure.isEmpty {
                diagnostic.primaryFailure = text ?? "Bounded fan acknowledgement failed: \(termination); the pending operation is retained."
            }
            return .hardware(diagnostic.primaryFailure)
        }
        let readStartedAt = instant(timing)
        let after: FanControlObservation
        do { after = try hardware.readControlState(pending.capabilities) }
        catch {
            diagnostic.probes = [immediateProbe(operation, record: pending, startedAt: readStartedAt,
                returnedAt: instant(timing), observation: nil, error: error.localizedDescription)]
            correlateWrite(&diagnostic, record: pending)
            diagnostic.termination = "immediateReadFailure"; diagnostic.primaryFailure = error.localizedDescription
            throw error
        }
        let readReturnedAt = instant(timing)
        let immediate = immediateProbe(operation, record: pending, startedAt: readStartedAt,
            returnedAt: readReturnedAt, observation: after)
        diagnostic.probes = [immediate]
        // Real readback rejects non-finite values; a fake or future transport
        // must not make the whole recovery reply unencodable. The probe-0 error
        // still describes any rejected value.
        diagnostic.after = (try? JSONEncoder().encode(after)) == nil ? nil : after
        if !immediate.operationConfirmed {
            diagnostic.firstMismatchAt = readReturnedAt
            diagnostic.primaryFailure = mismatch(operation, before: before, after: after)
        }
        correlateWrite(&diagnostic, record: pending)
        guard let deadline = diagnostic.deadline else {
            throw failure("invalidNativeWriteReceipt",
                "The returned fan write has no valid correlated native receipt; recovery remains pending.")
        }
        guard var latest = readReturnedAt, let returned = performReturnedAt, latest >= returned else {
            throw failure("invalidOrBackwardClock")
        }
        func stopReason() -> String? {
            guard let now = instant(timing), now >= latest else { return "invalidOrBackwardClock" }
            latest = now
            if now + 0.000_001 >= deadline { return "deadline" }
            return nil
        }
        // Process enumeration is costly, so a known competing utility is
        // checked at probe boundaries and before publication, not per call.
        func competingUtility() -> String? {
            guard let utility = conflict() else { return nil }
            diagnostic.cancellationCause = "\(utility) appeared."
            return utility
        }
        if let reason = stopReason() { throw failure(reason) }
        if immediate.error != nil { throw failure("invalidImmediateObservation") }
        if !immediate.ownershipMatches { throw failure("unexpectedOwnership") }
        var previousCapture = after.capturedAt
        var consecutive = 0
        var accepted: FanControlObservation?
        var probeCalls = 8 + pending.capabilities.fans.count * 20
        // Before any complete probe, the immediate readback's duration stands in.
        var probeDuration: TimeInterval = 0
        if let start = readStartedAt, let end = readReturnedAt { probeDuration = max(0, end - start) }
        probing: for index in 1...10 {
            if let reason = stopReason() { diagnostic.termination = reason; break }
            let neededCalls = 8 + pending.capabilities.fans.count * 20
            guard hardware.commandDiagnosticCapacityRemaining >= neededCalls else {
                diagnostic.termination = "nativeTraceCapacity"; break
            }
            let nextProbeAt = nextProbeStart(after: latest, deadline: deadline, consecutive: consecutive,
                remainingProbes: probesRemaining(needed: neededCalls, perProbe: probeCalls, cap: 11 - index),
                lastProbeDuration: probeDuration)
            for _ in 0..<Self.waitSteps(from: latest, until: min(nextProbeAt, deadline)) {
                if let reason = stopReason() { diagnostic.termination = reason; break probing }
                let remaining = min(nextProbeAt, deadline) - latest
                if remaining <= 0.000_001 { break }
                let prior = latest
                timing.pause(min(0.01, remaining))
                if let reason = stopReason() { diagnostic.termination = reason; break probing }
                if latest <= prior { diagnostic.termination = "clockDidNotAdvance"; break probing }
            }
            let boundaryStartedAt = instant(timing)
            if competingUtility() != nil { diagnostic.termination = "conflictingUtility"; break }
            if let reason = stopReason() { diagnostic.termination = reason; break }
            let capacityBefore = hardware.commandDiagnosticCapacityRemaining
            let startedAt = instant(timing)
            do {
                let native = try hardware.probeFans(pending.capabilities, cancelled: { stopReason() != nil })
                let probe = diagnosticProbe(operation, record: pending, index: index,
                    startedAt: startedAt, returnedAt: instant(timing), probe: native)
                diagnostic.probes.append(probe)
                probeCalls = capacityBefore - hardware.commandDiagnosticCapacityRemaining
                if !probe.operationConfirmed && diagnostic.firstMismatchAt == nil {
                    diagnostic.firstMismatchAt = probe.returnedAt
                    diagnostic.primaryFailure = mismatch(operation, before: before, after: native.observation)
                }
                if let reason = stopReason() { diagnostic.termination = reason; break }
                if probe.error != nil { diagnostic.termination = "invalidObservation"; break }
                if !probe.ownershipMatches { diagnostic.termination = "unexpectedOwnership"; break }
                guard native.observation.capturedAt > previousCapture else {
                    diagnostic.termination = "nonDistinctObservation"; break
                }
                previousCapture = native.observation.capturedAt
                if competingUtility() != nil { diagnostic.termination = "conflictingUtility"; break }
                if let begin = boundaryStartedAt, let end = instant(timing) { probeDuration = max(0, end - begin) }
                consecutive = probe.operationConfirmed ? consecutive + 1 : 0
                if consecutive == 2 {
                    accepted = native.observation; diagnostic.termination = "probesConfirmed"; break
                }
            } catch {
                diagnostic.probes.append(diagnosticProbe(operation, record: pending, index: index,
                    startedAt: startedAt, returnedAt: instant(timing), probe: nil,
                    error: error.localizedDescription))
                diagnostic.termination = stopReason() ?? "readFailure"
                break
            }
        }
        guard let accepted else { throw failure(diagnostic.termination) }
        if !journal {
            // A self-recovery release write: `pending` is an in-memory working
            // record. The unconfirmed command stays pending in the journal, so
            // nothing is saved or published here.
            if competingUtility() != nil { throw failure("conflictingUtility") }
            if let reason = stopReason() { throw failure(reason) }
            diagnostic.acknowledgedAt = latest; diagnostic.endedAt = latest
            diagnostic.termination = "acknowledged"
            diagnostic.evidenceOnly = false; diagnostic.pendingRetained = false
            return accepted
        }
        var acknowledged = pending
        acknowledged.acknowledged = accepted; acknowledged.pending = nil
        var publishing = false
        do {
            try acknowledged.validate()
            try persistence.acknowledgeBoundedOperation(pending: pending, acknowledged: acknowledged, validate: {
                guard self.record == pending else { throw FanControlError.ownership("Pending fan ownership changed during acknowledgement.") }
                if let reason = stopReason() { throw FanControlError.hardware(reason) }
            })
            publishing = true
            // Memory-only publication on the serialized hardware executor, so
            // every successor write, including queued restoration, follows it.
            if let utility = competingUtility() {
                throw FanControlError.ownership("\(utility) appeared before fan acknowledgement publication.")
            }
            if let reason = stopReason() { throw FanControlError.hardware(reason) }
            guard self.record == pending else {
                throw FanControlError.ownership("Pending fan ownership changed at acknowledgement publication.")
            }
            self.record = acknowledged
            diagnostic.acknowledgedAt = latest; diagnostic.endedAt = latest
            diagnostic.termination = "acknowledged"
            diagnostic.evidenceOnly = false; diagnostic.pendingRetained = false
        } catch {
            record = pending
            diagnostic.acknowledgedAt = nil
            diagnostic.evidenceOnly = true; diagnostic.pendingRetained = true
            let conflicted = publishing && diagnostic.cancellationCause != nil ? "conflictingUtility" : nil
            diagnostic.termination = stopReason() ?? conflicted
                ?? (publishing ? "acknowledgementPublicationFailure" : "acknowledgementPersistenceFailure")
            diagnostic.acknowledgementError = error.localizedDescription
            if diagnostic.primaryFailure.isEmpty { diagnostic.primaryFailure = error.localizedDescription }
            throw FanControlError.hardware(diagnostic.primaryFailure)
        }
        // Publication succeeded: the staged pending copy is no longer needed.
        // A failed deletion keeps it, so a restart conservatively holds.
        do {
            try persistence.retireAcknowledgementMarker(pending: pending, acknowledged: acknowledged)
            diagnostic.acknowledgementMarkerRetired = true
        } catch {
            diagnostic.acknowledgementMarkerRetired = false
            diagnostic.acknowledgementMarkerError = error.localizedDescription
        }
        return accepted
    }

    private func mismatch(_ operation: FanOperation, before: FanControlObservation, after: FanControlObservation) -> String {
        "Fan command was sent, but its effective state was not confirmed by readback. Operation: \(receiptJSON(operation)); before: \(receiptJSON(before)); after: \(receiptJSON(after))."
    }

    public func verifyOwnership(conflict: String?) throws -> FanControlObservation {
        guard let record else { throw FanControlError.ownership("No recorded fan ownership.") }
        guard !record.requiresExternalRecovery else { throw FanControlError.ownership(Self.externalRecoveryReason) }
        if let conflict { throw FanControlError.ownership("\(conflict) is running. Restoration is pending until ownership can be reconciled.") }
        let observed = try hardware.readControlState(record.capabilities)
        // An old record never authorizes a write after a reboot or replacement.
        guard record.bootID == bootID, record.artifactIdentity == artifactIdentity else {
            if observed.isFullyAutomatic { return observed }
            throw FanControlError.ownership("Interrupted ownership belongs to another boot or helper artifact. Return fans to automatic externally.")
        }
        guard record.matches(observed) || observed.isFullyAutomatic else {
            throw FanControlError.ownership("Observed fan settings no longer match this helper's ownership record. Return them to automatic externally.")
        }
        return observed
    }

    public func restore(conflict: @escaping () -> String?, cancelled: () -> Bool = { false }) throws -> FanControlObservation? {
        guard var next = record else { return nil } // Idle removal does not touch hardware.
        guard !next.requiresExternalRecovery else { throw FanControlError.ownership(Self.externalRecoveryReason) }
        var state = try verifyOwnership(conflict: conflict())
        if state.isFullyAutomatic {
            try persistence.remove(); record = nil
            return state
        }
        next.restorationStarted = true
        try persistence.save(next); record = next
        for fan in next.capabilities.fans {
            guard !cancelled(), conflict() == nil else { throw FanControlError.cancelled }
            // With timing, each release write stays pending until its bounded
            // acknowledgement. A failure leaves it pending; the controller then
            // decides on the helper's one recovery attempt.
            if let reading = state.fans.first(where: { $0.id == fan.id }), !reading.isAutomatic {
                state = try mutate(.mode(fan: fan.id, manual: false), cancelled: { cancelled() || conflict() != nil },
                                   acknowledgementConflict: conflict)
            }
            // Reset only a fan affected by this recorded session.
            state = try mutate(.target(fan: fan.id, rpm: 0), cancelled: { cancelled() || conflict() != nil },
                               acknowledgementConflict: conflict)
        }
        if next.capabilities.hasGlobalUnlock && state.globalUnlock != next.baseline.globalUnlock {
            state = try mutate(.globalUnlock(false), cancelled: { cancelled() || conflict() != nil })
        }
        state = try hardware.readControlState(next.capabilities)
        guard state.isFullyAutomatic else { throw FanControlError.hardware("Automatic fan mode/unlock restoration is not confirmed.") }
        try persistence.remove(); record = nil
        return state
    }

    // Records from another boot or helper build never authorize a write.
    public var recordIsFromThisBootAndBuild: Bool {
        record.map { $0.bootID == bootID && $0.artifactIdentity == artifactIdentity } ?? false
    }

    // Whether this hold's one automatic attempt is still open: bounded
    // acknowledgement, a pending record from this boot and build, and no
    // attempt or decline recorded for it on disk or in this process.
    public var automaticRecoveryAvailable: Bool {
        guard boundedAcknowledgement, let record, record.pending != nil, recordIsFromThisBootAndBuild else { return false }
        return !record.automaticRecoveryClosed && automaticRecoveryClosedSession != record.ownerSession
    }

    // E-Q1: the helper does not try by itself for this hold. The decision is
    // journaled so that a restart, which no longer knows why the command is
    // unconfirmed, does not try either. No fan is read or written. Returns
    // false when the decision could not be saved; it then holds only for the
    // life of this process.
    @discardableResult public func declineAutomaticRecovery() -> Bool {
        guard automaticRecoveryAvailable, var declined = record else { return false }
        automaticRecoveryClosedSession = declined.ownerSession
        declined.recoveryDeclined = true
        do { try persistence.save(declined) }
        catch {
            // A save can become durable and still report failure. Memory
            // follows the journal, so recovery and verification still agree.
            guard let persisted = try? persistence.load(), persisted == declined else { return false }
        }
        record = declined
        return true
    }

    // Why the pending operation stayed unconfirmed and its own fixed deadline,
    // when this process produced its trace. A restart, or an intent whose save
    // failed before the write, has neither.
    public var unconfirmedCommand: (cause: String?, deadline: TimeInterval?) {
        guard let pending = record?.pending else { return (nil, nil) }
        if let trace = lastManualModeDiagnostic, trace.operation == pending, trace.pendingRetained,
           trace.termination != "acknowledged" {
            return (trace.termination, trace.deadline ?? trace.performReturnedAt.map { $0 + 1 })
        }
        if let trace = lastTargetDiagnostic, trace.operation == pending, trace.pendingRetained,
           trace.termination != "acknowledged" {
            return (trace.termination, trace.deadline ?? trace.performReturnedAt.map { $0 + 1 })
        }
        return (nil, nil)
    }

    // One bounded attempt to return this helper's own fans to automatic while
    // a command is unconfirmed (decisions E-Q1 to E-Q6). It never requests a
    // speed or manual mode: it issues the release sequence of a normal stop,
    // each write confirmed by the same two-probe rule, then a settle check. A
    // command that asked for manual mode or a speed is therefore never sent
    // again; one that was itself a release write is part of the sequence.
    // The unconfirmed command stays pending in the journal
    // throughout. The only durable changes are the attempt mark, saved before
    // anything else, and the record's removal after the settle check, so any
    // failure leaves the hold exactly as it was.
    //
    // `automatic` and `startup` run at most once per hold and only for an
    // eligible cause and fans that still match the record, at the start and
    // before every release write. Matching allows for the unconfirmed command
    // itself: at the start a fan named by a manual entry may read manual at
    // any target, and between writes the fans are compared with the previous
    // step's result, where the named fan may read anything. A start state in
    // which every fan and the unlock already read automatic is accepted
    // whatever the record says. The unlock release is preceded by the
    // utility check only, not by another match.
    // `explicit` is the owner's own request: it
    // may repeat and may run on unmatched fans. None runs for another boot or
    // helper build, or while a known competing utility is running, and none
    // writes the zero reset target to a fan that reads manual.
    public func recoverOwnedFans(trigger: FanSelfRecoveryTrigger, cause: String?, notBefore: TimeInterval?,
                                 conflict: @escaping () -> String?, cancelled: () -> Bool = { false },
                                 commit: () throws -> Void = {}) throws -> FanSelfRecoveryReceipt {
        guard let held = record, let unconfirmed = held.pending else {
            throw FanControlError.ownership("No unconfirmed fan operation awaits recovery.")
        }
        guard let timing = modeDiagnosticTiming else {
            throw FanControlError.unavailable("Returning fans to automatic needs bounded acknowledgement.")
        }
        guard held.bootID == bootID, held.artifactIdentity == artifactIdentity else {
            throw FanControlError.ownership("The unconfirmed fan operation belongs to another boot or helper build. Return fans to automatic externally, then verify recovery.")
        }
        if trigger != .explicit {
            guard !held.automaticRecoveryClosed, automaticRecoveryClosedSession != held.ownerSession else {
                throw FanControlError.ownership("The automatic recovery attempt for this fan operation was already used.")
            }
            guard Self.selfRecoveryEligible(cause: cause) else {
                throw FanControlError.ownership("This unconfirmed fan operation is not eligible for automatic recovery (\(cause ?? "unknown cause")).")
            }
        }
        guard let startedAt = instant(timing) else { throw FanControlError.hardware("invalidOrBackwardClock") }
        var receipt = FanSelfRecoveryReceipt(recoveryID: held.ownerSession, trigger: trigger, cause: cause,
                                             unconfirmed: unconfirmed, startedAt: startedAt)
        selfRecoveryAttempts += 1
        func fail(_ error: Error) -> Error {
            receipt.failure = error.localizedDescription
            lastSelfRecoveryReceipt = receipt
            return error
        }
        // The automatic decision is made once per hold. Journal it first; a
        // mark that cannot be saved still uses the attempt and writes nothing.
        // The owner's explicit request needs no mark, so it can also clear a
        // hold whose journal state refuses one.
        var current = held
        if trigger != .explicit {
            automaticRecoveryClosedSession = held.ownerSession
            current.recoveryAttempted = true
            do { try persistence.save(current) }
            catch {
                // A save can become durable and still report failure. Memory
                // follows the journal, so the owner's explicit request and
                // verification still find the two in agreement.
                if let persisted = try? persistence.load(), persisted == current { record = current }
                throw fail(error)
            }
            record = current
        }
        func stopped() -> Error? {
            if cancelled() { return FanControlError.cancelled }
            if let utility = conflict() {
                return FanControlError.ownership("\(utility) is running. The fans were left as they are.")
            }
            return nil
        }
        // Waits check cancellation every step and the utility at their end.
        func wait(until target: TimeInterval) throws {
            guard var latest = instant(timing), target - latest <= 3 else {
                throw FanControlError.hardware("invalidOrBackwardClock")
            }
            var steps = 0
            while latest + 0.000_001 < target {
                if cancelled() { throw FanControlError.cancelled }
                timing.pause(min(0.01, target - latest))
                guard let now = instant(timing), now > latest, steps < 400 else {
                    throw FanControlError.hardware("clockDidNotAdvance")
                }
                latest = now; steps += 1
            }
        }
        // The fan the unconfirmed command names. It is released even if it
        // reads automatic, because that command may still land.
        let named: Int?
        switch unconfirmed {
        case .mode(let id, _), .target(let id, _): named = id
        case .globalUnlock: named = nil
        }
        var working = current
        func step(_ operation: FanOperation) throws -> FanControlObservation {
            if let error = stopped() { throw error }
            hardware.beginCommandDiagnosticCapture()
            var captureOpen = true
            defer { if captureOpen { _ = hardware.endCommandDiagnosticCapture() } }
            let previous = lastRecoveryStepDiagnostic
            var issued = false
            do {
                let before = try hardware.readControlState(held.capabilities)
                // The helper's own attempt goes on only while the fans read
                // as the previous step left them, apart from the fan the
                // unconfirmed command names, which that command may still
                // change. The owner's request does not depend on that.
                if trigger != .explicit {
                    var expected = working.acknowledged
                    if let named, let index = expected.fans.firstIndex(where: { $0.id == named }),
                       let reading = before.fans.first(where: { $0.id == named }) { expected.fans[index] = reading }
                    guard FanRecoveryRecord.matches(expected, before) else {
                        throw FanControlError.ownership("Fan settings changed during recovery. The fans were left as they are.")
                    }
                }
                // The zero target is only ever a reset on an automatic fan. It
                // is never written to a fan that reads manual, where it would
                // be a requested speed.
                if case .target(let id, _) = operation, before.fans.first(where: { $0.id == id })?.isAutomatic != true {
                    throw FanControlError.ownership("Fan \(id + 1) left automatic mode during recovery. No reset target was written.")
                }
                working.acknowledged = before; working.pending = operation
                let performStartedAt = instant(timing)
                issued = true
                try hardware.perform(operation, capabilities: held.capabilities,
                                     cancelled: { cancelled() || conflict() != nil })
                let accepted = try acknowledgeBounded(operation, pending: working, before: before,
                    performStartedAt: performStartedAt, performReturnedAt: instant(timing), timing: timing,
                    conflict: conflict, captureOpen: &captureOpen, journal: false)
                let trace = lastRecoveryStepDiagnostic
                receipt.steps.append(FanSelfRecoveryStep(operation: operation, termination: "acknowledged",
                    nativeWriteReturnedAt: trace?.nativeWriteReturnedAt, acknowledgedAt: trace?.acknowledgedAt,
                    observations: trace?.probes.count ?? 0, probes: trace?.probes ?? []))
                receipt.lastReleaseAcknowledgedAt = trace?.acknowledgedAt
                working.acknowledged = accepted; working.pending = nil
                return accepted
            } catch {
                let trace = lastRecoveryStepDiagnostic.flatMap { $0 != previous && $0.operation == operation ? $0 : nil }
                receipt.steps.append(FanSelfRecoveryStep(operation: operation,
                    termination: trace?.termination ?? (issued ? "notConfirmed" : "notIssued"),
                    nativeWriteReturnedAt: trace?.nativeWriteReturnedAt, acknowledgedAt: nil,
                    observations: trace?.probes.count ?? 0, probes: trace?.probes ?? []))
                throw error
            }
        }
        do {
            if let error = stopped() { throw error }
            // E-Q4: never start before the unconfirmed command's own deadline.
            // When this process does not know it (a restart, or a trace a
            // later release step replaced), one second from the attempt's own
            // start is at least as late.
            try wait(until: notBefore ?? startedAt + 1)
            if let error = stopped() { throw error }
            var state = try hardware.readControlState(held.capabilities)
            if trigger != .explicit {
                // The record's own states, or fully automatic. A manual entry
                // that landed late keeps whatever target firmware then held,
                // which the record cannot predict, so that one fan may read
                // manual at any target.
                var landed = held.acknowledged
                if case .mode(let id, true) = unconfirmed, let index = landed.fans.firstIndex(where: { $0.id == id }),
                   let reading = state.fans.first(where: { $0.id == id }), reading.mode == 1 { landed.fans[index] = reading }
                guard held.matches(state) || FanRecoveryRecord.matches(landed, state) || state.isFullyAutomatic else {
                    throw FanControlError.ownership("Fan settings no longer match this helper's record. The fans were left as they are.")
                }
            }
            working.acknowledged = state
            for fan in held.capabilities.fans {
                if named == fan.id || state.fans.first(where: { $0.id == fan.id })?.isAutomatic != true {
                    state = try step(.mode(fan: fan.id, manual: false))
                }
                state = try step(.target(fan: fan.id, rpm: 0))
            }
            if held.capabilities.hasGlobalUnlock && state.globalUnlock != held.baseline.globalUnlock {
                if let error = stopped() { throw error }
                // Global unlock keeps its single immediate readback, as in a
                // normal stop.
                var acknowledgedAt: TimeInterval?
                defer {
                    receipt.steps.append(FanSelfRecoveryStep(operation: .globalUnlock(false),
                        termination: acknowledgedAt == nil ? "notConfirmed" : "acknowledged",
                        nativeWriteReturnedAt: nil, acknowledgedAt: acknowledgedAt, observations: 1))
                }
                try hardware.perform(.globalUnlock(false), capabilities: held.capabilities,
                                     cancelled: { cancelled() || conflict() != nil })
                state = try hardware.readControlState(held.capabilities)
                guard operationConfirmed(.globalUnlock(false), observation: state), let now = instant(timing) else {
                    throw FanControlError.hardware(mismatch(.globalUnlock(false), before: working.acknowledged, after: state))
                }
                acknowledgedAt = now
                receipt.lastReleaseAcknowledgedAt = now
            }
            guard let released = receipt.lastReleaseAcknowledgedAt else {
                throw FanControlError.hardware("invalidOrBackwardClock")
            }
            // Settle check: two distinct complete automatic probes, the second
            // at least one second after the last release acknowledgement.
            let unsettled = "The fans did not stay automatic after release. Both fans and any discovered unlock must be automatic in fresh native observations with unchanged fan metadata."
            func settleProbe() throws -> FanFanProbe {
                if let error = stopped() { throw error }
                let probe = try hardware.probeFans(held.capabilities, cancelled: cancelled)
                guard let now = instant(timing) else { throw FanControlError.hardware("invalidOrBackwardClock") }
                try requireRecoveredProbe(probe, record: held, now: now, failure: unsettled)
                receipt.settle.append(probe)
                return probe
            }
            try wait(until: released + Self.minimumProbeSpacing)
            let first = try settleProbe()
            try wait(until: max(released + Self.selfRecoverySettleSeconds,
                                first.observation.capturedAt + Self.minimumProbeSpacing))
            let second = try settleProbe()
            guard second.observation.capturedAt > first.observation.capturedAt,
                  second.observation.capturedAt + 0.000_001 >= released + Self.selfRecoverySettleSeconds else {
                throw FanControlError.ownership(unsettled)
            }
            if let error = stopped() { throw error }
            guard record == current, try persistence.load() == current else {
                throw FanControlError.ownership("The retained recovery record changed during recovery. The hold remains.")
            }
            // A stalled journal read must not make stale observations acceptable.
            guard let now = instant(timing) else { throw FanControlError.hardware("invalidOrBackwardClock") }
            try requireRecoveredProbe(first, record: held, now: now, failure: unsettled)
            try requireRecoveredProbe(second, record: held, now: now, failure: unsettled)
            if let error = stopped() { throw error }
            try commit()
            do { try persistence.remove() }
            catch {
                try? persistence.save(current)
                throw error
            }
            record = nil
            receipt.confirmedAt = instant(timing)
            lastSelfRecoveryReceipt = receipt
            return receipt
        } catch {
            throw fail(error)
        }
    }

    // Calling this is an explicit owner acknowledgement of external recovery.
    // It observes native fan state only; it cannot restore fans or issue writes.
    public func confirmExternalRecovery(recoveryID: String, conflict: () -> String?,
                                        clock: () -> TimeInterval, cancelled: () -> Bool = { false },
                                        commit: () throws -> Void = {}) throws -> FanExternalRecoveryReceipt {
        guard let current = record, current.requiresExternalRecovery,
              UUID(uuidString: recoveryID) != nil, current.ownerSession == recoveryID else {
            throw FanControlError.ownership("This recovery confirmation does not match the unresolved fan session.")
        }
        guard !cancelled() else { throw FanControlError.cancelled }
        if let utility = conflict() { throw FanControlError.ownership("Quit \(utility) after returning both fans to Auto, then verify recovery.") }
        let first = try hardware.probeFans()
        try requireRecoveredProbe(first, record: current, now: clock())
        guard !cancelled() else { throw FanControlError.cancelled }
        if let utility = conflict() { throw FanControlError.ownership("\(utility) appeared during recovery verification. Quit it and verify again.") }
        let second = try hardware.probeFans()
        try requireRecoveredProbe(second, record: current, now: clock())
        guard second.observation.capturedAt > first.observation.capturedAt else {
            throw FanControlError.ownership("External recovery needs two distinct fresh native fan observations.")
        }
        // A stalled second read must not make the first observation acceptable.
        try requireRecoveredProbe(first, record: current, now: clock())
        if let utility = conflict() { throw FanControlError.ownership("\(utility) appeared during recovery verification. Quit it and verify again.") }
        guard record == current, try persistence.load() == current else {
            throw FanControlError.ownership("The retained recovery record changed during verification. Recovery remains unverified.")
        }
        // Journal validation can itself stall. Re-check the observations and
        // competing utility after it, immediately before the commit point.
        try requireRecoveredProbe(first, record: current, now: clock())
        try requireRecoveredProbe(second, record: current, now: clock())
        if let utility = conflict() { throw FanControlError.ownership("\(utility) appeared before recovery commit. Quit it and verify again.") }
        let receipt = FanExternalRecoveryReceipt(recoveryID: recoveryID, confirmedAt: clock(), first: first, second: second)
        try commit()
        do { try persistence.remove() }
        catch {
            // A store must retain a startup-visible retirement marker on a
            // failed durable deletion. Re-persist the intent as a further
            // conservative safeguard for other persistence implementations.
            try? persistence.save(current)
            throw error
        }
        record = nil
        return receipt
    }

    private func requireRecoveredProbe(_ probe: FanFanProbe, record: FanRecoveryRecord, now: TimeInterval,
                                       failure: String = "External recovery is unverified. Both fans and any discovered unlock must be automatic in fresh native observations with unchanged fan metadata.") throws {
        let state = probe.observation
        guard probe.model == record.capabilities.model, probe.fans == record.capabilities.fans,
              now.isFinite, state.capturedAt.isFinite, state.capturedAt <= now, now - state.capturedAt < 3,
              state.fans.count == probe.fans.count,
              Set(state.fans.map(\.id)) == Set(probe.fans.map(\.id)),
              state.fans.allSatisfy({ $0.actualRPM.isFinite && $0.targetRPM.isFinite
                  && (0...20_000).contains($0.actualRPM) && (0...20_000).contains($0.targetRPM) }),
              (record.capabilities.hasGlobalUnlock ? state.globalUnlock == 0 : state.globalUnlock == nil),
              state.isFullyAutomatic else {
            throw FanControlError.ownership(failure)
        }
    }

    private func operationConfirmed(_ operation: FanOperation, observation: FanControlObservation) -> Bool {
        switch operation {
        case .globalUnlock(let enabled): return observation.globalUnlock == (enabled ? 1 : 0)
        case .mode(let id, let manual):
            guard let fan = observation.fans.first(where: { $0.id == id }) else { return false }
            return manual ? fan.mode == 1 : fan.isAutomatic
        case .target(let id, let rpm):
            return observation.fans.first(where: { $0.id == id }).map { abs($0.targetRPM - rpm) <= 2 } ?? false
        }
    }

    // Bounded and manual-entry probes. A release reset, a zero target written
    // while that fan reads automatic, is confirmed by automatic mode because
    // automatic firmware reports its own nonzero target. Every other
    // operation, including zero on a manual fan whose minimum is zero, must
    // read back as written.
    private func acknowledgementConfirmed(_ operation: FanOperation, observation: FanControlObservation,
                                          record: FanRecoveryRecord) -> Bool {
        if releaseReset(operation, record: record), case .target(let id, _) = operation {
            return observation.fans.first(where: { $0.id == id })?.isAutomatic == true
        }
        return operationConfirmed(operation, observation: observation)
    }

    // `record.acknowledged` is the readback taken immediately before the write.
    private func releaseReset(_ operation: FanOperation, record: FanRecoveryRecord) -> Bool {
        guard case .target(let id, let rpm) = operation, rpm == 0 else { return false }
        return record.acknowledged.fans.first(where: { $0.id == id })?.isAutomatic == true
    }

    private func confirmationRule(_ operation: FanOperation, record: FanRecoveryRecord) -> String {
        switch operation {
        case .target: return releaseReset(operation, record: record) ? "fanAutomatic" : "requestedTargetWithin2RPM"
        case .mode(_, let manual): return manual ? "manualMode" : "fanAutomatic"
        case .globalUnlock: return "unlockState"
        }
    }

    private func receiptJSON<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "receipt encoding unavailable"
        }
        return text
    }
}
