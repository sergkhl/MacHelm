import XCTest
@testable import FanControlCore
@testable import FanControlHardware
@testable import FanControlRuntime

final class FanPolicyTests: XCTestCase {
    static let capabilities = FanCapabilities(model: "Mac14,9", sensors: [
        FanSensor(key: "TCMb", role: .cpuAverage, encoding: "flt "),
        FanSensor(key: "TCMz", role: .cpuMaximum, encoding: "flt "),
        FanSensor(key: "Tg0f", role: .gpuProtection, encoding: "flt ")
    ], fans: [
        FanDescriptor(id: 0, minimumRPM: 1000, maximumRPM: 6000, modeKey: "F0md", targetEncoding: "flt "),
        FanDescriptor(id: 1, minimumRPM: 1500, maximumRPM: 5500, modeKey: "F1md", targetEncoding: "flt ")
    ], hasGlobalUnlock: true)

    static func frame(_ temperature: Double, at time: Double = 0, gpu: Double = 40,
                      pressure: FanThermalPressure = .nominal, cpuMaximum: Double? = nil) -> FanSnapshot {
        FanSnapshot(capturedAt: time, temperatures: ["TCMb": temperature, "TCMz": cpuMaximum ?? temperature, "Tg0f": gpu],
                    fans: [FanReading(id: 0, actualRPM: 1000, targetRPM: 0, mode: 0),
                           FanReading(id: 1, actualRPM: 1500, targetRPM: 0, mode: 0)],
                    thermalPressure: pressure, globalUnlock: 0)
    }

    // The 65/85 °C profile these cases were written for. The default has been
    // 70/85 °C since Z-Q6; the policy's rules do not depend on it.
    static let profile = FanProfile(start: 65, maximum: 85)

    func testProfileBoundsAndEndpoints() throws {
        for profile in [FanProfile.standard, FanProfile(start: 40, maximum: 55), FanProfile(start: 75, maximum: 90)] {
            XCTAssertNoThrow(try profile.validate())
            XCTAssertEqual(profile.demand(at: profile.start - 1), 0)
            XCTAssertEqual(profile.demand(at: profile.maximum), 1)
        }
        for profile in [FanProfile(start: 39, maximum: 85), FanProfile(start: 76, maximum: 90),
                        FanProfile(start: 50, maximum: 54), FanProfile(start: 70, maximum: 91),
                        FanProfile(start: 70, maximum: 79), FanProfile(start: .nan, maximum: 85)] {
            XCTAssertThrowsError(try profile.validate())
        }
        XCTAssertEqual(FanProfile.standard, FanProfile(start: 70, maximum: 85), "Z-Q6")
        XCTAssertEqual(FanProfile.standard.demand(at: 77.5), 0.5, accuracy: 0.00001)
        XCTAssertEqual(FanProfile.standard.demand(at: 81.25), 0.75, accuracy: 0.00001)
    }

    func testFirmwareAverageAloneDrivesOrdinaryRamp() throws {
        let frame = Self.frame(75, cpuMaximum: 89)
        XCTAssertEqual(frame.cpuDieAverage(in: Self.capabilities), 75)
        XCTAssertEqual(frame.cpuDieMaximum(in: Self.capabilities), 89)
        var policy = FanPolicy()
        let output = try policy.evaluate(frame, capabilities: Self.capabilities, profile: Self.profile, now: 0)
        XCTAssertFalse(output.protection)
        XCTAssertEqual(try XCTUnwrap(output.demand), 0.5, accuracy: 0.00001)
        XCTAssertEqual(policy.smoothedCPU, 75)

        var coolPolicy = FanPolicy()
        let cool = try coolPolicy.evaluate(Self.frame(60, cpuMaximum: 89), capabilities: Self.capabilities,
                                          profile: Self.profile, now: 0)
        XCTAssertNil(cool.demand)
        XCTAssertFalse(cool.protection)
    }

