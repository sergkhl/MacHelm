import Foundation
#if canImport(FanControlCore)
import FanControlCore
#endif

public final class AppleFanHardware: FanHardware {
    private let smc: FanSMCTransport
    private let model: String
    public init() throws {
        #if !arch(arm64)
        throw FanControlError.unavailable("Fan Control supports recognized Apple Silicon Macs only.")
        #else
        model = try FanSystemIdentity.sysctlString("hw.model")
        _ = try FanSensorCatalog.candidates(model: model)
        smc = try AppleSMC()
        #endif
    }

    // Test seam for the actual discovery/frame reader; not exposed over XPC.
    init(model: String, smc: FanSMCTransport) throws {
        _ = try FanSensorCatalog.candidates(model: model)
        self.model = model; self.smc = smc
    }

    public func discover() throws -> FanCapabilities {
        // Both firmware CPU aggregates are mandatory. No HID, PMU or per-core
        // substitute can establish or replace this temperature basis.
        let thermal = try readSMCTemperatures()
        // Discovery qualifies a basis, so every reading must also be in range.
        for sensor in thermal.sensors {
            if let value = thermal.temperatures[sensor.key] { try FanSnapshot.requireQualified(value, sensor: sensor) }
        }
        return try discover(sensors: thermal.sensors)
    }

    private func discover(sensors: [FanSensor]) throws -> FanCapabilities {
        let metadata = try discoverFanMetadata()
        let capabilities = FanCapabilities(model: model, sensors: sensors, fans: metadata.fans, hasGlobalUnlock: metadata.unlock)
        try capabilities.validate()
        return capabilities
    }

    private func discoverFanMetadata(expected: FanCapabilities? = nil,
                                     cancelled: () -> Bool = { false }) throws -> (fans: [FanDescriptor], unlock: Bool) {
        let count = try required("FNum", cancelled: cancelled).number()
        guard count.rounded() == count, (1...10).contains(count) else {
            throw FanControlError.unavailable("This Mac has no supported controllable fans.")
        }
        if let expected, count != Double(expected.fans.count) {
            throw FanControlError.invalid("Fan count changed during acknowledgement.")
        }
        var fans: [FanDescriptor] = []
        for id in 0..<Int(count) {
            let lower = try smc.read("F\(id)md", cancelled: cancelled)
            let key = lower == nil ? "F\(id)Md" : "F\(id)md"
            let mode = try lower ?? required(key, cancelled: cancelled)
            guard mode.encoding == "ui8 ", [0, 1, 3].contains(try mode.number()) else {
                throw FanControlError.unavailable("Unrecognized fan mode for fan \(id + 1).")
            }
            let target = try required("F\(id)Tg", cancelled: cancelled)
            fans.append(FanDescriptor(id: id, minimumRPM: try required("F\(id)Mn", cancelled: cancelled).number(),
                                      maximumRPM: try required("F\(id)Mx", cancelled: cancelled).number(),
                                      modeKey: key, targetEncoding: target.encoding))
        }
        let unlock = try smc.read("Ftst", cancelled: cancelled)
        if let unlock {
            guard unlock.encoding == "ui8 ", [0, 1].contains(try unlock.number()) else {
                throw FanControlError.unavailable("Unrecognized global fan unlock state.")
            }
        }
        for fan in fans { try fan.validate() }
        if let expected, expected.model != model || expected.fans != fans || expected.hasGlobalUnlock != (unlock != nil) {
            throw FanControlError.invalid("Fan model, metadata or unlock capability changed during acknowledgement.")
        }
        return (fans, unlock != nil)
    }

    public func probeFans() throws -> FanFanProbe {
        let metadata = try discoverFanMetadata()
        // Incomplete thermal capabilities are read-only and cannot pass validate
        // or authorize any perform operation or control session.
        let capabilities = FanCapabilities(model: model, sensors: [], fans: metadata.fans, hasGlobalUnlock: metadata.unlock)
        return FanFanProbe(model: model, fans: metadata.fans, observation: try readControlState(capabilities))
    }

