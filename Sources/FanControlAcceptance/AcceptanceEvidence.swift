import Foundation
import Security
import Darwin
import FanControlCore
import FanControlHardware

struct AcceptanceCodeIdentity: Codable, Equatable {
    let path: String
    let identifier: String
    let team: String
    let cdhash: String

    static func inspect(path: String, identifier: String, team: String) throws -> Self {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { throw AcceptanceError.failed("Cannot inspect signed artifact at \(path).") }
        let text = try FanSigning.requirement(identifier: identifier, team: team)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw AcceptanceError.failed("Artifact does not meet the production identifier/team requirement: \(path).")
        }
        var dictionary: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let values = dictionary as? [String: Any],
              let signedIdentifier = values[kSecCodeInfoIdentifier as String] as? String,
              let signedTeam = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let hash = values[kSecCodeInfoUnique as String] as? Data else {
            throw AcceptanceError.failed("Incomplete artifact signing identity: \(path).")
        }
        return Self(path: path, identifier: signedIdentifier, team: signedTeam,
                    cdhash: hash.map { String(format: "%02x", $0) }.joined())
    }

    static func inspectFixture(path: String) throws -> Self {
        var code: SecStaticCode?
        var dictionary: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &dictionary) == errSecSuccess,
              let values = dictionary as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let hash = values[kSecCodeInfoUnique as String] as? Data else {
            throw AcceptanceError.failed("Cannot retain negative fixture signature metadata: \(path).")
        }
        return Self(path: path, identifier: identifier, team: values[kSecCodeInfoTeamIdentifier as String] as? String ?? "none",
                    cdhash: hash.map { String(format: "%02x", $0) }.joined())
    }
}

struct AcceptanceArtifactContext: Codable {
    let cli: AcceptanceCodeIdentity
    let app: AcceptanceCodeIdentity
    let expectedBundledHelper: AcceptanceCodeIdentity
    let helperAuthenticationRequirement: String
    let machineModel: String
    let os: String
    let effectiveUID: UInt32
    let cliPID: Int32
    let cliPurpose: String
    var artifactEvidenceScope = "Static expected app/helper identity; live XPC authenticates helper identifier/team. Peer PID is corroborating evidence. Independently inspect the running helper executable to establish its exact cdhash."

    static func capture(appPath: String, rejectedFixtureTeam: String? = nil) throws -> Self {
        let team: String
        if let rejectedFixtureTeam { team = rejectedFixtureTeam }
        else { team = try FanSigning.selfIdentity().team }
        var executableSize: UInt32 = 0
        _NSGetExecutablePath(nil, &executableSize)
        var executableBytes = [CChar](repeating: 0, count: Int(executableSize))
        guard _NSGetExecutablePath(&executableBytes, &executableSize) == 0 else {
            throw AcceptanceError.failed("Cannot resolve the running acceptance executable.")
        }
        let executable = URL(fileURLWithPath: String(cString: executableBytes)).resolvingSymlinksInPath().path
        let cli = try rejectedFixtureTeam == nil
            ? AcceptanceCodeIdentity.inspect(path: executable, identifier: FanServiceIdentity.app, team: team)
            : AcceptanceCodeIdentity.inspectFixture(path: executable)
        if rejectedFixtureTeam != nil && cli.team == team && cli.identifier == FanServiceIdentity.app {
            throw AcceptanceError.failed("rejected-client requires a deliberately untrusted signing fixture; this CLI matches the expected app identity.")
        }
        let app = try AcceptanceCodeIdentity.inspect(path: appPath, identifier: FanServiceIdentity.app, team: team)
        let helperPath = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Library/HelperTools/FanControlHelper").path
        let helper = try AcceptanceCodeIdentity.inspect(path: helperPath, identifier: FanServiceIdentity.helper, team: team)
        return Self(cli: cli, app: app, expectedBundledHelper: helper,
                    helperAuthenticationRequirement: try FanSigning.requirement(identifier: FanServiceIdentity.helper, team: team),
                    machineModel: try FanSystemIdentity.sysctlString("hw.model"),
                    os: ProcessInfo.processInfo.operatingSystemVersionString, effectiveUID: geteuid(), cliPID: getpid(),
                    cliPurpose: rejectedFixtureTeam == nil ? "Authenticated acceptance client" : "Deliberately untrusted read-only rejection fixture")
    }
}

struct AcceptanceEvent: Codable {
    let schemaVersion: Int
    let runID: String
    let recordedUTC: String
    let monotonicTime: TimeInterval
    let evidenceTier: String
    let event: String
    let detail: [String: String]
    let status: FanStatus?
    let artifactContext: AcceptanceArtifactContext?
}

protocol AcceptanceRecording: AnyObject {
    func record(_ event: String, details: [String: String], status: FanStatus?) throws
    func firstFailure(_ message: String, status: FanStatus?) throws
}

final class AcceptanceJSONL: AcceptanceRecording, @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private let runID = UUID().uuidString
    private let evidenceTier: String
    private var failureRecorded = false
    private let encoder: JSONEncoder

    init(path: String, evidenceTier: String = "live-authenticated-xpc") throws {
        // Preserve every existing receipt, including symlink destinations. The
        // caller must select a fresh filename for each explicitly selected run.
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AcceptanceError.failed("Cannot exclusively create evidence file (errno \(errno)): \(path).") }
        file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.evidenceTier = evidenceTier
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func context(_ context: AcceptanceArtifactContext) throws {
        try write(event: "artifact_context", details: [:], status: nil, context: context)
    }
    func record(_ event: String, details: [String: String] = [:], status: FanStatus? = nil) throws {
        try write(event: event, details: details, status: status, context: nil)
    }
    func firstFailure(_ message: String, status: FanStatus? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard !failureRecorded else { return }
        try append(event: "first_failure", details: ["message": message], status: status, context: nil)
        failureRecorded = true
    }
    private func write(event: String, details: [String: String], status: FanStatus?, context: AcceptanceArtifactContext?) throws {
        lock.lock(); defer { lock.unlock() }
        try append(event: event, details: details, status: status, context: context)
    }
    private func append(event: String, details: [String: String], status: FanStatus?, context: AcceptanceArtifactContext?) throws {
        let value = AcceptanceEvent(schemaVersion: 1, runID: runID, recordedUTC: Date().ISO8601Format(),
                                    monotonicTime: ProcessInfo.processInfo.systemUptime, evidenceTier: evidenceTier,
                                    event: event, detail: details, status: status, artifactContext: context)
        var bytes = try encoder.encode(value); bytes.append(0x0a)
        try file.write(contentsOf: bytes)
        try file.synchronize()
    }
}
