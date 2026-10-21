import Foundation
#if canImport(FanControlCore)
import FanControlCore
#endif

public final class FanHelperController {
    public let safety = FanSafetyGate()
    private let worker = DispatchQueue(label: "MacHelm.fan.hardware", qos: .userInitiated)
    private let watchdogQueue = DispatchQueue(label: "MacHelm.fan.watchdog", qos: .userInitiated)
    private let cacheLock = NSLock()
    private var cached: FanStatus
    private var observationUntil: TimeInterval = 0
    private var pollScheduled = false
    private var pollFollowUp = false
    private var reportedWatchdogGeneration: UInt64?
    private var watchdog: DispatchSourceTimer?
    private var sampler: DispatchSourceTimer?
    private let hardware: FanHardware
    private let actuator: FanActuator
    private let conflict: () -> String?
    private let clock: () -> TimeInterval
    private let qualificationProvenance: () -> String?
    private let entryFramePause: (TimeInterval) -> Void
    private var capabilities: FanCapabilities?
    private var activationReady = false
    private var profile = FanProfile.standard
    private var policy = FanPolicy()
    // Why control last ended; nil when nothing has ended it since the helper
    // started or since a recovery was confirmed. Worker-confined.
    private var terminalReason: String?
    // When the last complete usable frame was captured, in a session or at
    // idle. An out-of-range idle frame is skipped while it is recent (H-Q2).
    // Worker-confined.
    private var lastUsableFrameAt: TimeInterval?
    // Each fan's last acknowledged target in this session; worker-confined.
    private var acknowledgedTargetRPM: [Int: Double] = [:]
    // Helper start, and the session of a pending record found on disk then.
    // Only that record gets the startup attempt, on the first poll.
    private var startedAt: TimeInterval = 0
    private var startupRecoveryID: String?
    private let storageRecoveryOwner = UUID().uuidString
    private var nextStorageRecoveryAt: TimeInterval = 0
    private var lastStorageRecoveryError: String?
    public static let storageRecoveryRetrySeconds: TimeInterval = 15
    // A bounded write is admitted only while its fixed one-second window plus
    // margin fits before lease or complete-telemetry expiry. Manual entry also
    // leaves room for that fan's first target in the same cycle.
    static let targetAdmissionSeconds: TimeInterval = 1.5
    static let entryAdmissionSeconds: TimeInterval = 2.75
    // An ordinary target is written only when it moves at least this far from
    // the fan's last acknowledged target. Each fan's first target after entry
    // is always written; the protection maximum and the exact minimum and
    // maximum are written unless the acknowledged target is within 2 RPM.
    public static let targetDeadbandRPM: Double = 50
    // The helper lets the system sleep once owned release finishes, or after
    // this long at most. A release is one bounded write per fan in manual
    // mode, up to about 1 s each (with the zero targets written before Z-Q3,
    // a two-fan release took about 1.3–1.8 s, 3.5 s at worst); macOS waits up
    // to 30 s for this acknowledgement.
    // A release write that stays unconfirmed is followed by the helper's own
    // recovery attempt, which can outlast this allowance. Sleep does not
    // cancel that attempt; it goes on after wake.
    public static let sleepAllowanceSeconds: TimeInterval = 5
    // H-Q3: an out-of-range entry frame makes a begin wait for the next
    // frame, one second later, for at most three seconds from the first one.
    static let entryFrameIntervalSeconds: TimeInterval = 1
    static let entryFrameWaitSeconds: TimeInterval = 3

    public init(hardware: FanHardware, persistence: FanRecoveryPersistence, bootID: String,
                artifactIdentity: String, conflict: @escaping () -> String?,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                startTimers: Bool = true, qualificationProvenance: @escaping () -> String? = { nil },
                modeDiagnosticTiming: FanModeDiagnosticTiming? = nil,
                entryFramePause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        let generation = UUID().uuidString
        self.hardware = hardware; self.conflict = conflict; self.clock = clock
        self.qualificationProvenance = qualificationProvenance
        self.entryFramePause = entryFramePause
        cached = FanStatus(serviceGeneration: generation)
        actuator = try FanActuator(hardware: hardware, persistence: persistence, bootID: bootID,
                                  serviceGeneration: generation, artifactIdentity: artifactIdentity,
                                  modeDiagnosticTiming: modeDiagnosticTiming)
        startedAt = clock()
        if actuator.record != nil {
            capabilities = actuator.record?.capabilities
            cached.capabilities = capabilities; cached.ownsOverride = true
            if actuator.requiresExternalRecovery {
                cached.mode = .externalRecoveryRequired; cached.reason = actuator.holdReason
                cached.externalRecoveryRequired = true
                cached.externalRecoveryID = actuator.record?.ownerSession
                cached.restoreAutomaticOffered = actuator.recordIsFromThisBootAndBuild
                cached.storageRecoveryPending = actuator.storageRecoveryPending
                // E-Q6: a same-boot, same-build record gets its one automatic
                // attempt on the first poll; any other record only holds.
                startupRecoveryID = actuator.record?.ownerSession
            } else {
                cached.mode = .restoring; cached.reason = "Reconciling a recorded interrupted session."
            }
        } else {
            cached.safeToUnregister = true
        }
        if startTimers { start() }
    }

    deinit { sampler?.cancel(); watchdog?.cancel() }

    #if FAN_CONTROL_QUALIFICATION
    // Private qualification artifact only (E-Q7, W-Q1): see FanActuator.
    public func setQualificationAcknowledgementWithholder(_ withholds: @escaping (FanOperation) -> FanQualificationWithholding?) {
        worker.async { [self] in actuator.qualificationWithholdsAcknowledgement = withholds }
    }
    #endif