    func testStartThresholdAndEditedCurve() throws {
        var policy = FanPolicy()
        XCTAssertNil(try policy.evaluate(Self.frame(64), capabilities: Self.capabilities, profile: Self.profile, now: 0).demand)
        let entered = try policy.evaluate(Self.frame(75, at: 5), capabilities: Self.capabilities, profile: Self.profile, now: 5)
        XCTAssertNotNil(entered.demand)
        // Long elapsed samples establish the smoothed threshold boundaries.
        _ = try policy.evaluate(Self.frame(67, at: 50), capabilities: Self.capabilities, profile: Self.profile, now: 50)
        XCTAssertTrue(policy.customEntered)
        // Z-Q4: below the start control goes on at zero demand, and ends
        // after ten seconds of readings there.
        for time in 100...109 {
            XCTAssertEqual(try policy.evaluate(Self.frame(64, at: Double(time)), capabilities: Self.capabilities,
                                               profile: Self.profile, now: Double(time)).demand, 0, "\(time)")
            XCTAssertTrue(policy.customEntered)
        }
        XCTAssertNil(try policy.evaluate(Self.frame(64, at: 110), capabilities: Self.capabilities, profile: Self.profile, now: 110).demand)
        XCTAssertFalse(policy.customEntered)
        var threshold = FanPolicy()
        XCTAssertEqual(try threshold.evaluate(Self.frame(65), capabilities: Self.capabilities, profile: Self.profile, now: 0).demand, 0)
        XCTAssertEqual(try threshold.evaluate(Self.frame(64, at: 50), capabilities: Self.capabilities, profile: Self.profile, now: 50).demand, 0)
        let edited = FanProfile(start: 50, maximum: 60)
        var editedPolicy = FanPolicy()
        XCTAssertEqual(try editedPolicy.evaluate(Self.frame(55), capabilities: Self.capabilities, profile: edited, now: 0).demand, 0.5)
    }

    // Z-Q4: the sequence of 2026-10-19. One reading took the smoothed average
    // just below the start and the next took it back above. Control released
    // and re-entered within two seconds; it now stays through such a dip.
    func testOneReadingDipBelowTheStartDoesNotRelease() throws {
        var policy = FanPolicy()
        func evaluate(_ temperature: Double, _ time: Double) throws -> FanDecision {
            try policy.evaluate(Self.frame(temperature, at: time), capabilities: Self.capabilities, profile: Self.profile, now: time)
        }
        XCTAssertEqual(try XCTUnwrap(evaluate(66, 0).demand), 0.05, accuracy: 0.00001)
        let dip = try evaluate(60, 1)
        XCTAssertLessThan(try XCTUnwrap(policy.smoothedCPU), 65)
        XCTAssertEqual(dip.demand, 0, "Still in control, at the minimum.")
        XCTAssertTrue(policy.customEntered)
        let back = try evaluate(75, 2)
        XCTAssertGreaterThan(try XCTUnwrap(policy.smoothedCPU), 65)
        XCTAssertGreaterThan(try XCTUnwrap(back.demand), 0)
    }

    // Z-Q4: ten seconds of readings below the start end control. A reading
    // back at or above it, an unusable frame or a gap of three seconds
    // restarts the count, which can only keep control longer.
    func testReleaseWaitRestartsOnAReturnAnUnusableFrameOrAGap() throws {
        func evaluate(_ policy: inout FanPolicy, _ temperature: Double, _ time: Double) throws -> Double? {
            try policy.evaluate(Self.frame(temperature, at: time, cpuMaximum: min(temperature, 80)),
                                capabilities: Self.capabilities, profile: Self.profile, now: time).demand
        }
        // Long elapsed samples let the smoothed average follow the readings.
        var returned = FanPolicy()
        XCTAssertNotNil(try evaluate(&returned, 75, 0))
        for time in 50...58 { XCTAssertEqual(try evaluate(&returned, 60, Double(time)), 0, "\(time)") }
        // 90 °C for one reading lifts the smoothed average back above 65 °C.
        XCTAssertGreaterThan(try XCTUnwrap(evaluate(&returned, 90, 59)), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(returned.smoothedCPU), 65)
        for time in 60...69 { XCTAssertNotNil(try evaluate(&returned, 60, Double(time)), "\(time)") }
        XCTAssertNil(try evaluate(&returned, 60, 70))

        var skipped = FanPolicy()
        XCTAssertNotNil(try evaluate(&skipped, 75, 0))
        for time in 50...54 { XCTAssertNotNil(try evaluate(&skipped, 60, Double(time))) }
        skipped.noteUnusableFrame() // The frame at 55 s was skipped.
        for time in 56...65 { XCTAssertNotNil(try evaluate(&skipped, 60, Double(time)), "\(time)") }
        XCTAssertNil(try evaluate(&skipped, 60, 66))

        var gap = FanPolicy()
        XCTAssertNotNil(try evaluate(&gap, 75, 0))
        for time in 50...55 { XCTAssertNotNil(try evaluate(&gap, 60, Double(time))) }
        for time in stride(from: 58.5, through: 67.5, by: 1) { XCTAssertNotNil(try evaluate(&gap, 60, time), "\(time)") }
        XCTAssertNil(try evaluate(&gap, 60, 68.5))
    }

