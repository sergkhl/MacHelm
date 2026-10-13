// AppleSMC wire layout and M2 sensor keys adapted from Stats at
// ee4265f3b9afdffebd3273cf6a83b9327ead45b5. See ThirdPartyNotices.txt.
import Foundation
import IOKit
#if canImport(FanControlCore)
import FanControlCore
#endif

struct SMCValue: Equatable {
    let encoding: String
    let bytes: [UInt8]

    func number() throws -> Double {
        let value: Double
        switch (encoding, bytes.count) {
        case ("ui8 ", 1): value = Double(bytes[0])
        case ("ui16", 2): value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case ("ui32", 4):
            value = Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case ("sp78", 2):
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case ("fpe2", 2): value = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case ("flt ", 4):
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
            value = Double(Float(bitPattern: bits))
        default: throw FanControlError.invalid("Unsupported SMC encoding \(encoding) (\(bytes.count) bytes).")
        }
        guard value.isFinite else { throw FanControlError.invalid("SMC returned a non-finite value.") }
        return value
    }

    func replacing(number: Double) throws -> SMCValue {
        guard number.isFinite, number >= 0 else { throw FanControlError.invalid("Invalid fan write value.") }
        let data: [UInt8]
        switch (encoding, bytes.count) {
        case ("ui8 ", 1) where number.rounded() == number && number <= 255:
            data = [UInt8(number)]
        case ("flt ", 4) where number <= 20_000:
            let bits = Float(number).bitPattern
            data = (0..<4).map { UInt8(truncatingIfNeeded: bits >> (8 * $0)) }
        case ("fpe2", 2) where number <= 16_383.75:
            let fixed = UInt16((number * 4).rounded())
            data = [UInt8(fixed >> 8), UInt8(truncatingIfNeeded: fixed)]
        default: throw FanControlError.invalid("Unsupported fan write encoding \(encoding).")
        }
        return SMCValue(encoding: encoding, bytes: data)
    }
}

// Swift layout is checked before opening the driver. IOConnectCallStructMethod
// uses the 80-byte AppleSMC ABI, including the padding before result/data32.
struct SMCMessage {
    struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct Limits {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0
    }
    struct Info {
        var size: UInt32 = 0, type: UInt32 = 0
        var attributes: UInt8 = 0
    }
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    var key: UInt32 = 0
    var version = Version()
    var limits = Limits()
    var info = Info()
    var padding: UInt16 = 0
    var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
    var data: UInt32 = 0
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

protocol FanSMCTransport {
    func read(_ key: String, cancelled: () -> Bool) throws -> SMCValue?
    func writeFanValue(_ key: String, value: SMCValue, cancelled: () -> Bool) throws
    func beginCommandDiagnosticCapture()
    func endCommandDiagnosticCapture() -> [FanNativeCallReceipt]
    var commandDiagnosticCapacityRemaining: Int { get }
    var commandDiagnosticWrite: FanNativeCallReceipt? { get }
}

extension FanSMCTransport {
    func read(_ key: String) throws -> SMCValue? { try read(key, cancelled: { false }) }
    func beginCommandDiagnosticCapture() {}
    func endCommandDiagnosticCapture() -> [FanNativeCallReceipt] { [] }
    var commandDiagnosticCapacityRemaining: Int { Int.max }
    var commandDiagnosticWrite: FanNativeCallReceipt? { nil }
}

final class AppleSMC: FanSMCTransport {
    private var connection: io_connect_t = 0
    private let invoke: (SMCMessage) -> (result: kern_return_t, reply: SMCMessage, size: Int,
                                       startedAt: TimeInterval, returnedAt: TimeInterval)
    private var diagnosticCalls: [FanNativeCallReceipt]?
    static let maximumDiagnosticCalls = 256

    init() throws {
        guard MemoryLayout<SMCMessage>.stride == 80,
              MemoryLayout<SMCMessage>.offset(of: \.bytes) == 48,
              MemoryLayout<SMCMessage>.offset(of: \.result) == 40 else {
            throw FanControlError.unavailable("Unsupported AppleSMC ABI layout.")
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw FanControlError.unavailable("AppleSMC is unavailable.") }
        defer { IOObjectRelease(service) }
        var openedConnection: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &openedConnection)
        guard result == KERN_SUCCESS else {
            throw FanControlError.unavailable("Cannot open AppleSMC (IOKit \(result)).")
        }
        connection = openedConnection
        invoke = { message in
            var input = message, output = SMCMessage()
            var size = MemoryLayout<SMCMessage>.stride
            let startedAt = ProcessInfo.processInfo.systemUptime
            let result = IOConnectCallStructMethod(openedConnection, 2, &input, size, &output, &size)
            let returnedAt = ProcessInfo.processInfo.systemUptime
            return (result, output, size, startedAt, returnedAt)
        }
    }

    // Fake native invocation only: no driver, service, journal or fan write.
    init(invoke: @escaping (SMCMessage) -> (result: kern_return_t, reply: SMCMessage, size: Int),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.invoke = { message in
            let startedAt = clock()
            let response = invoke(message)
            return (response.result, response.reply, response.size, startedAt, clock())
        }
    }

