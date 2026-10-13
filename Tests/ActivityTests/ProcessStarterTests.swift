import XCTest
@testable import ActivityCore

// Who started a process, as the owner asked on 2026-10-12: "Sometimes codex,
// claude or playwright use browser (brave or integrated) and the processes
// may get high CPU usage; it is not clear what actually uses it" (Q2, Q3,
// Q14 and Q15 of the Power and Storage record). Read through the production
// reader over a fake process table.
final class ProcessStarterTests: XCTestCase {
    private let ghostty = "/Applications/Ghostty.app/Contents/MacOS/ghostty"
    private let brave = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
    private let braveHelper = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/141/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"
    private let chromium = "/Users/owner/Library/Caches/ms-playwright/chromium-1200/chrome-mac/Chromium.app/Contents/MacOS/Chromium"
    private let chromiumHelper = "/Users/owner/Library/Caches/ms-playwright/chromium-1200/chrome-mac/Chromium.app/Contents/Frameworks/Chromium Framework.framework/Versions/140/Helpers/Chromium Helper (Renderer).app/Contents/MacOS/Chromium Helper (Renderer)"
    private let node = "/opt/homebrew/bin/node"
    private let encoder = "/System/Library/Frameworks/VideoToolbox.framework/Versions/A/XPCServices/VTEncoderXPCService.xpc/Contents/MacOS/VTEncoderXPCService"

    private func described(_ pid: Int32, in pass: ProcessPass) -> ProcessDescription? {
        pass.own.first { $0.description.identity.pid == pid }?.description
    }

