#if FAN_CONTROL_QUALIFICATION
import Foundation
import Darwin
#if canImport(FanControlCore)
import FanControlCore
#endif

// This entire source is absent from an ordinary app/helper binary. The private
// qualification artifact can only raise valid thermal inputs or invalidate a
// complete frame. It cannot replace native fan observations, change bounds,
// stall hardware work, or issue a fan operation of its own. The two
// unconfirmed-* scenarios (E-Q7) change no input at all: they only make the
// helper treat the acknowledgement of one real write as unconfirmed. The
// helper then responds as it would to a naturally unconfirmed command,
// which includes its own release attempt. declined-unconfirmed-target (W-Q1)
// does the same to one positive target; once its probes saw that target, the
// helper declines its own attempt, so the hold waits on the owner. An injected finite
// out-of-range value makes frames unusable, as a natural glitch would: they
// are skipped, which can delay protection until the complete-frame window ends.
public enum FanQualificationScenario: String, CaseIterable, Codable {
    case cpuAverage70 = "cpu-average-70"
    case cpuAverage75 = "cpu-average-75"
    case cpuAverage80 = "cpu-average-80"
    case cpuAverage85 = "cpu-average-85"
    case cpuMaximumProtection = "cpu-maximum-protection"
    case gpuProtection = "gpu-protection"
    case pressureSerious = "pressure-serious"
    case pressureCritical = "pressure-critical"
    case missingCPUAverage = "missing-cpu-average"
    case missingCPUMaximum = "missing-cpu-maximum"
    case missingGPU = "missing-gpu"
    case invalidCPUAverage = "invalid-cpu-average"
    case invalidCPUMaximum = "invalid-cpu-maximum"
    case invalidGPU = "invalid-gpu"
    case nonfiniteCPUAverage = "nonfinite-cpu-average"
    case nonfiniteCPUMaximum = "nonfinite-cpu-maximum"
    case nonfiniteGPU = "nonfinite-gpu"
    case staleFrame = "stale-frame"
    case telemetryReadFailure = "telemetry-read-failure"
    // The next manual-entry (or positive target) write is issued natively and
    // observed natively, but its acknowledgement is treated as unconfirmed.
    case unconfirmedManualEntry = "unconfirmed-manual-entry"
    case unconfirmedTarget = "unconfirmed-target"
    // W-Q1: as unconfirmed-target, and the helper then declines its own
    // attempt, so the fan holds at that target until the owner acts.
    case declinedUnconfirmedTarget = "declined-unconfirmed-target"
}

struct FanQualificationPlan: Codable, Equatable {
    static let maximumDuration: TimeInterval = 60
    let version: Int
    let runID: UUID
    let bootID: UUID
    let scenario: FanQualificationScenario
    let expiresAtUptime: TimeInterval

    init(runID: UUID, bootID: UUID = UUID(), scenario: FanQualificationScenario, expiresAtUptime: TimeInterval) {
        version = 1; self.runID = runID; self.bootID = bootID
        self.scenario = scenario; self.expiresAtUptime = expiresAtUptime
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case version, runID, bootID, scenario, expiresAtUptime }

    init(from decoder: Decoder) throws {
        let allKeys = try decoder.container(keyedBy: Key.self)
        guard Set(allKeys.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw FanControlError.invalid("Qualification input must contain exactly version, runID, bootID, scenario and expiresAtUptime.")
        }
        let input = try decoder.container(keyedBy: CodingKeys.self)
        version = try input.decode(Int.self, forKey: .version)
        runID = try input.decode(UUID.self, forKey: .runID)
        bootID = try input.decode(UUID.self, forKey: .bootID)
        scenario = try input.decode(FanQualificationScenario.self, forKey: .scenario)
        expiresAtUptime = try input.decode(TimeInterval.self, forKey: .expiresAtUptime)
    }