    // Z-Q4: the count runs during protection too. Protection starts at 2 s
    // and its ten cool seconds run from 3 s, so it ends at 13 s.
    func testReleaseWaitOverlapsTheProtectionCoolDown() throws {
        func evaluate(_ policy: inout FanPolicy, _ temperature: Double, _ time: Double, _ maximum: Double) throws -> FanDecision {
            try policy.evaluate(Self.frame(temperature, at: time, cpuMaximum: maximum), capabilities: Self.capabilities,
                                profile: Self.profile, now: time)
        }
        // The average drops at 3 s and reads below 65 °C from 4 s, during
        // protection. At 13 s nine seconds have counted, so control goes on
        // for one more, coming down from maximum under the decrease limit.
        var early = FanPolicy()
        for time in 0...2 { _ = try evaluate(&early, 70, Double(time), 92) }
        XCTAssertTrue(early.protectionActive)
        XCTAssertTrue(try evaluate(&early, 50, 3, 80).protection)
        for time in 4...12 {
            XCTAssertTrue(try evaluate(&early, 50, Double(time), 80).protection)
            XCTAssertLessThan(try XCTUnwrap(early.smoothedCPU), 65)
        }
        let ended = try evaluate(&early, 50, 13, 80)
        XCTAssertFalse(ended.protection)
        XCTAssertEqual(try XCTUnwrap(ended.demand), 0.94, accuracy: 0.00001)
        XCTAssertNil(try evaluate(&early, 50, 14, 80).demand, "Ten seconds counted since 4 s, nine of them in protection.")

        // The average first reads below 65 °C at 13 s, as protection ends: a
        // run that began then still has to reach ten seconds.
        var late = FanPolicy()
        for time in 0...2 { _ = try evaluate(&late, 70, Double(time), 92) }
        for time in 3...9 { XCTAssertTrue(try evaluate(&late, 70, Double(time), 80).protection) }
        for time in 10...12 { XCTAssertTrue(try evaluate(&late, 60, Double(time), 80).protection) }
        let lateEnd = try evaluate(&late, 60, 13, 80)
        XCTAssertLessThan(try XCTUnwrap(late.smoothedCPU), 65)
        XCTAssertFalse(lateEnd.protection)
        XCTAssertEqual(try XCTUnwrap(lateEnd.demand), 0.94, accuracy: 0.00001)
        for time in 14...22 { XCTAssertNotNil(try evaluate(&late, 60, Double(time), 80).demand, "\(time)") }
        XCTAssertNil(try evaluate(&late, 60, 23, 80).demand)
    }

    func testJitterUsesElapsedExponentialSmoothing() throws {
        var policy = FanPolicy()
        _ = try policy.evaluate(Self.frame(60), capabilities: Self.capabilities, profile: Self.profile, now: 0)
        _ = try policy.evaluate(Self.frame(80, at: 2.5), capabilities: Self.capabilities, profile: Self.profile, now: 2.5)
        XCTAssertEqual(policy.smoothedCPU!, 60 + (1 - exp(-0.5)) * 20, accuracy: 0.00001)
        XCTAssertTrue(policy.customEntered)
    }

    func testRawProtectionBypassesSmoothingAndRecoversAfterTenSeconds() throws {
        var policy = FanPolicy()
        _ = try policy.evaluate(Self.frame(40), capabilities: Self.capabilities, profile: Self.profile, now: 0)
        // P-Q1: the third reading in a row at 90 °C starts it, whatever the average.
        for time in 1...2 {
            XCTAssertNil(try policy.evaluate(Self.frame(40, at: Double(time), cpuMaximum: 90), capabilities: Self.capabilities,
                                             profile: Self.profile, now: Double(time)).demand)
        }
        let decision = try policy.evaluate(Self.frame(40, at: 3, cpuMaximum: 90), capabilities: Self.capabilities,
                                           profile: Self.profile, now: 3)
        XCTAssertEqual(decision.demand, 1); XCTAssertTrue(decision.protection)
        XCTAssertLessThan(policy.smoothedCPU!, 70)
        for time in 4...13 {
            XCTAssertTrue(try policy.evaluate(Self.frame(40, at: Double(time)), capabilities: Self.capabilities,
                                              profile: Self.profile, now: Double(time)).protection)
        }
        XCTAssertNil(try policy.evaluate(Self.frame(40, at: 14), capabilities: Self.capabilities, profile: Self.profile, now: 14).demand)
    }

