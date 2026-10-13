#if FAN_CONTROL_QUALIFICATION
import XCTest
import Darwin
@testable import FanControlCore
@testable import FanControlHardware
@testable import FanControlRuntime

private final class QualificationNativeFixture: FanHardware {
    let capabilities = FanPolicyTests.capabilities
    var now: TimeInterval = 100
    var temperatures: [String: Double] = ["TCMb": 50, "TCMz": 55, "Tg0f": 45]
    var pressure = FanThermalPressure.nominal
    var readings = FanPolicyTests.frame(50).fans
    var unlock = 0
    var operations: [FanOperation] = []
    var reads = 0
    var failRead = false

    func discover() throws -> FanCapabilities { capabilities }
    func read(_ capabilities: FanCapabilities) throws -> FanSnapshot {
        reads += 1
        if failRead { throw FanControlError.hardware("Native fixture telemetry failure") }
        return FanSnapshot(capturedAt: now, temperatures: temperatures, fans: readings,
                           thermalPressure: pressure, globalUnlock: unlock)
    }
    func readControlState(_ capabilities: FanCapabilities) throws -> FanControlObservation {
        FanControlObservation(capturedAt: now, fans: readings, globalUnlock: unlock)
    }
    func perform(_ operation: FanOperation, capabilities: FanCapabilities, cancelled: () -> Bool) throws {
        guard !cancelled() else { throw FanControlError.cancelled }
        operations.append(operation)
        switch operation {
        case .mode(let id, let manual): readings[id].mode = manual ? 1 : 0
        case .target(let id, let rpm): readings[id].targetRPM = rpm
        case .globalUnlock(let enabled): unlock = enabled ? 1 : 0
        }
    }
}

private final class QualificationMemoryJournal: FanRecoveryPersistence {
    var record: FanRecoveryRecord?
    func load() throws -> FanRecoveryRecord? { record }
    func save(_ record: FanRecoveryRecord) throws { try record.validate(); self.record = record }
    func remove() throws { record = nil }
}

final class FanQualificationTests: XCTestCase {
    private let fixtureBootID = UUID()
    private func wrapper(_ native: QualificationNativeFixture, scenario: FanQualificationScenario?) -> FanQualificationHardware {
        FanQualificationHardware(delegating: native, plan: { _ in
            scenario.map { FanQualificationPlan(runID: UUID(), scenario: $0, expiresAtUptime: native.now + 30) }
        }, clock: { native.now })
    }