    private func start() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in
            self?.checkWatchdog()
            // Re-arm if a timer callback arrived just before the monotonic
            // deadline. Dispatch scheduling is not a hard real-time clock.
            self?.armWatchdog()
        }
        timer.resume(); watchdog = timer
        let sampleTimer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        sampleTimer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(20))
        sampleTimer.setEventHandler { [weak self] in self?.schedulePoll() }
        sampleTimer.resume(); sampler = sampleTimer
    }

    public func status(observe: Bool) -> FanStatus {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if observe { observationUntil = clock() + 3 }
        var result = cached
        if let frame = result.snapshot, clock() - frame.capturedAt >= 3 { result.snapshot = nil }
        if let probe = result.fanProbe, clock() - probe.observation.capturedAt >= 3 {
            result.fanProbe = nil; result.releaseVerified = false
        }
        return result
    }

    public func begin(owner: String, profile: FanProfile, completion: @escaping (FanStatus) -> Void) {
        if status(observe: false).externalRecoveryRequired {
            var reply = status(observe: false); reply.requestError = reply.reason ?? FanActuator.externalRecoveryReason
            completion(reply); return
        }
        do {
            try profile.validate()
            let session = try safety.begin(owner: owner, now: clock())
            armWatchdog()
            update { $0.safeToUnregister = false; $0.manualModeDiagnostic = nil; $0.targetDiagnostic = nil
                $0.selfRecoveryReceipt = nil }
            worker.async { [self] in
                do {
                    guard actuator.record == nil else {
                        throw FanControlError.ownership("Automatic restoration is still pending. Resolve it before re-enabling.")
                    }
                    let (discovered, frame) = try qualifiedEntryFrame(session: session)
                    let state = safety.check(now: clock())
                    guard state.session == session, state.reason == nil else { throw FanControlError.cancelled }
                    capabilities = discovered; self.profile = profile; policy = FanPolicy()
                    acknowledgedTargetRPM = [:]
                    activationReady = true
                    terminalReason = nil
                    lastUsableFrameAt = frame.capturedAt
                    safety.fresh(at: frame.capturedAt, now: clock())
                    armWatchdog()
                    update { $0.capabilities = discovered; $0.snapshot = frame; $0.sessionID = session
                        $0.fanProbe = FanFanProbe(model: discovered.model, fans: discovered.fans, observation: frame.controlObservation)
                        $0.mode = .automatic; $0.reason = nil; $0.releaseVerified = true; $0.safeToUnregister = false }
                    log("Qualified \(discovered.model), basis \(discovered.temperatureBasis.rawValue): \(discovered.sensors.map { "\($0.key):\($0.role.title):\($0.encoding)" }.joined(separator: ", "))")
                    // First policy evaluation is tied to this complete frame.
                    try control(frame)
                    completion(status(observe: false))
                } catch {
                    fail(error)
                    completion(status(observe: false))
                }
            }
        } catch {
            var reply = status(observe: false)
            reply.requestError = error.localizedDescription
            // A failed second begin must not replace the existing owner's state.
            completion(reply)
        }
    }

    // The entry check of a begin: no competing utility, a discovered machine
    // and one complete valid frame with every fan automatic. H-Q3: the
    // firmware can publish an out-of-range value for about one of its
    // one-second updates, so such a frame makes the begin wait for the next
    // one, for at most three seconds from the first. The whole check is
    // repeated each time. Any other fault fails at once, and so does a stop
    // or an expiry during the wait. The hardware reader reports such a
    // reading itself, from discovery and from the frame read, so the wait
    // covers both as well as the validation here.
    private func qualifiedEntryFrame(session: String) throws -> (FanCapabilities, FanSnapshot) {
        var waitEnds: TimeInterval?, waits = 0
        while true {
            if let conflict = conflict() { throw FanControlError.unavailable("Quit \(conflict) before enabling Fan Control.") }
            do {
                let discovered = try hardware.discover()
                let frame = try readHardwareSnapshot(discovered)
                try frame.validate(against: discovered, now: clock())
                guard frame.isFullyAutomatic else {
                    throw FanControlError.ownership("Fans are already in custom control. Return them to automatic in your existing utility first.")
                }
                return (discovered, frame)
            } catch FanControlError.readingOutOfRange(let reason) {
                let now = clock(), ends = waitEnds ?? now + Self.entryFrameWaitSeconds
                waitEnds = ends
                // The count bounds the wait even if the clock does not advance.
                guard now < ends, waits < Int(Self.entryFrameWaitSeconds / Self.entryFrameIntervalSeconds) else {
                    throw FanControlError.readingOutOfRange(reason)
                }
                waits += 1
                log("Entry frame unusable: \(reason) Waiting one second for the next frame, three seconds at most.")
                entryFramePause(Self.entryFrameIntervalSeconds)
                let state = safety.check(now: clock())
                guard state.session == session, state.reason == nil else { throw FanControlError.cancelled }
            }
        }
    }

    public func updateProfile(owner: String, session: String, profile: FanProfile,
                              completion: @escaping (FanStatus) -> Void) {
        if status(observe: false).externalRecoveryRequired {
            var reply = status(observe: false); reply.requestError = reply.reason ?? FanActuator.externalRecoveryReason
            completion(reply); return
        }
        do {
            try profile.validate()
            guard safety.revise(owner: owner, session: session, now: clock()) else {
                throw FanControlError.invalid("The control lease is no longer valid.")
            }
            worker.async { [self] in
                if safety.check(now: clock()).session == session {
                    self.profile = profile
                    log("Profile updated: \(profile.start)/\(profile.maximum) °C; fixed protection unchanged.")
                }
                completion(status(observe: false))
            }
        } catch {
            var reply = status(observe: false); reply.requestError = error.localizedDescription
            completion(reply)
        }
    }

    public func renew(owner: String, session: String) -> Bool {
        guard !status(observe: false).externalRecoveryRequired else { return false }
        let renewed = safety.renew(owner: owner, session: session, now: clock())
        armWatchdog()
        return renewed
    }

    public func stop(owner: String, reason: String, completion: @escaping (FanStatus) -> Void) {
        // Stop immediately, independently of a queued/stalled hardware operation.
        safety.stop(owner: owner, reason: reason)
        let state = safety.check(now: clock())
        guard state.session == nil || state.reason != nil else {
            var reply = status(observe: false); reply.requestError = "This connection does not own the active session."
            completion(reply); return
        }
        worker.async { [self] in
            noteTerminal(reason)
            restore(endingSession: true)
            completion(status(observe: false))
        }
    }

    public func disconnected(owner: String) {
        safety.cancelExternalRecovery(owner: owner)
        safety.cancelRemoval(owner: owner)
        safety.stop(owner: owner, reason: "The authenticated app connection was lost.")
        checkWatchdog()
    }

    public func checkWatchdog() {
        let state = safety.check(now: clock())
        if let reason = state.reason {
            cacheLock.lock()
            if reportedWatchdogGeneration != state.generation {
                reportedWatchdogGeneration = state.generation
                cached.diagnostics.append("\(Date().ISO8601Format()) [\(clock())] Watchdog detected: \(reason)")
                trimDiagnostics()
            }
            cacheLock.unlock()
            update {
                if !$0.externalRecoveryRequired { $0.mode = .restoring; $0.reason = reason }
                $0.sessionID = nil; $0.releaseVerified = false
            }
            schedulePoll()
        }
    }

    private func armWatchdog() {
        watchdogQueue.async { [weak self] in
            guard let self, let timer = self.watchdog else { return }
            let now = self.clock()
            if let deadline = self.safety.nextDeadline(now: now) {
                timer.schedule(deadline: .now() + max(0, deadline - now), leeway: .nanoseconds(0))
            } else {
                timer.schedule(deadline: .distantFuture)
                self.checkWatchdog()
            }
        }
    }

    public func prepareRemoval(owner: String, completion: @escaping (FanStatus) -> Void) {
        if status(observe: false).externalRecoveryRequired {
            var reply = status(observe: false); reply.requestError = reply.reason ?? FanActuator.externalRecoveryReason
            completion(reply); return
        }
        guard safety.prepareRemoval(owner: owner) else {
            var reply = status(observe: false); reply.requestError = "Another connection owns Fan Control; it must release before helper removal."
            completion(reply); return
        }
        worker.async { [self] in
            noteTerminal("Helper removal requested.")
            restore(endingSession: true)
            completion(status(observe: false))
        }
    }

    public func confirmExternalRecovery(owner: String, recoveryID: String,
                                        completion: @escaping (FanStatus) -> Void) {
        let reservation: UInt64
        do {
            let current = status(observe: false)
            guard current.externalRecoveryRequired else {
                throw FanControlError.ownership("No unconfirmed fan operation awaits external recovery.")
            }
            guard current.mode != .restoring else { throw FanControlError.unavailable(Self.attemptRunningReason) }
            reservation = try safety.reserveExternalRecovery(owner: owner)
        } catch {
            var reply = status(observe: false); reply.requestError = error.localizedDescription
            completion(reply); return
        }
        worker.async { [self] in
            defer { safety.endExternalRecovery(owner: owner, generation: reservation) }
            do {
                let receipt = try actuator.confirmExternalRecovery(recoveryID: recoveryID, conflict: conflict, clock: clock,
                    cancelled: { !self.safety.permitsExternalRecovery(owner: owner, generation: reservation) },
                    commit: { try self.safety.commitExternalRecovery(owner: owner, generation: reservation) })
                activationReady = false; terminalReason = nil
                armWatchdog()
                let probe = receipt.second
                let encoded = (try? JSONEncoder().encode(receipt)).map { String(decoding: $0, as: UTF8.self) } ?? "unavailable"
                log("Explicit external recovery confirmed by authenticated connection \(owner); native receipt \(encoded).")
                update {
                    $0.mode = .off; $0.reason = nil; $0.snapshot = nil; $0.smoothedCPU = nil
                    $0.sessionID = nil; $0.ownsOverride = false; $0.requestedRPM = [:]
                    $0.fanProbe = probe; $0.releaseVerified = true; $0.safeToUnregister = true
                    $0.externalRecoveryRequired = false; $0.externalRecoveryID = nil
                    $0.restoreAutomaticOffered = nil
                    $0.storageRecoveryPending = nil; $0.storageRecoveryRetryAt = nil
                    $0.externalRecoveryReceipt = receipt
                }
                safety.endExternalRecovery(owner: owner, generation: reservation)
                completion(status(observe: false))
            } catch {
                log("External recovery confirmation rejected: \(error.localizedDescription)")
                var reply = status(observe: false); reply.requestError = error.localizedDescription
                safety.endExternalRecovery(owner: owner, generation: reservation)
                completion(reply)
            }
        }
    }

    // E-Q3: the owner's explicit request for one bounded attempt to return
    // the recorded fans to automatic. It holds the same exclusive reservation
    // as explicit verification, may repeat, and may run on fans that no longer
    // match the record; it is refused for another boot or build and while a
    // known competing utility is running.
    public func restoreAutomatic(owner: String, recoveryID: String, completion: @escaping (FanStatus) -> Void) {
        let reservation: UInt64
        do {
            let current = status(observe: false)
            guard current.externalRecoveryRequired else {
                throw FanControlError.ownership("No unconfirmed fan operation awaits recovery.")
            }
            // The helper's own attempt is running; a second one must not queue behind it.
            guard current.mode != .restoring else { throw FanControlError.unavailable(Self.attemptRunningReason) }
            reservation = try safety.reserveExternalRecovery(owner: owner)
        } catch {
            var reply = status(observe: false); reply.requestError = error.localizedDescription
            completion(reply); return
        }
        worker.async { [self] in
            defer { safety.endExternalRecovery(owner: owner, generation: reservation) }
            let earlier = actuator.selfRecoveryAttempts
            do {
                guard UUID(uuidString: recoveryID) != nil, actuator.record?.ownerSession == recoveryID else {
                    throw FanControlError.ownership("This recovery request does not match the unresolved fan session.")
                }
                let command = actuator.unconfirmedCommand
                let receipt = try actuator.recoverOwnedFans(trigger: .explicit, cause: command.cause,
                    notBefore: command.deadline, conflict: conflict,
                    cancelled: { !self.safety.permitsExternalRecovery(owner: owner, generation: reservation) },
                    commit: { try self.safety.commitExternalRecovery(owner: owner, generation: reservation) })
                log("Explicit automatic restoration requested by authenticated connection \(owner).")
                publishSelfRecovery(receipt, mode: .off, reason: nil)
                safety.endExternalRecovery(owner: owner, generation: reservation)
                completion(status(observe: false))
            } catch {
                log("Explicit automatic restoration did not clear the hold: \(error.localizedDescription)\(failedReceipt(since: earlier))")
                // A request refused before any attempt publishes no receipt.
                if actuator.selfRecoveryAttempts != earlier { update { $0.selfRecoveryReceipt = actuator.lastSelfRecoveryReceipt } }
                var reply = status(observe: false); reply.requestError = error.localizedDescription
                safety.endExternalRecovery(owner: owner, generation: reservation)
                completion(reply)
            }
        }
    }

    public func systemWillSleep(completion: @escaping () -> Void) {
        let live = safety.suspendForSleep()
        worker.async { [self] in
            // L-Q2b: a sleep that finds Fan Control off is not an ending; the
            // label and the recorded ending stay as they were.
            if live || actuator.record != nil { noteTerminal("System sleep requested.") }
            restore(endingSession: true)
            completion()
        }
    }

    public func systemDidWake() { safety.wake() }

    // Also used by deterministic tests with timers disabled.
    public func poll(completion: @escaping () -> Void = {}) {
        worker.async { [self] in pollOnWorker(); completion() }
    }

    // A request that arrives while a poll is queued or running runs one more
    // poll as soon as it ends, so a long bounded acknowledgement cannot push
    // the next complete frame to the complete-frame limit.
    func schedulePoll() {
        cacheLock.lock()
        guard !pollScheduled else { pollFollowUp = true; cacheLock.unlock(); return }
        pollScheduled = true
        cacheLock.unlock()
        worker.async { [self] in
            pollOnWorker()
            cacheLock.lock()
            pollScheduled = false
            let followUp = pollFollowUp; pollFollowUp = false
            cacheLock.unlock()
            if followUp { schedulePoll() }
        }
    }

    private func pollOnWorker() {
        if actuator.requiresExternalRecovery {
            if let found = startupRecoveryID {
                startupRecoveryID = nil
                if actuator.record?.ownerSession == found, attemptSelfRecovery(.startup) { return }
            }
            holdForExternalRecovery()
            if attemptStorageRecovery() { return }
            cacheLock.lock(); let observing = clock() < observationUntil; cacheLock.unlock()
            if observing {
                // Observation can show an apparent automatic state, but never
                // retires a submitted intent or enables another native write.
                if let probe = try? hardware.probeFans() { update { $0.fanProbe = probe } }
            }
            return
        }
        let state = safety.check(now: clock())
        if let reason = state.reason {
            terminalReason = reason
            restore(endingSession: true)
            return
        }
        if state.session == nil && actuator.record != nil {
            restore(endingSession: true)
            return
        }
        // Reservation alone must not arm writes ahead of begin's qualification
        // work when a sampler callback was already queued.
        if state.session != nil && !activationReady { return }
        cacheLock.lock(); let observing = clock() < observationUntil; cacheLock.unlock()
        guard state.session != nil || observing else { return }
        do {
            if state.session != nil, let utility = conflict() {
                throw FanControlError.ownership("\(utility) appeared. Fan Control stopped; handover requires ownership reconciliation.")
            }
            if capabilities == nil || state.session == nil { capabilities = try hardware.discover() }
            guard let capabilities else { return }
            let frame = try readHardwareSnapshot(capabilities)
            try frame.validate(against: capabilities, now: clock())
            lastUsableFrameAt = frame.capturedAt
            update { $0.snapshot = frame; $0.capabilities = capabilities
                $0.fanProbe = FanFanProbe(model: capabilities.model, fans: capabilities.fans, observation: frame.controlObservation) }
            if state.session == nil { reconcileIdleAvailability(frame, generation: state.generation) }
            if state.session != nil {
                safety.fresh(at: frame.capturedAt, now: clock())
                armWatchdog()
                try control(frame)
            }
        } catch {
            var failure = error
            if state.session != nil, case .readingOutOfRange(let reason)? = error as? FanControlError, let capabilities {
                // An otherwise valid frame with a finite out-of-range reading is
                // unusable: no decision or write follows and nothing is
                // substituted, clamped or kept for control. The last usable
                // frame stays visible until it is three seconds old, and the
                // complete-frame deadline keeps running from it. Its fan state
                // must still match this helper's ownership.
                do {
                    try requireOwnedFanState(hardware.readControlState(capabilities))
                    policy.noteUnusableFrame()
                    log("Unusable frame skipped: \(reason) No decision or write; the complete-frame deadline keeps running; an active protection cool-down restarts.")
                    return
                } catch { failure = error }
            }
            if state.session == nil {
                noteIdleFault(error)
                // H-Q2: at idle such a frame is skipped as well. The last
                // frame and the label are kept until no usable frame has
                // arrived for the complete-frame limit. Without a recent
                // usable frame there is nothing to keep, and it shows at once.
                if case .readingOutOfRange? = error as? FanControlError, let last = lastUsableFrameAt,
                   clock() - last < FanSafetyGate.completeFrameLimitSeconds {
                    if let probe = try? hardware.probeFans() { update { $0.fanProbe = probe } }
                    return
                }
            }
            update { $0.snapshot = nil }
            if state.session != nil {
                // A failed required channel releases immediately, without waiting
                // to reuse an invalid frame until the complete-frame deadline.
                // A cancelled cycle normally just ends. One that left an intent
                // pending does not: the helper then stops and decides on its
                // one recovery attempt now, not at some later stop or sleep.
                if (failure as? FanControlError) == .cancelled && safety.check(now: clock()).reason == nil
                    && !actuator.requiresExternalRecovery { return }
                fail(failure)
            } else {
                // Independent fan observations are still useful when required
                // CPU telemetry is invalid; they never authorize control.
                if let probe = try? hardware.probeFans() { update { $0.fanProbe = probe } }
                // E-Q5: a failed idle observation does not replace the
                // self-recovery explanation either. F-Q5: the label change
                // writes no log line; noteIdleFault has counted it.
                if terminalReason != FanActuator.selfRecoveredReason {
                    update(logsModeChange: false) { $0.mode = .unavailable; $0.reason = error.localizedDescription }
                }
            }
        }
    }

    // F-Q4: one rule for every ending. A good idle frame returns an idle
    // fault label to what the ending left: off when nothing has ended
    // control, otherwise paused with the reason it ended. A fault still needs
    // Fan Control to be turned on again; only the label changes, and no log
    // line is written for it (F-Q5).
    private func reconcileIdleAvailability(_ frame: FanSnapshot, generation: UInt64) {
        guard !activationReady, actuator.record == nil else { return }
        let ended = terminalReason
        _ = safety.commitIdleObservation(generation: generation, clock: clock) { now in
            guard frame.capturedAt <= now, now - frame.capturedAt < 3,
                  frame.readDuration <= now - frame.capturedAt else { return false }
            cacheLock.lock(); defer { cacheLock.unlock() }
            guard cached.mode == .unavailable, cached.sessionID == nil, !cached.ownsOverride,
                  !cached.externalRecoveryRequired, cached.externalRecoveryID == nil else { return false }
            cached.mode = ended == nil ? .off : .paused; cached.reason = ended
            return true
        }
    }

    // F-Q5: a failed idle observation writes no log line. Status keeps how
    // many there were since the helper started, and the latest one.
    private func noteIdleFault(_ error: Error) {
        let at = clock(), utc = Date().ISO8601Format()
        cacheLock.lock()
        cached.idleFaults = FanIdleFaults(count: (cached.idleFaults?.count ?? 0) + 1,
                                          lastReason: error.localizedDescription, lastAt: at, lastAtUTC: utc)
        cacheLock.unlock()
    }

    private func readHardwareSnapshot(_ capabilities: FanCapabilities) throws -> FanSnapshot {
        defer {
            if let provenance = qualificationProvenance() {
                // Existing diagnostics are sufficient to distinguish synthetic
                // qualification input without adding any XPC control or schema.
                let bounded = String(provenance.prefix(4_096)).replacingOccurrences(of: "\n", with: " ")
                log("Qualification provenance: \(bounded)")
            }
        }
        return try hardware.read(capabilities)
    }

    private func control(_ frame: FanSnapshot) throws {
        guard let capabilities else { throw FanControlError.unavailable("No qualified hardware.") }
        let state = safety.check(now: clock())
        guard let session = state.session, state.reason == nil else { throw FanControlError.cancelled }
        try requireOwnedFanState(frame.controlObservation)
        let decision = try policy.evaluate(frame, capabilities: capabilities, profile: profile, now: clock())
        update { $0.smoothedCPU = policy.smoothedCPU }
        log("Sample at monotonic \(frame.capturedAt), read duration \(frame.readDuration) s: firmware CPU die average (TCMb) \(frame.cpuDieAverage(in: capabilities)) °C, firmware CPU die maximum (TCMz) \(frame.cpuDieMaximum(in: capabilities)) °C, hottest qualified GPU \(frame.hottestGPU(in: capabilities)) °C; smoothed CPU die average \(policy.smoothedCPU ?? .nan) °C; demand \(String(describing: decision.demand)).")
        guard let demand = decision.demand else {
            acknowledgedTargetRPM = [:]
            if actuator.record != nil { restore(endingSession: false) }
            else { update { $0.mode = .automatic; $0.reason = nil; $0.requestedRPM = [:]; $0.releaseVerified = true } }
            return
        }
        let revoked = { [self] in !safety.permits(state.generation, now: clock()) }
        let cancelled = { [self] in
            guard !revoked() else { return true }
            guard conflict() == nil else { return true }
            // Process enumeration can consume the remaining lease or telemetry
            // budget. Check again immediately before permitting a native call.
            return revoked()
        }
        let bounded = actuator.boundedAcknowledgement
        func admitted(_ seconds: TimeInterval) -> Bool {
            guard bounded else { return true }
            let now = clock()
            guard safety.permits(state.generation, now: now), let expiry = safety.nextDeadline(now: now) else { return false }
            return expiry - now >= seconds
        }
        if actuator.record == nil {
            try actuator.establish(session: session, capabilities: capabilities, baseline: frame.controlObservation)
            update { $0.ownsOverride = true; $0.releaseVerified = false }
        }
        var observed = try actuator.verifyOwnership(conflict: conflict())
        let entering = Set(capabilities.fans.filter { fan in observed.fans.first(where: { $0.id == fan.id })?.mode != 1 }.map(\.id))
        // Fans awaiting manual entry go first. With bounded acknowledgement at
        // most one enters per cycle, as its first write. A fan whose entry is
        // not admitted stays automatic; one whose target is not admitted keeps
        // its current target (its last acknowledged one, or the firmware's
        // entry target right after manual entry). Deferred writes are never issued.
        let order = capabilities.fans.filter { entering.contains($0.id) } + capabilities.fans.filter { !entering.contains($0.id) }
        var wrote = false
        var deferred: [Int] = [], held: [Int] = [], acknowledgements: [String] = []
        for fan in order {
            guard !cancelled() else { throw FanControlError.cancelled }
            if entering.contains(fan.id) {
                guard !bounded || (!wrote && admitted(Self.entryAdmissionSeconds)) else { deferred.append(fan.id); continue }
                wrote = true
                // Its confirmation probes check lifecycle permission per native
                // call and the competing utility only at probe boundaries.
                observed = try actuator.mutate(.mode(fan: fan.id, manual: true), cancelled: cancelled,
                    confirmationCancelled: revoked,
                    manualModePending: { [self] in
                        update {
                            $0.mode = .acquiring; $0.reason = "Waiting for fan \(fan.id + 1) to confirm manual control."
                            $0.releaseVerified = false; $0.safeToUnregister = false
                        }
                    }, manualModeCommit: { [self] publish in
                        // The actuator checks the competing utility immediately
                        // before this publication and names it in the trace.
                        try safety.commitManualModeAcknowledgement(generation: state.generation, session: session,
                            clock: clock, publish: publish)
                    }, acknowledgementConflict: conflict)
                update { $0.manualModeDiagnostic = actuator.lastManualModeDiagnostic }
                if let trace = actuator.lastManualModeDiagnostic {
                    if !trace.primaryFailure.isEmpty { log("First manual-mode mismatch retained: \(trace.primaryFailure)") }
                    log("Manual-mode acknowledgement: \(trace.termination) at \(String(describing: trace.acknowledgedAt)); no mode retry.")
                }
            }
            let target = fan.target(demand: demand)
            let endpoint = decision.protection || demand <= 0 || demand >= 1
            guard Self.writesTarget(target, acknowledged: acknowledgedTargetRPM[fan.id], endpoint: endpoint) else {
                held.append(fan.id); continue
            }
            guard admitted(Self.targetAdmissionSeconds) else { deferred.append(fan.id); continue }
            wrote = true
            do {
                observed = try actuator.mutate(.target(fan: fan.id, rpm: target), cancelled: cancelled,
                                               acknowledgementConflict: conflict)
            } catch {
                // A write cancelled before it started leaves the previous
                // write's trace in place; report only this write's failure.
                if let trace = actuator.lastTargetDiagnostic, trace.evidenceOnly,
                   trace.operation == .target(fan: fan.id, rpm: target) {
                    update { $0.targetDiagnostic = trace }
                    if !trace.primaryFailure.isEmpty { log("First target mismatch retained: \(trace.primaryFailure)") }
                    log("Target acknowledgement failed: \(trace.termination)\(trace.cancellationCause.map { " (\($0))" } ?? "") after \(trace.probes.count) observations; pending intent retained, no target retry or unlock fallback.")
                }
                throw error
            }
            acknowledgedTargetRPM[fan.id] = target
            let trace = actuator.lastTargetDiagnostic
            // Publish each request with its own acknowledged readback, so status
            // never pairs a new requested RPM with a pre-write observation.
            update {
                $0.requestedRPM[fan.id] = target
                if let trace { $0.targetDiagnostic = trace }
                $0.fanProbe = FanFanProbe(model: capabilities.model, fans: capabilities.fans, observation: observed)
                $0.snapshot?.fans = observed.fans; $0.snapshot?.globalUnlock = observed.globalUnlock
            }
            if let trace, let at = trace.acknowledgedAt, let returned = trace.nativeWriteReturnedAt {
                acknowledgements.append("F\(fan.id) target acknowledged \(Int(((at - returned) * 1000).rounded())) ms after native return (\(trace.probes.count) observations)")
            }
        }
        let waiting = capabilities.fans.first { acknowledgedTargetRPM[$0.id] == nil }
        // A stop, expiry or revision that arrived during the last confirmation
        // keeps its own presentation until the queued restoration runs.
        let permitted = safety.permits(state.generation, now: clock())
        update {
            // Ordinary presentation starts only once every fan has an
            // acknowledged target; pending writes never flicker it.
            if permitted, let waiting {
                $0.mode = .acquiring
                $0.reason = "Waiting to bring fan \(waiting.id + 1) under control within the lease and telemetry window."
                    + (decision.protection ? " Protection requested: \(decision.reason ?? "maximum cooling")." : "")
            } else if permitted {
                $0.mode = decision.protection ? .protection : .custom; $0.reason = decision.reason
            }
            $0.fanProbe = FanFanProbe(model: capabilities.model, fans: capabilities.fans, observation: observed)
            $0.snapshot?.fans = observed.fans; $0.snapshot?.globalUnlock = observed.globalUnlock }
        let details = acknowledgements + (deferred.isEmpty ? [] : ["deferred fans \(deferred.map(String.init).joined(separator: ","))"])
            + (held.isEmpty ? [] : ["deadband-held fans \(held.map(String.init).joined(separator: ","))"])
        log("Demand \(demand); readback \(observed.fans.map { "F\($0.id) mode=\($0.mode) target=\($0.targetRPM) actual=\($0.actualRPM)" }.joined(separator: "; ")); unlock=\(String(describing: observed.globalUnlock))\(details.isEmpty ? "" : "; " + details.joined(separator: "; "))")
    }

    // Whether a fan's target must be written. The first target after entry
    // always is; an ordinary one only when it moves at least the deadband from
    // the acknowledged target; an endpoint (minimum, maximum or the protection
    // maximum) whenever it differs by more than the 2 RPM readback tolerance.
    static func writesTarget(_ target: Double, acknowledged: Double?, endpoint: Bool) -> Bool {
        guard let acknowledged else { return true }
        let moved = abs(target - acknowledged)
        return moved >= targetDeadbandRPM || (endpoint && moved > 2)
    }

    // Fan state owned by this helper must match its record; without a record
    // every fan must be automatic.
    private func requireOwnedFanState(_ observed: FanControlObservation) throws {
        if let record = actuator.record {
            guard record.matches(observed) else {
                throw FanControlError.ownership("Fan mode or target changed unexpectedly; ownership was lost.")
            }
        } else if !observed.isFullyAutomatic {
            throw FanControlError.ownership("An unexplained custom fan mode appeared. Return it to automatic externally.")
        }
    }

    // E-Q5: once the helper has returned its own fans to automatic after an
    // unconfirmed command, that explanation stays until Fan Control is turned
    // on again. A later stop, sleep or removal request does not replace it.
    private func noteTerminal(_ reason: String) {
        if terminalReason != FanActuator.selfRecoveredReason { terminalReason = reason }
    }

    private func fail(_ error: Error) {
        let reason = error.localizedDescription
        // A cycle or a begin that a stop cancelled ended for the reason the
        // gate holds (the app's stop, a lost connection, an expiry, a sleep),
        // not for the cancellation. It is logged and released like any
        // failed cycle.
        if (error as? FanControlError) == .cancelled, !actuator.requiresExternalRecovery,
           let stopped = safety.pendingStopReason {
            terminalReason = stopped
        } else {
            terminalReason = reason
        }
        update { $0.snapshot = nil; $0.smoothedCPU = nil
            $0.manualModeDiagnostic = actuator.lastManualModeDiagnostic }
        safety.stop(reason: reason)
        log("Control stopped: \(reason)")
        restore(endingSession: true)
    }

    private func restore(endingSession: Bool) {
        if actuator.requiresExternalRecovery {
            if attemptSelfRecovery(.automatic) { return }
            holdForExternalRecovery(); return
        }
        update { $0.mode = .restoring; $0.reason = terminalReason; $0.releaseVerified = false }
        acknowledgedTargetRPM = [:]
        let previousTrace = actuator.lastTargetDiagnostic
        do {
            let wasOwned = actuator.record != nil
            let observed = try actuator.restore(conflict: conflict)
            publishReleaseTrace(previous: previousTrace)
            if wasOwned { log("Automatic restoration readback confirmed at \(clock()).") }
            if endingSession { activationReady = false; safety.finish() }
            armWatchdog()
            update {
                $0.ownsOverride = false; $0.requestedRPM = [:]
                $0.safeToUnregister = endingSession
                if let observed {
                    $0.snapshot?.fans = observed.fans; $0.snapshot?.globalUnlock = observed.globalUnlock
                    if let capabilities { $0.fanProbe = FanFanProbe(model: capabilities.model, fans: capabilities.fans, observation: observed) }
                }
                let releaseState = observed ?? $0.fanProbe?.observation
                $0.releaseVerified = releaseState.map { $0.isFullyAutomatic && $0.capturedAt <= clock()
                    && clock() - $0.capturedAt < 3 } ?? false
                $0.mode = endingSession ? (terminalReason == nil ? .off : .paused) : .automatic
                $0.reason = endingSession ? terminalReason : nil
                if endingSession { $0.sessionID = nil }
            }
        } catch {
            publishReleaseTrace(previous: previousTrace)
            if actuator.requiresExternalRecovery {
                if let trace = actuator.lastTargetDiagnostic, trace != previousTrace, trace.evidenceOnly {
                    log("Release acknowledgement failed: \(trace.termination)\(trace.cancellationCause.map { " (\($0))" } ?? "") after \(trace.probes.count) observations; pending intent retained, no retry.")
                }
                log("Restoration stopped at a pending fan operation: \(error.localizedDescription)")
                if attemptSelfRecovery(.automatic) { return }
                holdForExternalRecovery(); return
            }
            // Retain the journal and retry only while fresh observations still
            // establish ownership. Never label a requested reset as automatic.
            log("Restoration failed/pending at \(clock()): \(error.localizedDescription)")
            terminalReason = error.localizedDescription
            activationReady = false
            safety.stop(reason: error.localizedDescription)
            safety.finish()
            armWatchdog()
            update { $0.mode = .restorationFailed; $0.reason = error.localizedDescription
                $0.ownsOverride = actuator.record != nil; $0.releaseVerified = false; $0.safeToUnregister = false; $0.sessionID = nil }
        }
    }

    // E-Q1, E-Q2 and E-Q6: the helper's one automatic attempt to return its
    // own fans to automatic while a command is unconfirmed. It runs at most
    // once per hold, for an eligible cause, on a record from this boot and
    // build. Returns true only when the hold was cleared.
    private func attemptSelfRecovery(_ trigger: FanSelfRecoveryTrigger) -> Bool {
        // ENOSPC has a separate writable-storage check and retry path. It
        // must not become a permanently declined automatic recovery.
        guard !actuator.storageRecoveryPending else { return false }
        guard actuator.automaticRecoveryAvailable, let record = actuator.record else { return false }
        // A record found at start is not a live failure: this process has no
        // cause for it. Its attempt waits for the first poll.
        if trigger == .automatic, startupRecoveryID == record.ownerSession { return false }
        let command = actuator.unconfirmedCommand
        let cause = trigger == .startup ? "helperRestart" : command.cause
        guard FanActuator.selfRecoveryEligible(cause: cause) else {
            // E-Q1. Journaled, so a restart does not try either.
            let journaled = actuator.declineAutomaticRecovery()
            log("No automatic recovery: the unconfirmed fan command ended as \(cause ?? "an unknown cause"). The hold remains\(journaled ? "." : "; this decision could not be journaled and holds only until the helper restarts.")")
            return false
        }
        update {
            $0.mode = .restoring; $0.reason = "A fan command could not be confirmed. Returning the fans to automatic."
            $0.releaseVerified = false; $0.safeToUnregister = false
        }
        let earlier = actuator.selfRecoveryAttempts
        do {
            let receipt = try actuator.recoverOwnedFans(trigger: trigger, cause: cause,
                notBefore: trigger == .startup ? startedAt + 1 : command.deadline, conflict: conflict)
            // The live session, if any, ends here. A restart has none, and
            // ending one anyway would strand another connection's recovery
            // reservation, which ends only at its own generation.
            let state = safety.check(now: clock())
            if state.session != nil || state.reason != nil {
                safety.stop(reason: FanActuator.selfRecoveredReason)
                safety.finish()
            }
            publishSelfRecovery(receipt, mode: .paused, reason: FanActuator.selfRecoveredReason)
            return true
        } catch {
            log("Automatic recovery did not clear the hold: \(error.localizedDescription)\(failedReceipt(since: earlier))")
            if actuator.selfRecoveryAttempts != earlier { update { $0.selfRecoveryReceipt = actuator.lastSelfRecoveryReceipt } }
            return false
        }
    }

    private func attemptStorageRecovery() -> Bool {
        let now = clock()
        guard actuator.storageRecoveryPending, now.isFinite, now >= nextStorageRecoveryAt,
              let reservation = try? safety.reserveExternalRecovery(owner: storageRecoveryOwner) else { return false }
        defer { safety.endExternalRecovery(owner: storageRecoveryOwner, generation: reservation) }
        nextStorageRecoveryAt = now + Self.storageRecoveryRetrySeconds
        let earlier = actuator.selfRecoveryAttempts
        do {
            try actuator.prepareStorageRecovery()
            update {
                $0.mode = .restoring; $0.reason = "Disk space is writable again. Completing automatic fan recovery."
            }
            let receipt = try actuator.retryStorageRecovery(conflict: conflict,
                cancelled: { !self.safety.permitsExternalRecovery(owner: self.storageRecoveryOwner, generation: reservation) },
                commit: { try self.safety.commitExternalRecovery(owner: self.storageRecoveryOwner, generation: reservation) })
            lastStorageRecoveryError = nil; nextStorageRecoveryAt = 0
            publishSelfRecovery(receipt, mode: .paused, reason: FanActuator.selfRecoveredReason)
            return true
        } catch {
            nextStorageRecoveryAt = clock() + Self.storageRecoveryRetrySeconds
            let outOfSpace: Bool
            if case .persistence(_, let code) = error as? FanControlError { outOfSpace = code == ENOSPC }
            else { outOfSpace = false }
            if !outOfSpace { actuator.cancelStorageRecovery() }
            let message = error.localizedDescription
            if lastStorageRecoveryError != message {
                log("Storage recovery deferred: \(message)")
                lastStorageRecoveryError = message
            }
            if actuator.selfRecoveryAttempts != earlier { update { $0.selfRecoveryReceipt = actuator.lastSelfRecoveryReceipt } }
            publishExternalRecoveryHold()
            return false
        }
    }

    // E-Q5: after a cleared hold Fan Control is off and needs explicit
    // re-enabling; the receipt keeps every release step and the settle probes.
    private func publishSelfRecovery(_ receipt: FanSelfRecoveryReceipt, mode: FanOperatingMode, reason: String?) {
        activationReady = false; terminalReason = reason
        acknowledgedTargetRPM = [:]
        armWatchdog()
        let encoded = (try? JSONEncoder().encode(receipt)).map { String(decoding: $0, as: UTF8.self) } ?? "unavailable"
        log("Self-recovery (\(receipt.trigger.rawValue)) returned the fans to automatic and cleared the hold; receipt \(encoded).")
        let probe = receipt.settle.last
        update {
            $0.mode = mode; $0.reason = reason; $0.snapshot = nil; $0.smoothedCPU = nil
            $0.sessionID = nil; $0.ownsOverride = false; $0.requestedRPM = [:]
            if let probe { $0.fanProbe = probe }
            $0.releaseVerified = probe.map { $0.observation.isFullyAutomatic && $0.observation.capturedAt <= clock()
                && clock() - $0.observation.capturedAt < 3 } ?? false
            $0.safeToUnregister = true
            $0.externalRecoveryRequired = false; $0.externalRecoveryID = nil
            $0.restoreAutomaticOffered = nil
            $0.storageRecoveryPending = nil; $0.storageRecoveryRetryAt = nil
            $0.selfRecoveryReceipt = receipt
        }
    }

    public static let appStopReason = "Fan Control was turned off by the app."

    public static let attemptRunningReason = "The helper is returning the fans to automatic. Wait for it to finish, then review the result."

    // The receipt of an attempt that did not clear the hold, for the log. A
    // request refused before any attempt began leaves the earlier receipt in
    // place; that one is not logged again.
    private func failedReceipt(since earlier: Int) -> String {
        guard actuator.selfRecoveryAttempts != earlier, let receipt = actuator.lastSelfRecoveryReceipt,
              let data = try? JSONEncoder().encode(receipt) else { return "" }
        return "; receipt \(String(decoding: data, as: UTF8.self))"
    }

    // Publish a release write's trace only when this restoration produced
    // one; begin has already cleared an earlier session's trace from status.
    private func publishReleaseTrace(previous: FanTargetDiagnostic?) {
        guard let trace = actuator.lastTargetDiagnostic, trace != previous else { return }
        update { $0.targetDiagnostic = trace }
    }

    private func publishExternalRecoveryHold() {
        activationReady = false
        let reason = actuator.holdReason, offered = actuator.recordIsFromThisBootAndBuild
        terminalReason = reason
        // An intent is pending. It disarms every ordinary native successor
        // and remains authoritative across stop and restart; only a recovery
        // attempt may issue release writes.
        update {
            $0.mode = .externalRecoveryRequired; $0.reason = reason
            $0.restoreAutomaticOffered = offered
            $0.externalRecoveryRequired = true; $0.externalRecoveryID = actuator.record?.ownerSession
            $0.storageRecoveryPending = actuator.storageRecoveryPending
            $0.storageRecoveryRetryAt = actuator.storageRecoveryPending ? nextStorageRecoveryAt : nil
            $0.externalRecoveryReceipt = nil
            $0.snapshot = nil; $0.smoothedCPU = nil; $0.requestedRPM = [:]; $0.sessionID = nil
            $0.ownsOverride = true; $0.releaseVerified = false; $0.safeToUnregister = false
        }
    }

    private func holdForExternalRecovery() {
        publishExternalRecoveryHold()
        safety.holdForExternalRecovery()
        armWatchdog()
    }

    private func update(logsModeChange: Bool = true, _ mutate: (inout FanStatus) -> Void) {
        cacheLock.lock()
        let previous = cached.mode
        mutate(&cached)
        if logsModeChange, cached.mode != previous {
            cached.diagnostics.append("\(Date().ISO8601Format()) [\(clock())] Mode: \(previous.rawValue) → \(cached.mode.rawValue); \(cached.reason ?? "no fault")")
            trimDiagnostics()
        }
        cacheLock.unlock()
    }

    private func log(_ message: String) {
        let line = "\(Date().ISO8601Format()) [\(clock())] \(message)"
        cacheLock.lock(); cached.diagnostics.append(line)
        trimDiagnostics()
        cacheLock.unlock()
    }

    private func trimDiagnostics() {
        if cached.diagnostics.count > 200 { cached.diagnostics.removeFirst(cached.diagnostics.count - 200) }
    }
}
