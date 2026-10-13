import XCTest
@testable import FanControlCore
@testable import FanControlHardware
@testable import FanControlRuntime

private final class TelemetryJournal: FanRecoveryPersistence {
    var record: FanRecoveryRecord?
    func load() throws -> FanRecoveryRecord? { record }
    func save(_ record: FanRecoveryRecord) throws { self.record = record }
    func remove() throws { record = nil }
}

private final class ReadOnlySMCFixture: FanSMCTransport {
    var values: [String: SMCValue] = [
        "TCMb": SMCValue(encoding: "flt ", bytes: [0, 0, 0x96, 0x42]), // 75
        "TCMz": SMCValue(encoding: "flt ", bytes: [0, 0, 0xaa, 0x42]), // 85
        "Tg0f": SMCValue(encoding: "flt ", bytes: [0, 0, 0x20, 0x42]), // 40
        "Tg0j": SMCValue(encoding: "flt ", bytes: [0, 0, 0x24, 0x42]), // 41
        "FNum": SMCValue(encoding: "ui8 ", bytes: [1]),
        "F0Md": SMCValue(encoding: "ui8 ", bytes: [0]),
        "F0Mn": SMCValue(encoding: "fpe2", bytes: [0x0f, 0xa0]), // 1000
        "F0Mx": SMCValue(encoding: "fpe2", bytes: [0x5d, 0xc0]), // 6000
        "F0Tg": SMCValue(encoding: "flt ", bytes: [0, 0, 0, 0]),
        "F0Ac": SMCValue(encoding: "fpe2", bytes: [0x0f, 0xa0])
    ]
    var requestedKeys: [String] = []
    var failureKey: String?
    // Whether the nth read of TCMz returns a well-formed out-of-range value,
    // as the firmware does for about one second at a time.
    var invalidMaximumOnRead: (Int) -> Bool = { _ in false }
    var maximumReads = 0

    static func float(_ value: Float) -> SMCValue {
        SMCValue(encoding: "flt ", bytes: withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) })
    }

    func read(_ key: String, cancelled: () -> Bool) throws -> SMCValue? {
        guard !cancelled() else { throw FanControlError.cancelled }
        requestedKeys.append(key)
        if failureKey == key { throw FanControlError.hardware("Injected read failure for \(key)") }
        if key == "TCMz" {
            maximumReads += 1
            if invalidMaximumOnRead(maximumReads) { return Self.float(255.97) }
        }
        return values[key]
    }
    func writeFanValue(_ key: String, value: SMCValue, cancelled: () -> Bool) throws {
        XCTFail("Telemetry tests must never issue a fan write: \(key)")
        throw FanControlError.cancelled
    }
}

final class FanTelemetryTests: XCTestCase {
    // Review finding on H-Q3. The production reader reports an out-of-range
    // reading itself, from discovery and from the frame read, before the
    // controller validates anything. A begin must wait in both cases.
    func testBeginWaitsForTheNextFrameThroughTheProductionReader() throws {
        try XCTSkipIf(ProcessInfo.processInfo.thermalState.rawValue >= 2, "Thermal pressure would request protection writes.")
        func begin(invalidOnRead: @escaping (Int) -> Bool) throws -> (status: FanStatus, pauses: Int, transport: ReadOnlySMCFixture) {
            let transport = ReadOnlySMCFixture()
            transport.values["TCMb"] = ReadOnlySMCFixture.float(60); transport.values["TCMz"] = ReadOnlySMCFixture.float(62)
            transport.invalidMaximumOnRead = invalidOnRead
            let hardware = try AppleFanHardware(model: "Mac14,9", smc: transport)
            var pauses = 0
            let controller = try FanHelperController(hardware: hardware, persistence: TelemetryJournal(),
                bootID: UUID().uuidString, artifactIdentity: "fake-telemetry-artifact", conflict: { nil },
                startTimers: false, entryFramePause: { _ in pauses += 1 })
            let done = expectation(description: "begin")
            var status = FanStatus(serviceGeneration: "none")
            controller.begin(owner: "owner", profile: .standard) { status = $0; done.fulfill() }
            wait(for: [done], timeout: 2)
            return (status, pauses, transport)
        }
        // Wrong at discovery (the first TCMz read), or first at the frame read (the second).
        for invalidRead in [1, 2] {
            let result = try begin { $0 == invalidRead }
            XCTAssertNotNil(result.status.sessionID, "\(invalidRead)")
            XCTAssertEqual(result.status.mode, .automatic, "\(invalidRead)")
            XCTAssertEqual(result.pauses, 1, "\(invalidRead)")
            XCTAssertEqual(result.status.diagnostics.filter {
                $0.contains("Entry frame unusable") && $0.contains("TCMz")
            }.count, 1, "\(invalidRead)")
            XCTAssertEqual(result.status.snapshot?.temperatures["TCMz"], 62, "\(invalidRead)")
        }
        // A reading that stays wrong fails the begin after three waits. The
        // fixture fails the test on any fan write.
        let failed = try begin { _ in true }
        XCTAssertNil(failed.status.sessionID); XCTAssertEqual(failed.pauses, 3)
        XCTAssertEqual(failed.status.mode, .paused)
        XCTAssertTrue(failed.status.reason?.contains("outside its qualified reading range") == true)
        XCTAssertEqual(failed.transport.maximumReads, 4, "Four attempts, each stopped at discovery.")
    }

