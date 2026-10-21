import Foundation

public enum FanControlError: Error, LocalizedError, Equatable {
    case invalid(String)
    case unavailable(String)
    case busy
    case cancelled
    case hardware(String)
    case ownership(String)
    // Preserve the filesystem error as data so recovery never retries a
    // permissions/ownership failure by matching user-facing text.
    case persistence(operation: String, code: Int32)
    // A finite temperature outside its role's qualified range. Frame
    // validation reports it only after every other check has passed. Within
    // an established session such a frame is unusable: no decision or write
    // follows, nothing is substituted, clamped or kept for control, and the
    // complete-frame deadline keeps running. At idle it is skipped the same
    // way, and a begin waits for the next frame.
    case readingOutOfRange(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason), .unavailable(let reason), .hardware(let reason), .ownership(let reason),
             .readingOutOfRange(let reason): return reason
        case .busy: return "Another authenticated app connection owns Fan Control."
        case .cancelled: return "Fan Control was stopped; obsolete fan commands were cancelled."
        case .persistence(let operation, let code):
            return "Cannot \(operation) (errno \(code)); fan writes remain disarmed."
        }
    }
}

public struct FanProfile: Codable, Equatable {
    public let start: Double
    public let maximum: Double
    public static let standard = FanProfile(start: 70, maximum: 85)

    public init(start: Double, maximum: Double) {
        self.start = start
        self.maximum = maximum
    }

    public func validate() throws {
        guard start.isFinite, maximum.isFinite, (40...75).contains(start),
              (55...90).contains(maximum), maximum - start >= 10 else {
            throw FanControlError.invalid("Choose a start of 40–75 °C and maximum of 55–90 °C, at least 10 °C apart.")
        }
    }

    public func demand(at temperature: Double) -> Double {
        max(0, min(1, (temperature - start) / (maximum - start)))
    }
}

public enum FanSensorGroup: String, Codable {
    // Historical/HID inventory groups, never an active control basis.
    case performance, efficiency, gpu
}

public enum FanTelemetryRole: String, Codable {
    case cpuAverage, cpuMaximum, gpuProtection

    public var title: String {
        switch self {
        case .cpuAverage: return "Firmware CPU die average"
        case .cpuMaximum: return "Firmware CPU die maximum"
        case .gpuProtection: return "GPU protection temperature"
        }
    }
}

public enum FanTemperatureBasis: String, Codable {
    case appleSMCCPUDieAggregates
}

public struct FanSensor: Codable, Equatable, Identifiable {
    public let key: String
    public let role: FanTelemetryRole
    public let encoding: String
    public var id: String { key }
    public init(key: String, role: FanTelemetryRole, encoding: String) {
        self.key = key; self.role = role; self.encoding = encoding
    }

    public func validate() throws {
        let qualified: Bool
        switch role {
        case .cpuAverage: qualified = key == "TCMb" && encoding == "flt "
        case .cpuMaximum: qualified = key == "TCMz" && encoding == "flt "
        case .gpuProtection: qualified = ["Tg0f", "Tg0j"].contains(key) && ["flt ", "sp78"].contains(encoding)
        }
        guard qualified else {
            throw FanControlError.unavailable("Unqualified \(role.title) channel or encoding: \(key) (\(encoding)).")
        }
    }
}

public struct FanDescriptor: Codable, Equatable, Identifiable {
    public let id: Int
    public let minimumRPM: Double
    public let maximumRPM: Double
    public let modeKey: String
    public let targetEncoding: String
    public var span: Double { maximumRPM - minimumRPM }

    public init(id: Int, minimumRPM: Double, maximumRPM: Double, modeKey: String, targetEncoding: String) {
        self.id = id; self.minimumRPM = minimumRPM; self.maximumRPM = maximumRPM
        self.modeKey = modeKey; self.targetEncoding = targetEncoding
    }

    public func validate() throws {
        guard (0...9).contains(id), minimumRPM.isFinite, maximumRPM.isFinite,
              minimumRPM >= 0, maximumRPM <= 20_000, span > 0,
              ["F\(id)md", "F\(id)Md"].contains(modeKey),
              ["flt ", "fpe2"].contains(targetEncoding),
              targetEncoding != "fpe2" || maximumRPM <= 16_383.75 else {
            throw FanControlError.invalid("Fan \(id + 1) has unsupported mode, encoding, or RPM bounds.")
        }
    }

