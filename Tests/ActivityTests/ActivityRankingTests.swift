import XCTest
@testable import ActivityCore

// What a row stands for, which rows are the heaviest, and what each offers
// (the owner's decisions of 2026-10-12, in CONTEXT.md).
final class ProcessGroupingTests: XCTestCase {
    private let renderer = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"

    func testAHelperCountsAsItsApp() {
        let group = ProcessGrouping.group(of: Sampled.describe(7, path: renderer), parents: [:], services: [:])
        XCTAssertEqual(group, ProcessGroupID(kind: .app(bundlePath: "/Applications/Brave Browser.app"), name: "Brave Browser"))
    }

    func testAStartupServiceTakesItsProcessAndWhatThatStarted() {
        let service = ServiceRoot(id: "com.quantumcraft.reply-assistant", name: "Telegram Reply Assistant", pid: 100)
        let parents: [Int32: Int32] = [100: 1, 101: 100, 102: 101, 200: 1]
        let expected = ProcessGroupID(kind: .service(id: service.id), name: service.name)
        for (pid, path) in [(Int32(100), "/Users/owner/app/.venv/bin/python"), (101, "/bin/sh"), (102, renderer)] {
            XCTAssertEqual(ProcessGrouping.group(of: Sampled.describe(pid, path: path), parents: parents, services: [100: service]),
                           expected, "pid \(pid)")
        }
        XCTAssertEqual(ProcessGrouping.group(of: Sampled.describe(200, path: "/Users/owner/app/.venv/bin/python"),
                                             parents: parents, services: [100: service]),
                       ProcessGroupID(kind: .process, name: "python"))
    }

    func testAWindowsProgramStandsApartFromSteamAndFromWine() {
        let wine = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine"
        let game = ProcessGrouping.group(of: Sampled.describe(7, path: wine, wine: .program("SkyrimSE.exe")), parents: [:], services: [:])
        let steam = ProcessGrouping.group(of: Sampled.describe(8, path: wine, wine: .program("steam.exe")), parents: [:], services: [:])
        let server = ProcessGrouping.group(of: Sampled.describe(9, path: wine, wine: .background), parents: [:], services: [:])
        XCTAssertEqual(game, ProcessGroupID(kind: .windowsProgram, name: "SkyrimSE.exe"))
        XCTAssertEqual(steam, ProcessGroupID(kind: .windowsProgram, name: "steam.exe"))
        XCTAssertEqual(server, ProcessGroupID(kind: .wineBackground, name: "Wine"))
    }

    func testAProgramOutsideAnAppIsNamedByItsFile() {
        XCTAssertEqual(ProcessGrouping.group(of: Sampled.describe(7, path: "/opt/homebrew/bin/node"), parents: [:], services: [:]),
                       ProcessGroupID(kind: .process, name: "node"))
    }

    func testASystemProcessStandsAloneEvenInsideAnApp() {
        let helper = Sampled.describeSystem(565, path: "/Applications/MacHelm.app/Contents/Library/HelperTools/FanControlHelper")
        XCTAssertEqual(ProcessGrouping.group(of: helper, parents: [565: 100], services: [100: ServiceRoot(id: "s", name: "S", pid: 100)]),
                       ProcessGroupID(kind: .system, name: "FanControlHelper"))
    }

    func testALoopInTheParentTableEnds() {
        XCTAssertEqual(ProcessGrouping.group(of: Sampled.describe(5), parents: [5: 6, 6: 5], services: [:]),
                       ProcessGroupID(kind: .process, name: "tool"))
    }
}

final class ActivityRankingTests: XCTestCase {
    private func averages(_ processes: [ProcessAverage], parents: [Int32: Int32] = [:]) -> ActivityAverages {
        ActivityAverages(seconds: 10, processes: processes, parents: parents)
    }

    private func app(_ pid: Int32, _ name: String, cpu: Double? = nil, memory: Double? = nil, gpu: Double? = nil,
                     energy: Double? = nil, disk: Double? = nil, helper: String? = nil) -> ProcessAverage {
        let path = "/Applications/\(name).app/Contents/" + (helper.map { "Frameworks/\($0).app/Contents/MacOS/\($0)" } ?? "MacOS/\(name)")
        return ProcessAverage(description: Sampled.describe(pid, path: path), cpuPercent: cpu, memoryBytes: memory,
                              gpuPercent: gpu, energyWatts: energy, diskBytesPerSecond: disk)
    }