    func validate(now: TimeInterval) throws {
        guard version == 1, now.isFinite, expiresAtUptime.isFinite,
              expiresAtUptime > now, expiresAtUptime - now <= Self.maximumDuration else {
            throw FanControlError.invalid("Qualification input is unsupported, expired, or exceeds its 60-second monotonic limit.")
        }
    }
}

// No directory is created and no caller-supplied path is accepted by the public
// helper construction. Each system parent is opened relative to a trusted fd.
// An absent qualification directory/file means natural telemetry; an existing
// unsafe or malformed input fails the read and therefore cancels control.
final class FanQualificationFileSource {
    static let directoryPath = "/Library/Application Support/io.github.sergkhl.MacHelm.FanControlHelper/qualification"
    static let filePath = directoryPath + "/scenario.json"
    static let maximumFileSize: off_t = 4_096
    private let requiredUID: uid_t
    private let fixtureDirectory: URL?
    private let fixtureBootID: UUID?

    init() { requiredUID = 0; fixtureDirectory = nil; fixtureBootID = nil }

    // File-security tests never need root and never reach the fixed live path.
    init(testDirectory: URL, requiredUID: uid_t, bootID: UUID) {
        fixtureDirectory = testDirectory; self.requiredUID = requiredUID; fixtureBootID = bootID
    }

    func load(now: TimeInterval) throws -> FanQualificationPlan? {
        guard geteuid() == requiredUID else {
            throw FanControlError.ownership("Qualification input is accessible only to its service owner.")
        }
        guard let directoryFD = try openDirectory() else { return nil }
        defer { close(directoryFD) }
        let fd = openat(directoryFD, "scenario.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure("open qualification input") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_uid == requiredUID,
              before.st_mode & S_IFMT == S_IFREG, before.st_mode & 0o7777 == 0o600,
              before.st_nlink == 1, before.st_size > 0, before.st_size <= Self.maximumFileSize else {
            throw FanControlError.ownership("Qualification input has unsafe ownership, permissions, type, links or size.")
        }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size))
        let total = bytes.count
        var offset = 0
        while offset < total {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), total - offset)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw failure("read qualification input") }
            offset += count
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_uid == after.st_uid,
              before.st_mode == after.st_mode, after.st_nlink == 1,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FanControlError.ownership("Qualification input changed while being read; control remains disarmed.")
        }
        let plan: FanQualificationPlan
        do { plan = try JSONDecoder().decode(FanQualificationPlan.self, from: Data(bytes)) }
        catch { throw FanControlError.invalid("Qualification input is malformed or contains an unapproved scenario/field.") }
        let currentBoot: UUID
        if let fixtureBootID { currentBoot = fixtureBootID }
        else {
            guard let boot = UUID(uuidString: try FanSystemIdentity.sysctlString("kern.bootsessionuuid")) else {
                throw FanControlError.unavailable("Cannot establish the current boot for qualification input.")
            }
            currentBoot = boot
        }
        guard plan.bootID == currentBoot else {
            throw FanControlError.invalid("Qualification input belongs to another boot; it cannot authorize injected telemetry.")
        }
        try plan.validate(now: now)
        return plan
    }

    private func openDirectory() throws -> Int32? {
        if let fixtureDirectory {
            let fd = open(fixtureDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure("open qualification fixture directory") }
            do { try checkDirectory(fd, privateToOwner: true); return fd }
            catch { close(fd); throw error }
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("open trusted root") }
        do {
            try checkDirectory(fd, privateToOwner: false)
            let components = [("Library", false), ("Application Support", false),
                              ("io.github.sergkhl.MacHelm.FanControlHelper", true), ("qualification", true)]
            for (component, privateToOwner) in components {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && privateToOwner { close(fd); return nil }
                guard next >= 0 else { throw failure("open trusted qualification parent") }
                close(fd); fd = next
                try checkDirectory(fd, privateToOwner: privateToOwner)
            }
            return fd
        } catch { close(fd); throw error }
    }

    private func checkDirectory(_ fd: Int32, privateToOwner: Bool) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == requiredUID, info.st_mode & S_IFMT == S_IFDIR,
              privateToOwner ? (info.st_mode & 0o7777 == 0o700) : (info.st_mode & 0o022 == 0) else {
            throw FanControlError.ownership("Qualification parent is not trusted/private to its service owner.")
        }
    }

    private func failure(_ action: String) -> FanControlError {
        .ownership("Cannot \(action) (errno \(errno)); qualification control remains disarmed.")
    }
}