    // The same reader on the other two paths: an out-of-range reading is
    // skipped at idle (H-Q2), where it surfaces from discovery, and inside a
    // session, where it surfaces from the frame read.
    func testAnOutOfRangeReadingIsSkippedAtIdleAndInASessionThroughTheProductionReader() throws {
        try XCTSkipIf(ProcessInfo.processInfo.thermalState.rawValue >= 2, "Thermal pressure would request protection writes.")
        let transport = ReadOnlySMCFixture()
        transport.values["TCMb"] = ReadOnlySMCFixture.float(60); transport.values["TCMz"] = ReadOnlySMCFixture.float(62)
        let hardware = try AppleFanHardware(model: "Mac14,9", smc: transport)
        let controller = try FanHelperController(hardware: hardware, persistence: TelemetryJournal(),
            bootID: UUID().uuidString, artifactIdentity: "fake-telemetry-artifact", conflict: { nil },
            startTimers: false, entryFramePause: { _ in })
        func poll(invalid: Bool) -> FanStatus {
            let next = transport.maximumReads + 1
            transport.invalidMaximumOnRead = { invalid && $0 == next }
            let done = expectation(description: "poll")
            _ = controller.status(observe: true)
            controller.poll { done.fulfill() }
            wait(for: [done], timeout: 2)
            return controller.status(observe: false)
        }
        let idle = poll(invalid: false)
        XCTAssertEqual(idle.mode, .off); XCTAssertNotNil(idle.snapshot)
        let skippedIdle = poll(invalid: true)
        XCTAssertEqual(skippedIdle.mode, .off); XCTAssertEqual(skippedIdle.snapshot, idle.snapshot)
        XCTAssertEqual(skippedIdle.idleFaults?.count, 1)
        XCTAssertEqual(skippedIdle.idleFaults?.lastReason.contains("TCMz"), true)
        XCTAssertTrue(skippedIdle.diagnostics.isEmpty)
        let began = expectation(description: "begin")
        var session: String?
        controller.begin(owner: "owner", profile: .standard) { session = $0.sessionID; began.fulfill() }
        wait(for: [began], timeout: 2)
        XCTAssertNotNil(session)
        let frame = controller.status(observe: false).snapshot
        let skipped = poll(invalid: true)
        XCTAssertEqual(skipped.sessionID, session); XCTAssertEqual(skipped.mode, .automatic)
        XCTAssertEqual(skipped.snapshot, frame)
        XCTAssertEqual(skipped.diagnostics.filter { $0.contains("Unusable frame skipped") && $0.contains("TCMz") }.count, 1)
        XCTAssertEqual(skipped.idleFaults?.count, 1, "A frame skipped inside a session is logged, not counted.")
        XCTAssertEqual(poll(invalid: false).sessionID, session)
    }

    func testReadOnlyQualificationIsExplicitAndBounded() throws {
        XCTAssertEqual(try FanReadOnlyQualification.sampleCount(arguments: ["--read-only"]), 1)
        XCTAssertEqual(try FanReadOnlyQualification.sampleCount(arguments: ["--read-only", "--samples", "30"]), 30)
        for args in [[], ["--samples", "12"], ["--read-only", "--samples", "0"],
                     ["--read-only", "--samples", "31"], ["--read-only", "--samples", "NaN"],
                     ["--read-only", "--write"], ["--read-only", "--samples", "2", "extra"]] {
            XCTAssertThrowsError(try FanReadOnlyQualification.sampleCount(arguments: args))
        }
    }