    // P-Q1: the hottest core jumps for a second at a time, so one or two
    // readings at or above 90 °C no longer start protection. Three in a row
    // do, and until then the ramp goes on from the smoothed average.
    func testCPUProtectionStartsOnlyAfterThreeHotReadingsInARow() throws {
        var policy = FanPolicy()
        func evaluate(_ time: Double, _ maximum: Double) throws -> FanDecision {
            try policy.evaluate(Self.frame(75, at: time, cpuMaximum: maximum), capabilities: Self.capabilities,
                                profile: Self.profile, now: time)
        }
        // One hot reading, then two, each run ended by a cooler one.
        for (time, maximum) in [(0.0, 89.9), (1, 96.5), (2, 89.9), (3, 90), (4, 93), (5, 89.9), (6, 90), (7, 90)] {
            let decision = try evaluate(time, maximum)
            XCTAssertFalse(decision.protection, "\(time)"); XCTAssertNil(decision.reason, "\(time)")
            XCTAssertEqual(try XCTUnwrap(decision.demand), 0.5, accuracy: 0.00001, "The ramp goes on: \(time)")
        }
        XCTAssertFalse(policy.protectionActive)
        let third = try evaluate(8, 90)
        XCTAssertTrue(third.protection); XCTAssertEqual(third.demand, 1)
        XCTAssertEqual(third.reason, "Firmware CPU die maximum (TCMz) ≥90 °C for three readings in a row")
        XCTAssertEqual(try evaluate(9, 91).reason, third.reason, "The trigger is named while the run lasts.")
    }

    // Two reads less than a second apart can carry the same firmware value,
    // so three hot frames count only once they span 1.9 s. Three ordinary
    // frames span two seconds give or take a few hundredths.
    func testHotReadingsMustSpanAboutTwoSeconds() throws {
        func protectionStarts(_ times: [Double]) throws -> Double? {
            var policy = FanPolicy()
            return try times.first {
                try policy.evaluate(Self.frame(60, at: $0, cpuMaximum: 92), capabilities: Self.capabilities,
                                    profile: Self.profile, now: $0).protection
            }
        }
        XCTAssertEqual(try protectionStarts([0, 1, 2, 3]), 2)
        XCTAssertEqual(try protectionStarts([0, 0.97, 1.93, 2.9]), 1.93, "Ordinary jitter")
        XCTAssertEqual(try protectionStarts([0, 0.9, 1.9, 2.9]), 1.9, "Exactly 1.9 s")
        XCTAssertEqual(try protectionStarts([0, 0.4, 1, 2, 3]), 2, "A repeated read after the first")
        XCTAssertEqual(try protectionStarts([0, 0.86, 1.86, 2.86]), 2.86, "A repeated read 0.86 s later")
        XCTAssertEqual(try protectionStarts([0, 1.45, 2, 3]), 2, "A slow cycle, then the next tick")
        XCTAssertNil(try protectionStarts([0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8]), "Seven reads inside 1.9 s")
    }

    // A skipped frame's reading is unknown: it neither counts as hot nor ends
    // the run, and neither does a gap. Only a usable reading below 90 °C does.
    func testSkippedFramesAndGapsNeitherCountNorEndTheHotRun() throws {
        func hot(_ policy: inout FanPolicy, _ time: Double, _ maximum: Double = 92) throws -> Bool {
            try policy.evaluate(Self.frame(60, at: time, cpuMaximum: maximum), capabilities: Self.capabilities,
                                profile: Self.profile, now: time).protection
        }
        var policy = FanPolicy()
        XCTAssertFalse(try hot(&policy, 0)); XCTAssertFalse(try hot(&policy, 1))
        policy.noteUnusableFrame() // The frame at 2 s was skipped.
        XCTAssertFalse(policy.protectionActive, "A skipped frame is not the third reading.")
        XCTAssertTrue(try hot(&policy, 3), "The third usable hot reading starts protection.")
        // Two skipped frames in a row, the most a session rides out.
        var twice = FanPolicy()
        XCTAssertFalse(try hot(&twice, 0))
        twice.noteUnusableFrame(); twice.noteUnusableFrame()
        XCTAssertFalse(try hot(&twice, 3)); XCTAssertTrue(try hot(&twice, 4))
        // A gap without any frame, up to the four-second complete-frame limit.
        var gap = FanPolicy()
        XCTAssertFalse(try hot(&gap, 0)); XCTAssertFalse(try hot(&gap, 3.9)); XCTAssertTrue(try hot(&gap, 4.9))
        // A usable reading below 90 °C does end the run.
        var cooled = FanPolicy()
        XCTAssertFalse(try hot(&cooled, 0)); XCTAssertFalse(try hot(&cooled, 1))
        XCTAssertFalse(try hot(&cooled, 2, 89.9))
        XCTAssertFalse(try hot(&cooled, 3)); XCTAssertFalse(try hot(&cooled, 4)); XCTAssertTrue(try hot(&cooled, 5))
    }

