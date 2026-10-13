import XCTest
@testable import ActivityCore

// The production reader over a fake process table (ADR 0002): what it takes
// from each source, how often, and what it makes of a refusal.
final class ProcessReaderTests: XCTestCase {
    private let windowServer = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
    private let wine = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine"

    // MARK: Own processes

    func testAnOwnProcessIsReadWithItsCountersScaledByTheTimebase() {
        let processes = FakeProcesses()
        // Apple silicon: one unit is 125/3 nanoseconds.
        processes.timebase = (125, 3)
        processes.table[700] = .init(parent: 40, name: "Brave Browser H", path: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
                                     usage: ProcessUsage(startedAt: 48_000_000, cpuTime: 24_000_000,
                                                         energyNanojoules: 3_000_000_000, footprintBytes: 1_024))
        let pass = ProcessReader(transport: processes).read(at: 10)

        XCTAssertEqual(pass.uptime, 10)
        XCTAssertEqual(pass.own.count, 1)
        guard let sample = pass.own.first else { return }
        XCTAssertEqual(sample.cpuSeconds, 1, accuracy: 1e-9)
        XCTAssertEqual(sample.energyJoules ?? -1, 3, accuracy: 1e-9)
        XCTAssertEqual(sample.memoryBytes, 1_024)
        XCTAssertEqual(sample.description.identity, ProcessIdentity(pid: 700, startedAt: 48_000_000))
        XCTAssertEqual(sample.description.parent, 40)
        XCTAssertTrue(sample.description.isOwn)
        // The file name, not the 15 characters the kernel keeps.
        XCTAssertEqual(sample.description.name, "Brave Browser")
        XCTAssertEqual(sample.description.startedUptime ?? -1, 2, accuracy: 1e-9)
    }

    func testAWineProcesssArgumentsAreReadOnce() {
        let processes = FakeProcesses()
        processes.own(800, path: wine, arguments: [wine, "C:\\Games\\game.exe"])
        let reader = ProcessReader(transport: processes)
        for second in 0...3 { _ = reader.read(at: TimeInterval(second)) }
        XCTAssertEqual(processes.argumentReads, [800])
    }

    // The kernel's short name can stay the same across an exec; the path does not.
    func testAProgramThatBecameAnotherOfTheSameNameIsDescribedAgain() {
        let processes = FakeProcesses()
        processes.own(700, path: "/usr/local/launchers/tool", parent: 40, startedAt: 10)
        let reader = ProcessReader(transport: processes)
        XCTAssertEqual(reader.read(at: 0).own.first?.description.executablePath, "/usr/local/launchers/tool")

        processes.own(700, path: "/Applications/Holder.app/Contents/MacOS/tool", parent: 40, startedAt: 10)
        XCTAssertEqual(reader.read(at: 1).own.first?.description.executablePath, "/Applications/Holder.app/Contents/MacOS/tool")
    }

    func testAReusedIdentifierIsANewProcess() {
        let processes = FakeProcesses()
        processes.own(700, path: "/usr/local/bin/first", startedAt: 10)
        let reader = ProcessReader(transport: processes)
        XCTAssertEqual(reader.read(at: 0).own.first?.description.name, "first")

        processes.own(700, path: "/usr/local/bin/second", startedAt: 20)
        let sample = reader.read(at: 1).own.first
        XCTAssertEqual(sample?.description.name, "second")
        XCTAssertEqual(sample?.description.identity, ProcessIdentity(pid: 700, startedAt: 20))
    }

    // An exec keeps the identifier and the start time and changes the program.
    func testAProcessThatBecameAnotherProgramIsDescribedAgain() {
        let processes = FakeProcesses()
        processes.own(700, path: "/bin/sh", parent: 40, startedAt: 10)
        let reader = ProcessReader(transport: processes)
        XCTAssertEqual(reader.read(at: 0).own.first?.description.name, "sh")

        processes.own(700, path: "/Applications/Server.app/Contents/MacOS/Server", parent: 40, startedAt: 10)
        let description = reader.read(at: 1).own.first?.description
        XCTAssertEqual(description?.identity, ProcessIdentity(pid: 700, startedAt: 10))
        XCTAssertEqual(description?.name, "Server")
        XCTAssertEqual(description?.executablePath, "/Applications/Server.app/Contents/MacOS/Server")
    }