    // Ghostty, a shell in it, codex, npx, the Playwright server it runs, and the browser that started.
    private func agentBrowser() -> FakeProcesses {
        let processes = FakeProcesses()
        processes.own(10, path: ghostty)
        processes.own(11, path: "/bin/zsh", parent: 10)
        processes.own(12, path: "/opt/homebrew/bin/codex", parent: 11)
        processes.own(13, path: node, parent: 12, arguments: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npx-cli.js", "@playwright/mcp"])
        processes.own(14, path: node, parent: 13, arguments: ["node", "/Users/owner/.npm/_npx/ab12/node_modules/@playwright/mcp/cli.js"])
        processes.own(15, path: chromium, parent: 14, arguments: [chromium, "--remote-debugging-pipe"])
        processes.own(16, path: chromiumHelper, parent: 15, arguments: [chromiumHelper, "--type=renderer", "--lang=en-US"])
        return processes
    }

    // MARK: The starter

    func testAProcessKeepsItsStarterAfterTheStarterEnded() {
        let processes = FakeProcesses()
        processes.own(100, path: "/bin/zsh")
        processes.own(200, path: "/usr/local/bin/tool", parent: 100)
        let reader = ProcessReader(transport: processes)
        XCTAssertEqual(described(200, in: reader.read(at: 0))?.starter, ProcessStarter(pid: 100, name: "zsh"))

        // The shell ends, and macOS hands its child to launchd.
        processes.table[100] = nil
        processes.table[200]?.parent = 1
        let later = described(200, in: reader.read(at: 5))
        XCTAssertEqual(later?.starter, ProcessStarter(pid: 100, name: "zsh", ended: true))
        XCTAssertEqual(later?.parent, 1)
    }

    func testAProcessThatLaunchdStartedHasNoStarter() {
        let processes = FakeProcesses()
        processes.own(200, path: "/usr/local/bin/tool")
        let description = described(200, in: ProcessReader(transport: processes).read(at: 0))
        XCTAssertNil(description?.starter)
        XCTAssertEqual(description?.chain, [])
    }

    func testAStarterInsideTheProcesssOwnAppIsNotShown() {
        let processes = FakeProcesses()
        processes.own(300, path: brave)
        processes.own(301, path: braveHelper, parent: 300, arguments: [braveHelper, "--type=renderer"])
        XCTAssertNil(described(301, in: ProcessReader(transport: processes).read(at: 0))?.starter)
    }

    func testASystemProcessCanBeTheStarter() {
        let processes = FakeProcesses()
        processes.system(50, name: "sshd-session")
        processes.own(200, path: "/usr/local/bin/tool", parent: 50)
        let description = described(200, in: ProcessReader(transport: processes).read(at: 0))
        XCTAssertEqual(description?.starter, ProcessStarter(pid: 50, name: "sshd-session"))
        XCTAssertEqual(description?.chain, ["sshd-session"])
    }

    func testAProcessThatBecameAnotherProgramKeepsItsStarter() {
        let processes = FakeProcesses()
        processes.own(11, path: "/bin/zsh")
        processes.own(12, path: "/bin/sh", parent: 11)
        let reader = ProcessReader(transport: processes)
        _ = reader.read(at: 0)
        // The shell ends; what it started then runs another program in its place.
        processes.table[11] = nil
        processes.own(12, path: "/opt/homebrew/bin/codex", parent: 1)
        let description = described(12, in: reader.read(at: 1))
        XCTAssertEqual(description?.name, "codex")
        XCTAssertEqual(description?.starter, ProcessStarter(pid: 11, name: "zsh", ended: true))
    }

    func testAnEndedStartersIdentifierUsedAgainIsNotTheStarter() {
        let processes = FakeProcesses()
        processes.own(100, path: "/bin/zsh")
        processes.own(200, path: "/usr/local/bin/tool", parent: 100)
        let reader = ProcessReader(transport: processes)
        _ = reader.read(at: 0)
        processes.table[200]?.parent = 1
        processes.own(100, path: "/usr/bin/vim", startedAt: 9_000_000_000)
        let pass = reader.read(at: 5)
        XCTAssertEqual(described(200, in: pass)?.starter, ProcessStarter(pid: 100, name: "zsh", ended: true))
        XCTAssertNil(described(100, in: pass)?.starter)
    }

    // MARK: The responsible app

    func testAProcessSeenFirstWithoutItsStarterShowsItsResponsibleApp() {
        let processes = FakeProcesses()
        processes.own(10, path: ghostty)
        // codex outlived the shell that started it before the first reading.
        processes.own(12, path: "/opt/homebrew/bin/codex")
        processes.responsible = [10: 10, 12: 10]
        let description = described(12, in: ProcessReader(transport: processes).read(at: 0))
        XCTAssertNil(description?.starter)
        XCTAssertEqual(description?.responsibleApp, "Ghostty")
        XCTAssertEqual(description?.chain, ["Ghostty"])
    }

    func testTheResponsibleAppIsLeftOutWhenItIsTheStarterOrTheProcesssOwnApp() {
        let processes = FakeProcesses()
        processes.own(10, path: ghostty)
        processes.own(11, path: "/bin/zsh", parent: 10)
        processes.own(300, path: brave)
        processes.own(301, path: braveHelper, parent: 300, arguments: [braveHelper, "--type=renderer"])
        processes.responsible = [10: 10, 11: 10, 300: 300, 301: 300]
        let pass = ProcessReader(transport: processes).read(at: 0)
        XCTAssertEqual(described(11, in: pass)?.starter, ProcessStarter(pid: 10, name: "Ghostty"))
        XCTAssertNil(described(11, in: pass)?.responsibleApp)
        XCTAssertNil(described(300, in: pass)?.responsibleApp)
        XCTAssertNil(described(301, in: pass)?.responsibleApp)
    }

    func testAShellInsideAnotherToolShowsTheAppItRunsUnder() {
        let processes = agentBrowser()
        processes.own(20, path: "/bin/zsh", parent: 12)
        processes.responsible = [20: 10]
        let description = described(20, in: ProcessReader(transport: processes).read(at: 0))
        XCTAssertEqual(description?.starter, ProcessStarter(pid: 12, name: "codex"))
        XCTAssertEqual(description?.responsibleApp, "Ghostty")
    }

    // MARK: The chain and the origin

    func testTheChainLeavesOutShellsAndPackageRunnersAndNamesAnInterpreterByItsScript() {
        let pass = ProcessReader(transport: agentBrowser()).read(at: 0)
        XCTAssertEqual(described(15, in: pass)?.chain, ["@playwright/mcp", "codex", "Ghostty"])
        XCTAssertEqual(described(15, in: pass)?.starter, ProcessStarter(pid: 14, name: "@playwright/mcp"))
        XCTAssertEqual(described(14, in: pass)?.chain, ["codex", "Ghostty"])
        XCTAssertEqual(described(12, in: pass)?.chain, ["Ghostty"])
        XCTAssertEqual(described(12, in: pass)?.starter, ProcessStarter(pid: 11, name: "zsh"))
    }

    func testACopyOfAnAppThatAnotherProgramStartedHasItsOriginAndSoHaveItsHelpers() {
        let pass = ProcessReader(transport: agentBrowser()).read(at: 0)
        XCTAssertEqual(described(15, in: pass)?.origin, ["@playwright/mcp", "codex", "Ghostty"])
        XCTAssertEqual(described(16, in: pass)?.origin, ["@playwright/mcp", "codex", "Ghostty"])
        // A program outside any app has no origin: rows by name stay summed.
        XCTAssertEqual(described(14, in: pass)?.origin, [])
        XCTAssertEqual(described(12, in: pass)?.origin, [])
    }

    func testACopyThatLaunchdStartedHasNoOrigin() {
        let processes = FakeProcesses()
        processes.own(300, path: brave)
        processes.own(301, path: braveHelper, parent: 300, arguments: [braveHelper, "--type=renderer"])
        processes.responsible = [300: 300, 301: 300]
        let pass = ProcessReader(transport: processes).read(at: 0)
        XCTAssertEqual(described(300, in: pass)?.origin, [])
        XCTAssertEqual(described(301, in: pass)?.origin, [])
    }

    func testTheOriginStaysAfterTheStartersHaveEnded() {
        let processes = agentBrowser()
        let reader = ProcessReader(transport: processes)
        _ = reader.read(at: 0)
        for pid in [11, 12, 13, 14] as [Int32] { processes.table[pid] = nil }
        processes.table[15]?.parent = 1
        let pass = reader.read(at: 5)
        XCTAssertEqual(described(15, in: pass)?.origin, ["@playwright/mcp", "codex", "Ghostty"])
        XCTAssertEqual(described(16, in: pass)?.origin, ["@playwright/mcp", "codex", "Ghostty"])
    }

    func testACopySeenFirstWithoutItsStarterTakesItsOriginFromTheResponsibleApp() {
        let processes = FakeProcesses()
        processes.own(10, path: ghostty)
        processes.own(15, path: chromium)
        processes.own(16, path: chromiumHelper, parent: 15, arguments: [chromiumHelper, "--type=renderer"])
        processes.responsible = [10: 10, 15: 10, 16: 10]
        let pass = ProcessReader(transport: processes).read(at: 0)
        XCTAssertEqual(described(15, in: pass)?.origin, ["Ghostty"])
        XCTAssertEqual(described(16, in: pass)?.origin, ["Ghostty"])
    }

    func testAHelperOfACopyThatLaunchdHoldsTakesTheCopysOrigin() {
        let processes = agentBrowser()
        // Its crash reporter left its parent; macOS still names the browser copy as responsible.
        let reporter = "/Users/owner/Library/Caches/ms-playwright/chromium-1200/chrome-mac/Chromium.app/Contents/Frameworks/Chromium Framework.framework/Helpers/chrome_crashpad_handler"
        processes.own(17, path: reporter)
        processes.responsible = [17: 15]
        XCTAssertEqual(described(17, in: ProcessReader(transport: processes).read(at: 0))?.origin, ["@playwright/mcp", "codex", "Ghostty"])
    }

    func testWhatAnInterpreterRunsIsReadFromItsArguments() {
        XCTAssertEqual(ProcessReader.scriptName(arguments: ["node", "/x/node_modules/.bin/chrome-devtools-mcp"]), "chrome-devtools-mcp")
        XCTAssertEqual(ProcessReader.scriptName(arguments: ["node", "/x/node_modules/@playwright/mcp/cli.js"]), "@playwright/mcp")
        XCTAssertEqual(ProcessReader.scriptName(arguments: ["node", "/x/node_modules/a/node_modules/typescript/lib/tsserver.js"]), "typescript")
        XCTAssertEqual(ProcessReader.scriptName(arguments: ["python3", "-m", "http.server", "8000"]), "http.server")
        XCTAssertEqual(ProcessReader.scriptName(arguments: ["python3", "/Users/owner/tools/server.py"]), "tools/server.py")
        XCTAssertEqual(ProcessReader.scriptName(arguments: ["node", "--max-old-space-size=4096", "/x/build/index.js"]), "build/index.js")
        XCTAssertEqual(ProcessReader.scriptName(arguments: ["python3", "/Users/owner/tools/sync_photos.py"]), "sync_photos")
        XCTAssertNil(ProcessReader.scriptName(arguments: ["node", "-e", "console.log(1)"]))
        XCTAssertNil(ProcessReader.scriptName(arguments: ["node"]))
    }

    // MARK: Helpers that launchd started

    func testAHelperThatLaunchdStartedCountsTowardItsResponsibleApp() {
        let processes = agentBrowser()
        processes.own(300, path: brave)
        processes.own(40, path: encoder)
        processes.own(41, path: encoder, startedAt: 2_000_000_000)
        processes.responsible = [300: 300, 40: 300, 41: 15]
        let pass = ProcessReader(transport: processes).read(at: 0)
        XCTAssertEqual(described(40, in: pass)?.adoptedBy, "/Applications/Brave Browser.app")
        XCTAssertEqual(described(40, in: pass)?.origin, [])
        // One that works for the agent's browser counts toward that copy.
        XCTAssertEqual(described(41, in: pass)?.adoptedBy, "/Users/owner/Library/Caches/ms-playwright/chromium-1200/chrome-mac/Chromium.app")
        XCTAssertEqual(described(41, in: pass)?.origin, ["@playwright/mcp", "codex", "Ghostty"])
    }

    func testAToolThatOutlivedItsShellIsNotTakenForAHelper() {
        let processes = FakeProcesses()
        processes.own(10, path: ghostty)
        processes.own(12, path: "/opt/homebrew/bin/codex")
        processes.responsible = [10: 10, 12: 10]
        XCTAssertNil(described(12, in: ProcessReader(transport: processes).read(at: 0))?.adoptedBy)
    }

    // MARK: Process kinds

    func testAHelperIsLabelledByWhatItDoes() {
        let claudeHelper = "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)"
        let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        let processes = FakeProcesses()
        processes.own(300, path: brave, arguments: [brave])
        processes.own(301, path: braveHelper, parent: 300, arguments: [braveHelper, "--type=renderer", "--lang=en-US"])
        processes.own(302, path: braveHelper, parent: 300, arguments: [braveHelper, "--type=renderer", "--extension-process"])
        processes.own(303, path: braveHelper, parent: 300, arguments: [braveHelper, "--type=gpu-process"])
        processes.own(304, path: braveHelper, parent: 300,
                      arguments: [braveHelper, "--type=utility", "--utility-sub-type=network.mojom.NetworkService"])
        processes.own(305, path: braveHelper, parent: 300,
                      arguments: [braveHelper, "--type=utility", "--utility-sub-type=audio.mojom.AudioService"])
        processes.own(306, path: braveHelper, parent: 300, arguments: [braveHelper, "--type=utility", "--utility-sub-type=some.mojom.Thing"])
        processes.own(400, path: claudeHelper, arguments: [claudeHelper, "--type=renderer"])
        processes.own(500, path: webContent)
        let pass = ProcessReader(transport: processes).read(at: 0)
        XCTAssertNil(described(300, in: pass)?.kind)
        XCTAssertEqual([301, 302, 303, 304, 305, 306].map { described($0, in: pass)?.kind },
                       ["tab", "extension", "GPU", "network", "audio", "utility"])
        // In an app that is not a browser a renderer is a window, not a tab.
        XCTAssertEqual(described(400, in: pass)?.kind, "window")
        XCTAssertEqual(described(500, in: pass)?.kind, "tab")
    }

    func testArgumentsAreReadOnceAndOnlyWhereTheyTellSomething() {
        let processes = agentBrowser()
        processes.own(200, path: "/usr/local/bin/tool", arguments: ["tool"])
        let reader = ProcessReader(transport: processes)
        _ = reader.read(at: 0)
        _ = reader.read(at: 1)
        // The two interpreters, the app copy and its helper; not the shell, codex or the tool.
        XCTAssertEqual(processes.argumentReads.sorted(), [10, 13, 14, 15, 16])
    }
}

final class ProcessOriginGroupingTests: XCTestCase {
    private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private func group(_ description: ProcessDescription) -> ProcessGroupID {
        ProcessGrouping.group(of: description, parents: [:], services: [:])
    }