    func beginCommandDiagnosticCapture() { diagnosticCalls = [] }
    func endCommandDiagnosticCapture() -> [FanNativeCallReceipt] {
        defer { diagnosticCalls = nil }
        return diagnosticCalls ?? []
    }
    var commandDiagnosticCapacityRemaining: Int {
        diagnosticCalls.map { Self.maximumDiagnosticCalls - $0.count } ?? Int.max
    }
    var commandDiagnosticWrite: FanNativeCallReceipt? {
        diagnosticCalls?.last(where: { $0.command == 6 })
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func read(_ key: String, cancelled: () -> Bool = { false }) throws -> SMCValue? {
        var input = SMCMessage()
        input.key = try code(key)
        input.command = 9
        guard let infoReply = try call(input, missingAllowed: true, cancelled: cancelled) else { return nil }
        let info = infoReply.info
        guard info.size > 0, info.size <= 32, info.type != 0 else {
            throw FanControlError.invalid("Malformed AppleSMC metadata for \(key).")
        }
        input.info.size = info.size; input.command = 5
        guard var reply = try call(input, missingAllowed: true, cancelled: cancelled) else { return nil }
        let bytes = withUnsafeBytes(of: &reply.bytes) { Array($0.prefix(Int(info.size))) }
        let characters = (0..<4).reversed().map { UInt8(truncatingIfNeeded: info.type >> (8 * $0)) }
        guard let encoding = String(bytes: characters, encoding: .ascii) else {
            throw FanControlError.invalid("Invalid SMC type for \(key).")
        }
        return SMCValue(encoding: encoding, bytes: bytes)
    }

    // Accessible only inside this transport; XPC accepts typed operations.
    func writeFanValue(_ key: String, value: SMCValue, cancelled: () -> Bool) throws {
        guard key == "Ftst" || (0...9).contains(where: { ["F\($0)md", "F\($0)Md", "F\($0)Tg"].contains(key) }) else {
            throw FanControlError.invalid("Rejected non-fan SMC write.")
        }
        guard (1...32).contains(value.bytes.count) else { throw FanControlError.invalid("Invalid SMC write size.") }
        var input = SMCMessage()
        input.key = try code(key); input.command = 6; input.info.size = UInt32(value.bytes.count)
        withUnsafeMutableBytes(of: &input.bytes) { $0.copyBytes(from: value.bytes) }
        _ = try call(input, missingAllowed: false, cancelled: cancelled)
    }

    private func code(_ key: String) throws -> UInt32 {
        guard key.utf8.count == 4, key.unicodeScalars.allSatisfy(\.isASCII) else {
            throw FanControlError.invalid("Malformed SMC key.")
        }
        return key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func call(_ message: SMCMessage, missingAllowed: Bool, cancelled: () -> Bool) throws -> SMCMessage? {
        guard !cancelled() else { throw FanControlError.cancelled }
        guard commandDiagnosticCapacityRemaining > 0 else {
            throw FanControlError.hardware("Native command diagnostic capacity reached; no further call was issued.")
        }
        let response = invoke(message)
        let startedAt = response.startedAt, returnedAt = response.returnedAt
        var output = response.reply
        let result = response.result, size = response.size
        if diagnosticCalls != nil {
            let validReply = result == KERN_SUCCESS && size == MemoryLayout<SMCMessage>.stride
            let keyBytes = (0..<4).reversed().map { UInt8(truncatingIfNeeded: message.key >> (8 * $0)) }
            let key = String(bytes: keyBytes, encoding: .ascii) ?? "unknown"
            let valueHex: String? = validReply && [5, 6].contains(message.command)
                ? withUnsafeBytes(of: &output.bytes) {
                    $0.prefix(min(32, Int(message.info.size))).map { String(format: "%02x", $0) }.joined()
                  } : nil
            let requestedHex: String? = message.command == 6
                ? withUnsafeBytes(of: message.bytes) {
                    $0.prefix(min(32, Int(message.info.size))).map { String(format: "%02x", $0) }.joined()
                  } : nil
            diagnosticCalls?.append(FanNativeCallReceipt(key: key, command: message.command,
                startedAt: startedAt, returnedAt: returnedAt, kernelResult: result,
                requestedValueBytes: message.info.size, returnedStructBytes: size,
                firmwareResult: validReply ? output.result : nil,
                firmwareStatus: validReply ? output.status : nil, returnedValueHex: valueHex,
                requestedValueHex: requestedHex))
        }
        guard result == KERN_SUCCESS, size == MemoryLayout<SMCMessage>.stride else {
            throw FanControlError.hardware("AppleSMC IOKit request failed (\(result), \(size) bytes).")
        }
        if missingAllowed && output.result == 0x84 { return nil }
        guard output.result == 0 else {
            throw FanControlError.hardware("AppleSMC firmware rejected the request (result \(output.result), status \(output.status)).")
        }
        return output
    }
}
