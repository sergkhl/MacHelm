import Foundation

struct AcceptanceOptions {
    enum Command: String { case status, hostileInputs = "hostile-inputs", rejectedClient = "rejected-client", roundTrip = "round-trip" }
    let command: Command
    let appPath: String
    let outputPath: String
    let samples: Int
    let duration: TimeInterval?
    let expectedTeam: String?

    static let help = """
    Usage:
      fan-control-acceptance status --app /path/MacHelm.app --output /new/evidence.jsonl [--samples 12]
      fan-control-acceptance hostile-inputs --app /path/MacHelm.app --output /new/evidence.jsonl
      fan-control-acceptance rejected-client --app /path/MacHelm.app --output /new/evidence.jsonl --expected-team YOURTEAMID
      fan-control-acceptance round-trip --app /path/MacHelm.app --output /new/evidence.jsonl --allow-native-writes --duration 30

    status only observes. hostile-inputs sends only invalid profiles/sessions and
    requires an idle automatic baseline. round-trip explicitly enables a temporary
    45/85 session profile; it never changes the GUI's saved profile. Its selected
    native session bound must be 1–60 seconds. It exercises second-owner rejection,
    records effective mode/target/unlock and actual RPM, and sends one stop/release
    on success, first failure or the selected bound. Native restoration can outlast
    that bound if the hardware service stalls; no hard recovery deadline is claimed.
    Every output path must be new. No command installs or approves a service.
    rejected-client is a deliberate wrong/ad-hoc signature fixture. It bypasses
    fixture self-trust and sends one status(observe:false) only. A transport
    rejection is retained as an observation; unavailable service is never a
    security pass. Corroborate a working authenticated service separately.
    """

    static func parse(_ arguments: [String]) throws -> Self {
        guard let first = arguments.first, let command = Command(rawValue: first) else {
            throw AcceptanceError.failed(help)
        }
        var values: [String: String] = [:]
        var writes = false
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            if key == "--allow-native-writes" {
                guard !writes else { throw AcceptanceError.failed("Duplicate native-write flag.") }
                writes = true; index += 1; continue
            }
            guard ["--app", "--output", "--samples", "--duration", "--expected-team"].contains(key), values[key] == nil,
                  index + 1 < arguments.count else { throw AcceptanceError.failed("Invalid/duplicate argument: \(key).\n\(help)") }
            values[key] = arguments[index + 1]; index += 2
        }
        guard let app = values["--app"], app.hasPrefix("/"),
              let output = values["--output"], output.hasPrefix("/") else {
            throw AcceptanceError.failed("Explicit absolute --app and fresh --output paths are required.")
        }
        let samples = Int(values["--samples"] ?? "12")
        guard let samples, (1...30).contains(samples) else { throw AcceptanceError.failed("--samples must be 1–30.") }
        let duration: TimeInterval?
        if command == .roundTrip {
            guard writes, let text = values["--duration"], let requested = Double(text), requested.isFinite,
                  (1...60).contains(requested), values["--samples"] == nil else {
                throw AcceptanceError.failed("round-trip requires --allow-native-writes and explicit --duration 1–60; it does not accept --samples.")
            }
            duration = requested
        } else {
            guard !writes, values["--duration"] == nil,
                  command == .status || values["--samples"] == nil else {
                throw AcceptanceError.failed("Native flags apply only to round-trip; --samples applies only to status.")
            }
            duration = nil
        }
        if command == .rejectedClient {
            guard let team = values["--expected-team"], team.count == 10,
                  team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
                throw AcceptanceError.failed("rejected-client requires a valid explicit --expected-team.")
            }
        } else if values["--expected-team"] != nil {
            throw AcceptanceError.failed("--expected-team applies only to the deliberate rejected-client fixture.")
        }
        return Self(command: command, appPath: app, outputPath: output, samples: samples, duration: duration,
                    expectedTeam: values["--expected-team"])
    }
}