    // Serious or critical pressure and a hot GPU still start protection on
    // their first reading, also while the CPU count is running.
    func testPressureAndGPUStillStartProtectionAtOnce() throws {
        let pressure = "System thermal pressure is serious or critical"
        for (hot, line) in [(Self.frame(60, pressure: .serious, cpuMaximum: 95), pressure),
                            (Self.frame(60, pressure: .critical, cpuMaximum: 95), pressure),
                            (Self.frame(60, gpu: 85, cpuMaximum: 95), "Hottest GPU ≥85 °C")] {
            var policy = FanPolicy()
            let decision = try policy.evaluate(hot, capabilities: Self.capabilities, profile: Self.profile, now: 0)
            XCTAssertTrue(decision.protection); XCTAssertEqual(decision.demand, 1)
            XCTAssertEqual(decision.reason, line, "One hot CPU reading is not a trigger yet.")
        }
    }

    // The cool-down is as it was: ten seconds below 85 °C. During an active
    // spell one reading at 90 °C is not a new trigger, but it is not a cool
    // second either. After the spell a single hot reading starts nothing.
    func testCoolDownIsUnchangedAfterThreeHotReadings() throws {
        var policy = FanPolicy()
        func evaluate(_ time: Double, _ maximum: Double) throws -> FanDecision {
            try policy.evaluate(Self.frame(60, at: time, cpuMaximum: maximum), capabilities: Self.capabilities,
                                profile: Self.profile, now: time)
        }
        for time in 0...2 { _ = try evaluate(Double(time), 92) }
        XCTAssertTrue(policy.protectionActive)
        let waiting = "Waiting for ten seconds of cool CPU/GPU and nominal/fair pressure."
        for time in 3...7 { XCTAssertEqual(try evaluate(Double(time), 84.9).reason, waiting) }
        let single = try evaluate(8, 90)
        XCTAssertTrue(single.protection); XCTAssertEqual(single.reason, waiting)
        for time in 9...18 { XCTAssertTrue(try evaluate(Double(time), 84.9).protection, "\(time)") }
        let released = try evaluate(19, 84.9)
        XCTAssertFalse(released.protection); XCTAssertNil(released.demand)
        XCTAssertFalse(try evaluate(20, 95).protection)
    }

    func testGPUAndPressureAndStrictRecoveryThresholds() throws {
        for hot in [Self.frame(40, gpu: 85), Self.frame(40, pressure: .serious), Self.frame(40, pressure: .critical)] {
            var policy = FanPolicy()
            XCTAssertTrue(try policy.evaluate(hot, capabilities: Self.capabilities, profile: Self.profile, now: 0).protection)
            for time in 1...15 {
                XCTAssertTrue(try policy.evaluate(Self.frame(85, at: Double(time), gpu: 80), capabilities: Self.capabilities,
                                                  profile: Self.profile, now: Double(time)).protection)
            }
        }
    }

    func testSharedDecreaseCapPreservesNormalizedDemand() throws {
        var policy = FanPolicy()
        _ = try policy.evaluate(Self.frame(85), capabilities: Self.capabilities, profile: Self.profile, now: 0)
        let next = try policy.evaluate(Self.frame(67, at: 1), capabilities: Self.capabilities, profile: Self.profile, now: 1)
        XCTAssertEqual(next.demand!, 0.94, accuracy: 0.00001)
        XCTAssertEqual(Self.capabilities.fans[0].target(demand: 1) - Self.capabilities.fans[0].target(demand: next.demand!), 300, accuracy: 0.00001)
        XCTAssertEqual(Self.capabilities.fans[1].target(demand: 1) - Self.capabilities.fans[1].target(demand: next.demand!), 240, accuracy: 0.00001)
    }