public final class FanQualificationHardware: FanHardware {
    private let native: FanHardware
    private let loadPlan: (TimeInterval) throws -> FanQualificationPlan?
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var latest: String?
    private var withheldRun: UUID?
    private var withheldNote: String?

    public init(delegating hardware: FanHardware) {
        native = hardware
        let source = FanQualificationFileSource()
        loadPlan = { try source.load(now: $0) }
        clock = { ProcessInfo.processInfo.systemUptime }
    }

    init(delegating hardware: FanHardware, plan: @escaping (TimeInterval) throws -> FanQualificationPlan?,
         clock: @escaping () -> TimeInterval) {
        native = hardware; loadPlan = plan; self.clock = clock
    }

    // The controller copies this bounded JSON marker into existing diagnostics.
    // Every affected frame, native read failure and rejected input has an event.
    public var provenance: String? { lock.lock(); defer { lock.unlock() }; return latest }

    public func discover() throws -> FanCapabilities { try native.discover() }
    public func readControlState(_ capabilities: FanCapabilities) throws -> FanControlObservation {
        try native.readControlState(capabilities)
    }
    public func readControlState(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanControlObservation {
        try native.readControlState(capabilities, cancelled: cancelled)
    }
    public func beginCommandDiagnosticCapture() { native.beginCommandDiagnosticCapture() }
    public func endCommandDiagnosticCapture() -> [FanNativeCallReceipt] { native.endCommandDiagnosticCapture() }
    public var commandDiagnosticCapacityRemaining: Int { native.commandDiagnosticCapacityRemaining }
    public var commandDiagnosticWrite: FanNativeCallReceipt? { native.commandDiagnosticWrite }
    public func probeFans() throws -> FanFanProbe { try native.probeFans() }
    public func probeFans(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanFanProbe {
        try native.probeFans(capabilities, cancelled: cancelled)
    }
    public func perform(_ operation: FanOperation, capabilities: FanCapabilities, cancelled: () -> Bool) throws {
        try native.perform(operation, capabilities: capabilities, cancelled: cancelled)
    }

    // E-Q7 and W-Q1. Once per qualification run, for the first journaled write
    // of the scenario's kind while the private input is valid, this says how
    // the helper treats that write's acknowledgement: as unconfirmed, or also
    // as a recovery it declines once the probes saw the target. The write and
    // every observation stay native. Any rejected, absent or expired input
    // withholds nothing.
    public func withholdsAcknowledgement(of operation: FanOperation) -> FanQualificationWithholding? {
        guard let plan = try? loadPlan(clock()), (try? plan.validate(now: clock())) != nil else { return nil }
        let withholding: FanQualificationWithholding
        switch (plan.scenario, operation) {
        case (.unconfirmedManualEntry, .mode(_, true)): withholding = .unconfirmed
        case (.unconfirmedTarget, .target(_, let rpm)) where rpm > 0: withholding = .unconfirmed
        case (.declinedUnconfirmedTarget, .target(_, let rpm)) where rpm > 0: withholding = .declinedRecovery
        default: return nil
        }
        guard withheldRun != plan.runID else { return nil }
        withheldRun = plan.runID
        let declined = withholding == .declinedRecovery
        // Every later event carries this note, so the next logged frame shows it.
        withheldNote = "run \(plan.runID.uuidString) withheld the acknowledgement of \(operation) at uptime \(clock())"
            + (declined ? "; once its probes see the target, the helper is to decline its own attempt" : "")
        sequence &+= 1
        var event = Event(sequence: sequence, observedAtUptime: clock())
        event.runID = plan.runID.uuidString; event.scenario = plan.scenario.rawValue
        event.bootID = plan.bootID.uuidString; event.expiresAtUptime = plan.expiresAtUptime
        event.outcome = declined ? "withheld-acknowledgement-declined-recovery" : "withheld-acknowledgement"
        event.withheldAcknowledgement = withheldNote
        event.reason = declined
            ? "The write and every observation stay native; the helper's acknowledgement is treated as unconfirmed and, once its probes see the target, as a recovery the helper declines."
            : "The write and every observation stay native; only the helper's acknowledgement is treated as unconfirmed."
        retain(event)
        return withholding
    }

    public func read(_ capabilities: FanCapabilities) throws -> FanSnapshot {
        sequence &+= 1
        var event = Event(sequence: sequence, observedAtUptime: clock())
        event.withheldAcknowledgement = withheldNote
        defer { retain(event) }
        let plan: FanQualificationPlan?
        do { plan = try loadPlan(clock()) }
        catch {
            event.outcome = "rejected-private-input"; event.reason = error.localizedDescription
            throw error
        }
        event.runID = plan?.runID.uuidString; event.scenario = plan?.scenario.rawValue ?? "none"
        event.bootID = plan?.bootID.uuidString
        event.expiresAtUptime = plan?.expiresAtUptime
        let frame: FanSnapshot
        do { frame = try native.read(capabilities) }
        catch {
            event.outcome = "native-read-failure"; event.reason = error.localizedDescription
            throw error
        }
        // Never supply an injected valid frame over real missing/invalid data.
        do { try frame.validate(against: capabilities, now: clock()) }
        catch {
            event.outcome = "native-frame-rejected"; event.reason = error.localizedDescription
            throw error
        }
        event.nativeCapturedAt = frame.capturedAt
        event.nativeTemperatures = frame.temperatures
        event.nativeThermalPressure = frame.thermalPressure.rawValue
        guard let plan else { event.record(frame); return frame }
        // Re-check after native I/O in case the requested deadline elapsed.
        do { try plan.validate(now: clock()) }
        catch { event.outcome = "expired-private-input"; event.reason = error.localizedDescription; throw error }
        if plan.scenario == .telemetryReadFailure {
            event.outcome = "injected-read-failure"
            event.reason = "Qualification injected telemetry-read-failure after the native complete-frame read."
            throw FanControlError.hardware(event.reason!)
        }
        var temperatures = frame.temperatures
        var pressure = frame.thermalPressure
        var capturedAt = frame.capturedAt
        func raise(_ role: FanTelemetryRole, to value: Double) {
            for sensor in capabilities.sensors where sensor.role == role {
                temperatures[sensor.key] = max(temperatures[sensor.key] ?? value, value)
            }
        }
        func replace(_ role: FanTelemetryRole, with value: Double?) {
            for sensor in capabilities.sensors where sensor.role == role { temperatures[sensor.key] = value }
        }
        switch plan.scenario {
        case .cpuAverage70: raise(.cpuAverage, to: 70)
        case .cpuAverage75: raise(.cpuAverage, to: 75)
        case .cpuAverage80: raise(.cpuAverage, to: 80)
        case .cpuAverage85: raise(.cpuAverage, to: 85)
        case .cpuMaximumProtection: raise(.cpuMaximum, to: 90)
        case .gpuProtection: raise(.gpuProtection, to: 85)
        case .pressureSerious: pressure = FanThermalPressure(rawValue: max(pressure.rawValue, 2))!
        case .pressureCritical: pressure = .critical
        case .missingCPUAverage: replace(.cpuAverage, with: nil)
        case .missingCPUMaximum: replace(.cpuMaximum, with: nil)
        case .missingGPU: replace(.gpuProtection, with: nil)
        case .invalidCPUAverage: replace(.cpuAverage, with: 7)
        case .invalidCPUMaximum: replace(.cpuMaximum, with: 7)
        case .invalidGPU: replace(.gpuProtection, with: 0)
        case .nonfiniteCPUAverage: replace(.cpuAverage, with: .nan)
        case .nonfiniteCPUMaximum: replace(.cpuMaximum, with: .nan)
        case .nonfiniteGPU: replace(.gpuProtection, with: .nan)
        case .staleFrame: capturedAt -= 3
        case .telemetryReadFailure: break // Throws above, after preserving the native evidence.
        case .unconfirmedManualEntry, .unconfirmedTarget, .declinedUnconfirmedTarget: break // Telemetry stays native.
        }
        switch plan.scenario {
        case .cpuAverage70, .cpuAverage75, .cpuAverage80, .cpuAverage85:
            // A synthetic average cannot invent a lower maximum or mask a
            // native maximum/GPU/pressure protection trigger.
            raise(.cpuMaximum, to: temperatures["TCMb"] ?? frame.cpuDieMaximum(in: capabilities))
        default: break
        }
        let effective = FanSnapshot(capturedAt: capturedAt, temperatures: temperatures, fans: frame.fans,
                                    thermalPressure: pressure, globalUnlock: frame.globalUnlock,
                                    readDuration: frame.readDuration)
        event.record(effective)
        return effective
    }

    public static func schemaJSON() throws -> Data {
        struct Schema: Encodable {
            let qualificationBuild = true
            let version = 1
            let fixedInputFile = FanQualificationFileSource.filePath
            let requiredOwner = "root"
            let privateDirectoryMode = "0700"
            let fileMode = "0600"
            let maximumBytes = FanQualificationFileSource.maximumFileSize
            let maximumScenarioSeconds = FanQualificationPlan.maximumDuration
            let exactFields = ["version", "runID", "bootID", "scenario", "expiresAtUptime"]
            let bootBinding = "bootID must match kern.bootsessionuuid; a retained input cannot re-arm after reboot."
            let scenarios = FanQualificationScenario.allCases.map(\.rawValue)
            let fanObservationsAndWrites = "Delegated unchanged to the native adapter, with all existing recovery/cancellation guards. The unconfirmed-* scenarios leave them native too and only withhold the helper's acknowledgement of one write per run. declined-unconfirmed-target withholds one positive target the same way; once its probes saw that target, its ending is named qualificationDeclinedRecovery and the helper declines its own attempt, so the hold waits on the owner."
            let thermalBehavior = "Valid injections only raise native temperature/pressure; data-loss scenarios invalidate the complete frame."
            let absentInput = "Natural telemetry; unsafe/malformed/expired input fails closed."
            let readOnlyCommand = "--read-only always uses the native reader and never applies qualification inputs."
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Schema())
    }

    private struct Event: Encodable {
        let build = "FAN_CONTROL_QUALIFICATION"
        let fanStateOrigin = "native-unmodified"
        let sequence: UInt64
        let observedAtUptime: TimeInterval
        var scenario = "not-loaded"
        var runID: String?
        var bootID: String?
        var expiresAtUptime: TimeInterval?
        var nativeCapturedAt: TimeInterval?
        var effectiveCapturedAt: TimeInterval?
        var nativeTemperatures: [String: Double]?
        var effectiveTemperatures: [String: String]?
        var nativeThermalPressure: Int?
        var effectiveThermalPressure: Int?
        var outcome = "complete-frame"
        var reason: String?
        var withheldAcknowledgement: String?
        mutating func record(_ frame: FanSnapshot) {
            effectiveCapturedAt = frame.capturedAt
            effectiveTemperatures = frame.temperatures.mapValues { String($0) }
            effectiveThermalPressure = frame.thermalPressure.rawValue
        }
    }

    private func retain(_ event: Event) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let text = (try? encoder.encode(event)).map { String(decoding: $0, as: UTF8.self) }
            ?? "{\"build\":\"FAN_CONTROL_QUALIFICATION\",\"outcome\":\"provenance-encoding-failed\"}"
        lock.lock(); latest = text; lock.unlock()
    }
}
#endif