    private func provenance(_ hardware: FanQualificationHardware) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(hardware.provenance).utf8)) as? [String: Any])
    }

    func testAbsentInputPreservesNaturalTelemetryAndLabelsQualificationBuild() throws {
        let native = QualificationNativeFixture()
        let hardware = wrapper(native, scenario: nil)
        XCTAssertEqual(try hardware.discover(), native.capabilities)
        let frame = try hardware.read(native.capabilities)
        XCTAssertEqual(frame.temperatures, native.temperatures)
        XCTAssertEqual(frame.fans, native.readings)
        XCTAssertEqual(frame.globalUnlock, native.unlock)
        XCTAssertEqual(frame.thermalPressure, native.pressure)
        let marker = try provenance(hardware)
        XCTAssertEqual(marker["build"] as? String, "FAN_CONTROL_QUALIFICATION")
        XCTAssertEqual(marker["scenario"] as? String, "none")
        XCTAssertEqual(marker["fanStateOrigin"] as? String, "native-unmodified")
        XCTAssertTrue(native.operations.isEmpty)
    }

    func testWhitelistedValidScenariosExerciseRampAndProtectionWithoutChangingFanEvidence() throws {
        let scenarios: [FanQualificationScenario] = [.cpuAverage70, .cpuAverage75, .cpuAverage80, .cpuAverage85,
                                                     .cpuMaximumProtection, .gpuProtection, .pressureSerious, .pressureCritical]
        for scenario in scenarios {
            let native = QualificationNativeFixture(), hardware = wrapper(native, scenario: scenario)
            var policy = FanPolicy()
            if scenario == .cpuMaximumProtection {
                // P-Q1: the injected 90 °C starts protection on its third reading in a row.
                for _ in 0..<2 {
                    XCTAssertFalse(try policy.evaluate(try hardware.read(native.capabilities), capabilities: native.capabilities,
                                                       profile: .standard, now: native.now).protection)
                    native.now += 1
                }
            }
            let frame = try hardware.read(native.capabilities)
            try frame.validate(against: native.capabilities, now: native.now)
            XCTAssertEqual(frame.fans, native.readings, scenario.rawValue)
            XCTAssertEqual(frame.globalUnlock, native.unlock, scenario.rawValue)
            let decision = try policy.evaluate(frame, capabilities: native.capabilities, profile: .standard, now: native.now)
            switch scenario {
            case .cpuAverage70: XCTAssertEqual(decision.demand, 0); XCTAssertFalse(decision.protection)
            case .cpuAverage75: XCTAssertEqual(try XCTUnwrap(decision.demand), 1 / 3.0, accuracy: 0.00001)
            case .cpuAverage80: XCTAssertEqual(try XCTUnwrap(decision.demand), 2 / 3.0, accuracy: 0.00001)
            case .cpuAverage85: XCTAssertEqual(decision.demand, 1); XCTAssertFalse(decision.protection)
            default: XCTAssertEqual(decision.demand, 1); XCTAssertTrue(decision.protection)
            }
            let marker = try provenance(hardware)
            XCTAssertEqual(marker["scenario"] as? String, scenario.rawValue)
            XCTAssertNotNil(marker["runID"])
            XCTAssertEqual(marker["nativeTemperatures"] as? [String: Double], native.temperatures)
            XCTAssertEqual(marker["effectiveCapturedAt"] as? Double, frame.capturedAt)
            XCTAssertTrue(native.operations.isEmpty)
        }
    }

    func testValidInjectionCannotLowerNativeProtectionOrMaskInvalidNativeTelemetry() throws {
        for scenario in [FanQualificationScenario.cpuAverage75, .cpuMaximumProtection, .gpuProtection, .pressureSerious] {
            let native = QualificationNativeFixture()
            native.temperatures = ["TCMb": 95, "TCMz": 100, "Tg0f": 95]; native.pressure = .critical
            let hardware = wrapper(native, scenario: scenario)
            let frame = try hardware.read(native.capabilities)
            XCTAssertEqual(frame.temperatures, native.temperatures)
            XCTAssertEqual(frame.thermalPressure, .critical)
        }
        let native = QualificationNativeFixture(), hardware = wrapper(native, scenario: .cpuAverage75)
        native.temperatures["TCMb"] = 7
        XCTAssertThrowsError(try hardware.read(native.capabilities))
        XCTAssertEqual(try provenance(hardware)["outcome"] as? String, "native-frame-rejected")
        native.failRead = true
        XCTAssertThrowsError(try hardware.read(native.capabilities))
        XCTAssertEqual(try provenance(hardware)["outcome"] as? String, "native-read-failure")
        XCTAssertTrue(native.operations.isEmpty)
    }

    // Finite out-of-range injections make each frame unusable and skipped; the
    // owned controller then stops at the four-second complete-frame
    // deadline. Missing, non-finite, stale and failed reads stop it at once.
    func testEveryDataLossScenarioStopsOwnedControllerAndRestoresUsingNativeReadbacks() throws {
        let skipped: Set<FanQualificationScenario> = [.invalidCPUAverage, .invalidCPUMaximum, .invalidGPU]
        let scenarios: [FanQualificationScenario] = [.missingCPUAverage, .missingCPUMaximum, .missingGPU,
                                                     .invalidCPUAverage, .invalidCPUMaximum, .invalidGPU,
                                                     .nonfiniteCPUAverage, .nonfiniteCPUMaximum, .nonfiniteGPU,
                                                     .staleFrame, .telemetryReadFailure]
        for scenario in scenarios {
            let native = QualificationNativeFixture(), journal = QualificationMemoryJournal()
            var plan = FanQualificationPlan(runID: UUID(), scenario: .cpuAverage75, expiresAtUptime: 130)
            let hardware = FanQualificationHardware(delegating: native, plan: { _ in plan }, clock: { native.now })
            let controller = try FanHelperController(hardware: hardware, persistence: journal,
                                                     bootID: UUID().uuidString, artifactIdentity: "fake-qualification",
                                                     conflict: { nil }, clock: { native.now }, startTimers: false,
                                                     qualificationProvenance: { hardware.provenance })
            let started = expectation(description: "fake begin \(scenario.rawValue)")
            controller.begin(owner: "fixture-owner", profile: .standard) { status in
                XCTAssertEqual(status.mode, .custom); XCTAssertTrue(status.ownsOverride); started.fulfill()
            }
            wait(for: [started], timeout: 2)
            XCTAssertNotNil(journal.record)
            native.now = 101
            plan = FanQualificationPlan(runID: UUID(), scenario: scenario, expiresAtUptime: 130)
            let operations = native.operations
            let polled = expectation(description: "fake fault \(scenario.rawValue)")
            controller.poll { polled.fulfill() }
            wait(for: [polled], timeout: 2)
            if skipped.contains(scenario) {
                XCTAssertEqual(native.operations, operations, "No write on the skipped frame: \(scenario.rawValue)")
                let skippedStatus = controller.status(observe: false)
                XCTAssertNotNil(skippedStatus.sessionID, scenario.rawValue)
                XCTAssertEqual(skippedStatus.mode, .custom, scenario.rawValue)
                XCTAssertTrue(skippedStatus.diagnostics.contains { $0.contains("Unusable frame skipped") }, scenario.rawValue)
                XCTAssertNotNil(journal.record, scenario.rawValue)
                native.now = 103.99
                let waiting = expectation(description: "before the deadline \(scenario.rawValue)")
                controller.poll { waiting.fulfill() }
                wait(for: [waiting], timeout: 2)
                XCTAssertNotNil(controller.status(observe: false).sessionID, scenario.rawValue)
                native.now = 104
                let expired = expectation(description: "deadline \(scenario.rawValue)")
                controller.poll { expired.fulfill() }
                wait(for: [expired], timeout: 2)
                XCTAssertTrue(controller.status(observe: false).reason?.contains("four seconds") == true, scenario.rawValue)
                XCTAssertEqual(native.operations.prefix(operations.count), operations[...], scenario.rawValue)
            }
            let status = controller.status(observe: false)
            XCTAssertEqual(status.mode, .paused, scenario.rawValue)
            XCTAssertNil(status.snapshot, scenario.rawValue)
            XCTAssertNil(status.sessionID, scenario.rawValue)
            XCTAssertFalse(status.ownsOverride, scenario.rawValue)
            XCTAssertTrue(status.releaseVerified, scenario.rawValue)
            XCTAssertTrue(status.safeToUnregister, scenario.rawValue)
            XCTAssertTrue(status.requestedRPM.isEmpty, scenario.rawValue)
            XCTAssertNil(journal.record, scenario.rawValue)
            XCTAssertTrue(try hardware.readControlState(native.capabilities).isFullyAutomatic, scenario.rawValue)
            XCTAssertTrue(native.readings.allSatisfy { $0.targetRPM == 0 }, scenario.rawValue)
            XCTAssertEqual(native.unlock, 0)
            XCTAssertTrue(status.diagnostics.contains { $0.contains("FAN_CONTROL_QUALIFICATION") && $0.contains(scenario.rawValue) })
        }
    }

    func testRejectedPrivateInputNeverBlocksNativeRestorationOrAddsOperations() throws {
        let native = QualificationNativeFixture()
        let hardware = FanQualificationHardware(delegating: native, plan: { _ in
            throw FanControlError.ownership("Unsafe fake qualification file")
        }, clock: { native.now })
        XCTAssertThrowsError(try hardware.read(native.capabilities))
        XCTAssertEqual(native.reads, 0)
        XCTAssertEqual(try provenance(hardware)["outcome"] as? String, "rejected-private-input")
        XCTAssertTrue(try hardware.readControlState(native.capabilities).isFullyAutomatic)
        XCTAssertTrue(try hardware.probeFans().observation.isFullyAutomatic)
        XCTAssertThrowsError(try hardware.perform(.mode(fan: 0, manual: true), capabilities: native.capabilities, cancelled: { true }))
        XCTAssertTrue(native.operations.isEmpty)
        try hardware.perform(.mode(fan: 0, manual: false), capabilities: native.capabilities, cancelled: { false })
        XCTAssertEqual(native.operations, [.mode(fan: 0, manual: false)])
    }

    func testExpiredScenarioCannotAuthorizeOrContinueAFrame() throws {
        let native = QualificationNativeFixture()
        let hardware = FanQualificationHardware(delegating: native, plan: { _ in
            FanQualificationPlan(runID: UUID(), scenario: .cpuAverage75, expiresAtUptime: 100)
        }, clock: { native.now })
        XCTAssertThrowsError(try hardware.read(native.capabilities))
        XCTAssertEqual(try provenance(hardware)["outcome"] as? String, "expired-private-input")
        XCTAssertTrue(native.operations.isEmpty)
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fan-qualification-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    @discardableResult private func writeInput(_ data: Data, directory: URL, mode: mode_t = 0o600) throws -> URL {
        let file = directory.appendingPathComponent("scenario.json")
        try data.write(to: file)
        XCTAssertEqual(chmod(file.path, mode), 0)
        return file
    }

    func testPrivateFixtureFileAcceptsOnlyWhitelistedBoundedPlan() throws {
        let directory = try fixtureDirectory(), source = FanQualificationFileSource(testDirectory: directory, requiredUID: geteuid(), bootID: fixtureBootID)
        XCTAssertNil(try source.load(now: 100))
        let plan = FanQualificationPlan(runID: UUID(), bootID: fixtureBootID, scenario: .gpuProtection, expiresAtUptime: 130)
        try writeInput(JSONEncoder().encode(plan), directory: directory)
        XCTAssertEqual(try source.load(now: 100), plan)
        let foreignBoot = FanQualificationPlan(runID: UUID(), bootID: UUID(), scenario: .gpuProtection, expiresAtUptime: 130)
        try writeInput(JSONEncoder().encode(foreignBoot), directory: directory)
        XCTAssertThrowsError(try source.load(now: 100))
        try writeInput(JSONEncoder().encode(plan), directory: directory)
        for time in [130.0, 99.0 - 60] { XCTAssertThrowsError(try source.load(now: time)) }
        let malformed = [
            "{}",
            "{\"version\":2,\"runID\":\"\(UUID().uuidString)\",\"bootID\":\"\(fixtureBootID.uuidString)\",\"scenario\":\"gpu-protection\",\"expiresAtUptime\":130}",
            "{\"version\":1,\"runID\":\"\(UUID().uuidString)\",\"bootID\":\"\(fixtureBootID.uuidString)\",\"scenario\":\"arbitrary-smc-write\",\"expiresAtUptime\":130}",
            "{\"version\":1,\"runID\":\"\(UUID().uuidString)\",\"bootID\":\"\(fixtureBootID.uuidString)\",\"scenario\":\"gpu-protection\",\"expiresAtUptime\":130,\"path\":\"/tmp/input\"}",
            "{\"version\":1,\"runID\":\"invalid\",\"bootID\":\"\(fixtureBootID.uuidString)\",\"scenario\":\"gpu-protection\",\"expiresAtUptime\":130}"
        ]
        for json in malformed {
            try writeInput(Data(json.utf8), directory: directory)
            XCTAssertThrowsError(try source.load(now: 100))
        }
    }

    func testFilePermissionsSizeTypeLinksAndServiceOwnerFailClosed() throws {
        let data = try JSONEncoder().encode(FanQualificationPlan(runID: UUID(), bootID: fixtureBootID, scenario: .gpuProtection, expiresAtUptime: 130))
        for mode in [mode_t(0o640), 0o644, 0o400, 0o660, 0o4600] {
            let directory = try fixtureDirectory(), source = FanQualificationFileSource(testDirectory: directory, requiredUID: geteuid(), bootID: fixtureBootID)
            try writeInput(data, directory: directory, mode: mode)
            XCTAssertThrowsError(try source.load(now: 100))
        }
        for invalid in [Data(), Data(repeating: 0x20, count: 4_097)] {
            let directory = try fixtureDirectory(), source = FanQualificationFileSource(testDirectory: directory, requiredUID: geteuid(), bootID: fixtureBootID)
            try writeInput(invalid, directory: directory)
            XCTAssertThrowsError(try source.load(now: 100))
        }
        let directory = try fixtureDirectory(), source = FanQualificationFileSource(testDirectory: directory, requiredUID: geteuid(), bootID: fixtureBootID)
        let target = directory.appendingPathComponent("target.json")
        try data.write(to: target); XCTAssertEqual(chmod(target.path, 0o600), 0)
        let input = directory.appendingPathComponent("scenario.json")
        try FileManager.default.createSymbolicLink(at: input, withDestinationURL: target)
        XCTAssertThrowsError(try source.load(now: 100))
        try FileManager.default.removeItem(at: input)
        XCTAssertEqual(link(target.path, input.path), 0)
        XCTAssertThrowsError(try source.load(now: 100))
        try FileManager.default.removeItem(at: input)
        XCTAssertEqual(mkfifo(input.path, 0o600), 0)
        XCTAssertThrowsError(try source.load(now: 100))
        XCTAssertThrowsError(try FanQualificationFileSource(testDirectory: directory, requiredUID: geteuid() + 1, bootID: fixtureBootID).load(now: 100))
    }

    func testQualificationDirectoryMustBePrivateAndCannotBeASymlink() throws {
        let directory = try fixtureDirectory()
        XCTAssertEqual(chmod(directory.path, 0o755), 0)
        let source = FanQualificationFileSource(testDirectory: directory, requiredUID: geteuid(), bootID: fixtureBootID)
        XCTAssertThrowsError(try source.load(now: 100))
        XCTAssertEqual(chmod(directory.path, 0o700), 0)
        let containing = try fixtureDirectory(), alias = containing.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertThrowsError(try FanQualificationFileSource(testDirectory: alias, requiredUID: geteuid(), bootID: fixtureBootID).load(now: 100))
    }
}
#endif