    private func system(_ pid: Int32, _ name: String, cpu: Double? = nil, gpu: Double? = nil) -> ProcessAverage {
        ProcessAverage(description: Sampled.describeSystem(pid, path: "/usr/sbin/\(name)"), cpuPercent: cpu, gpuPercent: gpu)
    }

    // MARK: The heaviest processes

    func testTheFiveHeaviestPerMeasureHeaviestFirst() {
        let names = ["A", "B", "C", "D", "E", "F", "G"]
        let processes = names.enumerated().map { app(Int32(10 + $0.offset), $0.element, cpu: Double($0.offset + 1) * 10) }
        let rows = ActivityRanking.snapshot(of: averages(processes), services: [], ownPID: 1).rows[.cpu] ?? []
        XCTAssertEqual(rows.map(\.group.name), ["G", "F", "E", "D", "C"])
        XCTAssertEqual(rows.map(\.value), [70, 60, 50, 40, 30])
    }

    func testEveryMeasureHasItsOwnList() {
        let snapshot = ActivityRanking.snapshot(of: averages([
            app(10, "A", cpu: 5, memory: 4_000, gpu: 1, energy: 0.2),
            app(11, "B", cpu: 9, memory: 1_000, gpu: 7, energy: 0.1)
        ]), services: [], ownPID: 1)
        XCTAssertEqual(snapshot.seconds, 10)
        XCTAssertEqual(snapshot.rows[.cpu]?.map(\.group.name), ["B", "A"])
        XCTAssertEqual(snapshot.rows[.memory]?.map(\.group.name), ["A", "B"])
        XCTAssertEqual(snapshot.rows[.gpu]?.map(\.group.name), ["B", "A"])
        XCTAssertEqual(snapshot.rows[.energy]?.map(\.group.name), ["A", "B"])
        XCTAssertEqual(snapshot.heaviest(.memory)?.value, 4_000)
    }

    func testHelpersAreSummedIntoTheirAppAndListedHeaviestFirst() {
        let rows = ActivityRanking.snapshot(of: averages([
            app(10, "Brave Browser", cpu: 20),
            app(11, "Brave Browser", cpu: 85, helper: "Brave Browser Helper (Renderer)"),
            app(12, "Brave Browser", cpu: 0, helper: "Brave Browser Helper"),
            app(13, "Ghostty", cpu: 15)
        ]), services: [], ownPID: 1).rows[.cpu] ?? []
        XCTAssertEqual(rows.map(\.group.name), ["Brave Browser", "Ghostty"])
        XCTAssertEqual(rows.first?.value, 105)
        // A helper that used nothing is not listed under its app.
        XCTAssertEqual(rows.first?.processes.map(\.identity.pid), [11, 10])
        XCTAssertEqual(rows.first?.processes.map(\.name), ["Brave Browser Helper (Renderer)", "Brave Browser"])
        // Quit and Force Quit act on the whole app, the idle helper included.
        XCTAssertEqual(rows.first?.members.map(\.pid), [10, 11, 12])
    }

    func testSystemProcessesAppearUnderCPUAndGPUOnly() {
        let snapshot = ActivityRanking.snapshot(of: averages([
            system(425, "WindowServer", cpu: 38, gpu: 5),
            app(10, "A", cpu: 5, memory: 4_000, gpu: 1, energy: 0.2)
        ]), services: [], ownPID: 1)
        XCTAssertEqual(snapshot.rows[.cpu]?.map(\.group.name), ["WindowServer", "A"])
        XCTAssertEqual(snapshot.rows[.gpu]?.map(\.group.name), ["WindowServer", "A"])
        XCTAssertEqual(snapshot.rows[.memory]?.map(\.group.name), ["A"])
        XCTAssertEqual(snapshot.rows[.energy]?.map(\.group.name), ["A"])
        XCTAssertEqual(snapshot.rows[.cpu]?.first?.group.kind, .system)
    }

    func testAGroupThatUsedAlmostNothingIsNotListed() {
        let snapshot = ActivityRanking.snapshot(of: averages([
            app(10, "Idle", cpu: 0.01, memory: 0, gpu: 0, energy: 0.001, disk: 1_000),
            app(11, "Busy", cpu: 0.06, memory: 2, gpu: 0.05, energy: 0.005, disk: 1_024)
        ]), services: [], ownPID: 1)
        for measure in ActivityMeasure.allCases {
            XCTAssertEqual(snapshot.rows[measure]?.map(\.group.name), ["Busy"], "\(measure)")
        }
    }

