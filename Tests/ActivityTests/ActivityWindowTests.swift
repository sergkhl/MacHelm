import XCTest
@testable import ActivityCore

// The 10-second average and its edges, as the owner decided them on
// 2026-10-12: what the first seconds show, what a process that started or
// ended inside the window counts for, and how the slower system read fits.
final class ActivityWindowTests: XCTestCase {
    // One pass a second from 0 to `last`, with the samples `at` gives for that second.
    private func window(_ last: Int, at samples: (Int) -> [ProcessSample]) -> ActivityWindow {
        var window = ActivityWindow()
        for second in 0...last { window.add(ProcessPass(uptime: TimeInterval(second), own: samples(second))) }
        return window
    }

    // MARK: The window

    func testNothingIsRankedOnLessThanTwoSeconds() {
        var window = ActivityWindow()
        XCTAssertNil(window.averages())
        window.add(ProcessPass(uptime: 0, own: [Sampled.own(7, cpu: 0)]))
        window.add(ProcessPass(uptime: 1, own: [Sampled.own(7, cpu: 1)]))
        XCTAssertNil(window.averages())
        window.add(ProcessPass(uptime: 2.02, own: [Sampled.own(7, cpu: 2)]))
        let averages = window.averages()
        XCTAssertEqual(averages?.seconds ?? 0, 2.02, accuracy: 1e-9)
        XCTAssertEqual(averages?.process(7)?.cpuPercent ?? 0, 2 / 2.02 * 100, accuracy: 1e-6)
    }

    func testCPUIsTheAverageOverTenSeconds() {
        let averages = window(20) { [Sampled.own(7, cpu: Double($0) * 0.5)] }.averages()
        XCTAssertEqual(averages?.seconds, 10)
        XCTAssertEqual(averages?.process(7)?.cpuPercent ?? 0, 50, accuracy: 1e-9)
    }

    func testABurstOlderThanTenSecondsNoLongerCounts() {
        // Five seconds of CPU between the first two passes, nothing after.
        let burst: (Int) -> [ProcessSample] = { [Sampled.own(7, cpu: $0 == 0 ? 0 : 5)] }
        XCTAssertEqual(window(10, at: burst).averages()?.process(7)?.cpuPercent ?? 0, 50, accuracy: 1e-9)
        XCTAssertEqual(window(11, at: burst).averages()?.process(7)?.cpuPercent ?? -1, 0, accuracy: 1e-9)
    }

    func testAPassThatCameLateKeepsTheWindowAtTenSeconds() {
        var window = ActivityWindow()
        for second in 0...9 { window.add(ProcessPass(uptime: TimeInterval(second), own: [Sampled.own(7, cpu: Double(second))])) }
        window.add(ProcessPass(uptime: 10.3, own: [Sampled.own(7, cpu: 10.3)]))
        let averages = window.averages()
        XCTAssertEqual(averages?.seconds, 10)
        XCTAssertEqual(averages?.process(7)?.cpuPercent ?? 0, 100, accuracy: 1e-9)
    }

    // MARK: A process that started or ended inside the window

    func testAProcessStartedInsideTheWindowIsCountedFromZero() {
        // Seen first at 6 s, having used 0.4 s of CPU since it started at 5.5 s.
        let averages = window(10) { second in
            second < 6 ? [] : [Sampled.own(7, cpu: 0.4 + Double(second - 6) * 0.25, started: 5.5)]
        }.averages()
        XCTAssertEqual(averages?.process(7)?.cpuPercent ?? 0, 14, accuracy: 1e-9)
    }

    func testAProcessMissedAtTheStartIsCountedFromWhereItWasFirstSeen() {
        // An old process with a thousand seconds of CPU, absent from the first pass only.
        let averages = window(10) { second in
            second == 0 ? [] : [Sampled.own(7, cpu: 1_000 + Double(second - 1) * 0.2, started: -500)]
        }.averages()
        XCTAssertEqual(averages?.process(7)?.cpuPercent ?? 0, 18, accuracy: 1e-6)
    }