    public func target(demand: Double) -> Double {
        minimumRPM + min(1, max(0, demand)) * span
    }
}

public struct FanCapabilities: Codable, Equatable {
    public let model: String
    public let temperatureBasis: FanTemperatureBasis
    public let sensors: [FanSensor]
    public let fans: [FanDescriptor]
    public let hasGlobalUnlock: Bool

    public init(model: String, sensors: [FanSensor], fans: [FanDescriptor], hasGlobalUnlock: Bool,
                temperatureBasis: FanTemperatureBasis = .appleSMCCPUDieAggregates) {
        self.model = model; self.temperatureBasis = temperatureBasis
        self.sensors = sensors; self.fans = fans; self.hasGlobalUnlock = hasGlobalUnlock
    }

    public func validate() throws {
        guard !model.isEmpty, !fans.isEmpty, fans.count <= 10,
              Set(fans.map(\.id)).count == fans.count,
              Set(sensors.map(\.key)).count == sensors.count,
              sensors.filter({ $0.role == .cpuAverage }).count == 1,
              sensors.filter({ $0.role == .cpuMaximum }).count == 1,
              sensors.contains(where: { $0.role == .gpuProtection }) else {
            throw FanControlError.unavailable("Firmware CPU die average (TCMb), CPU die maximum (TCMz), qualified GPU readings and controllable fans are required.")
        }
        for sensor in sensors { try sensor.validate() }
        for fan in fans { try fan.validate() }
    }
}

public enum FanThermalPressure: Int, Codable {
    case nominal = 0, fair = 1, serious = 2, critical = 3
}

public struct FanReading: Codable, Equatable, Identifiable {
    public let id: Int
    public var actualRPM: Double
    public var targetRPM: Double
    public var mode: Int
    public var isAutomatic: Bool { mode == 0 || mode == 3 }
    public init(id: Int, actualRPM: Double, targetRPM: Double, mode: Int) {
        self.id = id; self.actualRPM = actualRPM; self.targetRPM = targetRPM; self.mode = mode
    }
}

public struct FanSnapshot: Codable, Equatable {
    // Monotonic time of the first read, never a carried-forward sensor value.
    public let capturedAt: TimeInterval
    public let readDuration: TimeInterval
    public let temperatures: [String: Double]
    public var fans: [FanReading]
    public let thermalPressure: FanThermalPressure
    public var globalUnlock: Int?

    public init(capturedAt: TimeInterval, temperatures: [String: Double], fans: [FanReading],
                thermalPressure: FanThermalPressure, globalUnlock: Int?, readDuration: TimeInterval = 0) {
        self.capturedAt = capturedAt; self.temperatures = temperatures; self.fans = fans
        self.thermalPressure = thermalPressure; self.globalUnlock = globalUnlock
        self.readDuration = readDuration
    }

    public func validate(against capabilities: FanCapabilities, now: TimeInterval) throws {
        try capabilities.validate()
        guard capturedAt.isFinite, now.isFinite, capturedAt <= now, now - capturedAt < 3,
              readDuration.isFinite, readDuration >= 0, readDuration <= now - capturedAt else {
            throw FanControlError.invalid("No complete fresh sensor snapshot for three seconds.")
        }
        guard Set(temperatures.keys) == Set(capabilities.sensors.map(\.key)) else {
            throw FanControlError.invalid("The contributing sensor set changed; re-enable to qualify it again.")
        }
        for sensor in capabilities.sensors {
            guard let value = temperatures[sensor.key], value.isFinite else {
                throw FanControlError.invalid("Missing or invalid temperature: \(sensor.key).")
            }
        }
        guard fans.count == capabilities.fans.count, Set(fans.map(\.id)) == Set(capabilities.fans.map(\.id)),
              capabilities.hasGlobalUnlock == (globalUnlock != nil),
              globalUnlock == nil || globalUnlock == 0 || globalUnlock == 1 else {
            throw FanControlError.invalid("Fan capabilities or global control state changed.")
        }
        for reading in fans {
            guard [0, 1, 3].contains(reading.mode), reading.actualRPM.isFinite,
                  reading.targetRPM.isFinite, (0...20_000).contains(reading.actualRPM),
                  (0...20_000).contains(reading.targetRPM) else {
                throw FanControlError.invalid("Missing or invalid bounds/mode/RPM for fan \(reading.id + 1).")
            }
        }
        // Checked last, so only an otherwise valid frame reports a range fault.
        for sensor in capabilities.sensors {
            if let value = temperatures[sensor.key] { try Self.requireQualified(value, sensor: sensor) }
        }
    }