    // The kernel reports whichever name of a hard-linked program was looked
    // up last, so the path can change while the program stays the same.
    func testAnotherNameOfTheSameFileIsNotAnotherProgram() {
        let processes = FakeProcesses()
        let main = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
        let link = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser"
        processes.files = [main: 1, link: 1]
        processes.own(700, path: main, startedAt: 10)
        let reader = ProcessReader(transport: processes)
        let first = reader.read(at: 0).own.first?.description

        processes.own(700, path: link, startedAt: 10)
        XCTAssertEqual(reader.read(at: 1).own.first?.description, first)
        processes.own(700, path: main, startedAt: 10)
        XCTAssertEqual(reader.read(at: 2).own.first?.description, first)
    }

    func testAProcessThatBecameAWindowsProgramGetsItsWineRole() {
        let processes = FakeProcesses()
        processes.own(800, path: "/bin/sh", startedAt: 10)
        let reader = ProcessReader(transport: processes)
        XCTAssertNil(reader.read(at: 0).own.first?.description.wine)

        processes.own(800, path: wine, startedAt: 10, arguments: [wine, "C:\\Games\\game.exe"])
        XCTAssertEqual(reader.read(at: 1).own.first?.description.wine, .program("game.exe"))
    }

    func testAProcessWhoseParentEndedIsReadWithItsNewParent() {
        let processes = FakeProcesses()
        processes.own(700, parent: 40)
        let reader = ProcessReader(transport: processes)
        XCTAssertEqual(reader.read(at: 0).own.first?.description.parent, 40)
        processes.own(700, parent: 1)
        XCTAssertEqual(reader.read(at: 1).own.first?.description.parent, 1)
    }

    // MARK: System processes

    func testAProcessThatRefusesIsTakenFromTheListing() {
        let processes = FakeProcesses()
        processes.system(425, name: "WindowServer", userID: 88)
        processes.own(900)
        processes.listing = """
            425    88     1  97:48.76 \(windowServer)
            900   501     1   0:01.00 /usr/local/bin/tool

        """
        let pass = ProcessReader(transport: processes).read(at: 0)

        XCTAssertEqual(pass.own.map(\.description.identity.pid), [900])
        XCTAssertEqual(pass.system?.count, 1)
        guard let sample = pass.system?.first else { return XCTFail("no system process") }
        XCTAssertEqual(sample.description.identity, ProcessIdentity(pid: 425, startedAt: 0))
        XCTAssertEqual(sample.description.name, "WindowServer")
        XCTAssertEqual(sample.description.executablePath, windowServer)
        XCTAssertEqual(sample.description.parent, 1)
        XCTAssertFalse(sample.description.isOwn)
        XCTAssertEqual(sample.cpuSeconds, 97 * 60 + 48.76, accuracy: 1e-6)
        // Memory and energy cannot be read for it without root.
        XCTAssertNil(sample.memoryBytes)
        XCTAssertNil(sample.energyJoules)
    }

    func testACommandWithSpacesIsKeptWhole() {
        let processes = FakeProcesses()
        processes.listing = "   88     0     1   0:02.50 /Library/Application Support/Some Vendor/daemon tool\n"
        let sample = ProcessReader(transport: processes).read(at: 0).system?.first
        XCTAssertEqual(sample?.description.executablePath, "/Library/Application Support/Some Vendor/daemon tool")
        XCTAssertEqual(sample?.description.name, "daemon tool")
    }

    func testAMalformedLineIsSkipped() {
        let processes = FakeProcesses()
        processes.listing = "garbage\n  x 0 1 0:01.00 /sbin/a\n  12 0 1 soon /sbin/b\n  13 0 1 0:01.00\n  14 0 1 0:03.00 /sbin/c\n"
        XCTAssertEqual(ProcessReader(transport: processes).read(at: 0).system?.map(\.description.identity.pid), [14])
    }

    // The second read comes at 2 seconds, so system processes have a figure
    // when the lists first appear; after that every 5 seconds (ADR 0002).
    func testTheListingIsReadAtTwoSecondsAndThenEveryFive() {
        let processes = FakeProcesses()
        processes.listing = "  14 0 1 0:03.00 /sbin/c\n"
        let reader = ProcessReader(transport: processes)
        var readAt: [Double] = []
        for second in 0...17 where reader.read(at: TimeInterval(second)).system != nil { readAt.append(Double(second)) }
        XCTAssertEqual(readAt, [0, 2, 7, 12, 17])
        XCTAssertEqual(processes.listingReads, 5)
    }

