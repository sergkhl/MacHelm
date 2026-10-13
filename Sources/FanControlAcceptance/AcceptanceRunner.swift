import Foundation
import FanControlCore
import FanControlHardware

protocol AcceptanceClock {
    var now: TimeInterval { get }
    func sleep(seconds: TimeInterval) async throws
}

struct SystemAcceptanceClock: AcceptanceClock {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

struct RPMConvergence {
    struct Window {
        var target: Double
        var frames: Int
        var lastTimestamp: TimeInterval
        var stableAt: TimeInterval?
        var converged: Bool
    }
    struct Update {
        let fan: Int
        let event: String
        let target: Double
        let measured: Double
        let stableFrames: Int
        let elapsedSinceStable: TimeInterval?
        let relativeError: Double
    }
    private(set) var windows: [Int: Window] = [:]
    private(set) var lastUpdates: [Update] = []
    // Measured RPM is judged once the requested target has held within this
    // allowance of the window's first target across two distinct fresh custom
    // frames. Each frame's effective target must still read back within the
    // separate 2 RPM tolerance of its own request.
    static let stabilityAllowanceRPM: Double = 50
    static let readbackToleranceRPM: Double = 2

    mutating func observe(_ status: FanStatus, now: TimeInterval) throws -> [Update] {
        guard status.mode == .custom, let capabilities = status.capabilities, let frame = status.snapshot else {
            throw AcceptanceError.failed("RPM convergence requires a fresh ordinary custom-control frame.")
        }
        try frame.validate(against: capabilities, now: now)
        guard Set(status.requestedRPM.keys) == Set(capabilities.fans.map(\.id)) else {
            throw AcceptanceError.failed("Requested RPM set does not match all qualified fans.")
        }
        lastUpdates = []
        for fan in frame.fans {
            guard let target = status.requestedRPM[fan.id], let descriptor = capabilities.fans.first(where: { $0.id == fan.id }),
                  target.isFinite, (descriptor.minimumRPM...descriptor.maximumRPM).contains(target),
                  fan.mode == 1, abs(fan.targetRPM - target) <= Self.readbackToleranceRPM else {
                throw AcceptanceError.failed("Fan \(fan.id) target/mode acknowledgement does not match its bounded requested RPM.")
            }
            let relativeError = abs(fan.actualRPM - target) / max(target, 1)
            var window = windows[fan.id]
            if let previous = window, frame.capturedAt <= previous.lastTimestamp { continue }
            let previouslyConverged = window?.converged ?? false
            let event: String
            if window == nil || abs(window!.target - target) > Self.stabilityAllowanceRPM {
                event = window == nil ? "convergence_window_started" : "convergence_window_reset"
                window = Window(target: target, frames: 1, lastTimestamp: frame.capturedAt, stableAt: nil, converged: false)
            } else {
                window!.frames += 1
                window!.lastTimestamp = frame.capturedAt
                if window!.stableAt == nil { window!.stableAt = frame.capturedAt }
                // This is measured response evidence, separate from the effective
                // mode/target receipt above. Every drift reset is retained.
                window!.converged = relativeError <= 0.10
                event = window!.converged ? "measured_rpm_converged" : "convergence_waiting"
            }
            let elapsed = window!.stableAt.map { now - $0 }
            lastUpdates.append(Update(fan: fan.id, event: event, target: target, measured: fan.actualRPM,
                                  stableFrames: window!.frames, elapsedSinceStable: elapsed, relativeError: relativeError))
            windows[fan.id] = window!
            if let elapsed, (!window!.converged && elapsed >= 20) || (!previouslyConverged && elapsed > 20) {
                throw AcceptanceError.failed("Fan \(fan.id) measured RPM did not reach ±10% within 20 seconds of its stable target.")
            }
        }
        return lastUpdates
    }
    func qualified(fans: [FanDescriptor]) -> Bool {
        !fans.isEmpty && fans.allSatisfy { windows[$0.id]?.converged == true && (windows[$0.id]?.frames ?? 0) >= 2 }
    }
}

// Native cleanup is independent of evidence I/O success. At most one owner
// stop is sent, and every caller shares that single release task.
actor AcceptanceSessionSupervisor {
    private let client: AcceptanceClient
    private let log: AcceptanceRecording
    private let clock: AcceptanceClock
    private(set) var failure: String?
    private var releaseTask: Task<FanStatus?, Never>?
    init(client: AcceptanceClient, log: AcceptanceRecording, clock: AcceptanceClock) {
        self.client = client; self.log = log; self.clock = clock
    }
    func fail(_ message: String, status: FanStatus? = nil) {
        guard failure == nil else { return }
        failure = message
        do { try log.firstFailure(message, status: status) }
        catch { fputs("Acceptance evidence write failed: \(error.localizedDescription)\n", stderr) }
    }
    func release(reason: String) async -> FanStatus? {
        if let releaseTask { return await releaseTask.value }
        let client = self.client, log = self.log, clock = self.clock
        let task = Task<FanStatus?, Never> {
            do { try log.record("release_requested", details: ["reason": reason], status: nil) }
            catch { self.fail("Could not retain release-request evidence: \(error.localizedDescription)") }
            do {
                let status = try await client.stop()
                try log.record("release_reply", details: [:], status: status)
                guard status.requestError == nil, status.sessionID == nil, !status.ownsOverride,
                      status.releaseVerified, status.safeToUnregister,
                      let probe = status.fanProbe, probe.observation.isFullyAutomatic,
                      probe.observation.capturedAt <= clock.now,
                      clock.now - probe.observation.capturedAt < 3 else {
                    throw AcceptanceError.failed("Owner stop did not return fresh, effective automatic mode/unlock and verified release.")
                }
                // A helper that had to return its own fans to automatic after
                // an unconfirmed command leaves the same clean release fields.
                // That is a recovery, not the normal release this test accepts.
                // An accepted begin clears an earlier session's receipt. After
                // a begin the helper refused, a receipt here can be an earlier
                // session's; the first failure is already recorded by then.
                if let recovery = status.selfRecoveryReceipt {
                    throw AcceptanceError.failed("The helper's own recovery attempt ran (\(recovery.trigger.rawValue), cause \(recovery.cause ?? "unknown")). The fans read automatic, but this was not a normal release.")
                }
                try log.record("release_verified", details: ["effectiveAutomatic": "true"], status: status)
                return status
            } catch {
                self.fail("Automatic restoration acceptance failed: \(error.localizedDescription)")
                try? log.record("release_failed", details: ["message": error.localizedDescription], status: nil)
                return nil
            }
        }
        releaseTask = task
        return await task.value
    }
}

final class FanAcceptanceRunner {
    private let primary: AcceptanceClient
    private let makeSecondary: () throws -> AcceptanceClient
    private let log: AcceptanceRecording
    private let clock: AcceptanceClock
    private let conflict: () -> String?
    init(primary: AcceptanceClient, makeSecondary: @escaping () throws -> AcceptanceClient,
         log: AcceptanceRecording, clock: AcceptanceClock = SystemAcceptanceClock(),
         conflict: @escaping () -> String? = FanUtilityRegistry.runningConflict) {
        self.primary = primary; self.makeSecondary = makeSecondary; self.log = log
        self.clock = clock; self.conflict = conflict
    }

