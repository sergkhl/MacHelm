import XCTest
import FanControlCore
@testable import FanControlAcceptance

final class AcceptanceTests: XCTestCase {
    func testNativeSelectionRequiresExplicitBoundAndWriteFlag() throws {
        let paths = ["--app", "/tmp/app", "--output", "/tmp/new.jsonl"]
        XCTAssertThrowsError(try AcceptanceOptions.parse(["round-trip"] + paths + ["--duration", "30"]))
        XCTAssertThrowsError(try AcceptanceOptions.parse(["round-trip"] + paths + ["--allow-native-writes", "--duration", "61"]))
        XCTAssertThrowsError(try AcceptanceOptions.parse(["status"] + paths + ["--allow-native-writes"]))
        XCTAssertThrowsError(try AcceptanceOptions.parse(["round-trip"] + paths + ["--allow-native-writes", "--duration", "nan"]))
        XCTAssertEqual(try AcceptanceOptions.parse(["round-trip"] + paths + ["--allow-native-writes", "--duration", "60"]).duration, 60)
    }

    func testMeasuredResponseRequiresDistinctStableFramesAndResetsDrift() throws {
        var monitor = RPMConvergence()
        _ = try monitor.observe(Self.status(at: 1, target: 4000, measured: 4000), now: 1)
        XCTAssertFalse(monitor.qualified(fans: Self.capabilities.fans))
        XCTAssertTrue(try monitor.observe(Self.status(at: 1, target: 4000, measured: 4000), now: 1).isEmpty)
        // A request that moves up to 50 RPM from the window's first target keeps
        // the window; measured RPM is judged against that frame's own request.
        let held = try monitor.observe(Self.status(at: 2, target: 4050, measured: 3646), now: 2)
        XCTAssertEqual(held.first?.event, "measured_rpm_converged")
        XCTAssertTrue(monitor.qualified(fans: Self.capabilities.fans))
        let reset = try monitor.observe(Self.status(at: 3, target: 4051, measured: 4051), now: 3)
        XCTAssertEqual(reset.first?.event, "convergence_window_reset")
        XCTAssertFalse(monitor.qualified(fans: Self.capabilities.fans))
        // Drift is measured from the window's first target, not the previous frame.
        var drifting = RPMConvergence()
        _ = try drifting.observe(Self.status(at: 1, target: 4000, measured: 4000), now: 1)
        XCTAssertEqual(try drifting.observe(Self.status(at: 2, target: 4030, measured: 4030), now: 2).first?.event,
                       "measured_rpm_converged")
        XCTAssertEqual(try drifting.observe(Self.status(at: 3, target: 4060, measured: 4060), now: 3).first?.event,
                       "convergence_window_reset")
        XCTAssertEqual(RPMConvergence.stabilityAllowanceRPM, 50)
        XCTAssertEqual(RPMConvergence.readbackToleranceRPM, 2)
    }

    func testTargetReceiptIsSeparateFromActualConvergenceAndExpiresAtTwentySeconds() throws {
        var monitor = RPMConvergence()
        _ = try monitor.observe(Self.status(at: 1, target: 4000, measured: 3000), now: 1)
        _ = try monitor.observe(Self.status(at: 2, target: 4000, measured: 3000), now: 2)
        XCTAssertFalse(monitor.qualified(fans: Self.capabilities.fans))
        XCTAssertThrowsError(try monitor.observe(Self.status(at: 22, target: 4000, measured: 3000), now: 22))
        var wrongTarget = Self.status(at: 1, target: 4000, measured: 4000)
        wrongTarget.snapshot?.fans[0].targetRPM = 4003
        var wrongMonitor = RPMConvergence()
        XCTAssertThrowsError(try wrongMonitor.observedForTest(wrongTarget))
        var late = RPMConvergence()
        _ = try late.observe(Self.status(at: 1, target: 4000, measured: 3000), now: 1)
        _ = try late.observe(Self.status(at: 2, target: 4000, measured: 3000), now: 2)
        XCTAssertThrowsError(try late.observe(Self.status(at: 23, target: 4000, measured: 4000), now: 23))
    }