    func testATimerThatFiresALittleEarlyStillReadsTheListing() {
        let processes = FakeProcesses()
        processes.listing = "  14 0 1 0:03.00 /sbin/c\n"
        let reader = ProcessReader(transport: processes)
        XCTAssertNotNil(reader.read(at: 0).system)
        XCTAssertNil(reader.read(at: 1.02).system)
        XCTAssertNotNil(reader.read(at: 1.97).system)
        XCTAssertNil(reader.read(at: 6).system)
        XCTAssertNotNil(reader.read(at: 6.9).system)
    }

    func testAListingThatFailedIsTriedAgainOnTheNextRead() {
        let processes = FakeProcesses()
        processes.listing = nil
        let reader = ProcessReader(transport: processes)
        XCTAssertNil(reader.read(at: 0).system)
        processes.listing = "  14 0 1 0:03.00 /sbin/c\n"
        XCTAssertNotNil(reader.read(at: 1).system)
    }

    func testCPUTimeAsPsWritesIt() {
        XCTAssertEqual(ProcessReader.cpuSeconds("0:00.03") ?? -1, 0.03, accuracy: 1e-9)
        XCTAssertEqual(ProcessReader.cpuSeconds("118:37.07") ?? -1, 118 * 60 + 37.07, accuracy: 1e-6)
        XCTAssertEqual(ProcessReader.cpuSeconds("1:02:03.50") ?? -1, 3_723.5, accuracy: 1e-6)
        XCTAssertEqual(ProcessReader.cpuSeconds("2-01:02:03.00") ?? -1, 2 * 86_400 + 3_723, accuracy: 1e-6)
        XCTAssertNil(ProcessReader.cpuSeconds("soon"))
        XCTAssertNil(ProcessReader.cpuSeconds("12"))
        XCTAssertNil(ProcessReader.cpuSeconds("1:-2.00"))
    }

    // MARK: GPU

    func testGPUTimeIsCountedFromTheFirstRead() {
        let processes = FakeProcesses()
        processes.system(425, name: "WindowServer", userID: 88)
        processes.clients = [GPUClient(id: 1, creator: "pid 425, WindowServer", nanoseconds: 5_000_000_000)]
        let reader = ProcessReader(transport: processes)
        XCTAssertEqual(reader.read(at: 0).gpuSeconds, [425: 0])

        processes.clients = [GPUClient(id: 1, creator: "pid 425, WindowServer", nanoseconds: 5_500_000_000)]
        XCTAssertEqual(reader.read(at: 1).gpuSeconds[425] ?? -1, 0.5, accuracy: 1e-9)
    }

    func testAProcessesClientsAreAddedUp() {
        let processes = FakeProcesses()
        processes.own(700)
        processes.clients = [GPUClient(id: 1, creator: "pid 700, tool", nanoseconds: 1_000_000_000),
                             GPUClient(id: 2, creator: "pid 700, tool", nanoseconds: 1_000_000_000)]
        let reader = ProcessReader(transport: processes)
        _ = reader.read(at: 0)
        processes.clients = [GPUClient(id: 1, creator: "pid 700, tool", nanoseconds: 1_200_000_000),
                             GPUClient(id: 2, creator: "pid 700, tool", nanoseconds: 1_300_000_000)]
        XCTAssertEqual(reader.read(at: 1).gpuSeconds[700] ?? -1, 0.5, accuracy: 1e-9)
    }

    func testAClientOpenedSinceTheLastReadCountsAllItsTime() {
        let processes = FakeProcesses()
        processes.own(700)
        let reader = ProcessReader(transport: processes)
        _ = reader.read(at: 0)
        processes.clients = [GPUClient(id: 9, creator: "pid 700, tool", nanoseconds: 250_000_000)]
        XCTAssertEqual(reader.read(at: 1).gpuSeconds[700] ?? -1, 0.25, accuracy: 1e-9)
    }

