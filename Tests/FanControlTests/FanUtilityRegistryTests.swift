import XCTest
@testable import FanControlHardware

// The competing utility is looked for among the processes whose short name
// can be its executable's; the path then decides, as it did for every process.
final class FanUtilityRegistryTests: XCTestCase {
    private func mayBe(_ shortName: String) -> Bool {
        FanUtilityRegistry.mayBeUtility(shortName: Array(shortName.utf8))
    }

    func testAShortNameThatIsAnExecutableNameIsACandidate() {
        XCTAssertTrue(mayBe("macsfancontrol"))
        XCTAssertTrue(mayBe("Macs Fan Control"))
    }

    // The kernel keeps 15 bytes of "Macs Fan Control".
    func testANameTheKernelCutOffIsACandidate() {
        XCTAssertEqual(FanUtilityRegistry.shortNameLimit, 15)
        XCTAssertTrue(mayBe("Macs Fan Contro"))
    }

    func testOtherNamesAreNotCandidates() {
        for name in ["", "Macs", "Macs Fan", "macsfan", "macsfancontrolx", "Macs Fan Controx", "MacHelm", "FanControlHelper",
                     "com.crystalidea.", "macs fan control"] {
            XCTAssertFalse(mayBe(name), name)
        }
    }

    func testARunningProcessGivesItsShortName() {
        let name = FanUtilityRegistry.shortName(of: getpid())
        XCTAssertEqual(name.map { String(decoding: $0, as: UTF8.self) }, String(ProcessInfo.processInfo.processName.prefix(15)))
        XCTAssertNil(FanUtilityRegistry.shortName(of: -1))
    }

    // On this Mac as it is now: narrowing by short name finds what reading every path finds.
    func testNarrowingAgreesWithReadingEveryPath() {
        XCTAssertEqual(FanUtilityRegistry.runningConflict() != nil, everyPathFindsAnExecutableName())
    }

    private func everyPathFindsAnExecutableName() -> Bool {
        var processes = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 128)
        let count = proc_listallpids(&processes, Int32(processes.count * MemoryLayout<pid_t>.stride))
        for pid in processes.prefix(Int(max(count, 0))) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            if FanUtilityRegistry.executableNames.contains(URL(fileURLWithPath: String(cString: path)).lastPathComponent) { return true }
        }
        return false
    }
}