    private func record(_ event: String, _ status: FanStatus? = nil, details: [String: String] = [:]) throws {
        var detail = details
        if let pid = primary.peerPID { detail["authenticatedXPCPeerPID"] = String(pid) }
        detail["runnerMonotonicTime"] = String(clock.now)
        try log.record(event, details: detail, status: status)
    }
    private func requireComplete(_ status: FanStatus) throws {
        guard status.protocolVersion == FanStatus.currentProtocolVersion else {
            throw AcceptanceError.failed("Incompatible helper telemetry protocol \(status.protocolVersion).")
        }
        if let error = status.requestError { throw AcceptanceError.failed(error) }
        guard let capabilities = status.capabilities, let frame = status.snapshot else {
            // Pause reasons describe earlier control events. Missing current
            // telemetry is a separate fact and must not inherit that reason.
            throw AcceptanceError.failed("No complete fresh qualified helper telemetry is available.")
        }
        try frame.validate(against: capabilities, now: clock.now)
    }
    private func requireIdleAutomatic(_ status: FanStatus) throws {
        try requireComplete(status)
        guard conflict() == nil, status.sessionID == nil, !status.ownsOverride,
              status.snapshot!.isFullyAutomatic else {
            throw AcceptanceError.failed("Acceptance needs an idle automatic baseline without a competing utility or an owned session.")
        }
    }
    private func initialObservation() async throws -> FanStatus {
        var status = try await primary.status(observe: true)
        try record("initial_status", status)
        // Cold cached state is observation setup, not a failed frame. A helper
        // fault is preserved immediately; no failed telemetry is resampled.
        let coldInitial = status.reason == nil && [.off, .automatic].contains(status.mode)
        let coldIdlePaused = status.mode == .paused && status.sessionID == nil && !status.ownsOverride
        if status.snapshot == nil && (coldInitial || coldIdlePaused) {
            try record("observation_armed", status, details: ["historicalReason": status.reason ?? "none",
                       "scope": "One bounded read-only warmup of an empty cache; no failed frame is resampled."])
            try await clock.sleep(seconds: 1)
            status = try await primary.status(observe: true)
            try record("first_observed_frame", status)
        }
        return status
    }