    // The pinned M2 reader accepts CPU aggregates within 10–120 °C and GPU
    // protection channels within 0–130 °C (exclusive). A finite value outside
    // makes the frame unusable; it is never substituted, clamped or kept.
    public static func requireQualified(_ value: Double, sensor: FanSensor) throws {
        guard value > 0, value < 130, sensor.role == .gpuProtection || (10...120).contains(value) else {
            throw FanControlError.readingOutOfRange("\(sensor.role.title) (\(sensor.key)) returned \(value) °C, outside its qualified reading range.")
        }
    }

    public func cpuDieAverage(in capabilities: FanCapabilities) -> Double {
        temperature(for: .cpuAverage, in: capabilities)
    }

    public func cpuDieMaximum(in capabilities: FanCapabilities) -> Double {
        temperature(for: .cpuMaximum, in: capabilities)
    }

    public func hottestGPU(in capabilities: FanCapabilities) -> Double {
        capabilities.sensors.filter { $0.role == .gpuProtection }.map { temperatures[$0.key] ?? .nan }.max() ?? .nan
    }

    private func temperature(for role: FanTelemetryRole, in capabilities: FanCapabilities) -> Double {
        guard let sensor = capabilities.sensors.first(where: { $0.role == role }) else { return .nan }
        return temperatures[sensor.key] ?? .nan
    }

    public var isFullyAutomatic: Bool {
        !fans.isEmpty && fans.allSatisfy(\.isAutomatic) && (globalUnlock == nil || globalUnlock == 0)
    }

    public var controlObservation: FanControlObservation {
        FanControlObservation(capturedAt: capturedAt, fans: fans, globalUnlock: globalUnlock)
    }
}

public struct FanControlObservation: Codable, Equatable {
    public let capturedAt: TimeInterval
    public var fans: [FanReading]
    public var globalUnlock: Int?
    public init(capturedAt: TimeInterval, fans: [FanReading], globalUnlock: Int?) {
        self.capturedAt = capturedAt; self.fans = fans; self.globalUnlock = globalUnlock
    }
    public var isFullyAutomatic: Bool {
        !fans.isEmpty && fans.allSatisfy(\.isAutomatic) && (globalUnlock == nil || globalUnlock == 0)
    }
}

public struct FanFanProbe: Codable {
    public let model: String
    public let fans: [FanDescriptor]
    public let observation: FanControlObservation
    public init(model: String, fans: [FanDescriptor], observation: FanControlObservation) {
        self.model = model; self.fans = fans; self.observation = observation
    }
}

public struct FanExternalRecoveryReceipt: Codable {
    public let recoveryID: String
    public let confirmedAt: TimeInterval
    public let first: FanFanProbe
    public let second: FanFanProbe
    public init(recoveryID: String, confirmedAt: TimeInterval, first: FanFanProbe, second: FanFanProbe) {
        self.recoveryID = recoveryID; self.confirmedAt = confirmedAt; self.first = first; self.second = second
    }
}

// What started the helper's own return to automatic after an unconfirmed
// command: the failure itself, a restart that found it on disk, or the owner.
public enum FanSelfRecoveryTrigger: String, Codable { case automatic, startup, explicit }

// One release write of a self-recovery attempt, with the readbacks that
// decided it. `termination` is `acknowledged`, or the bounded acknowledgement's
// own outcome such as `deadline`. `notIssued` means the attempt's checks
// refused the write before any native call. `notConfirmed` means the write
// call was made, or may have been, and left no acknowledgement trace.
public struct FanSelfRecoveryStep: Codable, Equatable {
    public let operation: FanOperation
    public let termination: String
    public let nativeWriteReturnedAt: TimeInterval?
    public let acknowledgedAt: TimeInterval?
    public let observations: Int
    // Probe 0 is the immediate readback; the rest are complete fan probes.
    // Global unlock keeps its single immediate readback and lists none.
    public let probes: [FanDiagnosticProbe]
    public init(operation: FanOperation, termination: String, nativeWriteReturnedAt: TimeInterval?,
                acknowledgedAt: TimeInterval?, observations: Int, probes: [FanDiagnosticProbe] = []) {
        self.operation = operation; self.termination = termination
        self.nativeWriteReturnedAt = nativeWriteReturnedAt; self.acknowledgedAt = acknowledgedAt
        self.observations = observations; self.probes = probes
    }
}

