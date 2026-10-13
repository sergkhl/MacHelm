import Foundation

// This lock is never held across hardware, filesystem, XPC, or process calls.
// A separate watchdog executor can revoke permission during a stalled SMC call.
public final class FanSafetyGate {
    private let lock = NSLock()
    private var owner: String?
    private var session: String?
    private var leaseDeadline: TimeInterval = 0
    private var telemetryDeadline: TimeInterval = 0
    private var generation: UInt64 = 0
    private var stopReason: String?
    private var removalOwner: String?
    private var recoveryOwner: String?
    private var recoveryCommitting = false
    private var sleeping = false

    // The longest a session lasts without a complete usable frame (H-Q4).
    // Frames come one second apart, so two unusable frames in a row are
    // ridden out and a third ends the session. A frame's own freshness stays
    // three seconds (FanSnapshot.validate).
    public static let completeFrameLimitSeconds: TimeInterval = 4

    public init() {}

    public func begin(owner: String, now: TimeInterval) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !sleeping else { throw FanControlError.unavailable("Fan Control is suspended for system sleep.") }
        guard self.owner == nil, removalOwner == nil, recoveryOwner == nil else { throw FanControlError.busy }
        self.owner = owner
        let id = UUID().uuidString
        session = id; leaseDeadline = now + 5; telemetryDeadline = now + Self.completeFrameLimitSeconds
        stopReason = nil; generation &+= 1
        return id
    }

    public func renew(owner: String, session: String, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        guard self.owner == owner, self.session == session, stopReason == nil else { return false }
        leaseDeadline = now + 5
        return true
    }

    public func fresh(at timestamp: TimeInterval, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        guard stopReason == nil, timestamp <= now, now - timestamp < 3 else { return }
        telemetryDeadline = timestamp + Self.completeFrameLimitSeconds
    }

    public func revise(owner: String, session: String, now: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        guard self.owner == owner, self.session == session, stopReason == nil else { return false }
        generation &+= 1
        return true
    }

    public func stop(owner: String? = nil, reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard self.owner != nil, owner == nil || self.owner == owner else { return }
        if stopReason == nil { stopReason = reason; generation &+= 1 }
    }

    public func prepareRemoval(owner: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard recoveryOwner == nil, self.owner == nil || self.owner == owner,
              removalOwner == nil || removalOwner == owner else { return false }
        removalOwner = owner
        if self.owner != nil && stopReason == nil {
            stopReason = "Helper removal requested."; generation &+= 1
        }
        return true
    }

    public func cancelRemoval(owner: String) {
        lock.lock(); defer { lock.unlock() }
        if removalOwner == owner { removalOwner = nil }
    }

    // Returns whether a session was live, so that a sleep which finds Fan
    // Control off can be told from one that ends control.
    @discardableResult public func suspendForSleep() -> Bool {
        lock.lock(); defer { lock.unlock() }
        sleeping = true
        if recoveryOwner != nil && !recoveryCommitting { recoveryOwner = nil; generation &+= 1 }
        if owner != nil && stopReason == nil { stopReason = "System sleep requested."; generation &+= 1 }
        return owner != nil
    }

    public func wake() {
        lock.lock(); sleeping = false; lock.unlock()
    }

    public func check(now: TimeInterval) -> (session: String?, generation: UInt64, reason: String?) {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        return (session, generation, stopReason)
    }

    // The reason a live session is being stopped for, read without
    // evaluating any deadline. Nil when nothing has stopped it.
    public var pendingStopReason: String? {
        lock.lock(); defer { lock.unlock() }
        return stopReason
    }

    public func nextDeadline(now: TimeInterval) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        guard owner != nil, stopReason == nil else { return nil }
        return min(leaseDeadline, telemetryDeadline)
    }

    public func permits(_ expectedGeneration: UInt64, now: TimeInterval) -> Bool {
        let state = check(now: now)
        return state.session != nil && state.reason == nil && state.generation == expectedGeneration
    }

    // Linearize manual-entry acknowledgement with stop/profile/sleep/removal.
    // The clock must be a pure monotonic read and publication must only update
    // memory; neither closure may call this gate or perform I/O under its lock.
    public func commitManualModeAcknowledgement(generation expected: UInt64, session expectedSession: String,
                                                clock: () -> TimeInterval,
                                                publish: (TimeInterval) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        guard now.isFinite, now >= 0 else { throw FanControlError.cancelled }
        expire(now: now)
        guard owner != nil, session == expectedSession, generation == expected, stopReason == nil,
              !sleeping, removalOwner == nil, recoveryOwner == nil else { throw FanControlError.cancelled }
        try publish(now)
    }

    // Publish an idle observation before any concurrent begin/removal/sleep
    // reservation. Both closures must be memory-only and must not call this gate.
    public func commitIdleObservation(generation expected: UInt64, clock: () -> TimeInterval,
                                      publish: (TimeInterval) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = clock()
        guard now.isFinite, now >= 0 else { return false }
        expire(now: now)
        guard generation == expected, owner == nil, session == nil, stopReason == nil,
              !sleeping, removalOwner == nil, recoveryOwner == nil else { return false }
        return publish(now)
    }

    public func finish() {
        lock.lock(); defer { lock.unlock() }
        owner = nil; session = nil; stopReason = nil; generation &+= 1
    }

    public func holdForExternalRecovery() {
        lock.lock(); defer { lock.unlock() }
        // Polling an existing hold must not revoke an explicit verification.
        guard recoveryOwner == nil else { return }
        guard owner != nil || session != nil || stopReason != nil || removalOwner != nil else { return }
        owner = nil; session = nil; stopReason = nil; removalOwner = nil
        generation &+= 1
    }

    public func reserveExternalRecovery(owner: String) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard !sleeping else { throw FanControlError.unavailable("Recovery requests are suspended for system sleep.") }
        guard self.owner == nil, session == nil, removalOwner == nil, recoveryOwner == nil else { throw FanControlError.busy }
        recoveryOwner = owner; recoveryCommitting = false; generation &+= 1
        return generation
    }

    public func permitsExternalRecovery(owner: String, generation expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return recoveryOwner == owner && generation == expected && !sleeping && !recoveryCommitting
    }

    // This is the transaction's commit point, after readback validation and
    // before filesystem retirement. Cancellation before it retains the record.
    // Afterwards the reservation remains exclusive until retirement finishes;
    // there are no hardware writes to interrupt during that phase.
    public func commitExternalRecovery(owner: String, generation expected: UInt64) throws {
        lock.lock(); defer { lock.unlock() }
        guard recoveryOwner == owner, generation == expected, !sleeping, !recoveryCommitting else {
            throw FanControlError.cancelled
        }
        recoveryCommitting = true
    }

    public func endExternalRecovery(owner: String, generation expected: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard recoveryOwner == owner, generation == expected else { return }
        recoveryOwner = nil; recoveryCommitting = false; generation &+= 1
    }

    public func cancelExternalRecovery(owner: String) {
        lock.lock(); defer { lock.unlock() }
        guard recoveryOwner == owner, !recoveryCommitting else { return }
        recoveryOwner = nil; generation &+= 1
    }

    private func expire(now: TimeInterval) {
        guard owner != nil, stopReason == nil else { return }
        if now >= leaseDeadline { stopReason = "The app lease expired after five seconds." }
        else if now >= telemetryDeadline { stopReason = "No complete fresh sensor snapshot for four seconds." }
        if stopReason != nil { generation &+= 1 }
    }
}
