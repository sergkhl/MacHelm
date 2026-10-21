import XCTest
import IOKit
@testable import FanControlCore
@testable import FanControlHardware
@testable import FanControlRuntime

private final class NativeDiagnosticJournal: FanRecoveryPersistence {
    var record: FanRecoveryRecord?
    func load() throws -> FanRecoveryRecord? { record }
    func save(_ record: FanRecoveryRecord) throws { self.record = record }
    func remove() throws { record = nil }
}

final class FanNativeDiagnosticTests: XCTestCase {
    func testNativeWriteTimingAndFirmwareStatusAreEvidenceWithoutChangingAcceptance() throws {
        var now = 10.0, commands: [UInt8] = []
        let smc = AppleSMC(invoke: { input in
            commands.append(input.command); now += 0.004
            var reply = SMCMessage(); reply.status = 127; reply.bytes.0 = 1
            return (KERN_SUCCESS, reply, 80)
        }, clock: { now })
        smc.beginCommandDiagnosticCapture()
        try smc.writeFanValue("F0Md", value: SMCValue(encoding: "ui8 ", bytes: [1]), cancelled: { false })
        let receipt = try XCTUnwrap(smc.endCommandDiagnosticCapture().first)
        XCTAssertEqual(commands, [6]); XCTAssertEqual(receipt.key, "F0Md")
        XCTAssertEqual(receipt.startedAt, 10); XCTAssertEqual(receipt.returnedAt, 10.004)
        XCTAssertEqual(receipt.kernelResult, KERN_SUCCESS); XCTAssertEqual(receipt.firmwareResult, 0)
        XCTAssertEqual(receipt.firmwareStatus, 127); XCTAssertEqual(receipt.returnedValueHex, "01")
        XCTAssertEqual(receipt.requestedValueHex, "01")
        XCTAssertNil(smc.commandDiagnosticWrite)
    }