// The helper's one bounded attempt to return its own fans to automatic after
// an unconfirmed command. It issues release writes only (automatic mode and
// unlock release; since Z-Q3 no zero reset target) and never requests a speed
// or manual mode. When the unconfirmed command was itself a release write, the
// sequence contains that same write again. `confirmedAt` is set only when the hold was
// cleared; otherwise `failure` says why the hold remains.
public struct FanSelfRecoveryReceipt: Codable {
    public let recoveryID: String
    public let trigger: FanSelfRecoveryTrigger
    // Termination of the unconfirmed command's acknowledgement, when known.
    public let cause: String?
    public let unconfirmed: FanOperation
    public let startedAt: TimeInterval
    public var steps: [FanSelfRecoveryStep] = []
    public var lastReleaseAcknowledgedAt: TimeInterval?
    // Two complete automatic probes, the second at least one second after the
    // last release acknowledgement.
    public var settle: [FanFanProbe] = []
    public var confirmedAt: TimeInterval?
    public var failure: String?
    public init(recoveryID: String, trigger: FanSelfRecoveryTrigger, cause: String?,
                unconfirmed: FanOperation, startedAt: TimeInterval) {
        self.recoveryID = recoveryID; self.trigger = trigger; self.cause = cause
        self.unconfirmed = unconfirmed; self.startedAt = startedAt
    }
}

public enum FanOperatingMode: String, Codable {
    case off, automatic, custom, protection, acquiring, paused, unavailable, restoring, restorationFailed, externalRecoveryRequired
    public var title: String {
        switch self {
        case .off: return "Off"
        case .automatic: return "Apple automatic"
        case .custom: return "CPU temperature ramp"
        case .protection: return "Protection: maximum cooling"
        case .acquiring: return "Acquiring fan control"
        case .paused: return "Paused"
        case .unavailable: return "Unavailable"
        case .restoring: return "Restoration pending"
        case .restorationFailed: return "Restoration needs attention"
        case .externalRecoveryRequired: return "Recovery required"
        }
    }
}

// Failed idle observations since the helper started (F-Q5). They write no
// log line; status keeps how many there were and the latest one's text and
// time. A frame skipped at idle for an out-of-range reading counts too.
public struct FanIdleFaults: Codable, Equatable {
    public var count: Int
    // The error as the helper reports it, with the reading it names.
    public var lastReason: String
    public var lastAt: TimeInterval
    public var lastAtUTC: String
    public init(count: Int, lastReason: String, lastAt: TimeInterval, lastAtUTC: String) {
        self.count = count; self.lastReason = lastReason; self.lastAt = lastAt; self.lastAtUTC = lastAtUTC
    }
}

public struct FanStatus: Codable {
    // Version 3 added explicit external recovery and its exact-record identity.
    // Version 4 adds the helper's own bounded recovery and its explicit request.
    // `idleFaults` was added without a new version: it is optional, and a
    // client built before it ignores the key.
    public static let currentProtocolVersion = 4
    public var protocolVersion = currentProtocolVersion
    public var serviceGeneration: String
    public var mode: FanOperatingMode = .off
    public var reason: String?
    public var requestError: String?
    public var capabilities: FanCapabilities?
    public var snapshot: FanSnapshot?
    public var fanProbe: FanFanProbe?
    public var requestedRPM: [Int: Double] = [:]
    public var smoothedCPU: Double?
    public var sessionID: String?
    public var ownsOverride = false
    public var releaseVerified = false
    public var safeToUnregister = false
    public var externalRecoveryRequired = false
    public var externalRecoveryID: String?
    public var storageRecoveryPending: Bool?
    public var storageRecoveryRetryAt: TimeInterval?
    public var externalRecoveryReceipt: FanExternalRecoveryReceipt?
    // True while a recovery hold exists that this helper may release itself:
    // its record is from this boot and this helper build. False for a record
    // from another boot or build, which only external recovery can resolve.
    public var restoreAutomaticOffered: Bool?
    // The most recent self-recovery attempt since Fan Control was last turned
    // on, whether or not it cleared the hold.
    public var selfRecoveryReceipt: FanSelfRecoveryReceipt?
    // Optional evidence records acknowledgement separately from the first mismatch.
    public var manualModeDiagnostic: FanManualModeDiagnostic?
    // Optional trace of the most recent bounded acknowledgement: an ordinary
    // target, a zero target on an automatic fan or a mode release, acknowledged or failed.
    public var targetDiagnostic: FanTargetDiagnostic?
    public var idleFaults: FanIdleFaults?
    public var diagnostics: [String] = []
    public var diagnosticsOmittedCount: Int?
    public init(serviceGeneration: String) { self.serviceGeneration = serviceGeneration }

