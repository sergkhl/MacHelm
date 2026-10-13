import Foundation
#if canImport(FanControlCore)
import FanControlCore
#endif

public enum FanSensorCatalog {
    // Explicit M2-family identity registry. Other SoCs require a reviewed map.
    public static let m2Models: Set<String> = [
        "Mac14,2", "Mac14,3", "Mac14,5", "Mac14,6", "Mac14,7", "Mac14,9", "Mac14,10",
        "Mac14,12", "Mac14,13", "Mac14,14", "Mac14,15"
    ]
    public static func candidates(model: String) throws -> [(String, FanTelemetryRole)] {
        guard m2Models.contains(model) else {
            throw FanControlError.unavailable("No reviewed Apple Silicon sensor map for \(model).")
        }
        // CPU meanings follow the pinned aggregate research, not a computed
        // P/E-zone mean. GPU keys retain the reviewed M2 protection mapping.
        return [("TCMb", .cpuAverage), ("TCMz", .cpuMaximum)]
            + ["Tg0f", "Tg0j"].map { ($0, .gpuProtection) }
    }
}

// A single fresh pass, shared by discovery and every complete control frame.
// The injected read function allows transport failures and real raw payloads
// to be checked without opening AppleSMC or issuing any fan writes.
enum FanSMCTemperatureReader {
    static func read(model: String, channel: (String) throws -> SMCValue?) throws
        -> (sensors: [FanSensor], temperatures: [String: Double]) {
        var sensors: [FanSensor] = []
        var temperatures: [String: Double] = [:]
        for (key, role) in try FanSensorCatalog.candidates(model: model) {
            guard let value = try channel(key) else {
                if role == .gpuProtection { continue }
                throw FanControlError.unavailable("Required \(role.title) AppleSMC channel is missing: \(key).")
            }
            let sensor = FanSensor(key: key, role: role, encoding: value.encoding)
            try sensor.validate()
            let number = try value.number() // Also requires four bytes for flt.
            // A non-finite value fails at once. A finite value outside the
            // qualified range is reported by discovery, or by frame validation
            // after every other check, so only an otherwise valid frame can be
            // skipped as unusable.
            guard number.isFinite else {
                throw FanControlError.unavailable("\(role.title) (\(key)) returned a non-finite value.")
            }
            sensors.append(sensor)
            temperatures[key] = number
        }
        guard sensors.contains(where: { $0.role == .gpuProtection }) else {
            throw FanControlError.unavailable("No reviewed GPU protection temperature channel is readable.")
        }
        return (sensors, temperatures)
    }
}

public enum FanSystemIdentity {
    public static func sysctlString(_ key: String) throws -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size < 4096 else {
            throw FanControlError.unavailable("Cannot read machine identity \(key).")
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else {
            throw FanControlError.unavailable("Cannot read machine identity \(key).")
        }
        return String(cString: bytes)
    }
}
