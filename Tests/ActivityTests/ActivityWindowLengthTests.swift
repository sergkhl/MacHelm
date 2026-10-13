import XCTest
@testable import ActivityCore

// The window as a setting, the two reading paces, the Disk measure and ended
// processes, as the owner decided them on 2026-10-12 (Q4, Q11, Q12, Q16 and
// Q18 of the Power and Storage record).
final class ActivityWindowLengthTests: XCTestCase {
    private func cpu(_ uptime: TimeInterval, _ seconds: Double) -> ProcessPass {
        ProcessPass(uptime: uptime, own: [Sampled.own(7, cpu: seconds)])
    }

    // MARK: The length

    func testTheLengthsOfferedAndTheUsualOne() {
        XCTAssertEqual(ActivityWindow.lengths, [5, 10, 30, 60, 300])
        XCTAssertEqual(ActivityWindow().length, 10)
    }

    func testAFiveSecondWindowForgetsWhatATenSecondWindowStillCounts() {
        // Five seconds of CPU between the passes at 2 and 3, nothing else.
        let burst: (Int) -> Double = { $0 <= 2 ? 0 : 5 }
        var short = ActivityWindow(length: 5), usual = ActivityWindow()
        for second in 0...10 {
            short.add(cpu(TimeInterval(second), burst(second)))
            usual.add(cpu(TimeInterval(second), burst(second)))
        }
        XCTAssertEqual(short.averages()?.seconds, 5)
        XCTAssertEqual(short.averages()?.process(7)?.cpuPercent ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(usual.averages()?.process(7)?.cpuPercent ?? 0, 50, accuracy: 1e-9)
    }

    func testAFiveMinuteWindowAveragesOverFiveMinutes() {
        var window = ActivityWindow(length: 300)
        // Half a core for the first minute, then nothing.
        for second in 0...300 { window.add(cpu(TimeInterval(second), min(Double(second), 60) * 0.5)) }
        XCTAssertEqual(window.averages()?.seconds, 300)
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? 0, 10, accuracy: 1e-9)
        // The first second has left the window.
        window.add(cpu(301, 30))
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? 0, 29.5 / 300 * 100, accuracy: 1e-9)
    }

    func testWhileALongWindowFillsItSaysWhatItCovers() {
        var window = ActivityWindow(length: 300)
        for second in 0...42 { window.add(cpu(TimeInterval(second), Double(second))) }
        XCTAssertEqual(window.averages()?.seconds, 42)
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? 0, 100, accuracy: 1e-9)
    }

    func testAShorterWindowDropsTheOlderReadingsAndALongerOneFillsAgain() {
        var window = ActivityWindow(length: 30)
        for second in 0...30 { window.add(cpu(TimeInterval(second), Double(min(second, 5)))) }
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? 0, 5.0 / 30 * 100, accuracy: 1e-9)

        window.length = 10
        window.add(cpu(31, 5))
        XCTAssertEqual(window.averages()?.seconds, 10)
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? -1, 0, accuracy: 1e-9)

        // What was dropped stays dropped: at 50 it covers 21 to 50.
        window.length = 60
        for second in 32...50 { window.add(cpu(TimeInterval(second), 5 + Double(second - 31))) }
        XCTAssertEqual(window.averages()?.seconds ?? 0, 29, accuracy: 1e-9)
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? 0, 19.0 / 29 * 100, accuracy: 1e-9)
    }

    func testMemoryIsTheAverageOverTheReadingsOfALongWindow() {
        var window = ActivityWindow(length: 60)
        for second in 0...60 {
            window.add(ProcessPass(uptime: TimeInterval(second), own: [Sampled.own(7, cpu: 0, memory: second <= 30 ? 100 : 400)]))
        }
        // 31 readings of 100 and 30 of 400.
        XCTAssertEqual(window.averages()?.process(7)?.memoryBytes ?? 0, (31 * 100 + 30 * 400) / 61.0, accuracy: 1e-9)
        // The reading at 0 leaves.
        window.add(ProcessPass(uptime: 61, own: [Sampled.own(7, cpu: 0, memory: 400)]))
        XCTAssertEqual(window.averages()?.process(7)?.memoryBytes ?? 0, (30 * 100 + 31 * 400) / 61.0, accuracy: 1e-9)
    }

    // MARK: The pace

    func testReadingsEveryFiveSecondsGiveTheSameAverage() {
        var window = ActivityWindow(length: 30)
        for uptime in stride(from: 0.0, through: 60, by: 5) { window.add(cpu(uptime, uptime * 0.5)) }
        XCTAssertEqual(window.averages()?.seconds, 30)
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? 0, 50, accuracy: 1e-9)
    }

    func testAWindowAsLongAsThePaceHasItsTwoReadingsAlsoWhenOneCameLate() {
        var window = ActivityWindow(length: 5)
        window.add(cpu(0, 0))
        window.add(cpu(5, 1))
        window.add(cpu(10.8, 2.16))
        XCTAssertEqual(window.averages()?.seconds, 5)
        // Over the 5.8 seconds between the two it has.
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? 0, 20, accuracy: 1e-9)
    }

    // The menu opens: readings every second follow readings every ten.
    func testAfterASlowPaceTheWindowOpensAtTheReadingBeforeItUntilHalfOfItIsRead() {
        var window = ActivityWindow()
        window.add(cpu(0, 0))
        window.add(cpu(10, 10))
        // The process is idle from 10 on.
        window.add(cpu(11, 10))
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? 0, 10.0 / 11 * 100, accuracy: 1e-9)
        for second in 12...14 { window.add(cpu(TimeInterval(second), 10)) }
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? 0, 10.0 / 14 * 100, accuracy: 1e-9)
        // Half of the window has been read since 10, so it opens there.
        window.add(cpu(15, 10))
        XCTAssertEqual(window.averages()?.seconds ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? -1, 0, accuracy: 1e-9)
    }

    // After a sleep the reading before it says nothing about now.
    func testAReadingFromLongAgoDoesNotOpenTheWindow() {
        var window = ActivityWindow()
        window.add(cpu(0, 0))
        window.add(cpu(3_600, 100))
        window.add(cpu(3_601, 100))
        XCTAssertNil(window.averages())
        window.add(cpu(3_602, 100))
        XCTAssertEqual(window.averages()?.process(7)?.cpuPercent ?? -1, 0, accuracy: 1e-9)
    }

    func testASystemProcessHasAFigureInAFiveSecondWindowAlsoWhenAReadCameLate() {
        var window = ActivityWindow(length: 5)
        for (uptime, cpu) in [(0.0, 100.0), (5.0, 101.0), (10.7, 102.14)] {
            window.add(ProcessPass(uptime: uptime, own: [Sampled.own(7, cpu: 0)], system: [Sampled.system(425, cpu: cpu)]))
        }
        XCTAssertEqual(window.averages()?.seconds, 5)
        XCTAssertEqual(window.averages()?.process(425)?.cpuPercent ?? 0, 20, accuracy: 1e-6)
    }

    // MARK: Ended processes

    func testAProcessThatIsNotInTheLatestReadingHasEnded() {
        var window = ActivityWindow()
        for second in 0...10 {
            window.add(ProcessPass(uptime: TimeInterval(second),
                                   own: [Sampled.own(7, cpu: 0)] + (second <= 6 ? [Sampled.own(8, cpu: Double(second))] : [])))
        }
        XCTAssertEqual(window.averages()?.process(7)?.ended, false)
        XCTAssertEqual(window.averages()?.process(8)?.ended, true)
        XCTAssertEqual(window.averages()?.process(8)?.cpuPercent ?? 0, 60, accuracy: 1e-9)
    }

    // A process identifier used again inside the window: the earlier process has ended, the later one runs.
    func testAnEndedProcessAndItsSuccessorUnderTheSameIdentifierAreTwoProcesses() {
        var window = ActivityWindow()
        for second in 0...10 {
            let sample = second <= 4 ? Sampled.own(7, cpu: Double(second), started: -100) : Sampled.own(7, cpu: Double(second - 5) * 0.5, started: 4.5)
            window.add(ProcessPass(uptime: TimeInterval(second), own: [sample]))
        }
        let all = window.averages()?.processes ?? []
        let both = all.filter { $0.description.identity.pid == 7 }
        XCTAssertEqual(both.map(\.ended).sorted { !$0 && $1 }, [false, true])
        XCTAssertEqual(both.first { $0.ended }?.cpuPercent ?? 0, 40, accuracy: 1e-9)
        XCTAssertEqual(both.first { !$0.ended }?.cpuPercent ?? 0, 25, accuracy: 1e-9)
    }

    // MARK: Disk

    func testDiskIsBytesPerSecond() {
        var window = ActivityWindow()
        for second in 0...10 {
            window.add(ProcessPass(uptime: TimeInterval(second), own: [Sampled.own(7, cpu: 0, disk: 1_000 + Double(second) * 2_048)]))
        }
        XCTAssertEqual(window.averages()?.process(7)?.diskBytesPerSecond ?? 0, 2_048, accuracy: 1e-9)
    }

    func testAProcessStartedInsideTheWindowCountsItsDiskFromZero() {
        var window = ActivityWindow()
        for second in 0...10 {
            window.add(ProcessPass(uptime: TimeInterval(second),
                                   own: second < 6 ? [] : [Sampled.own(7, cpu: 0, started: 5.5, disk: 4_000 + Double(second - 6) * 1_500)]))
        }
        XCTAssertEqual(window.averages()?.process(7)?.diskBytesPerSecond ?? 0, 1_000, accuracy: 1e-9)
    }

    func testAProcessWithoutDiskCountsAndASystemProcessHaveNoDiskFigure() {
        var window = ActivityWindow()
        for second in 0...10 {
            window.add(ProcessPass(uptime: TimeInterval(second), own: [Sampled.own(7, cpu: 0)],
                                   system: second % 5 == 0 ? [Sampled.system(425, cpu: Double(second))] : nil))
        }
        XCTAssertNotNil(window.averages()?.process(7))
        XCTAssertNil(window.averages()?.process(7)?.diskBytesPerSecond)
        XCTAssertNotNil(window.averages()?.process(425))
        XCTAssertNil(window.averages()?.process(425)?.diskBytesPerSecond)
    }
}