    public static let maximumReplyBytes = 262_144

    public func encodedReply() throws -> Data {
        let encoder = JSONEncoder()
        let full = try encoder.encode(self)
        guard full.count > Self.maximumReplyBytes else { return full }
        // Keep the complete structured receipt and recovery fields. Only older
        // routine log lines may be omitted, and the reply reports that count.
        func encode(keeping count: Int) throws -> Data {
            var bounded = self
            bounded.diagnostics = Array(diagnostics.suffix(count))
            bounded.diagnosticsOmittedCount = (diagnosticsOmittedCount ?? 0) + diagnostics.count - count
            return try encoder.encode(bounded)
        }
        var result = try encode(keeping: 0)
        guard result.count <= Self.maximumReplyBytes else {
            throw FanControlError.invalid("The complete fan recovery receipt exceeds the reply limit.")
        }
        var lower = 0, upper = diagnostics.count
        while lower < upper {
            let count = (lower + upper + 1) / 2
            let candidate = try encode(keeping: count)
            if candidate.count <= Self.maximumReplyBytes {
                lower = count; result = candidate
            } else { upper = count - 1 }
        }
        return result
    }
}

public enum FanOperation: Codable, Equatable {
    case mode(fan: Int, manual: Bool)
    case target(fan: Int, rpm: Double)
    case globalUnlock(Bool)
}

#if FAN_CONTROL_QUALIFICATION
// Private qualification artifact only: how the helper treats the
// acknowledgement of one real write it was told to withhold. This type does
// not exist in a production build.
public enum FanQualificationWithholding: Equatable {
    // E-Q7: unconfirmed, as after a natural timeout. The helper's own
    // attempt follows.
    case unconfirmed
    // W-Q1: unconfirmed and, once the probes saw the written target, named
    // a cause the helper declines, so the hold waits on the owner.
    case declinedRecovery
}
#endif

public struct FanNativeCallReceipt: Codable, Equatable {
    public let key: String
    public let command: UInt8
    public let startedAt: TimeInterval
    public let returnedAt: TimeInterval
    public let kernelResult: Int32
    public let requestedValueBytes: UInt32
    public let returnedStructBytes: Int
    public let firmwareResult: UInt8?
    public let firmwareStatus: UInt8?
    public let returnedValueHex: String?
    public let requestedValueHex: String?

    public init(key: String, command: UInt8, startedAt: TimeInterval, returnedAt: TimeInterval,
                kernelResult: Int32, requestedValueBytes: UInt32, returnedStructBytes: Int,
                firmwareResult: UInt8?, firmwareStatus: UInt8?, returnedValueHex: String?,
                requestedValueHex: String? = nil) {
        self.key = key; self.command = command; self.startedAt = startedAt; self.returnedAt = returnedAt
        self.kernelResult = kernelResult; self.requestedValueBytes = requestedValueBytes
        self.returnedStructBytes = returnedStructBytes; self.firmwareResult = firmwareResult
        self.firmwareStatus = firmwareStatus; self.returnedValueHex = returnedValueHex
        self.requestedValueHex = requestedValueHex
    }
}

public struct FanDiagnosticProbe: Codable, Equatable {
    public let index: Int
    public let startedAt: TimeInterval?
    public let returnedAt: TimeInterval?
    public let observation: FanControlObservation?
    public let error: String?
    public let operationConfirmed: Bool
    public let ownershipMatches: Bool
    public let model: String?
    public let fanMetadata: [FanDescriptor]?