    func status(samples: Int) async throws {
        var status = try await initialObservation()
        var timestamp: TimeInterval?
        for index in 0..<samples {
            if index > 0 {
                try await clock.sleep(seconds: 1)
                status = try await primary.status(observe: true)
            }
            let observedControl = status.snapshot?.controlObservation ?? status.fanProbe?.observation
            try record("status_sample", status, details: ["index": String(index),
                        "automaticReadback": observedControl.map { String($0.isFullyAutomatic) } ?? "unknown",
                        "knownConflict": conflict() ?? "none"])
            try requireComplete(status)
            if let timestamp, status.snapshot!.capturedAt <= timestamp {
                throw AcceptanceError.failed("Read-only qualification received a repeated/out-of-order complete frame.")
            }
            timestamp = status.snapshot!.capturedAt
        }
        try record("status_qualification_completed", status, details: ["completeFreshFrames": String(samples),
                   "scope": "Read-only telemetry and authenticated helper identifier/team; native writes and lifecycle acceptance are unperformed."])
    }

    func hostileInputs() async throws {
        let baseline = try await initialObservation()
        try requireIdleAutomatic(baseline)
        let invalid: [(String, Data)] = [
            ("malformed-profile", Data("{".utf8)),
            ("oversized-profile", Data(repeating: 0x20, count: 513)),
            ("invalid-temperature-gap", try JSONEncoder().encode(FanProfile(start: 45, maximum: 50))),
            ("out-of-range-temperature", try JSONEncoder().encode(FanProfile(start: 39, maximum: 85)))
        ]
        for (label, bytes) in invalid {
            let rejected = try await primary.begin(profile: bytes)
            try record("invalid_profile_reply", rejected, details: ["case": label, "profileByteCount": String(bytes.count)])
            guard rejected.requestError != nil, rejected.sessionID == nil, !rejected.ownsOverride else {
                throw AcceptanceError.failed("Invalid profile was not rejected without acquiring ownership: \(label).")
            }
        }
        let profile = try JSONEncoder().encode(FanProfile(start: 45, maximum: 85))
        for session in ["invalid-uuid", UUID().uuidString] {
            let rejected = try await primary.update(session: session, profile: profile)
            try record("invalid_session_update_reply", rejected, details: ["session": session])
            guard rejected.requestError != nil, rejected.sessionID == nil, !rejected.ownsOverride else {
                throw AcceptanceError.failed("Invalid/foreign session update was not rejected.")
            }
            let renewed = try await primary.renew(session: session)
            try record("invalid_session_renew_reply", details: ["session": session, "accepted": String(renewed)])
            guard !renewed else { throw AcceptanceError.failed("An invalid/foreign session was renewed.") }
        }
        let after = try await primary.status(observe: true)
        try record("hostile_inputs_after", after)
        try requireIdleAutomatic(after)
        try record("hostile_inputs_completed", details: ["scope": "Authenticated invalid input rejection. Wrong-signature live client rejection is a separate case; no valid activation or stop was sent."])
    }