final class ActivityDiskAndEndedRankingTests: XCTestCase {
    private func app(_ pid: Int32, _ name: String, cpu: Double? = nil, disk: Double? = nil, ended: Bool = false) -> ProcessAverage {
        ProcessAverage(description: Sampled.describe(pid, path: "/Applications/\(name).app/Contents/MacOS/\(name)"), cpuPercent: cpu,
                       diskBytesPerSecond: disk, ended: ended)
    }

    private func rows(_ measure: ActivityMeasure, _ processes: [ProcessAverage]) -> [ActivityRow] {
        ActivityRanking.snapshot(of: ActivityAverages(seconds: 10, processes: processes, parents: [:]), services: [], ownPID: 999).rows[measure] ?? []
    }

    func testDiskIsAMeasureWithItsOwnList() {
        XCTAssertEqual(ActivityMeasure.allCases, [.cpu, .memory, .gpu, .energy, .disk])
        let system = ProcessAverage(description: Sampled.describeSystem(425, path: "/usr/sbin/daemon"), cpuPercent: 50)
        let listed = rows(.disk, [app(1, "Xcode", cpu: 1, disk: 5_000_000), app(2, "Safari", cpu: 2, disk: 2_000_000),
                                  app(3, "Notes", cpu: 3, disk: 100), system])
        // Under a kilobyte a second is not listed, and a system process has no disk figure.
        XCTAssertEqual(listed.map(\.group.name), ["Xcode", "Safari"])
        XCTAssertEqual(listed.first?.value, 5_000_000)
    }

    func testARowWhoseProcessesAllEndedIsMarkedAndOffersNothing() {
        let listed = rows(.cpu, [app(1, "Xcode", cpu: 30, ended: true), app(2, "Safari", cpu: 20), app(3, "Safari", cpu: 5, ended: true)])
        XCTAssertEqual(listed.map(\.group.name), ["Xcode", "Safari"])
        XCTAssertEqual(listed.map(\.ended), [true, false])
        XCTAssertEqual(listed.first?.actions, [])
        XCTAssertEqual(listed.first?.processes.flatMap(\.actions), [])
        // A row with something still running acts on what runs.
        XCTAssertEqual(listed.last?.actions, [.quit, .forceQuit])
        XCTAssertEqual(listed.last?.members.map(\.pid), [2])
        XCTAssertEqual(listed.last?.processes.map(\.actions), [[.forceQuit], []])
    }
}

final class ProcessReaderDiskTests: XCTestCase {
    func testDiskBytesAreReadWithTheOtherCounters() {
        let processes = FakeProcesses()
        processes.own(7, cpu: 1, disk: 4_096)
        let pass = ProcessReader(transport: processes).read(at: 10)
        XCTAssertEqual(pass.own.first?.diskBytes, 4_096)
    }
}