    func testACopyStartedByAnotherProgramIsAGroupOfItsOwn() {
        var own = Sampled.describe(1, path: chrome)
        var agents = Sampled.describe(2, path: chrome)
        agents.origin = ["chrome-devtools-mcp", "codex"]
        var another = Sampled.describe(3, path: chrome)
        another.origin = ["chrome-devtools-mcp", "codex"]
        XCTAssertEqual(group(own), ProcessGroupID(kind: .app(bundlePath: "/Applications/Google Chrome.app"), name: "Google Chrome"))
        XCTAssertEqual(group(agents).origin, ["chrome-devtools-mcp", "codex"])
        XCTAssertNotEqual(group(own), group(agents))
        // Copies with the same origin share a row.
        XCTAssertEqual(group(agents), group(another))
        own.origin = []
        XCTAssertEqual(group(own).origin, [])
    }

    func testAnAdoptedHelperJoinsItsAppAndItsCopy() {
        var helper = Sampled.describe(40, path: "/System/Library/Frameworks/VideoToolbox.framework/XPCServices/VTEncoderXPCService.xpc/Contents/MacOS/VTEncoderXPCService")
        XCTAssertEqual(group(helper).kind, .process)
        helper.adoptedBy = "/Applications/Google Chrome.app"
        XCTAssertEqual(group(helper), ProcessGroupID(kind: .app(bundlePath: "/Applications/Google Chrome.app"), name: "Google Chrome"))
        helper.origin = ["codex"]
        XCTAssertEqual(group(helper), ProcessGroupID(kind: .app(bundlePath: "/Applications/Google Chrome.app"), name: "Google Chrome",
                                                    origin: ["codex"]))
    }