    public init(index: Int, startedAt: TimeInterval?, returnedAt: TimeInterval?,
                observation: FanControlObservation?, error: String?,
                operationConfirmed: Bool, ownershipMatches: Bool,
                model: String? = nil, fanMetadata: [FanDescriptor]? = nil) {
        self.index = index; self.startedAt = startedAt; self.returnedAt = returnedAt
        self.observation = observation; self.error = error
        self.operationConfirmed = operationConfirmed; self.ownershipMatches = ownershipMatches
        self.model = model; self.fanMetadata = fanMetadata
    }
}

public struct FanManualModeDiagnostic: Codable, Equatable {
    public let operation: FanOperation
    public let before: FanControlObservation
    public let performStartedAt: TimeInterval?
    public let performReturnedAt: TimeInterval?
    public var firstMismatchAt: TimeInterval?
    public let deadline: TimeInterval?
    public var nativeWriteReturnedAt: TimeInterval?
    // Hardware confirmation retains its one-second deadline. Durable
    // publication has a separate allowance after the two matching probes.
    public var readbackConfirmedAt: TimeInterval?
    public var publicationDeadline: TimeInterval?
    public var publicationDeadlineOverrun: Bool?
    public var acknowledgedAt: TimeInterval?
    public var acknowledgementError: String?
    #if FAN_CONTROL_QUALIFICATION
    // Private qualification artifact only; see FanTargetDiagnostic. This
    // field does not exist in a production build.
    public var qualificationWithheld: Bool?
    #endif
    public var endedAt: TimeInterval?
    public var probes: [FanDiagnosticProbe]
    public var nativeCalls: [FanNativeCallReceipt] = []
    public var termination: String
    // The competing utility found at a probe boundary or before publication.
    public var cancellationCause: String?
    public var deadlineOverrun = false
    public var primaryFailure: String
    public var evidenceOnly: Bool
    public var pendingRetained: Bool

    public init(operation: FanOperation, before: FanControlObservation,
                performStartedAt: TimeInterval?, performReturnedAt: TimeInterval?,
                firstMismatchAt: TimeInterval?, deadline: TimeInterval?,
                probes: [FanDiagnosticProbe], termination: String, primaryFailure: String) {
        self.operation = operation; self.before = before
        self.performStartedAt = performStartedAt; self.performReturnedAt = performReturnedAt
        self.firstMismatchAt = firstMismatchAt; self.deadline = deadline
        self.probes = probes; self.termination = termination; self.primaryFailure = primaryFailure
        evidenceOnly = true; pendingRetained = true
    }
}

// Bounded acknowledgement of one returned ordinary target, zero target on an
// automatic fan, or mode release. Probe 0 is the immediate readback, evidence only; later
// probes are complete fan probes, and two consecutive distinct matches must
// arrive before the fixed hardware deadline. Durable publication then has a
// separate bounded allowance. A failed trace keeps
// evidenceOnly and pendingRetained: its matches never acknowledge the write,
// retire recovery or admit a successor.
public struct FanTargetDiagnostic: Codable, Equatable {
    public let operation: FanOperation
    public let before: FanControlObservation
    public let performStartedAt: TimeInterval?
    public let performReturnedAt: TimeInterval?
    // Present only when the capture's command-6 receipt correlates with this
    // fan's key, payload and successful native return.
    public var nativeWrite: FanNativeCallReceipt?
    public var nativeWriteReturnedAt: TimeInterval?
    public var deadline: TimeInterval?
    public var readbackConfirmedAt: TimeInterval?
    public var publicationDeadline: TimeInterval?
    public var publicationDeadlineOverrun: Bool?
    // The immediate readback, retained exactly even when its diagnostic probe
    // label rejects it, unless it cannot be JSON encoded (probe 0's error then
    // describes it). It never counts toward acknowledgement.
    public var after: FanControlObservation?
    // What a complete probe must show: the requested target within 2 RPM, or
    // the fan automatic (mode release, and zero targets whose automatic
    // firmware reports its own nonzero target).
    public var confirmationRule: String?
    public var firstMismatchAt: TimeInterval?
    // Set only by the earlier evidence-only design, which published the hold
    // before collecting; bounded acknowledgement publishes it after failure.
    public var holdPublishedAt: TimeInterval?
    public var acknowledgedAt: TimeInterval?
    public var acknowledgementError: String?
    // Whether the durable pending copy was deleted after publication; a
    // retained copy conservatively returns a hold after restart.
    public var acknowledgementMarkerRetired: Bool?
    public var acknowledgementMarkerError: String?
    #if FAN_CONTROL_QUALIFICATION
    // Private qualification artifact only: the helper was told to treat this
    // real write as unconfirmed, so no probe counts as a match although the
    // probes show the effect. This field does not exist in a production
    // build (decision E-Q7).
    public var qualificationWithheld: Bool?
    #endif
    public var endedAt: TimeInterval?
    public var probes: [FanDiagnosticProbe]
    public var nativeCalls: [FanNativeCallReceipt] = []
    public var termination: String
    // The competing utility that ended confirmation, read when it appeared.
    public var cancellationCause: String?
    // Hardware confirmation exceeded its deadline. Journal publication is
    // reported separately, so a slow save cannot look like slow firmware.
    public var deadlineOverrun = false
    public var primaryFailure: String
    public var evidenceOnly = true
    public var pendingRetained = true