    func testAClientThatGoesDoesNotTakeTheCountBack() {
        let processes = FakeProcesses()
        processes.own(700)
        processes.clients = [GPUClient(id: 1, creator: "pid 700, tool", nanoseconds: 0),
                             GPUClient(id: 2, creator: "pid 700, tool", nanoseconds: 0)]
        let reader = ProcessReader(transport: processes)
        _ = reader.read(at: 0)
        processes.clients = [GPUClient(id: 1, creator: "pid 700, tool", nanoseconds: 400_000_000),
                             GPUClient(id: 2, creator: "pid 700, tool", nanoseconds: 600_000_000)]
        XCTAssertEqual(reader.read(at: 1).gpuSeconds[700] ?? -1, 1, accuracy: 1e-9)
        processes.clients = [GPUClient(id: 2, creator: "pid 700, tool", nanoseconds: 700_000_000)]
        XCTAssertEqual(reader.read(at: 2).gpuSeconds[700] ?? -1, 1.1, accuracy: 1e-9)
    }

    func testTheGPUCountOfAProcessThatEndedIsDropped() {
        let processes = FakeProcesses()
        processes.own(700)
        processes.clients = [GPUClient(id: 1, creator: "pid 700, tool", nanoseconds: 0)]
        let reader = ProcessReader(transport: processes)
        XCTAssertEqual(reader.read(at: 0).gpuSeconds, [700: 0])
        processes.table[700] = nil
        processes.clients = []
        XCTAssertEqual(reader.read(at: 1).gpuSeconds, [:])
    }

    func testAGPUReadThatFailedKeepsTheCount() {
        let processes = FakeProcesses()
        processes.own(700)
        processes.clients = [GPUClient(id: 1, creator: "pid 700, tool", nanoseconds: 0)]
        let reader = ProcessReader(transport: processes)
        _ = reader.read(at: 0)
        processes.clients = [GPUClient(id: 1, creator: "pid 700, tool", nanoseconds: 500_000_000)]
        XCTAssertEqual(reader.read(at: 1).gpuSeconds[700] ?? -1, 0.5, accuracy: 1e-9)
        processes.clients = nil
        XCTAssertEqual(reader.read(at: 2).gpuSeconds[700] ?? -1, 0.5, accuracy: 1e-9)
        processes.clients = [GPUClient(id: 1, creator: "pid 700, tool", nanoseconds: 700_000_000)]
        XCTAssertEqual(reader.read(at: 3).gpuSeconds[700] ?? -1, 0.7, accuracy: 1e-9)
    }

    func testWithoutGPUClientsThereIsNoGPUTimeAndTheRestIsRead() {
        let processes = FakeProcesses()
        processes.own(700)
        processes.clients = nil
        let pass = ProcessReader(transport: processes).read(at: 0)
        XCTAssertEqual(pass.gpuSeconds, [:])
        XCTAssertEqual(pass.own.count, 1)
    }

    func testACreatorThatNamesNoProcessIsIgnored() {
        let processes = FakeProcesses()
        processes.own(700)
        let strangers = [GPUClient(id: 1, creator: "kernel", nanoseconds: 5), GPUClient(id: 2, creator: "pid x, y", nanoseconds: 5)]
        processes.clients = strangers + [GPUClient(id: 3, creator: "pid 700, tool", nanoseconds: 0)]
        let reader = ProcessReader(transport: processes)
        _ = reader.read(at: 0)
        processes.clients = strangers + [GPUClient(id: 3, creator: "pid 700, tool", nanoseconds: 500_000_000)]
        XCTAssertEqual(reader.read(at: 1).gpuSeconds, [700: 0.5])
    }

    // MARK: Wine

    func testAWindowsProgramIsNamedByItsExe() {
        let processes = FakeProcesses()
        processes.own(800, path: wine, arguments: [wine, "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Skyrim Special Edition\\SkyrimSE.exe", "-fullscreen"])
        processes.own(801, path: wine, arguments: ["Z:/Games/Launcher/Game Launcher.EXE"])
        let pass = ProcessReader(transport: processes).read(at: 0)
        XCTAssertEqual(pass.own.first { $0.description.identity.pid == 800 }?.description.wine, .program("SkyrimSE.exe"))
        XCTAssertEqual(pass.own.first { $0.description.identity.pid == 801 }?.description.wine, .program("Game Launcher.EXE"))
    }