    func rejectedClient() async throws {
        let status: FanStatus
        do {
            status = try await primary.status(observe: false)
        } catch {
            if case AcceptanceError.helperReply = error {
                try record("untrusted_client_received_malformed_reply", details: ["message": error.localizedDescription])
                throw AcceptanceError.failed("A deliberately untrusted client received helper reply bytes; malformed replies do not prove signing rejection.")
            }
            let failure = error as NSError
            try record("untrusted_client_transport_rejection", details: ["errorDomain": failure.domain,
                       "errorCode": String(failure.code), "message": failure.localizedDescription,
                       "securityConclusion": "Unqualified until a working authenticated service is independently corroborated; service-unavailable is not a security pass.",
                       "request": "One status(observe:false), no activation, renewal or stop."])
            return
        }
        try record("untrusted_client_received_status", status)
        throw AcceptanceError.failed("A deliberately untrusted signing fixture received a helper status reply.")
    }

    func roundTrip(duration: TimeInterval) async throws {
        guard duration.isFinite, (1...60).contains(duration) else { throw AcceptanceError.failed("Native duration must be 1–60 seconds.") }
        let baseline = try await initialObservation()
        do {
            try requireIdleAutomatic(baseline)
            let frame = baseline.snapshot!, capabilities = baseline.capabilities!
            guard frame.cpuDieMaximum(in: capabilities) < 85, frame.hottestGPU(in: capabilities) < 80,
                  frame.thermalPressure.rawValue <= FanThermalPressure.fair.rawValue else {
                throw AcceptanceError.failed("Ordinary native precondition needs CPU die maximum <85 °C, hottest GPU <80 °C and nominal/fair thermal pressure.")
            }
        } catch {
            try record("native_precondition_unqualified", baseline, details: ["message": error.localizedDescription,
                       "nativeBeginSent": "false", "scope": "Precondition only; fresh read-only observation may establish later eligibility. No native attempt or retry occurred."])
            throw error
        }
        let capabilities = baseline.capabilities!
        try record("native_round_trip_preflight", baseline, details: ["profile": "45/85", "sessionBoundSeconds": String(duration),
                   "stability": "Two distinct fresh custom frames with requested-target drift ≤50 RPM from the window's first target; each effective target within 2 RPM of its request; resets are retained.",
                   "measuredConvergence": "±10% within 20 seconds after target stability; effective target acknowledgement is separate."])
        let supervisor = AcceptanceSessionSupervisor(client: primary, log: log, clock: clock)
        let startedAt = clock.now
        let deadline = Task {
            do { try await clock.sleep(seconds: duration) } catch { return }
            await supervisor.fail("No completed ordinary convergence acceptance before the selected native session bound.")
            _ = await supervisor.release(reason: "Selected native session bound reached.")
        }
        var renewal: Task<Void, Never>?
        do {
            let profile = try JSONEncoder().encode(FanProfile(start: 45, maximum: 85))
            let begin = try await primary.begin(profile: profile)
            try record("native_begin_reply", begin)
            guard begin.requestError == nil, let session = begin.sessionID,
                  UUID(uuidString: session) != nil else {
                throw AcceptanceError.failed(begin.requestError ?? begin.reason ?? "Ordinary begin did not acquire a session.")
            }
            renewal = Task {
                while !Task.isCancelled {
                    do { try await self.clock.sleep(seconds: 1) } catch { return }
                    if Task.isCancelled { return }
                    do {
                        let accepted = try await self.primary.renew(session: session)
                        if Task.isCancelled {
                            try? self.record("lease_reply_after_completion", details: ["session": session, "accepted": String(accepted)])
                            return
                        }
                        try self.record("lease_renewal", details: ["session": session, "accepted": String(accepted)])
                        guard accepted else { throw AcceptanceError.failed("The ordinary test owner lease was rejected.") }
                    } catch {
                        if Task.isCancelled { return }
                        await supervisor.fail(error.localizedDescription)
                        _ = await supervisor.release(reason: "Owner lease/recording failure.")
                        return
                    }
                }
            }
            if let failure = await supervisor.failure { throw AcceptanceError.failed(failure) }
            guard clock.now - startedAt < duration - 6 else {
                throw AcceptanceError.failed("Less than six seconds remain for the second-owner check; no secondary activation is sent.")
            }
            try await checkSecondOwner(session: session, profile: profile)
            var convergence = RPMConvergence()
            while clock.now - startedAt < duration {
                if let failure = await supervisor.failure { throw AcceptanceError.failed(failure) }
                let status = try await primary.status(observe: true)
                try record("native_status", status)
                try requireComplete(status)
                guard status.sessionID == session, status.capabilities == capabilities,
                      conflict() == nil, ![.restoring, .restorationFailed, .unavailable, .paused].contains(status.mode) else {
                    throw AcceptanceError.failed(status.reason ?? "Ordinary control lost its owner, capabilities or no-conflict basis.")
                }
                guard status.mode != .protection else {
                    throw AcceptanceError.failed("Fixed protection activated; this ordinary acceptance is stopped without weakening protection.")
                }
                if status.mode == .custom {
                    do { _ = try convergence.observe(status, now: clock.now) }
                    catch { try retainConvergence(convergence.lastUpdates, status: status); throw error }
                    try retainConvergence(convergence.lastUpdates, status: status)
                    if convergence.qualified(fans: capabilities.fans) {
                        try record("ordinary_control_qualified", status)
                        break
                    }
                }
                try await clock.sleep(seconds: min(1, max(0, duration - (clock.now - startedAt))))
            }
            guard convergence.qualified(fans: capabilities.fans) else {
                throw AcceptanceError.failed("No stable, measured ordinary target qualified within the selected native session bound.")
            }
            deadline.cancel(); renewal?.cancel()
            let released = await supervisor.release(reason: "Ordinary control acceptance completed.")
            await renewal?.value
            if let failure = await supervisor.failure { throw AcceptanceError.failed(failure) }
            guard let released else { throw AcceptanceError.failed("Automatic release is unverified.") }
            try record("native_round_trip_completed", released, details: ["nativeElapsedSeconds": String(clock.now - startedAt),
                       "scope": "One ordinary 45/85 round trip, second-owner rejection, effective readbacks and measured response. Fault/lifecycle/sustained/distribution acceptance is unperformed."])
        } catch {
            await supervisor.fail(error.localizedDescription)
            deadline.cancel(); renewal?.cancel()
            _ = await supervisor.release(reason: "First acceptance failure; no activation retry.")
            await renewal?.value
            throw AcceptanceError.failed(await supervisor.failure ?? error.localizedDescription)
        }
    }

