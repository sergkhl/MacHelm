import Foundation

public struct FanDecision: Equatable {
    public let demand: Double?
    public let protection: Bool
    public let reason: String?
}

public struct FanPolicy {
    public private(set) var smoothedCPU: Double?
    public private(set) var customEntered = false
    public private(set) var protectionActive = false
    private var lastSample: TimeInterval?
    private var lastOutput: TimeInterval?
    private var previousDemand: Double?
    private var recoverySince: TimeInterval?
    // Z-Q4: when the current run of usable readings with the smoothed average
    // below the start temperature began. Ordinary control ends only once that
    // run has lasted ten seconds, so a one-reading dip does not release.
    private var belowStartSince: TimeInterval?
    static let releaseWaitSeconds: TimeInterval = 10
    // P-Q1: the usable frames in a row with the CPU die maximum at or above
    // 90 °C, and when the first of them was captured.
    private var hotReadings = 0
    private var hotSince: TimeInterval?
    // The hottest core jumps for a second at a time, so the CPU trigger needs
    // three readings in a row. Two reads less than a second apart can carry
    // the same firmware value, so the run must also span 1.9 s: three
    // ordinary frames span two seconds give or take a few hundredths.
    static let hotReadingsToProtect = 3
    static let hotRunSpanSeconds: TimeInterval = 1.9

    public init() {}

    public mutating func evaluate(_ frame: FanSnapshot, capabilities: FanCapabilities,
                                  profile: FanProfile, now: TimeInterval) throws -> FanDecision {
        try profile.validate()
        try frame.validate(against: capabilities, now: now)
        if let lastSample, frame.capturedAt <= lastSample {
            throw FanControlError.invalid("A sensor snapshot was repeated or arrived out of order.")
        }
        let average = frame.cpuDieAverage(in: capabilities)
        let sampleGap = lastSample.map { frame.capturedAt - $0 } ?? 0
        if let smoothedCPU {
            self.smoothedCPU = smoothedCPU + (1 - exp(-sampleGap / 5)) * (average - smoothedCPU)
        } else {
            smoothedCPU = average
        }
        lastSample = frame.capturedAt

        let cpu = frame.cpuDieMaximum(in: capabilities)
        let gpu = frame.hottestGPU(in: capabilities)
        // Only a usable reading below 90 °C ends the run. A skipped frame and
        // a gap do neither: what the die read then is unknown.
        if cpu >= 90 {
            hotReadings += 1
            if hotSince == nil { hotSince = frame.capturedAt }
        } else {
            hotReadings = 0; hotSince = nil
        }
        var triggers: [String] = []
        if hotReadings >= Self.hotReadingsToProtect, let hotSince,
           frame.capturedAt - hotSince >= Self.hotRunSpanSeconds {
            triggers.append("Firmware CPU die maximum (TCMz) ≥90 °C for three readings in a row")
        }
        if gpu >= 85 { triggers.append("Hottest GPU ≥85 °C") }
        if frame.thermalPressure.rawValue >= FanThermalPressure.serious.rawValue {
            triggers.append("System thermal pressure is serious or critical")
        }
        if !triggers.isEmpty {
            protectionActive = true
            recoverySince = nil
        } else if protectionActive {
            let recoveryHealthy = cpu < 85 && gpu < 80 && frame.thermalPressure.rawValue <= 1
            if recoveryHealthy && sampleGap < 3 {
                if recoverySince == nil { recoverySince = frame.capturedAt }
                if frame.capturedAt - (recoverySince ?? frame.capturedAt) >= 10 {
                    protectionActive = false
                    recoverySince = nil
                }
            } else {
                recoverySince = nil
            }
        }
        let temperature = smoothedCPU ?? average
        // The run is counted during protection too, so it can overlap the
        // protection cool-down. A reading at or above the start ends it; a
        // gap restarts it, as a gap restarts that cool-down.
        if temperature >= profile.start {
            belowStartSince = nil
        } else if belowStartSince == nil || sampleGap >= 3 {
            belowStartSince = frame.capturedAt
        }
        let elapsed = lastOutput.map { max(0, now - $0) } ?? 0
        lastOutput = now
        if protectionActive {
            customEntered = true
            previousDemand = 1
            return FanDecision(demand: 1, protection: true,
                               reason: triggers.isEmpty ? "Waiting for ten seconds of cool CPU/GPU and nominal/fair pressure." : triggers.joined(separator: "; "))
        }
        // Smoothing governs the threshold as well as the ramp. Control begins
        // at the start temperature and ends after ten seconds below it; until
        // then the demand falls toward zero under the decrease limit. Without
        // control the enabled policy observes only; an existing override is
        // released once.
        if temperature >= profile.start {
            customEntered = true
        } else if customEntered, let since = belowStartSince, frame.capturedAt - since >= Self.releaseWaitSeconds {
            customEntered = false
        }
        guard customEntered else {
            previousDemand = nil
            return FanDecision(demand: nil, protection: false, reason: nil)
        }
        var demand = profile.demand(at: temperature)
        if let previousDemand {
            let largestSpan = capabilities.fans.map(\.span).max() ?? 1
            demand = max(demand, previousDemand - 300 / largestSpan * elapsed)
        }
        previousDemand = demand
        return FanDecision(demand: demand, protection: false, reason: nil)
    }

    // A skipped, unusable frame leaves that moment's temperatures unknown, so
    // it cannot count toward the ten cool seconds that end protection: the
    // cool-down restarts. This can only keep protection active longer. The
    // run of hot readings is left as it is: such a frame neither counts
    // toward the three nor ends the run (P-Q1). For the same reason it
    // restarts the ten seconds below the start that end ordinary control
    // (Z-Q4), which can only keep control longer.
    public mutating func noteUnusableFrame() {
        if protectionActive { recoverySince = nil }
        belowStartSince = nil
    }
}

public struct FanWakeQualification {
    public private(set) var consecutiveHealthyFrames = 0
    private var previousTimestamp: TimeInterval?
    public init() {}
    public mutating func reset() { consecutiveHealthyFrames = 0; previousTimestamp = nil }

    public mutating func observe(_ status: FanStatus, now: TimeInterval, conflict: String?) throws -> Bool {
        guard let capabilities = status.capabilities, let frame = status.snapshot else { reset(); return false }
        do {
            try frame.validate(against: capabilities, now: now)
            guard frame.isFullyAutomatic, !status.ownsOverride, !status.externalRecoveryRequired,
                  status.mode != .externalRecoveryRequired, status.sessionID == nil, conflict == nil else {
                throw FanControlError.ownership("Wake resumption blocked by a fan ownership or utility conflict. Re-enable once resolved.")
            }
            guard frame.capturedAt != previousTimestamp else { return false }
            if let previousTimestamp, frame.capturedAt <= previousTimestamp || frame.capturedAt - previousTimestamp >= 3 {
                reset()
            }
            previousTimestamp = frame.capturedAt
            consecutiveHealthyFrames += 1
            return consecutiveHealthyFrames >= 3
        } catch { reset(); throw error }
    }
}
