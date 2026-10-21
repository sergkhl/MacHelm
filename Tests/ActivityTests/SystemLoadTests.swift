import XCTest
@testable import ActivityCore

// A Mac that only answers.
private final class FakeSystem: SystemTransport, @unchecked Sendable {
    var cores = 10
    var ticks: (busy: UInt64, all: UInt64)? = (0, 0)
    var memory: (used: UInt64, all: UInt64)? = (0, 0)
    var gpu: Double? = 0
    var power: Double? = 0
    var disk: UInt64? = 0

    func cpuTicks() -> (busy: UInt64, all: UInt64)? { ticks }
    func memoryBytes() -> (used: UInt64, all: UInt64)? { memory }
    func gpuPercent() -> Double? { gpu }
    func powerWatts() -> Double? { power }
    func diskBytes() -> UInt64? { disk }
}

// The whole Mac's figure beside each list, as the owner decided it on
// 2026-10-12 (Q34 of the Power and Storage record): what it is now.
final class SystemLoadTests: XCTestCase {
    private let system = FakeSystem()

    // On the rows' scale: percent of one core, so ten cores at work are a thousand.
    func testCPUIsWhatAllCoresUsedBetweenTheTwoLatestReadingsInPercentOfOneCore() {
        var meter = SystemMeter(transport: system)
        system.ticks = (1_000, 10_000)
        _ = meter.read(at: 100)
        // One second of ten cores is a thousand ticks; three hundred of them were work.
        system.ticks = (1_300, 11_000)
        let load = meter.read(at: 101)
        XCTAssertEqual(load.cpuPercent ?? -1, 300, accuracy: 0.001)
        XCTAssertEqual(load.cores, 10)
        // The reading after it counts from the second, not from the first.
        system.ticks = (2_200, 12_000)
        XCTAssertEqual(meter.read(at: 102).cpuPercent ?? -1, 900, accuracy: 0.001)
    }

    func testDiskIsWhatWasReadAndWrittenEachSecondSinceTheReadingBefore() {
        var meter = SystemMeter(transport: system)
        system.disk = 5_000_000
        _ = meter.read(at: 100)
        system.disk = 15_000_000
        XCTAssertEqual(meter.read(at: 105).diskBytesPerSecond ?? -1, 2_000_000, accuracy: 0.001)
    }

    func testMemoryTheGPUAndThePowerAreAsLastRead() {
        var meter = SystemMeter(transport: system)
        system.memory = (11_000_000_000, 17_179_869_184)
        system.gpu = 74
        system.power = 40.161
        let load = meter.read(at: 100)
        XCTAssertEqual(load.memoryUsedBytes, 11_000_000_000)
        XCTAssertEqual(load.memoryBytes, 17_179_869_184)
        XCTAssertEqual(load.gpuPercent, 74)
        XCTAssertEqual(load.powerWatts, 40.161)
    }

    func testTheFirstReadingHasNothingToCompareWith() {
        var meter = SystemMeter(transport: system)
        system.ticks = (1_000, 10_000)
        system.disk = 5_000_000
        system.gpu = 12
        let load = meter.read(at: 100)
        XCTAssertNil(load.cpuPercent)
        XCTAssertNil(load.diskBytesPerSecond)
        XCTAssertEqual(load.gpuPercent, 12)
    }

    func testWhatThisMacDoesNotSayIsMissing() {
        var meter = SystemMeter(transport: system)
        // A Mac without a battery says nothing about its power.
        system.power = nil
        system.gpu = nil
        system.memory = nil
        system.ticks = nil
        system.disk = nil
        _ = meter.read(at: 100)
        XCTAssertEqual(meter.read(at: 101), SystemLoad(cores: 10))
    }

    // A disk that was unplugged takes its bytes with it.
    func testACounterThatWentBackGivesNoFigureAndTheNextReadingCountsFromIt() {
        var meter = SystemMeter(transport: system)
        system.disk = 9_000_000
        system.ticks = (5_000, 50_000)
        _ = meter.read(at: 100)
        system.disk = 4_000_000
        system.ticks = (100, 1_000)
        let load = meter.read(at: 101)
        XCTAssertNil(load.diskBytesPerSecond)
        XCTAssertNil(load.cpuPercent)
        system.disk = 5_000_000
        system.ticks = (350, 2_000)
        let next = meter.read(at: 102)
        XCTAssertEqual(next.diskBytesPerSecond ?? -1, 1_000_000, accuracy: 0.001)
        XCTAssertEqual(next.cpuPercent ?? -1, 250, accuracy: 0.001)
    }

    // The page asks for a reading the moment it appears, which can follow a timed one at once.
    func testAReadingRightAfterAnotherKeepsThatOnesFigures() {
        var meter = SystemMeter(transport: system)
        system.ticks = (1_000, 10_000)
        system.disk = 1_000_000
        _ = meter.read(at: 100)
        system.ticks = (1_500, 11_000)
        system.disk = 3_000_000
        _ = meter.read(at: 101)
        // A twentieth of a second later: five ticks say nothing, and the level is new.
        system.ticks = (1_505, 11_005)
        system.disk = 3_000_000
        system.gpu = 55
        let soon = meter.read(at: 101.05)
        XCTAssertEqual(soon.cpuPercent ?? -1, 500, accuracy: 0.001)
        XCTAssertEqual(soon.diskBytesPerSecond ?? -1, 2_000_000, accuracy: 0.001)
        XCTAssertEqual(soon.gpuPercent, 55)
        // The next timed reading counts from the last full one.
        system.ticks = (1_700, 12_000)
        system.disk = 4_000_000
        let later = meter.read(at: 102)
        XCTAssertEqual(later.cpuPercent ?? -1, 200, accuracy: 0.001)
        XCTAssertEqual(later.diskBytesPerSecond ?? -1, 1_000_000, accuracy: 0.001)
    }

    func testEachMeasureHasItsFigure() {
        let load = SystemLoad(cpuPercent: 30, cores: 10, memoryUsedBytes: 11e9, memoryBytes: 16e9, gpuPercent: 74, powerWatts: 40,
                              diskBytesPerSecond: 2e6)
        XCTAssertEqual(ActivityMeasure.allCases.map { load.value(of: $0) }, [30, 11e9, 74, 40, 2e6])
        XCTAssertEqual(ActivityMeasure.allCases.map { SystemLoad(cores: 10).value(of: $0) }, [nil, nil, nil, nil, nil])
    }
}