    func testMissingStaleInvalidAndChangedFramesAreRejected() throws {
        var policy = FanPolicy()
        let frame = Self.frame(75)
        XCTAssertThrowsError(try policy.evaluate(frame, capabilities: Self.capabilities, profile: Self.profile, now: 3))
        for values in [["TCMb": 70, "Tg0f": 50],
                       ["TCMb": 70, "TCMz": Double.nan, "Tg0f": 50],
                       ["TCMb": 70, "TCMz": 70, "Tg0f": 50, "XXXX": 70]] {
            let invalid = FanSnapshot(capturedAt: 0, temperatures: values, fans: frame.fans, thermalPressure: .nominal, globalUnlock: 0)
            XCTAssertThrowsError(try invalid.validate(against: Self.capabilities, now: 0))
        }
        _ = try policy.evaluate(frame, capabilities: Self.capabilities, profile: Self.profile, now: 0)
        XCTAssertThrowsError(try policy.evaluate(frame, capabilities: Self.capabilities, profile: Self.profile, now: 1))
    }

    func testSensorMapsRejectUnrecognizedModels() throws {
        let channels = try FanSensorCatalog.candidates(model: "Mac14,9")
        XCTAssertEqual(channels.map { $0.0 }, ["TCMb", "TCMz", "Tg0f", "Tg0j"])
        XCTAssertThrowsError(try FanSensorCatalog.candidates(model: "MacBookPro18,1"))
        XCTAssertThrowsError(try FanSensorCatalog.candidates(model: "Mac99,1"))
    }

    func testSMCEncodingAndMalformedValues() throws {
        XCTAssertEqual(try SMCValue(encoding: "sp78", bytes: [75, 128]).number(), 75.5)
        XCTAssertEqual(try SMCValue(encoding: "fpe2", bytes: [0x5d, 0xc0]).number(), 6000)
        let encoded = try SMCValue(encoding: "flt ", bytes: [0, 0, 0, 0]).replacing(number: 3750)
        XCTAssertEqual(try encoded.number(), 3750)
        XCTAssertThrowsError(try SMCValue(encoding: "flt ", bytes: [0, 0, 0]).number())
        XCTAssertThrowsError(try SMCValue(encoding: "flt ", bytes: [0, 0, 0xc0, 0x7f]).number())
        XCTAssertThrowsError(try SMCValue(encoding: "xxxx", bytes: [1]).number())
    }

    func testWakeRequiresThreeDistinctHealthySnapshotsAndFreshOwnershipCheck() throws {
        var qualifier = FanWakeQualification()
        var status = FanStatus(serviceGeneration: UUID().uuidString)
        status.capabilities = Self.capabilities
        status.snapshot = Self.frame(40)
        XCTAssertFalse(try qualifier.observe(status, now: 0, conflict: nil))
        XCTAssertFalse(try qualifier.observe(status, now: 1, conflict: nil))
        XCTAssertEqual(qualifier.consecutiveHealthyFrames, 1)
        status.snapshot = Self.frame(40, at: 1)
        XCTAssertFalse(try qualifier.observe(status, now: 1, conflict: nil))
        status.snapshot = Self.frame(40, at: 2)
        XCTAssertTrue(try qualifier.observe(status, now: 2, conflict: nil))
        XCTAssertThrowsError(try qualifier.observe(status, now: 2, conflict: "Macs Fan Control"))
        XCTAssertEqual(qualifier.consecutiveHealthyFrames, 0)
        status.snapshot = Self.frame(40, at: 3)
        XCTAssertFalse(try qualifier.observe(status, now: 3, conflict: nil))
        status.snapshot = Self.frame(40, at: 6)
        XCTAssertFalse(try qualifier.observe(status, now: 6, conflict: nil))
        XCTAssertEqual(qualifier.consecutiveHealthyFrames, 1)
        status.ownsOverride = true
        XCTAssertThrowsError(try qualifier.observe(status, now: 6, conflict: nil))
    }

    func testEditingOrdinaryCurveCannotWeakenFixedProtection() throws {
        var policy = FanPolicy()
        let edited = FanProfile(start: 75, maximum: 90)
        let output = try policy.evaluate(Self.frame(40, gpu: 85), capabilities: Self.capabilities, profile: edited, now: 0)
        XCTAssertEqual(output.demand, 1)
        XCTAssertTrue(output.protection)
        for time in 1...5 {
            _ = try policy.evaluate(Self.frame(40, at: Double(time)), capabilities: Self.capabilities, profile: edited, now: Double(time))
        }
        // Brief recovery interruption resets the ten-second hold.
        _ = try policy.evaluate(Self.frame(40, at: 6, gpu: 80), capabilities: Self.capabilities, profile: edited, now: 6)
        for time in 7...16 {
            XCTAssertTrue(try policy.evaluate(Self.frame(40, at: Double(time)), capabilities: Self.capabilities,
                                              profile: edited, now: Double(time)).protection)
        }
        XCTAssertFalse(try policy.evaluate(Self.frame(40, at: 17), capabilities: Self.capabilities, profile: edited, now: 17).protection)
    }