    public func probeFans(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanFanProbe {
        let metadata = try discoverFanMetadata(expected: capabilities, cancelled: cancelled)
        return FanFanProbe(model: model, fans: metadata.fans,
                           observation: try readControlState(capabilities, cancelled: cancelled))
    }

    public func read(_ capabilities: FanCapabilities) throws -> FanSnapshot {
        try capabilities.validate()
        let timestamp = ProcessInfo.processInfo.systemUptime
        // Re-probe presence/encoding and bounds; never shrink the established set.
        let thermal = try readSMCTemperatures()
        let discovered = try discover(sensors: thermal.sensors)
        guard discovered == capabilities else {
            throw FanControlError.invalid("Sensor or fan capabilities changed; requalification is required.")
        }
        let control = try readControlState(capabilities)
        let pressure = FanThermalPressure(rawValue: ProcessInfo.processInfo.thermalState.rawValue) ?? .critical
        let completedAt = ProcessInfo.processInfo.systemUptime
        let frame = FanSnapshot(capturedAt: timestamp, temperatures: thermal.temperatures, fans: control.fans,
                                thermalPressure: pressure, globalUnlock: control.globalUnlock,
                                readDuration: completedAt - timestamp)
        try frame.validate(against: capabilities, now: completedAt)
        return frame
    }

    public func readControlState(_ capabilities: FanCapabilities) throws -> FanControlObservation {
        try readControlState(capabilities, cancelled: { false })
    }

    public func readControlState(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanControlObservation {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard try required("FNum", cancelled: cancelled).number() == Double(capabilities.fans.count) else {
            throw FanControlError.invalid("Fan count changed during restoration.")
        }
        let fans = try capabilities.fans.map { fan in
            try fan.validate()
            _ = try checkedFan(fan.id, capabilities: capabilities, cancelled: cancelled)
            let mode = try required(fan.modeKey, cancelled: cancelled)
            let target = try required("F\(fan.id)Tg", cancelled: cancelled)
            guard mode.encoding == "ui8 ", target.encoding == fan.targetEncoding else {
                throw FanControlError.invalid("Fan encoding changed during readback.")
            }
            let reading = FanReading(id: fan.id, actualRPM: try required("F\(fan.id)Ac", cancelled: cancelled).number(),
                                     targetRPM: try target.number(), mode: Int(try mode.number()))
            guard [0, 1, 3].contains(reading.mode), (0...20_000).contains(reading.actualRPM),
                  (0...20_000).contains(reading.targetRPM) else {
                throw FanControlError.invalid("Invalid fan control readback.")
            }
            return reading
        }
        let unlock = try capabilities.hasGlobalUnlock ? Int(required("Ftst", cancelled: cancelled).number()) : nil
        guard unlock == nil || unlock == 0 || unlock == 1 else {
            throw FanControlError.invalid("Invalid global unlock readback.")
        }
        return FanControlObservation(capturedAt: timestamp, fans: fans, globalUnlock: unlock)
    }

    public func beginCommandDiagnosticCapture() { smc.beginCommandDiagnosticCapture() }
    public func endCommandDiagnosticCapture() -> [FanNativeCallReceipt] { smc.endCommandDiagnosticCapture() }
    public var commandDiagnosticCapacityRemaining: Int { smc.commandDiagnosticCapacityRemaining }
    public var commandDiagnosticWrite: FanNativeCallReceipt? { smc.commandDiagnosticWrite }

    public func perform(_ operation: FanOperation, capabilities: FanCapabilities, cancelled: () -> Bool) throws {
        try capabilities.validate()
        guard !cancelled() else { throw FanControlError.cancelled }
        let key: String
        let number: Double
        let expectedEncoding: String
        switch operation {
        case .globalUnlock(let enabled):
            guard capabilities.hasGlobalUnlock else { throw FanControlError.invalid("No global unlock capability.") }
            key = "Ftst"; number = enabled ? 1 : 0; expectedEncoding = "ui8 "
        case .mode(let id, let manual):
            let fan = try checkedFan(id, capabilities: capabilities, cancelled: cancelled)
            key = fan.modeKey; number = manual ? 1 : 0; expectedEncoding = "ui8 "
        case .target(let id, let rpm):
            let fan = try checkedFan(id, capabilities: capabilities, cancelled: cancelled)
            guard rpm.isFinite, rpm == 0 || (fan.minimumRPM...fan.maximumRPM).contains(rpm) else {
                throw FanControlError.invalid("Fan target is outside the discovered RPM bounds.")
            }
            // Below a positive hardware minimum, zero is only a release
            // sentinel. Since Z-Q3 no release sends it; the guard remains.
            if rpm == 0 && fan.minimumRPM > 0 {
                guard [0, 3].contains(try required(fan.modeKey, cancelled: cancelled).number()) else {
                    throw FanControlError.invalid("Zero target is only allowed in automatic mode.")
                }
            }
            key = "F\(id)Tg"; number = rpm; expectedEncoding = fan.targetEncoding
        }
        let value = try required(key, cancelled: cancelled)
        guard value.encoding == expectedEncoding else { throw FanControlError.invalid("Fan encoding changed at \(key).") }
        try smc.writeFanValue(key, value: value.replacing(number: number), cancelled: cancelled)
    }

    private func checkedFan(_ id: Int, capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanDescriptor {
        guard let fan = capabilities.fans.first(where: { $0.id == id }) else {
            throw FanControlError.invalid("Unknown fan identifier.")
        }
        let minimum = try required("F\(id)Mn", cancelled: cancelled).number()
        let maximum = try required("F\(id)Mx", cancelled: cancelled).number()
        guard minimum == fan.minimumRPM, maximum == fan.maximumRPM else {
            throw FanControlError.invalid("Fan bounds changed before the write.")
        }
        return fan
    }

    private func readSMCTemperatures() throws -> (sensors: [FanSensor], temperatures: [String: Double]) {
        try FanSMCTemperatureReader.read(model: model) { try smc.read($0) }
    }

    private func required(_ key: String, cancelled: () -> Bool = { false }) throws -> SMCValue {
        guard let value = try smc.read(key, cancelled: cancelled) else {
            throw FanControlError.unavailable("Required AppleSMC channel is missing: \(key).")
        }
        return value
    }
}

public struct FanReadOnlyQualification: Encodable {
    public let captured: String
    public let os: String
    public let effectiveUID: UInt32
    public let capabilities: FanCapabilities
    public let frames: [FanSnapshot]
    public let firmwareTimestampAvailable = false

    public static func sampleCount(arguments: [String]) throws -> Int {
        if arguments == ["--read-only"] { return 1 }
        guard arguments.count == 3, arguments[0] == "--read-only", arguments[1] == "--samples",
              let count = Int(arguments[2]), (1...30).contains(count) else {
            throw FanControlError.invalid("Use --read-only [--samples 1–30]. This mode only reads telemetry.")
        }
        return count
    }

    // Runs only as a bounded standalone observation. No controller, ownership
    // store, XPC listener, daemon registration or fan-write path is constructed.
    public static func capture(sampleCount: Int = 1) throws -> FanReadOnlyQualification {
        guard (1...30).contains(sampleCount) else { throw FanControlError.invalid("Read-only sample count must be 1–30.") }
        let hardware = try AppleFanHardware()
        let capabilities = try hardware.discover()
        let captured = Date().ISO8601Format()
        var frames: [FanSnapshot] = []
        for index in 0..<sampleCount {
            if index > 0 { Thread.sleep(forTimeInterval: 1) }
            frames.append(try hardware.read(capabilities))
        }
        return FanReadOnlyQualification(captured: captured, os: ProcessInfo.processInfo.operatingSystemVersionString,
                                        effectiveUID: geteuid(), capabilities: capabilities, frames: frames)
    }
}