    func testEqualRowsKeepTheirOrderByName() {
        let rows = ActivityRanking.snapshot(of: averages([app(10, "Zed", cpu: 5), app(11, "Arc", cpu: 5)]),
                                            services: [], ownPID: 1).rows[.cpu] ?? []
        XCTAssertEqual(rows.map(\.group.name), ["Arc", "Zed"])
    }

    // MARK: Holding the order

    // While the pointer is over a list its rows stay where they are, so a
    // press lands on the row that was aimed at. The figures still move.
    func testAHeldListKeepsItsOrderAndTakesTheNewFigures() {
        let before = ActivityRanking.snapshot(of: averages([app(10, "A", cpu: 50), app(11, "B", cpu: 40), app(12, "C", cpu: 30)]),
                                              services: [], ownPID: 1).rows[.cpu] ?? []
        let after = ActivityRanking.snapshot(of: averages([app(10, "A", cpu: 5), app(11, "B", cpu: 60), app(13, "D", cpu: 90)]),
                                             services: [], ownPID: 1).rows[.cpu] ?? []
        XCTAssertEqual(after.map(\.group.name), ["D", "B", "A"])

        let held = ActivityRanking.keeping(before.map(\.group), in: after)
        // A and B stay in place with their new figures, C is gone, and D joins at the end.
        XCTAssertEqual(held.map(\.group.name), ["A", "B", "D"])
        XCTAssertEqual(held.map(\.value), [5, 60, 90])
    }

    func testWithNothingHeldTheRankingStands() {
        let rows = ActivityRanking.snapshot(of: averages([app(10, "A", cpu: 5), app(11, "B", cpu: 60)]), services: [], ownPID: 1).rows[.cpu] ?? []
        XCTAssertEqual(ActivityRanking.keeping([], in: rows), rows)
    }

    // MARK: What a row offers

    func testAnAppOffersQuitAndForceQuitAndItsProcessesForceQuitOnly() {
        let row = ActivityRanking.snapshot(of: averages([app(10, "Ghostty", cpu: 15)]), services: [], ownPID: 1).rows[.cpu]?.first
        XCTAssertEqual(row?.actions, [.quit, .forceQuit])
        XCTAssertEqual(row?.processes.first?.actions, [.forceQuit])
    }

    func testAStartupServiceOffersStopInPlaceOfQuit() {
        let python = ProcessAverage(description: Sampled.describe(100, path: "/Users/owner/app/.venv/bin/python"), cpuPercent: 60)
        var child = ProcessAverage(description: Sampled.describe(101, path: "/bin/sh"), cpuPercent: 2)
        child.description.parent = 100
        let service = ServiceRoot(id: "com.quantumcraft.reply-assistant", name: "Telegram Reply Assistant", pid: 100)
        let row = ActivityRanking.snapshot(of: averages([python, child], parents: [100: 1, 101: 100]),
                                           services: [service], ownPID: 1).rows[.cpu]?.first
        XCTAssertEqual(row?.group, ProcessGroupID(kind: .service(id: service.id), name: service.name))
        XCTAssertEqual(row?.value, 62)
        XCTAssertEqual(row?.actions, [.stopService(id: service.id)])
        XCTAssertEqual(row?.processes.map(\.actions), [[], []])
    }

    // A service that Startup Services only shows cannot be stopped there, and
    // launchd would start it again after a Quit, so its row offers nothing.
    func testAServiceThatCannotBeStoppedOffersNothing() {
        let python = ProcessAverage(description: Sampled.describe(100, path: "/Users/owner/app/.venv/bin/python"), cpuPercent: 60)
        let service = ServiceRoot(id: "com.example.observed", name: "Observed Service", pid: 100, canStop: false)
        let row = ActivityRanking.snapshot(of: averages([python], parents: [100: 1]), services: [service], ownPID: 1).rows[.cpu]?.first
        XCTAssertEqual(row?.group.name, "Observed Service")
        XCTAssertEqual(row?.actions, [])
        XCTAssertEqual(row?.processes.map(\.actions), [[]])
    }