    public init(operation: FanOperation, before: FanControlObservation,
                performStartedAt: TimeInterval?, performReturnedAt: TimeInterval?,
                probes: [FanDiagnosticProbe], termination: String, primaryFailure: String) {
        self.operation = operation; self.before = before
        self.performStartedAt = performStartedAt; self.performReturnedAt = performReturnedAt
        self.probes = probes; self.termination = termination; self.primaryFailure = primaryFailure
    }
}

public extension FanStatus {
    // E-Q5: whether `session` ended with the helper's own attempt to return
    // its fans to automatic after an unconfirmed command. Such a session
    // stays off until the owner turns Fan Control on again; the app does not
    // resume it after wake.
    func endedBySelfRecovery(session: String?) -> Bool {
        guard let session, let receipt = selfRecoveryReceipt else { return false }
        return receipt.recoveryID == session
    }
}

// There is deliberately no arbitrary SMC key/path/command in this interface.
public protocol FanHardware {
    func discover() throws -> FanCapabilities
    func read(_ capabilities: FanCapabilities) throws -> FanSnapshot
    // Restoration must remain possible when temperature telemetry fails.
    func readControlState(_ capabilities: FanCapabilities) throws -> FanControlObservation
    func readControlState(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanControlObservation
    func probeFans() throws -> FanFanProbe
    func probeFans(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanFanProbe
    func perform(_ operation: FanOperation, capabilities: FanCapabilities, cancelled: () -> Bool) throws
    func beginCommandDiagnosticCapture()
    func endCommandDiagnosticCapture() -> [FanNativeCallReceipt]
    var commandDiagnosticCapacityRemaining: Int { get }
    var commandDiagnosticWrite: FanNativeCallReceipt? { get }
}

public extension FanHardware {
    func readControlState(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanControlObservation {
        guard !cancelled() else { throw FanControlError.cancelled }
        return try readControlState(capabilities)
    }
    func beginCommandDiagnosticCapture() {}
    func endCommandDiagnosticCapture() -> [FanNativeCallReceipt] { [] }
    var commandDiagnosticCapacityRemaining: Int { Int.max }
    var commandDiagnosticWrite: FanNativeCallReceipt? { nil }
    func probeFans(_ capabilities: FanCapabilities, cancelled: () -> Bool) throws -> FanFanProbe {
        guard !cancelled() else { throw FanControlError.cancelled }
        return try probeFans()
    }
    func readControlState(_ capabilities: FanCapabilities) throws -> FanControlObservation {
        try read(capabilities).controlObservation
    }
    func probeFans() throws -> FanFanProbe {
        let capabilities = try discover()
        return FanFanProbe(model: capabilities.model, fans: capabilities.fans,
                           observation: try readControlState(capabilities))
    }
}

// The menu bar readout (M-Q1, M-Q2, M-Q5): the firmware CPU die average and
// the faster fan's measured speed, from a complete frame less than three
// seconds old. Without one, both lines show a dash.
public struct FanMenuBarReadout: Equatable {
    public static let dash = "–"
    public let temperature: String
    public let speed: String

    public init(snapshot: FanSnapshot?, capabilities: FanCapabilities?, now: TimeInterval) {
        guard let snapshot, let capabilities,
              (try? snapshot.validate(against: capabilities, now: now)) != nil,
              let fastest = snapshot.fans.map(\.actualRPM).max() else {
            temperature = Self.dash; speed = Self.dash; return
        }
        temperature = "\(Int(snapshot.cpuDieAverage(in: capabilities).rounded()))°C"
        speed = "\(Int(fastest.rounded()))rpm"
    }
}