    func testKnownLittleEndianCPUAndSentinelPayloads() throws {
        XCTAssertEqual(try SMCValue(encoding: "flt ", bytes: [0x4e, 0xd4, 0x54, 0x42]).number(), 53.20732879638672)
        XCTAssertEqual(try SMCValue(encoding: "flt ", bytes: [0x33, 0x63, 0x69, 0x42]).number(), 58.34687423706055)
        XCTAssertEqual(try SMCValue(encoding: "flt ", bytes: [0x66, 0x66, 0xd6, 0x40]).number(), 6.7, accuracy: 0.000001)
        XCTAssertEqual(try SMCValue(encoding: "flt ", bytes: [0x89, 0x41, 0x94, 0x40]).number(), 4.633, accuracy: 0.000001)
    }

    func testObservedPerCoreSentinelsNeitherContributeNorBlockAggregates() throws {
        struct Channel: Decodable { let key: String; let encoding: String; let rawHex: String; let value: Double }
        struct Fixture: Decodable { let sourceSHA256: String; let channels: [Channel] }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "m2-pro-cpu-aggregates-and-sentinels", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.sourceSHA256, "10bbecb23584b107eb2738b7e606ea5585c97777f6e5699bcb76cee14957243e")
        let transport = ReadOnlySMCFixture()
        for channel in fixture.channels {
            let hex = Array(channel.rawHex)
            let bytes = try stride(from: 0, to: hex.count, by: 2).map {
                try XCTUnwrap(UInt8(String(hex[$0...($0 + 1)]), radix: 16))
            }
            let value = SMCValue(encoding: channel.encoding, bytes: bytes)
            XCTAssertEqual(try value.number(), channel.value)
            transport.values[channel.key] = value
        }
        let hardware = try AppleFanHardware(model: "Mac14,9", smc: transport)
        let capabilities = try hardware.discover()
        let frame = try hardware.read(capabilities)
        XCTAssertEqual(frame.cpuDieAverage(in: capabilities), 52.04763412475586)
        XCTAssertEqual(frame.cpuDieMaximum(in: capabilities), 63.36249923706055)
        XCTAssertGreaterThan(frame.hottestGPU(in: capabilities), 49)
        XCTAssertFalse(transport.requestedKeys.contains { $0.hasPrefix("Tp") })
        XCTAssertFalse(frame.temperatures.keys.contains { $0.hasPrefix("Tp") })
        var policy = FanPolicy()
        let output = try policy.evaluate(frame, capabilities: capabilities, profile: .standard,
                                         now: ProcessInfo.processInfo.systemUptime)
        XCTAssertNil(output.demand); XCTAssertFalse(output.protection)
    }

    func testHardwareRequiresBothFreshAggregatesWithoutCachedFallback() throws {
        for key in ["TCMb", "TCMz"] {
            let transport = ReadOnlySMCFixture()
            let hardware = try AppleFanHardware(model: "Mac14,9", smc: transport)
            let capabilities = try hardware.discover()
            _ = try hardware.read(capabilities)
            transport.values.removeValue(forKey: key)
            XCTAssertThrowsError(try hardware.read(capabilities))
            XCTAssertThrowsError(try hardware.discover())
            transport.values[key] = SMCValue(encoding: "flt ", bytes: [0, 0, 0x96, 0x42])
            transport.failureKey = key
            XCTAssertThrowsError(try hardware.read(capabilities))
        }
    }

    func testAggregateEncodingPayloadSizeAndPlausibilityMustQualify() throws {
        let invalid = [
            SMCValue(encoding: "sp78", bytes: [75, 0]),
            SMCValue(encoding: "flt ", bytes: [0, 0, 0]),
            SMCValue(encoding: "flt ", bytes: [0, 0, 0xc0, 0x7f]),
            SMCValue(encoding: "flt ", bytes: [0, 0, 0x80, 0x7f]),
            SMCValue(encoding: "flt ", bytes: [0, 0, 0, 0]),
            SMCValue(encoding: "flt ", bytes: [0x66, 0x66, 0xd6, 0x40]),
            SMCValue(encoding: "flt ", bytes: [0x89, 0x41, 0x94, 0x40]),
            SMCValue(encoding: "flt ", bytes: [0, 0, 0xf2, 0x42]) // 121
        ]
        for key in ["TCMb", "TCMz"] {
            for value in invalid {
                let transport = ReadOnlySMCFixture()
                let hardware = try AppleFanHardware(model: "Mac14,9", smc: transport)
                let capabilities = try hardware.discover()
                transport.values[key] = value
                XCTAssertThrowsError(try hardware.read(capabilities), "\(key): \(value)")
                XCTAssertThrowsError(try hardware.discover(), "\(key): \(value)")
            }
        }
    }

    func testGPUSetAndFanMetadataCannotChangeWithinSession() throws {
        for key in ["Tg0f", "Tg0j", "F0Mn", "F0Mx", "F0Md", "FNum"] {
            let transport = ReadOnlySMCFixture()
            let hardware = try AppleFanHardware(model: "Mac14,9", smc: transport)
            let capabilities = try hardware.discover()
            transport.values.removeValue(forKey: key)
            XCTAssertThrowsError(try hardware.read(capabilities), key)
        }
        let transport = ReadOnlySMCFixture()
        let hardware = try AppleFanHardware(model: "Mac14,9", smc: transport)
        let capabilities = try hardware.discover()
        transport.values["F0Mx"] = SMCValue(encoding: "fpe2", bytes: [0x55, 0xf0]) // 5500
        XCTAssertThrowsError(try hardware.read(capabilities))
    }

    func testNoGPUOrUnsupportedModelIsUnavailableAndRestorationNeedsNoCPURead() throws {
        let transport = ReadOnlySMCFixture()
        XCTAssertThrowsError(try AppleFanHardware(model: "Mac99,1", smc: transport))
        let hardware = try AppleFanHardware(model: "Mac14,9", smc: transport)
        let capabilities = try hardware.discover()
        transport.values.removeValue(forKey: "Tg0f"); transport.values.removeValue(forKey: "Tg0j")
        XCTAssertThrowsError(try hardware.discover())
        transport.failureKey = "TCMb"
        transport.requestedKeys = []
        XCTAssertTrue(try hardware.readControlState(capabilities).isFullyAutomatic)
        XCTAssertFalse(transport.requestedKeys.contains("TCMb"))
        XCTAssertFalse(transport.requestedKeys.contains("TCMz"))
        XCTAssertTrue(try hardware.probeFans().observation.isFullyAutomatic)
    }

    // A finite value outside its role's range is reported separately, and only
    // after every other read and check passed; missing, non-finite, mis-sized
    // or mis-encoded values and failed reads are not.
    func testFiniteOutOfRangeIsReportedSeparatelyFromInvalidReads() throws {
        let outOfRange: [(String, [UInt8])] = [("TCMz", [0x66, 0xb0, 0x83, 0x43]), ("TCMb", [0x66, 0x66, 0xd6, 0x40]),
                                               ("TCMb", [0, 0, 0xf2, 0x42]), ("Tg0f", [0, 0, 0, 0]), ("Tg0j", [0, 0, 0x02, 0x43])]
        for (key, bytes) in outOfRange {
            let transport = ReadOnlySMCFixture()
            let hardware = try AppleFanHardware(model: "Mac14,9", smc: transport)
            let capabilities = try hardware.discover()
            transport.values[key] = SMCValue(encoding: "flt ", bytes: bytes)
            for attempt in [{ _ = try hardware.read(capabilities) }, { _ = try hardware.discover() }] {
                XCTAssertThrowsError(try attempt()) {
                    guard case .readingOutOfRange(let reason)? = $0 as? FanControlError else { return XCTFail("\(key): \($0)") }
                    XCTAssertTrue(reason.contains(key), reason)
                }
            }
            // A changed fan metadata read in the same frame still wins.
            transport.values["F0Mx"] = SMCValue(encoding: "fpe2", bytes: [0x55, 0xf0])
            XCTAssertThrowsError(try hardware.read(capabilities)) {
                if case .readingOutOfRange? = $0 as? FanControlError { XCTFail("\(key): \($0)") }
            }
        }
        let invalid: [(String, SMCValue?)] = [("TCMz", SMCValue(encoding: "flt ", bytes: [0, 0, 0xc0, 0x7f])),
                                              ("TCMb", SMCValue(encoding: "flt ", bytes: [0, 0, 0x80, 0xff])),
                                              ("TCMz", SMCValue(encoding: "flt ", bytes: [0, 0, 0])),
                                              ("TCMb", SMCValue(encoding: "sp78", bytes: [75, 0])), ("TCMz", nil)]
        for (key, value) in invalid {
            let transport = ReadOnlySMCFixture()
            let hardware = try AppleFanHardware(model: "Mac14,9", smc: transport)
            let capabilities = try hardware.discover()
            transport.values[key] = value
            XCTAssertThrowsError(try hardware.read(capabilities)) {
                if case .readingOutOfRange? = $0 as? FanControlError { XCTFail("\(key): \($0)") }
            }
        }
        let failing = ReadOnlySMCFixture()
        let hardware = try AppleFanHardware(model: "Mac14,9", smc: failing)
        let capabilities = try hardware.discover()
        failing.failureKey = "TCMz"
        XCTAssertThrowsError(try hardware.read(capabilities)) {
            if case .readingOutOfRange? = $0 as? FanControlError { XCTFail("\($0)") }
        }
    }
}