    func testCPUProtectionRecoveryRequiresCoolMaximumDespiteCoolAverage() throws {
        var policy = FanPolicy()
        for time in -2...0 {
            XCTAssertEqual(try policy.evaluate(Self.frame(60, at: Double(time), cpuMaximum: 90), capabilities: Self.capabilities,
                                               profile: Self.profile, now: Double(time)).protection, time == 0)
        }
        for time in 1...15 {
            XCTAssertTrue(try policy.evaluate(Self.frame(60, at: Double(time), cpuMaximum: 85), capabilities: Self.capabilities,
                                              profile: Self.profile, now: Double(time)).protection)
        }
        for time in 16...25 {
            XCTAssertTrue(try policy.evaluate(Self.frame(60, at: Double(time), cpuMaximum: 84.9), capabilities: Self.capabilities,
                                              profile: Self.profile, now: Double(time)).protection)
        }
        XCTAssertFalse(try policy.evaluate(Self.frame(60, at: 26, cpuMaximum: 84.9), capabilities: Self.capabilities,
                                           profile: Self.profile, now: 26).protection)
    }

    // A skipped frame's temperatures are unknown, so it cannot count toward the
    // ten cool seconds: protection clears ten seconds after the next cool frame.
    func testUnusableFrameRestartsTheProtectionCoolDown() throws {
        func evaluate(_ policy: inout FanPolicy, _ time: Double, _ maximum: Double) throws -> Bool {
            try policy.evaluate(Self.frame(60, at: time, cpuMaximum: maximum), capabilities: Self.capabilities,
                                profile: Self.profile, now: time).protection
        }
        var policy = FanPolicy()
        for time in -2...0 { XCTAssertEqual(try evaluate(&policy, Double(time), 92), time == 0) }
        for time in 1...4 { XCTAssertTrue(try evaluate(&policy, Double(time), 80)) }
        policy.noteUnusableFrame() // The frame at 5 s was skipped.
        for time in 6...15 { XCTAssertTrue(try evaluate(&policy, Double(time), 80), "\(time)") }
        XCTAssertFalse(try evaluate(&policy, 16, 80))
        // Outside protection an unusable frame changes nothing.
        var ordinary = FanPolicy()
        XCTAssertFalse(try evaluate(&ordinary, 0, 80))
        ordinary.noteUnusableFrame()
        XCTAssertFalse(ordinary.protectionActive)
        XCTAssertFalse(try evaluate(&ordinary, 2, 80))
    }

    func testEachAggregateIsRequiredAndInvalidDataCannotFallBack() throws {
        for key in ["TCMb", "TCMz"] {
            for invalid in [Double.nan, .infinity, -.infinity, 0, 6.7, 4.633, 9.999, 120.001] {
                var values = Self.frame(75).temperatures
                values[key] = invalid
                let frame = FanSnapshot(capturedAt: 0, temperatures: values, fans: Self.frame(75).fans,
                                        thermalPressure: .nominal, globalUnlock: 0)
                XCTAssertThrowsError(try frame.validate(against: Self.capabilities, now: 0), "\(key): \(invalid)")
            }
            var values = Self.frame(75).temperatures
            values.removeValue(forKey: key)
            let missing = FanSnapshot(capturedAt: 0, temperatures: values, fans: Self.frame(75).fans,
                                      thermalPressure: .nominal, globalUnlock: 0)
            XCTAssertThrowsError(try missing.validate(against: Self.capabilities, now: 0))
        }
        // Sequential reads do not establish an atomic max >= average rule.
        XCTAssertNoThrow(try Self.frame(75, cpuMaximum: 74.9).validate(against: Self.capabilities, now: 0))
    }

    func testCapabilitiesRejectMissingSwappedUnrecognizedAndDuplicateRoles() throws {
        let valid = Self.capabilities.sensors
        let invalidSets: [[FanSensor]] = [
            valid.filter { $0.role != .cpuAverage }, valid.filter { $0.role != .cpuMaximum },
            valid.filter { $0.role != .gpuProtection },
            [FanSensor(key: "TCMz", role: .cpuAverage, encoding: "flt "),
             FanSensor(key: "TCMb", role: .cpuMaximum, encoding: "flt "), valid[2]],
            [FanSensor(key: "TCMb", role: .cpuAverage, encoding: "sp78"), valid[1], valid[2]],
            [FanSensor(key: "Tp01", role: .cpuAverage, encoding: "flt "), valid[1], valid[2]],
            [valid[0], valid[1], FanSensor(key: "PMU tdie1", role: .gpuProtection, encoding: "hid-celsius")],
            valid + [valid[0]],
            valid + [FanSensor(key: "Tp05", role: .cpuAverage, encoding: "flt ")]
        ]
        for sensors in invalidSets {
            let capabilities = FanCapabilities(model: "Mac14,9", sensors: sensors, fans: Self.capabilities.fans, hasGlobalUnlock: true)
            XCTAssertThrowsError(try capabilities.validate())
        }
        XCTAssertNoThrow(try Self.capabilities.validate())
    }

