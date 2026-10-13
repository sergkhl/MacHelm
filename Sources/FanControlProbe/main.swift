import Foundation
import FanControlCore
import FanControlHardware

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments == ["--read-only", "--hid-inventory"] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(FanHIDDiagnostics.readOnlyInventory()), as: UTF8.self))
        exit(0)
    }
    if arguments == ["--read-only", "--fan-state"] {
        let hardware = try AppleFanHardware()
        struct Fans: Encodable {
            let captured: String
            let model: String
            let fans: [FanDescriptor]
            let state: FanControlObservation
        }
        let observed = try hardware.probeFans()
        let result = Fans(captured: Date().ISO8601Format(), model: observed.model, fans: observed.fans, state: observed.observation)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
        exit(0)
    }
    let count = try FanReadOnlyQualification.sampleCount(arguments: arguments)
    let fixture = try FanReadOnlyQualification.capture(sampleCount: count)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(fixture), as: UTF8.self))
} catch {
    fputs("Read-only qualification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