    func testAStartupServiceStillTakesWhatItStarted() {
        var browser = Sampled.describe(15, path: chrome, parent: 100)
        browser.origin = ["My Service"]
        let service = ServiceRoot(id: "com.example.service", name: "My Service", pid: 100)
        XCTAssertEqual(ProcessGrouping.group(of: browser, parents: [15: 100], services: [100: service]),
                       ProcessGroupID(kind: .service(id: service.id), name: "My Service"))
    }
}

final class ProcessOriginRankingTests: XCTestCase {
    private let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private func rows(_ processes: [ProcessAverage]) -> [ActivityRow] {
        ActivityRanking.snapshot(of: ActivityAverages(seconds: 10, processes: processes, parents: [:]), services: [], ownPID: 999).rows[.cpu] ?? []
    }

    func testTheRowsOfOneAppAreSplitByOrigin() {
        var agents = Sampled.describe(2, path: chrome)
        agents.origin = ["chrome-devtools-mcp", "codex"]
        var helper = Sampled.describe(3, path: chrome)
        helper.origin = ["chrome-devtools-mcp", "codex"]
        let listed = rows([ProcessAverage(description: Sampled.describe(1, path: chrome), cpuPercent: 10),
                           ProcessAverage(description: agents, cpuPercent: 30), ProcessAverage(description: helper, cpuPercent: 25)])
        XCTAssertEqual(listed.map(\.group.name), ["Google Chrome", "Google Chrome"])
        XCTAssertEqual(listed.map(\.group.origin), [["chrome-devtools-mcp", "codex"], []])
        XCTAssertEqual(listed.map(\.value), [55, 10])
        XCTAssertEqual(listed.map { $0.members.map(\.pid) }, [[2, 3], [1]])
    }

    func testAProcessOfARowCarriesItsKindItsStarterAndItsResponsibleApp() {
        var shell = Sampled.describe(20, path: "/bin/zsh")
        shell.starter = ProcessStarter(pid: 12, name: "codex")
        shell.responsibleApp = "Ghostty"
        shell.chain = ["codex", "Ghostty"]
        var tab = Sampled.describe(301, path: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
        tab.kind = "tab"
        let listed = rows([ProcessAverage(description: shell, cpuPercent: 40), ProcessAverage(description: tab, cpuPercent: 20),
                           ProcessAverage(description: Sampled.describe(21, path: "/bin/zsh"), cpuPercent: 5, ended: true)])
        let first = listed.first?.processes.first
        XCTAssertEqual(first?.starter, ProcessStarter(pid: 12, name: "codex"))
        XCTAssertEqual(first?.responsibleApp, "Ghostty")
        XCTAssertEqual(first?.chain, ["codex", "Ghostty"])
        XCTAssertEqual(listed.first?.processes.map(\.ended), [false, true])
        XCTAssertEqual(listed.last?.processes.first?.kind, "tab")
    }
}