    func testProtectedRowsOfferNothing() {
        let loginWindow = ProcessAverage(
            description: Sampled.describe(428, path: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"), cpuPercent: 3)
        let rows = ActivityRanking.snapshot(of: averages([
            system(425, "WindowServer", cpu: 38),
            loginWindow,
            app(767, "MacHelm", cpu: 9),
            app(10, "Ghostty", cpu: 1)
        ]), services: [], ownPID: 767).rows[.cpu] ?? []
        XCTAssertEqual(rows.map(\.group.name), ["WindowServer", "MacHelm", "loginwindow", "Ghostty"])
        XCTAssertEqual(rows.map(\.actions), [[], [], [], [.quit, .forceQuit]])
        XCTAssertEqual(rows.prefix(3).flatMap { $0.processes.flatMap(\.actions) }, [])
    }

    func testFinderAndDockCanBeQuit() {
        let rows = ActivityRanking.snapshot(of: averages([
            ProcessAverage(description: Sampled.describe(649, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"), cpuPercent: 2),
            ProcessAverage(description: Sampled.describe(644, path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"), cpuPercent: 1)
        ]), services: [], ownPID: 767).rows[.cpu] ?? []
        XCTAssertEqual(rows.map(\.actions), [[.quit, .forceQuit], [.quit, .forceQuit]])
    }
}

// Which requests ask first, and which apps a Quit asks (the owner, 2026-10-12).
final class ProcessActionPolicyTests: XCTestCase {
    private let app = ProcessGroupID(kind: .app(bundlePath: "/Applications/Ghostty.app"), name: "Ghostty")
    private let program = ProcessGroupID(kind: .process, name: "node")
    private let game = ProcessGroupID(kind: .windowsProgram, name: "SkyrimSE.exe")
    private let wine = ProcessGroupID(kind: .wineBackground, name: "Wine")

    func testForceQuitAlwaysAsksFirst() {
        for group in [app, program, game, wine] {
            XCTAssertTrue(ProcessActionPolicy.asksFirst(.forceQuit, in: group, members: 1), group.name)
        }
    }

    func testQuittingAnAppDoesNotAskBecauseTheAppCan() {
        XCTAssertFalse(ProcessActionPolicy.asksFirst(.quit, in: app, members: 1))
        XCTAssertFalse(ProcessActionPolicy.asksFirst(.quit, in: app, members: 40))
    }

    // A bundle with no app in it to ask gets signals, like programs outside an app.
    func testQuittingAnAppWithNobodyToAskAsksFirstWhenItHasSeveralProcesses() {
        XCTAssertTrue(ProcessActionPolicy.asksFirst(.quit, in: app, members: 3, canBeAsked: false))
        XCTAssertFalse(ProcessActionPolicy.asksFirst(.quit, in: app, members: 1, canBeAsked: false))
        XCTAssertFalse(ProcessActionPolicy.asksFirst(.quit, in: app, members: 3, canBeAsked: true))
    }

    func testQuittingSeveralProgramsOfOneNameAsksFirst() {
        XCTAssertFalse(ProcessActionPolicy.asksFirst(.quit, in: program, members: 1))
        XCTAssertTrue(ProcessActionPolicy.asksFirst(.quit, in: program, members: 2))
        XCTAssertTrue(ProcessActionPolicy.asksFirst(.quit, in: program, members: 20))
    }

    // A Windows program gets a signal and cannot ask about unsaved progress.
    func testQuittingAWindowsProgramAsksFirst() {
        XCTAssertTrue(ProcessActionPolicy.asksFirst(.quit, in: game, members: 1))
        XCTAssertTrue(ProcessActionPolicy.asksFirst(.quit, in: wine, members: 1))
    }

    func testStoppingAServiceDoesNotAsk() {
        let service = ProcessGroupID(kind: .service(id: "s"), name: "S")
        XCTAssertFalse(ProcessActionPolicy.asksFirst(.stopService(id: "s"), in: service, members: 3))
    }

    private func running(_ pid: Int32, _ bundle: String, userFacing: Bool = true, also resolved: String? = nil) -> RunningApp {
        RunningApp(identity: ProcessIdentity(pid: pid, startedAt: UInt64(pid)), bundlePaths: Set([bundle] + (resolved.map { [$0] } ?? [])),
                   isUserFacing: userFacing)
    }

    func testTheAppOfTheRowIsAskedAndItsHelpersAreNot() {
        let asked = ProcessActionPolicy.appsToAsk(toQuit: "/Applications/Brave Browser.app", among: [
            running(11, "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Helper.app", userFacing: false),
            running(10, "/Applications/Brave Browser.app")
        ])
        XCTAssertEqual(asked.map(\.pid), [10])
    }

    func testEveryRunningCopyOfTheAppIsAsked() {
        let asked = ProcessActionPolicy.appsToAsk(toQuit: "/Applications/Tool.app", among: [
            running(21, "/Applications/Tool.app"), running(20, "/Applications/Tool.app")
        ])
        XCTAssertEqual(asked.map(\.pid), [20, 21])
    }

    func testAnAppFoundThroughALinkIsStillTheApp() {
        let asked = ProcessActionPolicy.appsToAsk(toQuit: "/private/tmp/Tool.app", among: [
            running(20, "/tmp/Tool.app", also: "/private/tmp/Tool.app")
        ])
        XCTAssertEqual(asked.map(\.pid), [20])
    }

    // Simulator lives inside Xcode.app, so its row is Xcode's even when Xcode is not running.
    func testAnAppInsideTheRowsBundleIsAskedWhenTheBundlesOwnAppIsNotRunning() {
        let asked = ProcessActionPolicy.appsToAsk(toQuit: "/Applications/Xcode.app", among: [
            running(30, "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"),
            running(31, "/Applications/Xcode.app/Contents/SharedFrameworks/Some Helper.app", userFacing: false)
        ])
        XCTAssertEqual(asked.map(\.pid), [30])
    }

    func testWithNoAppAmongTheProcessesNobodyIsAsked() {
        XCTAssertEqual(ProcessActionPolicy.appsToAsk(toQuit: "/Applications/Tool.app", among: [
            running(31, "/Applications/Tool.app/Contents/Helpers/Helper.app", userFacing: false)
        ]), [])
    }
}

// Ending exactly what a row showed.
final class ProcessTerminatorTests: XCTestCase {
    private func table() -> FakeProcesses {
        let processes = FakeProcesses()
        processes.own(700, startedAt: 111)
        processes.own(701, startedAt: 222)
        return processes
    }

    func testForceQuitKillsTheProcessesNamed() {
        let processes = table()
        let both = [ProcessIdentity(pid: 700, startedAt: 111), ProcessIdentity(pid: 701, startedAt: 222)]
        let result = ProcessTerminator(transport: processes, ownPID: 1_000).terminate(both, force: true)
        XCTAssertEqual(processes.signals, ["\(SIGKILL) 700", "\(SIGKILL) 701"])
        XCTAssertEqual(result, ProcessTermination(signalled: both, skipped: []))
    }

    func testQuitSendsTheTerminateSignal() {
        let processes = table()
        _ = ProcessTerminator(transport: processes, ownPID: 1_000).terminate([ProcessIdentity(pid: 700, startedAt: 111)], force: false)
        XCTAssertEqual(processes.signals, ["\(SIGTERM) 700"])
    }

    func testAnotherProcessUnderTheSameIdentifierIsLeftAlone() {
        let processes = table()
        let shown = ProcessIdentity(pid: 700, startedAt: 111)
        // The process the row showed ended, and its identifier went to a new one.
        processes.own(700, startedAt: 999)
        let result = ProcessTerminator(transport: processes, ownPID: 1_000).terminate([shown], force: true)
        XCTAssertEqual(processes.signals, [])
        XCTAssertEqual(result, ProcessTermination(signalled: [], skipped: [shown]))
    }

    func testAProcessThatEndedIsSkipped() {
        let processes = table()
        let gone = ProcessIdentity(pid: 702, startedAt: 333)
        let result = ProcessTerminator(transport: processes, ownPID: 1_000).terminate([gone], force: true)
        XCTAssertEqual(processes.signals, [])
        XCTAssertEqual(result.skipped, [gone])
    }

    func testMacHelmLaunchdAndSystemProcessesAreNeverSignalled() {
        let processes = table()
        processes.own(1, startedAt: 5)
        processes.own(1_000, startedAt: 6)
        processes.own(425, startedAt: 0)
        let asked = [ProcessIdentity(pid: 1, startedAt: 5), ProcessIdentity(pid: 1_000, startedAt: 6), ProcessIdentity(pid: 425, startedAt: 0)]
        let result = ProcessTerminator(transport: processes, ownPID: 1_000).terminate(asked, force: true)
        XCTAssertEqual(processes.signals, [])
        XCTAssertEqual(result.skipped, asked)
    }

    func testARefusedSignalCountsAsSkipped() {
        let processes = table()
        processes.signalRefused = true
        let shown = ProcessIdentity(pid: 700, startedAt: 111)
        let result = ProcessTerminator(transport: processes, ownPID: 1_000).terminate([shown], force: true)
        XCTAssertEqual(processes.signals, ["\(SIGKILL) 700"])
        XCTAssertEqual(result, ProcessTermination(signalled: [], skipped: [shown]))
    }
}