    func testLateRPCCompletionCannotReplaceFirstReceipt() async throws {
        let value: Int = try await withCheckedThrowingContinuation { continuation in
            let reply = AcceptanceReply(continuation)
            reply.finish(.success(7))
            reply.finish(.failure(AcceptanceError.failed("Late timeout must not resume again")))
        }
        XCTAssertEqual(value, 7)
    }

    func testJSONLPreservesFirstFailureAndRefusesExistingOrSymlinkOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("evidence.jsonl")
        let log = try AcceptanceJSONL(path: path.path, evidenceTier: "fake-local")
        try log.firstFailure("initial cause")
        try log.firstFailure("later cleanup cause")
        try log.record("release_failed", details: ["message": "later cleanup cause"])
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(AcceptanceEvent.self, from: Data($0.utf8))
        }
        XCTAssertEqual(lines.filter { $0.event == "first_failure" }.count, 1)
        XCTAssertEqual(lines.first?.detail["message"], "initial cause")
        XCTAssertEqual(lines.last?.event, "release_failed")
        XCTAssertThrowsError(try AcceptanceJSONL(path: path.path))
        let symlink = directory.appendingPathComponent("alias.jsonl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: path)
        XCTAssertThrowsError(try AcceptanceJSONL(path: symlink.path))
    }

    func testHostileInputRunNeverSendsAValidActivationOrStop() async throws {
        let clock = FakeAcceptanceClock(now: 1)
        let client = FakeAcceptanceClient(status: Self.idle(at: 1))
        let log = FakeAcceptanceLog()
        let runner = FanAcceptanceRunner(primary: client, makeSecondary: { XCTFail("No second client needed"); return client },
                                         log: log, clock: clock, conflict: { nil })
        try await runner.hostileInputs()
        XCTAssertEqual(client.profiles.count, 4)
        XCTAssertEqual(client.validBegins, 0)
        XCTAssertEqual(client.stops, 0)
        XCTAssertEqual(client.renewals, 2)
        XCTAssertTrue(log.events.contains("hostile_inputs_completed"))
    }

    func testColdIdlePausedStatusGetsOneReadOnlyWarmupAndRetainsHistoricalReason() async throws {
        let clock = FakeAcceptanceClock(now: 1)
        var cold = Self.idle(at: 1)
        cold.mode = .paused; cold.reason = "Earlier stop reason"
        cold.snapshot = nil; cold.fanProbe = nil
        var observed = Self.idle(at: 2)
        observed.mode = .paused; observed.reason = cold.reason
        let client = FakeAcceptanceClient(status: cold)
        client.statusReplies = [cold, observed]
        let log = FakeAcceptanceLog()
        let runner = FanAcceptanceRunner(primary: client, makeSecondary: { client }, log: log,
                                         clock: clock, conflict: { nil })
        try await runner.status(samples: 1)
        XCTAssertEqual(client.observedSelections, [true, true])
        XCTAssertEqual(clock.sleeps, [1])
        XCTAssertEqual(client.validBegins, 0); XCTAssertTrue(client.profiles.isEmpty)
        XCTAssertEqual(client.stops, 0)
        let warmup = try XCTUnwrap(log.events.firstIndex(of: "observation_armed"))
        XCTAssertEqual(log.details[warmup]["historicalReason"], cold.reason)
        XCTAssertEqual(log.statuses[warmup]?.reason, cold.reason)
        let sample = try XCTUnwrap(log.events.firstIndex(of: "status_sample"))
        XCTAssertEqual(log.details[sample]["automaticReadback"], "true")
        XCTAssertEqual(log.statuses[sample]?.mode, .paused)
        XCTAssertEqual(log.statuses[sample]?.reason, cold.reason)
        XCTAssertTrue(log.events.contains("status_qualification_completed"))
    }

    func testColdPausedWarmupDoesNotRetryAndMissingObservationIsUnknown() async throws {
        let clock = FakeAcceptanceClock(now: 1)
        var cold = Self.idle(at: 1)
        cold.mode = .paused; cold.reason = "Historical pause reason"
        cold.snapshot = nil; cold.fanProbe = nil
        let client = FakeAcceptanceClient(status: cold)
        client.statusReplies = [cold, cold, Self.idle(at: 3)]
        let log = FakeAcceptanceLog()
        let runner = FanAcceptanceRunner(primary: client, makeSecondary: { client }, log: log,
                                         clock: clock, conflict: { nil })
        do { try await runner.status(samples: 1); XCTFail("Missing telemetry must remain unqualified") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("No complete fresh qualified helper telemetry"))
            XCTAssertFalse(error.localizedDescription.contains("Historical pause reason"))
        }
        XCTAssertEqual(client.observedSelections, [true, true])
        XCTAssertEqual(clock.sleeps, [1])
        XCTAssertEqual(client.statusReplies.count, 1)
        XCTAssertEqual(client.validBegins, 0); XCTAssertEqual(client.stops, 0)
        let sample = try XCTUnwrap(log.events.firstIndex(of: "status_sample"))
        XCTAssertEqual(log.details[sample]["automaticReadback"], "unknown")
        XCTAssertFalse(log.events.contains("status_qualification_completed"))
    }

    func testCurrentInvalidPausedFrameIsRejectedWithoutWarmupOrResampling() async throws {
        let clock = FakeAcceptanceClock(now: 1)
        var invalid = Self.idle(at: 1, maximum: 6)
        invalid.mode = .paused; invalid.reason = "Historical pause reason"
        let client = FakeAcceptanceClient(status: invalid)
        client.statusReplies = [invalid, Self.idle(at: 2)]
        let log = FakeAcceptanceLog()
        let runner = FanAcceptanceRunner(primary: client, makeSecondary: { client }, log: log,
                                         clock: clock, conflict: { nil })
        do { try await runner.status(samples: 1); XCTFail("Current invalid frame must fail") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("TCMz"))
            XCTAssertFalse(error.localizedDescription.contains("Historical pause reason"))
        }
        XCTAssertEqual(client.observedSelections, [true])
        XCTAssertTrue(clock.sleeps.isEmpty)
        XCTAssertEqual(client.statusReplies.count, 1)
        XCTAssertEqual(client.validBegins, 0); XCTAssertEqual(client.stops, 0)
        XCTAssertFalse(log.events.contains("observation_armed"))
        XCTAssertFalse(log.events.contains("status_qualification_completed"))
    }

    func testUnavailableOrOwnedPausedEmptyStateIsNotWarmedUp() async throws {
        for unavailable in [true, false] {
            let clock = FakeAcceptanceClock(now: 1)
            var faulty = Self.idle(at: 1)
            faulty.snapshot = nil; faulty.fanProbe = nil
            faulty.reason = "Existing fault reason"
            if unavailable { faulty.mode = .unavailable }
            else { faulty.mode = .paused; faulty.ownsOverride = true; faulty.sessionID = UUID().uuidString }
            let client = FakeAcceptanceClient(status: faulty)
            client.statusReplies = [faulty, Self.idle(at: 2)]
            let log = FakeAcceptanceLog()
            let runner = FanAcceptanceRunner(primary: client, makeSecondary: { client }, log: log,
                                             clock: clock, conflict: { nil })
            do { try await runner.status(samples: 1); XCTFail("Faulted/owned state must stay unqualified") }
            catch { XCTAssertTrue(error.localizedDescription.contains("No complete fresh")) }
            XCTAssertEqual(client.observedSelections, [true])
            XCTAssertTrue(clock.sleeps.isEmpty)
            XCTAssertEqual(client.statusReplies.count, 1)
            XCTAssertEqual(client.validBegins, 0); XCTAssertEqual(client.stops, 0)
            XCTAssertFalse(log.events.contains("observation_armed"))
        }
    }

    func testHotOrdinaryPreflightIsUnqualifiedBeforeAnyNativeBegin() async throws {
        let client = FakeAcceptanceClient(status: Self.idle(at: 1, maximum: 85))
        let log = FakeAcceptanceLog()
        let runner = FanAcceptanceRunner(primary: client, makeSecondary: { client }, log: log,
                                         clock: FakeAcceptanceClock(now: 1), conflict: { nil })
        do { try await runner.roundTrip(duration: 60); XCTFail("Hot preflight must refuse native activation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("<85")) }
        XCTAssertEqual(client.validBegins, 0)
        XCTAssertTrue(client.profiles.isEmpty)
        XCTAssertEqual(client.stops, 0)
        XCTAssertTrue(log.events.contains("native_precondition_unqualified"))
    }

    func testUntrustedClientRejectionNeverLabelsUnavailableServiceAsSecurityPass() async throws {
        let client = FakeAcceptanceClient(status: Self.idle(at: 1))
        client.statusError = NSError(domain: NSCocoaErrorDomain, code: 4099,
                                     userInfo: [NSLocalizedDescriptionKey: "Unavailable/rejected service"])
        let log = FakeAcceptanceLog()
        let runner = FanAcceptanceRunner(primary: client, makeSecondary: { client }, log: log,
                                         clock: FakeAcceptanceClock(now: 1), conflict: { nil })
        try await runner.rejectedClient()
        XCTAssertEqual(client.observedSelections, [false])
        XCTAssertEqual(client.validBegins, 0)
        XCTAssertEqual(client.stops, 0)
        XCTAssertTrue(log.details.last?["securityConclusion"]?.contains("Unqualified") == true)
        XCTAssertFalse(log.events.contains("security_pass"))
        client.statusError = AcceptanceError.helperReply("Malformed bytes")
        do { try await runner.rejectedClient(); XCTFail("A helper byte reply is not signing rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("reply bytes")) }
    }

    func testConcurrentCleanupSendsOneStopAndRetainsOriginalFailure() async throws {
        let client = FakeAcceptanceClient(status: Self.idle(at: 1))
        client.stopError = AcceptanceError.failed("Fake restore transport failed")
        let log = FakeAcceptanceLog()
        let supervisor = AcceptanceSessionSupervisor(client: client, log: log, clock: FakeAcceptanceClock(now: 1))
        await supervisor.fail("First measured-response failure")
        async let first = supervisor.release(reason: "test failure")
        async let second = supervisor.release(reason: "test bound")
        let replies = await (first, second)
        XCTAssertNil(replies.0); XCTAssertNil(replies.1)
        XCTAssertEqual(client.stops, 1)
        XCTAssertEqual(log.firstFailures, ["First measured-response failure"])
        XCTAssertTrue(log.events.contains("release_failed"))
    }

    func testEvidenceFailureStillSendsNativeCleanup() async throws {
        let client = FakeAcceptanceClient(status: Self.idle(at: 1))
        let log = FakeAcceptanceLog(); log.failWrites = true
        let supervisor = AcceptanceSessionSupervisor(client: client, log: log, clock: FakeAcceptanceClock(now: 1))
        let reply = await supervisor.release(reason: "fake evidence failure")
        XCTAssertNil(reply)
        XCTAssertEqual(client.stops, 1)
        let failure = await supervisor.failure
        XCTAssertTrue(failure?.contains("release-request evidence") == true)
    }

    func testFakeOrdinaryRoundTripRejectsSecondOwnerAndVerifiesOneRelease() async throws {
        let gate = FakeLiveAcceptanceGate()
        let primary = FakeLiveAcceptanceClient(gate: gate, owner: true)
        let secondary = FakeLiveAcceptanceClient(gate: gate, owner: false)
        let log = FakeAcceptanceLog()
        let runner = FanAcceptanceRunner(primary: primary, makeSecondary: { secondary }, log: log, conflict: { nil })
        try await runner.roundTrip(duration: 30)
        XCTAssertEqual(primary.begins, 1)
        XCTAssertEqual(secondary.begins, 1)
        XCTAssertEqual(primary.stops, 1)
        XCTAssertEqual(secondary.stops, 1) // Rejected wrong-owner stop, not a hardware release.
        XCTAssertTrue(log.events.contains("ordinary_control_qualified"))
        XCTAssertTrue(log.events.contains("release_verified"))
        XCTAssertTrue(log.events.contains("native_round_trip_completed"))
        XCTAssertTrue(log.firstFailures.isEmpty)
        XCTAssertNil(gate.session)
    }

    // A stop reply after the helper's own recovery attempt has every release
    // field clean. It is still not a normal release, and the trip must not pass.
    func testAStopReplyCarryingASelfRecoveryReceiptIsNotAVerifiedRelease() async throws {
        var recovered = Self.idle(at: 1)
        recovered.mode = .paused; recovered.reason = "A fan command could not be confirmed. The fans were returned to automatic and checked."
        recovered.selfRecoveryReceipt = FanSelfRecoveryReceipt(recoveryID: UUID().uuidString, trigger: .automatic, cause: "deadline",
            unconfirmed: .mode(fan: 0, manual: false), startedAt: 0.5)
        let client = FakeAcceptanceClient(status: recovered)
        let log = FakeAcceptanceLog()
        let supervisor = AcceptanceSessionSupervisor(client: client, log: log, clock: FakeAcceptanceClock(now: 1))
        let reply = await supervisor.release(reason: "fake completion")
        XCTAssertNil(reply); XCTAssertEqual(client.stops, 1)
        let failure = await supervisor.failure
        XCTAssertTrue(failure?.contains("own recovery attempt ran (automatic, cause deadline)") == true, failure ?? "no failure")
        XCTAssertTrue(log.events.contains("release_reply")); XCTAssertTrue(log.events.contains("release_failed"))
        XCTAssertFalse(log.events.contains("release_verified"))
        // The evidence keeps the reply itself, receipt included.
        let recorded = try XCTUnwrap(log.events.firstIndex(of: "release_reply"))
        XCTAssertEqual(log.statuses[recorded]?.selfRecoveryReceipt?.cause, "deadline")
        // The same reply without a receipt is a verified release.
        recovered.selfRecoveryReceipt = nil
        let ordinary = AcceptanceSessionSupervisor(client: FakeAcceptanceClient(status: recovered), log: FakeAcceptanceLog(),
                                                   clock: FakeAcceptanceClock(now: 1))
        let verified = await ordinary.release(reason: "fake completion")
        XCTAssertNotNil(verified)
    }

    func testARoundTripWhoseStopEndsInSelfRecoveryDoesNotComplete() async throws {
        let gate = FakeLiveAcceptanceGate(); gate.selfRecoveryAtStop = true
        let primary = FakeLiveAcceptanceClient(gate: gate, owner: true)
        let secondary = FakeLiveAcceptanceClient(gate: gate, owner: false)
        let log = FakeAcceptanceLog()
        let runner = FanAcceptanceRunner(primary: primary, makeSecondary: { secondary }, log: log, conflict: { nil })
        do { try await runner.roundTrip(duration: 30); XCTFail("A self-recovered stop must not pass") }
        catch { XCTAssertTrue(error.localizedDescription.contains("recovery attempt"), error.localizedDescription) }
        XCTAssertEqual(primary.begins, 1); XCTAssertEqual(primary.stops, 1)
        XCTAssertTrue(log.events.contains("ordinary_control_qualified"))
        XCTAssertTrue(log.events.contains("release_failed"))
        XCTAssertFalse(log.events.contains("release_verified"))
        XCTAssertFalse(log.events.contains("native_round_trip_completed"))
        XCTAssertEqual(log.firstFailures.count, 1)
    }

    func testFakeBadNativeReadbackStopsAtFirstFailureWithoutAnotherBegin() async throws {
        let gate = FakeLiveAcceptanceGate(); gate.wrongEffectiveTarget = true
        let primary = FakeLiveAcceptanceClient(gate: gate, owner: true)
        let secondary = FakeLiveAcceptanceClient(gate: gate, owner: false)
        let log = FakeAcceptanceLog()
        let runner = FanAcceptanceRunner(primary: primary, makeSecondary: { secondary }, log: log, conflict: { nil })
        do { try await runner.roundTrip(duration: 30); XCTFail("Wrong readback must stop") }
        catch { XCTAssertTrue(error.localizedDescription.contains("acknowledgement")) }
        XCTAssertEqual(primary.begins, 1)
        XCTAssertEqual(primary.stops, 1)
        XCTAssertEqual(log.firstFailures.count, 1)
        XCTAssertTrue(log.events.contains("release_verified"))
        XCTAssertFalse(log.events.contains("native_round_trip_completed"))
        XCTAssertNil(gate.session)
    }

    static let capabilities = FanCapabilities(model: "Mac14,9", sensors: [
        FanSensor(key: "TCMb", role: .cpuAverage, encoding: "flt "),
        FanSensor(key: "TCMz", role: .cpuMaximum, encoding: "flt "),
        FanSensor(key: "Tg0f", role: .gpuProtection, encoding: "flt ")
    ], fans: [FanDescriptor(id: 0, minimumRPM: 2317, maximumRPM: 6800, modeKey: "F0Md", targetEncoding: "flt ")], hasGlobalUnlock: true)
    static func status(at time: TimeInterval, target: Double, measured: Double) -> FanStatus {
        var status = FanStatus(serviceGeneration: UUID().uuidString)
        status.capabilities = capabilities; status.mode = .custom
        status.requestedRPM = [0: target]
        status.snapshot = FanSnapshot(capturedAt: time, temperatures: ["TCMb": 60, "TCMz": 65, "Tg0f": 55],
                                      fans: [FanReading(id: 0, actualRPM: measured, targetRPM: target, mode: 1)],
                                      thermalPressure: .nominal, globalUnlock: 1)
        return status
    }
    static func idle(at time: TimeInterval, maximum: Double = 65) -> FanStatus {
        var status = FanStatus(serviceGeneration: UUID().uuidString)
        status.capabilities = capabilities; status.mode = .automatic
        let reading = FanReading(id: 0, actualRPM: 2317, targetRPM: 0, mode: 0)
        status.snapshot = FanSnapshot(capturedAt: time, temperatures: ["TCMb": 60, "TCMz": maximum, "Tg0f": 55],
                                      fans: [reading], thermalPressure: .nominal, globalUnlock: 0)
        status.fanProbe = FanFanProbe(model: capabilities.model, fans: capabilities.fans,
                                     observation: FanControlObservation(capturedAt: time, fans: [reading], globalUnlock: 0))
        status.releaseVerified = true; status.safeToUnregister = true
        return status
    }
}

private extension RPMConvergence {
    mutating func observedForTest(_ status: FanStatus) throws { _ = try observe(status, now: 1) }
}

private final class FakeAcceptanceClock: AcceptanceClock {
    var now: TimeInterval
    var sleeps: [TimeInterval] = []
    init(now: TimeInterval) { self.now = now }
    func sleep(seconds: TimeInterval) async throws { sleeps.append(seconds); now += seconds }
}

private final class FakeAcceptanceClient: AcceptanceClient {
    let peerPID: Int32? = 555
    var reply: FanStatus
    var statusError: Error?
    var stopError: Error?
    var profiles: [Data] = []
    var observedSelections: [Bool] = []
    var statusReplies: [FanStatus] = []
    var validBegins = 0
    var stops = 0
    var renewals = 0
    init(status: FanStatus) { reply = status }
    func status(observe: Bool) async throws -> FanStatus {
        observedSelections.append(observe)
        if let statusError { throw statusError }
        if !statusReplies.isEmpty { return statusReplies.removeFirst() }
        return reply
    }
    func begin(profile: Data) async throws -> FanStatus {
        profiles.append(profile)
        do {
            guard profile.count <= 512 else { throw AcceptanceError.failed("Fake oversized profile") }
            try JSONDecoder().decode(FanProfile.self, from: profile).validate()
            validBegins += 1
        } catch { var response = reply; response.requestError = error.localizedDescription; return response }
        return reply
    }
    func update(session: String, profile: Data) async throws -> FanStatus {
        var response = reply; response.requestError = "Fake rejected session"; return response
    }
    func renew(session: String) async throws -> Bool { renewals += 1; return false }
    func stop() async throws -> FanStatus {
        stops += 1
        if let stopError { throw stopError }
        return reply
    }
    func close() {}
}

private final class FakeAcceptanceLog: AcceptanceRecording {
    private let lock = NSLock()
    var events: [String] = []
    var details: [[String: String]] = []
    var statuses: [FanStatus?] = []
    var firstFailures: [String] = []
    var failWrites = false
    func record(_ event: String, details: [String: String], status: FanStatus?) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw AcceptanceError.failed("Fake evidence I/O failure") }
        events.append(event); self.details.append(details); statuses.append(status)
    }
    func firstFailure(_ message: String, status: FanStatus?) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw AcceptanceError.failed("Fake evidence I/O failure") }
        if firstFailures.isEmpty { firstFailures.append(message) }
    }
}