    private func checkSecondOwner(session: String, profile: Data) async throws {
        let second = try makeSecondary(); defer { second.close() }
        let begin = try await second.begin(profile: profile)
        try record("second_owner_begin_reply", begin, details: ["secondPeerPID": second.peerPID.map { String($0) } ?? "unknown"])
        guard begin.requestError != nil, begin.sessionID == session else {
            // Unexpected secondary acquisition is itself the first failure.
            // Release it explicitly rather than relying on connection teardown.
            if begin.requestError == nil, begin.sessionID != nil, begin.sessionID != session {
                try log.firstFailure("The secondary connection unexpectedly acquired a new session.", status: begin)
                let released = try await second.stop()
                try record("unexpected_secondary_release_reply", released)
            }
            throw AcceptanceError.failed("A second authenticated connection did not receive busy while preserving the first session.")
        }
        let accepted = try await second.renew(session: session)
        try record("second_owner_renew_reply", details: ["accepted": String(accepted)])
        guard !accepted else { throw AcceptanceError.failed("Second connection renewed the first owner's session.") }
        let update = try await second.update(session: session, profile: profile)
        try record("second_owner_update_reply", update)
        guard update.requestError != nil, update.sessionID == session else {
            throw AcceptanceError.failed("Second connection revised/replaced the first owner's session.")
        }
        let stop = try await second.stop()
        try record("second_owner_stop_reply", stop)
        guard stop.requestError != nil, stop.sessionID == session else {
            throw AcceptanceError.failed("Second connection stopped/replaced the first owner's healthy session.")
        }
        let owner = try await primary.status(observe: true)
        try record("first_owner_after_second_client", owner)
        guard owner.sessionID == session, owner.requestError == nil else {
            throw AcceptanceError.failed("First owner's active session did not survive second-client checks.")
        }
    }

    private func retainConvergence(_ updates: [RPMConvergence.Update], status: FanStatus) throws {
        for update in updates {
            try record(update.event, status, details: ["fan": String(update.fan), "requestedRPM": String(update.target),
                       "measuredRPM": String(update.measured), "stableFrames": String(update.stableFrames),
                       "relativeError": String(update.relativeError),
                       "secondsSinceStable": update.elapsedSinceStable.map { String($0) } ?? "not-stable"])
        }
    }
}