    func testWinesOwnProcessesAreItsBackground() {
        let processes = FakeProcesses()
        processes.own(810, path: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineserver", arguments: ["wineserver"])
        processes.own(811, path: wine, arguments: [wine, "C:\\windows\\system32\\services.exe"])
        processes.own(812, path: wine, arguments: ["winedevice.exe"])
        processes.own(813, path: wine, arguments: nil)
        let pass = ProcessReader(transport: processes).read(at: 0)
        XCTAssertEqual(pass.own.map(\.description.wine), [.background, .background, .background, .background])
    }

    // Read from a running CrossOver on 2026-10-12: its launcher is started by
    // its path among Wine's built-in programs, not from C:\windows.
    func testWinesLauncherStartedByItsPathIsItsBackground() {
        let processes = FakeProcesses()
        processes.own(820, path: wine, arguments: ["/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-windows/winewrapper.exe",
                                                   "--enable-alt-loader", "macdrv", "--wait-children", "--start", "--",
                                                   "C:/ProgramData/Microsoft/Windows/Start Menu/Programs/Skyrim SE (SKSE).lnk", ""])
        processes.own(821, path: wine, arguments: ["C:\\Program Files (x86)\\Steam\\steam.exe", ""])
        let pass = ProcessReader(transport: processes).read(at: 0)
        XCTAssertEqual(pass.own.first { $0.description.identity.pid == 820 }?.description.wine, .background)
        XCTAssertEqual(pass.own.first { $0.description.identity.pid == 821 }?.description.wine, .program("steam.exe"))
    }

    // Since 2026-10-12 the arguments are read inside an app as well, for the
    // kind of its helpers; a plain program's are still left alone.
    func testArgumentsAreReadForWineAndInsideAnAppOnly() {
        let processes = FakeProcesses()
        processes.own(600, path: "/usr/local/bin/tool", arguments: ["tool", "game.exe"])
        processes.own(700, path: "/Applications/CrossOver.app/Contents/MacOS/CrossOver", arguments: ["CrossOver", "game.exe"])
        processes.own(800, path: wine, arguments: [wine, "C:\\Games\\game.exe"])
        let pass = ProcessReader(transport: processes).read(at: 0)
        XCTAssertEqual(processes.argumentReads, [700, 800])
        // CrossOver's own window is an app like any other.
        XCTAssertNil(pass.own.first { $0.description.identity.pid == 700 }?.description.wine)
    }

    // MARK: The kernel's argument block

    func testArgumentsAreTakenFromTheKernelsBlock() {
        var block: [UInt8] = [3, 0, 0, 0]
        block += Array("/usr/bin/tool".utf8) + [0, 0, 0, 0]
        for argument in ["tool", "C:\\Games\\game.exe", "--flag"] { block += Array(argument.utf8) + [0] }
        block += Array("HOME=/Users/owner".utf8) + [0]
        XCTAssertEqual(DarwinProcessTransport.arguments(inProcArgs: block), ["tool", "C:\\Games\\game.exe", "--flag"])
        XCTAssertNil(DarwinProcessTransport.arguments(inProcArgs: [1, 0]))
    }

    // MARK: Running `ps`

    func testACommandsOutputIsReturned() {
        XCTAssertEqual(DarwinProcessTransport.run("/bin/echo", ["hello"], limit: 2), "hello\n")
    }

    func testACommandThatTakesTooLongIsEnded() {
        let started = Date()
        XCTAssertNil(DarwinProcessTransport.run("/bin/sleep", ["5"], limit: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testACommandThatFailsOrCannotStartGivesNothing() {
        XCTAssertNil(DarwinProcessTransport.run("/usr/bin/false", [], limit: 2))
        XCTAssertNil(DarwinProcessTransport.run("/nonexistent/tool", [], limit: 2))
    }

    // MARK: The real table

    // One read of this Mac: the test's own process is an own process with
    // memory, and launchd is a system process taken from the listing.
    func testThisMacsOwnTable() {
        let pass = ProcessReader(transport: DarwinProcessTransport()).read(at: ProcessInfo.processInfo.systemUptime)
        let me = pass.own.first { $0.description.identity.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertGreaterThan(me?.memoryBytes ?? 0, 0)
        XCTAssertEqual(me?.description.isOwn, true)
        let launchd = pass.system?.first { $0.description.identity.pid == 1 }
        XCTAssertEqual(launchd?.description.name, "launchd")
        XCTAssertGreaterThan(launchd?.cpuSeconds ?? 0, 0)
    }
}