private final class FakeLiveAcceptanceGate {
    var session: String?
    var wrongEffectiveTarget = false
    var selfRecoveryAtStop = false
    func status() -> FanStatus {
        let time = ProcessInfo.processInfo.systemUptime
        guard let session else { return AcceptanceTests.idle(at: time) }
        var status = AcceptanceTests.status(at: time, target: 4000, measured: 4000)
        status.sessionID = session; status.ownsOverride = true
        if wrongEffectiveTarget { status.snapshot?.fans[0].targetRPM = 4003 }
        return status
    }
}

private final class FakeLiveAcceptanceClient: AcceptanceClient {
    let peerPID: Int32? = 556
    let gate: FakeLiveAcceptanceGate
    let owner: Bool
    var begins = 0
    var stops = 0
    init(gate: FakeLiveAcceptanceGate, owner: Bool) { self.gate = gate; self.owner = owner }
    func status(observe: Bool) async throws -> FanStatus { gate.status() }
    func begin(profile: Data) async throws -> FanStatus {
        begins += 1
        try JSONDecoder().decode(FanProfile.self, from: profile).validate()
        if gate.session != nil { var response = gate.status(); response.requestError = "Fake busy"; return response }
        gate.session = UUID().uuidString
        return gate.status()
    }
    func update(session: String, profile: Data) async throws -> FanStatus {
        var response = gate.status(); response.requestError = "Fake wrong owner"; return response
    }
    func renew(session: String) async throws -> Bool { owner && gate.session == session }
    func stop() async throws -> FanStatus {
        stops += 1
        if !owner { var response = gate.status(); response.requestError = "Fake wrong-owner stop"; return response }
        let ended = gate.session
        gate.session = nil
        var reply = gate.status()
        if gate.selfRecoveryAtStop, let ended {
            reply.mode = .paused
            reply.selfRecoveryReceipt = FanSelfRecoveryReceipt(recoveryID: ended, trigger: .automatic, cause: "deadline",
                unconfirmed: .mode(fan: 0, manual: false), startedAt: reply.snapshot?.capturedAt ?? 0)
        }
        return reply
    }
    func close() {}
}