    func testCompleteFrameIncludesReadDurationAndFanMetadata() throws {
        let frame = Self.frame(75)
        for (capture, duration, now) in [(0.0, 3.0, 3.0), (0, 0, 3), (2, 0, 1),
                                       (0, -1, 1), (0, 2, 1), (0, Double.nan, 1)] {
            let invalid = FanSnapshot(capturedAt: capture, temperatures: frame.temperatures, fans: frame.fans,
                                      thermalPressure: .nominal, globalUnlock: 0, readDuration: duration)
            XCTAssertThrowsError(try invalid.validate(against: Self.capabilities, now: now))
        }
        let valid = FanSnapshot(capturedAt: 0, temperatures: frame.temperatures, fans: frame.fans,
                                thermalPressure: .nominal, globalUnlock: 0, readDuration: 0.25)
        XCTAssertNoThrow(try valid.validate(against: Self.capabilities, now: 0.25))
        let noFans = FanSnapshot(capturedAt: 0, temperatures: frame.temperatures, fans: [], thermalPressure: .nominal, globalUnlock: 0)
        XCTAssertThrowsError(try noFans.validate(against: Self.capabilities, now: 0))
    }

    func testStatusCodablePreservesRolesAndRejectsLegacyCapabilitySchema() throws {
        var status = FanStatus(serviceGeneration: UUID().uuidString)
        status.capabilities = Self.capabilities; status.snapshot = Self.frame(75, cpuMaximum: 89)
        let restored = try JSONDecoder().decode(FanStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(restored.protocolVersion, 4)
        XCTAssertEqual(restored.capabilities, Self.capabilities)
        XCTAssertEqual(restored.snapshot, status.snapshot)
        XCTAssertEqual(restored.snapshot?.cpuDieAverage(in: Self.capabilities), 75)
        XCTAssertEqual(restored.snapshot?.cpuDieMaximum(in: Self.capabilities), 89)
        let data = try JSONEncoder().encode(Self.capabilities)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "temperatureBasis")
        XCTAssertThrowsError(try JSONDecoder().decode(FanCapabilities.self, from: JSONSerialization.data(withJSONObject: legacy)))
    }

    // M-Q1, M-Q2 and M-Q5: the die average and the faster fan, and a dash on
    // both lines without a complete frame less than three seconds old.
    func testMenuBarReadoutNeedsAFreshCompleteFrame() {
        var frame = Self.frame(72.6, at: 10, cpuMaximum: 91)
        frame.fans[0].actualRPM = 2301.6; frame.fans[1].actualRPM = 2480.4
        let fresh = FanMenuBarReadout(snapshot: frame, capabilities: Self.capabilities, now: 12.9)
        XCTAssertEqual(fresh.temperature, "73°C"); XCTAssertEqual(fresh.speed, "2480rpm")
        frame.fans[0].actualRPM = 2600
        XCTAssertEqual(FanMenuBarReadout(snapshot: frame, capabilities: Self.capabilities, now: 10).speed, "2600rpm")
        let dash = FanMenuBarReadout(snapshot: nil, capabilities: nil, now: 0)
        XCTAssertEqual(dash.temperature, "–"); XCTAssertEqual(dash.speed, "–")
        // Three seconds old, from the future, and without capabilities.
        XCTAssertEqual(FanMenuBarReadout(snapshot: frame, capabilities: Self.capabilities, now: 13), dash)
        XCTAssertEqual(FanMenuBarReadout(snapshot: frame, capabilities: Self.capabilities, now: 9.9), dash)
        XCTAssertEqual(FanMenuBarReadout(snapshot: frame, capabilities: nil, now: 10), dash)
        // An invalid reading drops the whole frame; nothing of it is shown.
        let invalid = Self.frame(72.6, at: 10, cpuMaximum: 256.08)
        XCTAssertEqual(FanMenuBarReadout(snapshot: invalid, capabilities: Self.capabilities, now: 10), dash)
    }
}