    func testRejectedAndShortNativeRepliesAreRetainedBeforeThrowing() throws {
        for failure in 0...2 {
            let smc = AppleSMC(invoke: { _ in
                var reply = SMCMessage(); reply.result = failure == 2 ? 0x84 : 0; reply.status = 23
                return (failure == 0 ? KERN_FAILURE : KERN_SUCCESS, reply, failure == 1 ? 79 : 80)
            })
            smc.beginCommandDiagnosticCapture()
            XCTAssertThrowsError(try smc.writeFanValue("F0Md", value: SMCValue(encoding: "ui8 ", bytes: [1]), cancelled: { false }))
            let calls = smc.endCommandDiagnosticCapture()
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls[0].returnedStructBytes, failure == 1 ? 79 : 80)
            XCTAssertEqual(calls[0].firmwareResult, failure == 2 ? 0x84 : nil)
            XCTAssertEqual(calls[0].firmwareStatus, failure == 2 ? 23 : nil)
        }
    }

    func testCancelledCallIsNotIssuedAndDeadlineBetweenMetadataAndDataStopsNextCall() throws {
        var now = 10.0, invocations = 0
        let smc = AppleSMC(invoke: { _ in
            invocations += 1; now += 0.15
            var reply = SMCMessage(); reply.info.size = 1; reply.info.type = 0x75693820
            return (KERN_SUCCESS, reply, 80)
        }, clock: { now })
        smc.beginCommandDiagnosticCapture()
        XCTAssertThrowsError(try smc.read("F0Md", cancelled: { true }))
        XCTAssertEqual(invocations, 0)
        XCTAssertThrowsError(try smc.read("F0Md", cancelled: { now >= 10.1 }))
        let calls = smc.endCommandDiagnosticCapture()
        XCTAssertEqual(invocations, 1); XCTAssertEqual(calls.map(\.command), [9])
        XCTAssertEqual(calls[0].startedAt, 10)
        XCTAssertGreaterThan(calls[0].returnedAt, 10.1)
    }

    func testTraceCapacityRejectsNextCallWithoutDroppingIssuedEvidenceAndCleanupResetsIt() throws {
        var invocations = 0
        let smc = AppleSMC(invoke: { _ in invocations += 1; return (KERN_SUCCESS, SMCMessage(), 80) })
        smc.beginCommandDiagnosticCapture()
        for _ in 0..<AppleSMC.maximumDiagnosticCalls {
            try smc.writeFanValue("F0Md", value: SMCValue(encoding: "ui8 ", bytes: [1]), cancelled: { false })
        }
        XCTAssertEqual(smc.commandDiagnosticCapacityRemaining, 0)
        XCTAssertThrowsError(try smc.writeFanValue("F0Md", value: SMCValue(encoding: "ui8 ", bytes: [1]), cancelled: { false }))
        XCTAssertEqual(invocations, 256)
        XCTAssertEqual(smc.endCommandDiagnosticCapture().count, 256)
        XCTAssertEqual(smc.commandDiagnosticCapacityRemaining, Int.max)
        try smc.writeFanValue("F0Md", value: SMCValue(encoding: "ui8 ", bytes: [1]), cancelled: { false })
        XCTAssertEqual(invocations, 257)
        XCTAssertTrue(smc.endCommandDiagnosticCapture().isEmpty)
    }

    func testABIAndReadPayloadAreRecordedThroughFakeNativeInvocation() throws {
        XCTAssertEqual(MemoryLayout<SMCMessage>.stride, 80)
        var commands: [UInt8] = []
        let smc = AppleSMC(invoke: { input in
            commands.append(input.command)
            var reply = SMCMessage(); reply.info.size = 1; reply.info.type = 0x75693820
            reply.bytes.0 = 3
            return (KERN_SUCCESS, reply, 80)
        })
        smc.beginCommandDiagnosticCapture()
        XCTAssertEqual(try smc.read("F0Md")?.number(), 3)
        let calls = smc.endCommandDiagnosticCapture()
        XCTAssertEqual(commands, [9, 5]); XCTAssertEqual(calls.last?.returnedValueHex, "03")
        XCTAssertEqual(calls.last?.requestedValueBytes, 1)
    }

    func testAppleFanControlReadPropagatesCancellationIntoTheNextChannel() throws {
        var revoked = false, invocations = 0
        let smc = AppleSMC(invoke: { input in
            invocations += 1
            var reply = SMCMessage(); reply.info.size = 1; reply.info.type = 0x75693820
            reply.bytes.0 = 2
            if input.command == 5 { revoked = true }
            return (KERN_SUCCESS, reply, 80)
        })
        let hardware = try AppleFanHardware(model: "Mac14,9", smc: smc)
        hardware.beginCommandDiagnosticCapture()
        XCTAssertThrowsError(try hardware.readControlState(FanPolicyTests.capabilities, cancelled: { revoked }))
        let calls = hardware.endCommandDiagnosticCapture()
        XCTAssertEqual(invocations, 2)
        XCTAssertEqual(calls.map(\.key), ["FNum", "FNum"])
        XCTAssertEqual(calls.map(\.command), [9, 5])
    }

    func testCorrelatedWriteReceiptUsesInputAndBelongsOnlyToItsCapture() throws {
        let smc = AppleSMC(invoke: { _ in (KERN_SUCCESS, SMCMessage(), 80) })
        XCTAssertNil(smc.commandDiagnosticWrite)
        smc.beginCommandDiagnosticCapture()
        try smc.writeFanValue("F0md", value: SMCValue(encoding: "ui8 ", bytes: [1]), cancelled: { false })
        let receipt = try XCTUnwrap(smc.commandDiagnosticWrite)
        XCTAssertEqual(receipt.command, 6); XCTAssertEqual(receipt.key, "F0md")
        XCTAssertEqual(receipt.requestedValueHex, "01"); XCTAssertEqual(receipt.returnedValueHex, "00")
        XCTAssertEqual(smc.endCommandDiagnosticCapture(), [receipt])
        XCTAssertNil(smc.commandDiagnosticWrite)
        smc.beginCommandDiagnosticCapture()
        XCTAssertNil(smc.commandDiagnosticWrite)
        XCTAssertTrue(smc.endCommandDiagnosticCapture().isEmpty)
    }

    func testFullFanProbeCancelsBetweenMetadataAndDataBoundaries() throws {
        for command in [UInt8(9), UInt8(5)] {
            var revoked = false, invocations = 0
            let smc = AppleSMC(invoke: { input in
                invocations += 1
                var reply = SMCMessage(); reply.info.size = 1; reply.info.type = 0x75693820
                reply.bytes.0 = 2
                if input.command == command { revoked = true }
                return (KERN_SUCCESS, reply, 80)
            })
            let hardware = try AppleFanHardware(model: "Mac14,9", smc: smc)
            hardware.beginCommandDiagnosticCapture()
            XCTAssertThrowsError(try hardware.probeFans(FanPolicyTests.capabilities, cancelled: { revoked }))
            let calls = hardware.endCommandDiagnosticCapture()
            XCTAssertEqual(invocations, command == 9 ? 1 : 2)
            XCTAssertTrue(calls.allSatisfy { $0.key == "FNum" })
        }
    }

    func testChangedFanCountStopsFullProbeBeforeReadingUnestablishedMetadata() throws {
        let smc = AppleSMC(invoke: { _ in
            var reply = SMCMessage(); reply.info.size = 1; reply.info.type = 0x75693820; reply.bytes.0 = 3
            return (KERN_SUCCESS, reply, 80)
        })
        let hardware = try AppleFanHardware(model: "Mac14,9", smc: smc)
        hardware.beginCommandDiagnosticCapture()
        XCTAssertThrowsError(try hardware.probeFans(FanPolicyTests.capabilities, cancelled: { false }))
        let calls = hardware.endCommandDiagnosticCapture()
        XCTAssertEqual(calls.map(\.key), ["FNum", "FNum"])
        XCTAssertEqual(calls.map(\.command), [9, 5])
    }

    func testReturnedModeWriteThenPartialNativeMetadataFailureRetainsHoldAndNoSuccessor() throws {
        var manual = false, writes: [String] = []
        let values: [String: (String, Double)] = [
            "FNum": ("ui8 ", 2), "F0md": ("ui8 ", 0), "F1md": ("ui8 ", 0), "Ftst": ("ui8 ", 0),
            "F0Mn": ("flt ", 1000), "F0Mx": ("flt ", 6000), "F1Mn": ("flt ", 1500), "F1Mx": ("flt ", 5500),
            "F0Tg": ("flt ", 0), "F1Tg": ("flt ", 0), "F0Ac": ("flt ", 1000), "F1Ac": ("flt ", 1500),
            "TCMb": ("flt ", 75), "TCMz": ("flt ", 75), "Tg0f": ("flt ", 40)
        ]
        let smc = AppleSMC(invoke: { input in
            let bytes = (0..<4).reversed().map { UInt8(truncatingIfNeeded: input.key >> (8 * $0)) }
            let key = String(bytes: bytes, encoding: .ascii)!
            var reply = SMCMessage()
            if input.command == 6 {
                writes.append(key); manual = true
                return (KERN_SUCCESS, reply, 80)
            }
            if manual && key == "F1Mx" { return (KERN_FAILURE, reply, 80) }
            guard let (encoding, defaultValue) = values[key] else {
                reply.result = 0x84; return (KERN_SUCCESS, reply, 80)
            }
            let size = encoding == "ui8 " ? 1 : 4
            reply.info.size = UInt32(size)
            reply.info.type = encoding.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if input.command == 5 {
                let value = try! SMCValue(encoding: encoding, bytes: Array(repeating: 0, count: size))
                    .replacing(number: key == "F0md" && manual ? 1 : defaultValue)
                reply.bytes.0 = value.bytes[0]
                if size == 4 { reply.bytes.1 = value.bytes[1]; reply.bytes.2 = value.bytes[2]; reply.bytes.3 = value.bytes[3] }
            }
            return (KERN_SUCCESS, reply, 80)
        })
        let hardware = try AppleFanHardware(model: "Mac14,9", smc: smc), journal = NativeDiagnosticJournal()
        let controller = try FanHelperController(hardware: hardware, persistence: journal, bootID: UUID().uuidString,
            artifactIdentity: "fake-native-artifact", conflict: { nil }, startTimers: false,
            modeDiagnosticTiming: FanModeDiagnosticTiming())
        let done = expectation(description: "partial fake native failure returns")
        controller.begin(owner: "owner", profile: .standard) { status in
            XCTAssertTrue(status.externalRecoveryRequired)
            XCTAssertFalse(status.releaseVerified); XCTAssertFalse(status.safeToUnregister)
            XCTAssertNil(status.sessionID)
            let trace = status.manualModeDiagnostic
            XCTAssertEqual(trace?.termination, "readFailure")
            XCTAssertEqual(trace?.probes.count, 1)
            XCTAssertNotNil(trace?.probes.first?.error); XCTAssertNil(trace?.probes.first?.observation)
            XCTAssertEqual(trace?.nativeCalls.filter { $0.command == 6 }.count, 1)
            XCTAssertEqual(trace?.nativeCalls.last?.key, "F1Mx")
            XCTAssertEqual(trace?.nativeCalls.last?.kernelResult, KERN_FAILURE)
            XCTAssertTrue(trace?.nativeCalls.contains { $0.key == "F1Mn" && $0.command == 5 } == true)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(writes, ["F0md"])
        XCTAssertEqual(journal.record?.pending, .mode(fan: 0, manual: true))
    }
}