    func testAnEndedProcessCountsUntilItsSamplesAgeOut() {
        // It ran for three seconds and ended.
        let ended: (Int) -> [ProcessSample] = { $0 <= 3 ? [Sampled.own(7, cpu: Double($0))] : [] }
        XCTAssertEqual(window(10, at: ended).averages()?.process(7)?.cpuPercent ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(window(12, at: ended).averages()?.process(7)?.cpuPercent ?? 0, 10, accuracy: 1e-9)
        XCTAssertNil(window(14, at: ended).averages()?.process(7))
    }

    // What a startup service started stays in the service's row after it ended.
    func testAnEndedChildOfAServiceStillCountsForTheService() {
        var window = ActivityWindow()
        for second in 0...10 {
            var samples = [Sampled.own(100, cpu: Double(second) * 0.1, path: "/Users/owner/app/.venv/bin/python")]
            if second <= 8 {
                var child = Sampled.own(101, cpu: Double(second) * 3, path: "/opt/homebrew/bin/ffmpeg")
                child.description.parent = 100
                samples.append(child)
            }
            window.add(ProcessPass(uptime: TimeInterval(second), own: samples))
        }
        guard let averages = window.averages() else { return XCTFail("no averages") }
        XCTAssertEqual(averages.parents[101], 100)

        let service = ServiceRoot(id: "com.example.service", name: "My Service", pid: 100)
        let rows = ActivityRanking.snapshot(of: averages, services: [service], ownPID: 1).rows[.cpu] ?? []
        XCTAssertEqual(rows.map(\.group.name), ["My Service"])
        XCTAssertEqual(rows.first?.value ?? 0, 250, accuracy: 1e-9)
        XCTAssertEqual(rows.first?.actions, [.stopService(id: service.id)])
    }

    // MARK: Memory and energy

    func testMemoryIsTheAverageOverThePasses() {
        let averages = window(10) { second in
            [Sampled.own(7, cpu: 0, memory: 100)] + (second >= 6 ? [Sampled.own(8, cpu: 0, memory: 110, started: 5.5)] : [])
        }.averages()
        XCTAssertEqual(averages?.process(7)?.memoryBytes ?? 0, 100, accuracy: 1e-9)
        // Five of eleven passes.
        XCTAssertEqual(averages?.process(8)?.memoryBytes ?? 0, 50, accuracy: 1e-9)
    }

    func testEnergyIsWatts() {
        let averages = window(10) { [Sampled.own(7, cpu: 0, energy: 100 + Double($0) * 2)] }.averages()
        XCTAssertEqual(averages?.process(7)?.energyWatts ?? 0, 2, accuracy: 1e-9)
    }

    // MARK: System processes

    private func withSystemReads(until last: Int, cpu: [Int: Double]) -> ActivityWindow {
        var window = ActivityWindow()
        for second in 0...last {
            window.add(ProcessPass(uptime: TimeInterval(second), own: [Sampled.own(7, cpu: 0)],
                                   system: cpu[second].map { [Sampled.system(425, cpu: $0)] }))
        }
        return window
    }

    func testASystemProcessIsAveragedOverItsOwnReads() {
        let reads = [0: 100.0, 5: 101.0, 10: 103.0, 15: 103.5]
        // One read: nothing to average yet.
        XCTAssertNil(withSystemReads(until: 3, cpu: reads).averages()?.process(425))
        // Two reads, five seconds apart.
        XCTAssertEqual(withSystemReads(until: 7, cpu: reads).averages()?.process(425)?.cpuPercent ?? 0, 20, accuracy: 1e-9)
        // Between two reads the last ten seconds read still stand.
        XCTAssertEqual(withSystemReads(until: 12, cpu: reads).averages()?.process(425)?.cpuPercent ?? 0, 30, accuracy: 1e-9)
        XCTAssertEqual(withSystemReads(until: 15, cpu: reads).averages()?.process(425)?.cpuPercent ?? 0, 25, accuracy: 1e-9)
    }

    // The reader's second read comes at 2 seconds, a little early or late like any pass.
    func testASystemProcessHasAFigureWhenTheListsFirstAppear() {
        var window = ActivityWindow()
        for (uptime, cpu) in [(0.0, 10.0), (1.0, nil), (1.98, 10.495)] as [(Double, Double?)] {
            window.add(ProcessPass(uptime: uptime, own: [Sampled.own(7, cpu: 0)], system: cpu.map { [Sampled.system(425, cpu: $0)] }))
        }
        XCTAssertEqual(window.averages()?.process(425)?.cpuPercent ?? 0, 25, accuracy: 1e-6)
    }

    // The reader takes its second listing from 1.5 seconds on; the window must accept what it took.
    func testASecondListingThatCameEarlyStillGivesAFigure() {
        var window = ActivityWindow()
        for (uptime, cpu) in [(0.0, 10.0), (1.0, nil), (1.55, 10.31), (2.55, nil)] as [(Double, Double?)] {
            window.add(ProcessPass(uptime: uptime, own: [Sampled.own(7, cpu: 0)], system: cpu.map { [Sampled.system(425, cpu: $0)] }))
        }
        XCTAssertEqual(window.averages()?.process(425)?.cpuPercent ?? 0, 20, accuracy: 1e-6)
    }

    func testASystemProcessHasNoMemoryOrEnergy() {
        let process = withSystemReads(until: 7, cpu: [0: 1, 5: 2]).averages()?.process(425)
        XCTAssertNotNil(process)
        XCTAssertNil(process?.memoryBytes)
        XCTAssertNil(process?.energyWatts)
        XCTAssertEqual(process?.description.isOwn, false)
    }

    func testASystemProcessThatEndedIsGone() {
        var window = ActivityWindow()
        for second in 0...10 {
            let system: [ProcessSample]? = second % 5 == 0 ? (second < 10 ? [Sampled.system(425, cpu: Double(second))] : []) : nil
            window.add(ProcessPass(uptime: TimeInterval(second), own: [Sampled.own(7, cpu: 0)], system: system))
        }
        XCTAssertNotNil(window.averages()?.process(7))
        XCTAssertNil(window.averages()?.process(425))
    }

    func testAnotherProgramUnderAReusedSystemIdentifierStartsAfresh() {
        var window = ActivityWindow()
        let paths = [0: "/usr/sbin/first", 5: "/usr/sbin/second", 10: "/usr/sbin/second"]
        let cpu = [0: 900.0, 5: 1.0, 10: 2.0]
        for second in 0...10 {
            let system = paths[second].map { [Sampled.system(425, cpu: cpu[second] ?? 0, path: $0)] }
            window.add(ProcessPass(uptime: TimeInterval(second), own: [Sampled.own(7, cpu: 0)], system: system))
        }
        XCTAssertEqual(window.averages()?.process(425)?.cpuPercent ?? -1, 20, accuracy: 1e-9)
    }

    // MARK: GPU

    func testGPUIsThePercentOfGPUTimeForOwnAndSystemProcesses() {
        var window = ActivityWindow()
        for second in 0...10 {
            window.add(ProcessPass(uptime: TimeInterval(second), own: [Sampled.own(7, cpu: 0)],
                                   system: second % 5 == 0 ? [Sampled.system(425, cpu: 50)] : nil,
                                   gpuSeconds: [7: Double(second) * 0.1, 425: 3 + Double(second) * 0.2]))
        }
        let averages = window.averages()
        XCTAssertEqual(averages?.process(7)?.gpuPercent ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(averages?.process(425)?.gpuPercent ?? 0, 20, accuracy: 1e-9)
    }

    func testAProcessThatOpenedTheGPUInsideTheWindowIsCountedFromZero() {
        let averages: ActivityAverages? = {
            var window = ActivityWindow()
            for second in 0...10 {
                window.add(ProcessPass(uptime: TimeInterval(second), own: [Sampled.own(7, cpu: 0)],
                                       gpuSeconds: second >= 4 ? [7: 0.5] : [:]))
            }
            return window.averages()
        }()
        XCTAssertEqual(averages?.process(7)?.gpuPercent ?? 0, 5, accuracy: 1e-9)
    }

    func testAProcessWithoutGPUTimeHasNoGPUFigure() {
        let process = window(10) { _ in [Sampled.own(7, cpu: 0)] }.averages()?.process(7)
        XCTAssertNotNil(process)
        XCTAssertNil(process?.gpuPercent)
    }

    // MARK: Parents

    func testTheParentsOfOwnAndSystemProcessesAreKept() {
        var window = ActivityWindow()
        for second in 0...5 {
            var sample = Sampled.own(7, cpu: 0)
            sample.description.parent = 40
            var system = Sampled.system(425, cpu: Double(second))
            system.description.parent = 2
            window.add(ProcessPass(uptime: TimeInterval(second), own: [sample], system: second % 5 == 0 ? [system] : nil))
        }
        XCTAssertEqual(window.averages()?.parents, [7: 40, 425: 2])
    }
}
