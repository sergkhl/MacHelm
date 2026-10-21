import XCTest
@testable import StorageCore

// Storage as the owner decided it on 2026-10-12 (Q5, Q23 to Q28 and Q32 of
// the Power and Storage record): what the script says, what may be checked,
// and which root removal the app passes on.
private let safe = "restored by a lockfile or a re-download, or no longer used"
private let dyld = "/Library/Developer/CoreSimulator/Caches/dyld/25G83/com.apple.CoreSimulator.SimRuntime.iOS-18-0.22A3351"

private func target(_ key: String, state: StorageTargetState = .selectable, projected: Int? = 1_000, root: Bool = false,
                    checked: Bool = false, paths: [String] = [], exclusive: String = "") -> StorageTarget {
    StorageTarget(key: key, group: safe, label: key, state: state, sizeKB: projected, projectedKB: projected, needsRoot: root,
                  defaultSelected: checked, paths: paths, exclusive: exclusive)
}

final class StorageProtocolTests: XCTestCase {
    // One line as the script printed it on 2026-10-12, with the paths replaced.
    private let targets = #"{"event": "targets", "free_kb": 24536000, "targets": [{"key": "sim-runtime-22A3351", "group": "restored by a lockfile or a re-download, or no longer used", "label": "Orphaned simulator runtime iOS 18.0", "state": "selectable", "detail": "0 devices", "size_kb": 8388608, "projected_kb": 8388608, "needs_sudo": true, "default_selected": true, "last_used_at": "2026-09-10T23:15:00Z", "paths": ["/System/Library/AssetsV2/x.asset", "/Library/Developer/CoreSimulator/Caches/dyld/25G83/com.apple.CoreSimulator.SimRuntime.iOS-18-0.22A3351"], "exclusive": ""}, {"key": "docker", "group": "reported, never modified", "label": "Docker", "state": "report_only", "detail": "allocated host storage", "size_kb": null, "projected_kb": 0, "needs_sudo": false, "default_selected": false, "last_used_at": null, "paths": [], "exclusive": ""}, {"key": "sim-erase-A", "group": "Erase shutdown simulators (keeps the device)", "label": "iPhone", "state": "selectable", "detail": "", "size_kb": 1024, "projected_kb": null, "needs_sudo": false, "default_selected": false, "last_used_at": null, "paths": ["/Users/owner/dev/A"], "exclusive": "sim-A"}]}"#

    func testAScanIsOneLineWithTheFreeSpaceAndEveryTarget() {
        guard case .targets(let free, let asOf, let idleDays, let listed)? = StorageProtocol.event(in: targets) else { return XCTFail("no targets") }
        XCTAssertEqual(free, 24_536_000)
        // A script from before ADR 0008 names no instant, no idle days, no kind and no access.
        XCTAssertNil(asOf)
        XCTAssertNil(idleDays)
        XCTAssertEqual(listed.map(\.kind), ["", "", ""])
        XCTAssertFalse(listed.contains(where: \.needsFullDiskAccess))
        XCTAssertEqual(listed.map(\.key), ["sim-runtime-22A3351", "docker", "sim-erase-A"])
        XCTAssertEqual(listed[0], StorageTarget(key: "sim-runtime-22A3351", group: safe, label: "Orphaned simulator runtime iOS 18.0",
                                               detail: "0 devices", sizeKB: 8_388_608, projectedKB: 8_388_608, needsRoot: true,
                                               defaultSelected: true, lastUsedAt: "2026-09-10T23:15:00Z",
                                               paths: ["/System/Library/AssetsV2/x.asset", dyld]))
        XCTAssertEqual(listed[1].state, .reportOnly)
        XCTAssertNil(listed[1].sizeKB)
        XCTAssertNil(listed[2].projectedKB)
        XCTAssertEqual(listed[2].exclusive, "sim-A")
    }

    // The interactive login shell printed its prompt before the script's line, on this Mac on 2026-10-12.
    func testWhatTheShellPrintsBeforeTheEventIsLeftOut() {
        let line = "\u{1B}[35m❯\u{1B}[39m \u{1B}]1337;RemoteHost=owner@Mac\u{07}" + #"{"event": "done", "reclaimed_kb": 2048, "failures": 1, "free_kb": 9}"#
        XCTAssertEqual(StorageProtocol.event(in: line), .done(reclaimedKB: 2_048, failures: 1, freeKB: 9))
    }

    func testEveryEventOfARunIsRead() {
        XCTAssertEqual(StorageProtocol.event(in: #"{"event": "remove-root", "path": "/Library/x"}"#), .removeRoot(path: "/Library/x"))
        XCTAssertEqual(StorageProtocol.event(in: #"{"event": "result", "key": "go", "ok": true, "freed_kb": 12, "error": null}"#),
                       .result(key: "go", ok: true, freedKB: 12, error: nil))
        XCTAssertEqual(StorageProtocol.event(in: #"{"event": "result", "key": "uv", "ok": false, "freed_kb": null, "error": "cache is in use"}"#),
                       .result(key: "uv", ok: false, freedKB: nil, error: "cache is in use"))
        XCTAssertEqual(StorageProtocol.event(in: #"{"event": "error", "message": "Not selectable: nope"}"#), .error("Not selectable: nope"))
    }

    func testALineWithoutAnEventIsNothing() {
        for line in ["", "~/_DEV/MacHelm", #"{"event": "unknown"}"#, #"{"event": "result", "key": 5}"#, #"{"event": "targets""#, "{}"] {
            XCTAssertNil(StorageProtocol.event(in: line), line)
        }
    }

    func testARootRemovalIsAnsweredWithOneLine() {
        XCTAssertEqual(StorageProtocol.reply(ok: true), "{\"ok\":true}\n")
        XCTAssertEqual(StorageProtocol.reply(ok: false, error: "The helper said \"no\"\nand left"),
                       "{\"error\":\"The helper said \\\"no\\\"\\nand left\",\"ok\":false}\n")
    }

    func testTheScriptRunsThroughTheLoginShell() {
        let scan = StorageProtocol.command(shell: "/bin/zsh", script: "/Applications/MacHelm.app/Contents/Resources/cleanup-macos-dev.py")
        XCTAssertEqual(scan.executable, "/bin/zsh")
        // The script and its arguments are passed as arguments, never pasted into the command.
        XCTAssertEqual(scan.arguments, ["-l", "-i", "-c", #"exec python3 "$0" "$@""#,
                                        "/Applications/MacHelm.app/Contents/Resources/cleanup-macos-dev.py", "--app"])
        let clean = StorageProtocol.command(shell: "/bin/zsh", script: "/x/cleanup.py", select: ["go", "sim-delete-A B"])
        XCTAssertEqual(Array(clean.arguments.suffix(4)), ["/x/cleanup.py", "--app", "--select", "go,sim-delete-A B"])
    }

    // ADR 0008: a scan says when it judged idleness and by how many days; a clean passes both back.
    func testAScanNamesItsInstantKindsAndAccessAndACleanPassesTheInstantBack() {
        let line = #"{"event": "targets", "free_kb": 9, "as_of": 1792105432.25, "idle_days": 7, "targets": [{"key": "trash", "group": "cannot be restored", "kind": "", "label": "Empty the Trash", "state": "selectable", "detail": "", "size_kb": null, "projected_kb": null, "needs_sudo": false, "needs_full_disk_access": true, "default_selected": false, "last_used_at": null, "paths": [], "exclusive": ""}, {"key": "app-cache-Figma", "group": "safe", "kind": "App caches", "label": "Figma", "state": "selectable", "detail": "", "size_kb": 5, "projected_kb": 5, "needs_sudo": false, "needs_full_disk_access": false, "default_selected": true, "last_used_at": null, "paths": [], "exclusive": ""}]}"#
        guard case .targets(_, let asOf, let idleDays, let listed)? = StorageProtocol.event(in: line) else { return XCTFail("no targets") }
        XCTAssertEqual(asOf, 1_792_105_432.25)
        XCTAssertEqual(idleDays, 7)
        XCTAssertEqual(listed.map(\.kind), ["", "App caches"])
        XCTAssertEqual(listed.map(\.needsFullDiskAccess), [true, false])
        let scan = StorageProtocol.command(shell: "/bin/zsh", script: "/x/cleanup.py", idleDays: 14)
        XCTAssertEqual(Array(scan.arguments.suffix(4)), ["/x/cleanup.py", "--app", "--idle-days", "14"])
        let clean = StorageProtocol.command(shell: "/bin/zsh", script: "/x/cleanup.py", select: ["trash"], idleDays: 7, asOf: 1_792_105_432.25)
        XCTAssertEqual(Array(clean.arguments.suffix(8)),
                       ["/x/cleanup.py", "--app", "--idle-days", "7", "--as-of", "1792105432.25", "--select", "trash"])
    }

    // What a running scan or clean is doing, a few times a second (2026-10-15).
    func testProgressAndTheCurrentStepOfATargetAreRead() {
        XCTAssertEqual(StorageProtocol.event(in: #"{"event": "progress", "phase": "deleting", "done": 3, "total": 22}"#),
                       .progress(phase: "deleting", done: 3, total: 22))
        XCTAssertEqual(StorageProtocol.event(in: #"{"event": "working", "key": "codex-archived-app", "detail": "deleting chat 12 of 190"}"#),
                       .working(key: "codex-archived-app", detail: "deleting chat 12 of 190"))
        XCTAssertEqual(StorageProtocol.event(in: #"{"event": "working", "key": "go", "detail": ""}"#), .working(key: "go", detail: ""))
        XCTAssertNil(StorageProtocol.event(in: #"{"event": "progress", "phase": "deleting"}"#))
        XCTAssertNil(StorageProtocol.event(in: #"{"event": "working", "detail": "x"}"#))
    }

    // A failed target's freed_kb is what went before it failed (2026-10-15).
    func testAPartlyRemovedTargetIsReadWithWhatWentAndWhy() {
        let line = #"{"event": "result", "key": "codex-archived-app", "ok": false, "freed_kb": 512, "error": "Codex kept 1 of 3 chats.\n“Drain plans”: a chat forked from it is still there."}"#
        XCTAssertEqual(StorageProtocol.event(in: line),
                       .result(key: "codex-archived-app", ok: false, freedKB: 512,
                               error: "Codex kept 1 of 3 chats.\n“Drain plans”: a chat forked from it is still there."))
    }

    // On 2026-10-15 the summary read "17 not removed: A; B; C and 14 more.
    // Their rows say why", and the scan that followed no longer listed those
    // rows. The report keeps each one with its reason.
    func testTheReportKeepsEachTargetNotRemovedWithItsReasonInTheListsOrder() {
        let chats = StorageTarget(key: "codex-archived-app", group: "cannot be restored", kind: "Codex archived chats", label: "app: 3 chats")
        let uv = StorageTarget(key: "uv", group: safe, label: "uv cache")
        let fine = StorageTarget(key: "fine", group: safe, label: "Fine")
        let results = ["uv": StorageResult(ok: false, error: "in use by 4 uv processes; quit them and clean again"),
                       "codex-archived-app": StorageResult(ok: false, freedKB: 2_048, error: "Codex kept 1 of 3 chats.\n“Drain plans”: a chat forked from it is still there."),
                       "fine": StorageResult(ok: true, freedKB: 10)]
        let report = StorageCleanReport(reclaimedKB: 2_058, failures: 2, confirmed: [chats, uv, fine], results: results)
        XCTAssertEqual(report.notRemoved.map(\.title), ["Codex archived chats: app: 3 chats", "uv cache"])
        XCTAssertEqual(report.notRemoved.map(\.outcome), ["Partly removed, \(bytes(2_048)) freed", "Not removed"])
        XCTAssertEqual(report.notRemoved.first?.reason, "Codex kept 1 of 3 chats.\n“Drain plans”: a chat forked from it is still there.")
        XCTAssertEqual(report.reclaimed, "Reclaimed \(bytes(2_058))")
        XCTAssertEqual(report.outcome, "2 not removed or only in part; nothing else was affected.")
        let whole = StorageCleanReport(reclaimedKB: 10, failures: 1, confirmed: [uv, fine], results: results)
        XCTAssertEqual(whole.outcome, "1 not removed; nothing else was affected.")
        XCTAssertEqual(StorageCleanReport(reclaimedKB: 10, failures: 0, confirmed: [fine], results: results).outcome,
                       "Everything you checked was removed.")
        // A refused run reports no targets: the count alone.
        XCTAssertEqual(StorageCleanReport(reclaimedKB: 0, failures: 2, confirmed: [uv], results: [:]).outcome,
                       "2 did not complete; nothing else was affected.")
    }

    func testARowSaysWhatTheCleanDidToIt() {
        XCTAssertEqual(StorageResult(ok: true, freedKB: 2_048).note, "Removed: \(bytes(2_048))")
        XCTAssertEqual(StorageResult(ok: true).note, "Removed")
        XCTAssertEqual(StorageResult(ok: false, error: "in use").note, "Not removed: in use")
        XCTAssertEqual(StorageResult(ok: false, freedKB: 0, error: "in use").note, "Not removed: in use")
        XCTAssertEqual(StorageResult(ok: false, freedKB: 2_048, error: "Codex kept 1 of 3 chats.").note,
                       "Partly removed, \(bytes(2_048)) freed: Codex kept 1 of 3 chats.")
    }

    private func bytes(_ kilobytes: Int) -> String {
        Int64(kilobytes * 1_024).formatted(.byteCount(style: .file))
    }

    func testTheIdleSettingStaysBetweenOneAndNinetyDays() {
        XCTAssertEqual(StorageIdle.standard, 7)
        XCTAssertEqual([0, 1, 7, 90, 400].map(StorageIdle.clamped), [1, 1, 7, 90, 90])
    }
}

// ADR 0008: groups, the kinds inside them, and a checkbox for each.
final class StorageTreeTests: XCTestCase {
    private func row(_ key: String, _ group: String, kind: String = "", state: StorageTargetState = .selectable, projected: Int? = 10,
                     checked: Bool = false, exclusive: String = "") -> StorageTarget {
        StorageTarget(key: key, group: group, kind: kind, label: key, state: state, sizeKB: projected, projectedKB: projected,
                      defaultSelected: checked, exclusive: exclusive)
    }

    private lazy var listed = [
        row("update-telegram", safe, kind: "Update downloads", projected: 5_000, checked: true),
        row("go", safe, projected: 30, checked: true),
        row("cache-figma", safe, kind: "App caches", projected: 1_000, checked: true),
        row("cache-chrome", safe, kind: "App caches", state: .blocked, projected: 3_000),
        row("cache-slack", safe, kind: "App caches", projected: 400, checked: true),
        row("avd-delete-Old", "Android emulators", kind: "Old", projected: 4_000, exclusive: "avd:Old"),
        row("avd-wipe-Old", "Android emulators", kind: "Old", projected: 3_000, exclusive: "avd:Old"),
        row("chats-app", "cannot be restored", kind: "Codex archived chats", projected: nil)
    ]

    func testKindsSitWhereTheirFirstTargetIsListed() {
        let groups = StorageTree.groups(listed)
        XCTAssertEqual(groups.map(\.name), [safe, "Android emulators", "cannot be restored"])
        XCTAssertEqual(groups[0].entries.map(\.id), ["kind:\(safe)\u{1F}Update downloads", "target:go", "kind:\(safe)\u{1F}App caches"])
        XCTAssertEqual(groups[0].targets.map(\.key), ["update-telegram", "go", "cache-figma", "cache-chrome", "cache-slack"])
        guard case .kind(let caches) = groups[0].entries[2] else { return XCTFail("no kind") }
        XCTAssertEqual(caches.targets.map(\.key), ["cache-figma", "cache-chrome", "cache-slack"])
    }

    func testATotalCountsTreatmentsOfOneThingOnceAndSaysWhenItCannotTell() {
        let groups = StorageTree.groups(listed)
        XCTAssertEqual(StorageTree.size(of: groups[1].targets).kilobytes, 4_000)
        XCTAssertFalse(StorageTree.size(of: groups[1].targets).atLeast)
        XCTAssertTrue(StorageTree.size(of: groups[2].targets).atLeast)
        // A blocked cache counts what it occupies.
        XCTAssertEqual(StorageTree.size(of: groups[0].targets).kilobytes, 9_430)
    }

    func testAKindsCheckboxChecksWhatMayBeCheckedAndShowsSome() {
        var selection = StorageSelection()
        let caches = listed.filter { $0.kind == "App caches" }
        XCTAssertEqual(selection.state(of: caches, helperReady: true), .unchecked)
        selection.toggle("cache-figma", in: listed, helperReady: true)
        XCTAssertEqual(selection.state(of: caches, helperReady: true), .mixed)
        selection.set(true, children: caches, in: listed, helperReady: true)
        // The blocked cache stays unchecked, and "all" means all that may be checked.
        XCTAssertEqual(selection.keys, ["cache-figma", "cache-slack"])
        XCTAssertEqual(selection.state(of: caches, helperReady: true), .checked)
        selection.set(false, children: caches, in: listed, helperReady: true)
        XCTAssertEqual(selection.keys, [])
        XCTAssertEqual(selection.state(of: [listed[3]], helperReady: true), .unavailable)
    }

    func testAParentOverTreatmentsChecksOneOfThem() {
        var selection = StorageSelection()
        let avd = listed.filter { $0.kind == "Old" }
        selection.set(true, children: avd, in: listed, helperReady: true)
        XCTAssertEqual(selection.keys, ["avd-delete-Old"])
        XCTAssertEqual(selection.state(of: avd, helperReady: true), .checked)
        // The treatment that was checked stays the one.
        selection.toggle("avd-wipe-Old", in: listed, helperReady: true)
        selection.set(true, children: avd, in: listed, helperReady: true)
        XCTAssertEqual(selection.keys, ["avd-wipe-Old"])
    }

    func testAGroupsCheckboxReachesIntoItsKinds() {
        var selection = StorageSelection()
        let safeGroup = StorageTree.groups(listed)[0]
        selection.set(true, children: safeGroup.targets, in: listed, helperReady: true)
        XCTAssertEqual(selection.keys, ["update-telegram", "go", "cache-figma", "cache-slack"])
    }
}

final class StorageSelectionTests: XCTestCase {
    private let listed = [
        target("go", checked: true),
        target("derived-data", projected: 5_000),
        target("old-runtime", state: .blocked, checked: true),
        target("docker", state: .reportOnly),
        target("sim-runtime", projected: 8_000, root: true, checked: true, paths: ["/System/Library/AssetsV2/x.asset", dyld]),
        target("sim-delete-A", projected: 300, exclusive: "sim-A"),
        target("sim-erase-A", projected: nil, exclusive: "sim-A"),
        target("sim-delete-B", projected: 200, exclusive: "sim-B")
    ]

    func testTheScriptsOwnDefaultsAreChecked() {
        XCTAssertEqual(StorageSelection(defaultsOf: listed, helperReady: true).keys, ["go", "sim-runtime"])
    }

    func testWithoutTheHelperARootTargetIsNotCheckedAndCannotBe() {
        var selection = StorageSelection(defaultsOf: listed, helperReady: false)
        XCTAssertEqual(selection.keys, ["go"])
        selection.toggle("sim-runtime", in: listed, helperReady: false)
        XCTAssertEqual(selection.keys, ["go"])
        XCTAssertTrue(StorageSelection.needsTerminal(listed[4], helperReady: false))
        XCTAssertFalse(StorageSelection.needsTerminal(listed[4], helperReady: true))
        XCTAssertFalse(StorageSelection.needsTerminal(listed[0], helperReady: false))
    }

    func testARootTargetOutsideTheHelpersFoldersNeedsATerminalEvenWithTheHelper() {
        let elsewhere = target("legacy", root: true, paths: ["/System/Library/AssetsV2/y.asset"])
        XCTAssertFalse(StorageSelection.canSelect(elsewhere, helperReady: true))
        XCTAssertTrue(StorageSelection.needsTerminal(elsewhere, helperReady: true))
        let tooDeep = target("deep", root: true, paths: [dyld + "/sub"])
        XCTAssertFalse(StorageSelection.canSelect(tooDeep, helperReady: true))
        // The helper cleans the dyld folder only (L9): a runtime's volume is not its to remove.
        let volume = target("volume", root: true, paths: ["/Library/Developer/CoreSimulator/Volumes/iOS_22A"])
        XCTAssertFalse(StorageSelection.canSelect(volume, helperReady: true))
        XCTAssertEqual(StorageRoot.helper, [StorageRoot("/Library/Developer/CoreSimulator/Caches/dyld", depth: 2)])
        let wholeBuild = target("stale", root: true, paths: ["/Library/Developer/CoreSimulator/Caches/dyld/25A1"])
        XCTAssertTrue(StorageSelection.canSelect(wholeBuild, helperReady: true))
    }

    func testABlockedOrReportOnlyTargetCannotBeChecked() {
        var selection = StorageSelection()
        for key in ["old-runtime", "docker", "missing"] { selection.toggle(key, in: listed, helperReady: true) }
        XCTAssertEqual(selection.keys, [])
    }

    func testACheckTogglesAndChoosingOneTreatmentClearsTheOther() {
        var selection = StorageSelection()
        selection.toggle("sim-delete-A", in: listed, helperReady: true)
        selection.toggle("sim-delete-B", in: listed, helperReady: true)
        selection.toggle("sim-erase-A", in: listed, helperReady: true)
        XCTAssertEqual(selection.keys, ["sim-erase-A", "sim-delete-B"])
        selection.toggle("sim-erase-A", in: listed, helperReady: true)
        XCTAssertEqual(selection.keys, ["sim-delete-B"])
    }

    func testTheTotalIsWhatTheCheckedTargetsFreeAndSaysWhenOneCannotTell() {
        var selection = StorageSelection(defaultsOf: listed, helperReady: true)
        XCTAssertEqual(selection.total(in: listed).kilobytes, 9_000)
        XCTAssertFalse(selection.total(in: listed).atLeast)
        selection.toggle("sim-erase-A", in: listed, helperReady: true)
        XCTAssertEqual(selection.total(in: listed).kilobytes, 9_000)
        XCTAssertTrue(selection.total(in: listed).atLeast)
    }

    func testWhatIsChosenIsInTheListsOrderAndOnlyWhatIsStillListed() {
        var selection = StorageSelection(defaultsOf: listed, helperReady: true)
        selection.toggle("derived-data", in: listed, helperReady: true)
        XCTAssertEqual(selection.chosen(in: listed).map(\.key), ["go", "derived-data", "sim-runtime"])
        // After a new scan a target that is gone, or blocked now, is not passed on.
        let later = [target("derived-data", projected: 5_000), target("go", state: .blocked)]
        XCTAssertEqual(selection.chosen(in: later).map(\.key), ["derived-data"])
    }
}

// Select All and Select None, which the owner asked for on 2026-10-12.
final class StorageSelectAllTests: XCTestCase {
    private let listed = [
        target("go", checked: true),
        target("derived-data", projected: 5_000),
        target("old-runtime", state: .blocked, checked: true),
        target("docker", state: .reportOnly),
        target("sim-runtime", projected: 8_000, root: true, checked: true, paths: ["/System/Library/AssetsV2/x.asset", dyld]),
        target("sim-delete-A", projected: 300, exclusive: "sim-A"),
        target("sim-erase-A", projected: nil, exclusive: "sim-A"),
        target("sim-delete-B", projected: 200, exclusive: "sim-B")
    ]

    func testSelectAllChecksEverythingTheOwnerMayCheck() {
        var selection = StorageSelection()
        selection.selectAll(in: listed, helperReady: true)
        // Not what is blocked or only reported, and one treatment of each simulator.
        XCTAssertEqual(selection.keys, ["go", "derived-data", "sim-runtime", "sim-delete-A", "sim-delete-B"])
        XCTAssertEqual(selection.chosen(in: listed).map(\.key), ["go", "derived-data", "sim-runtime", "sim-delete-A", "sim-delete-B"])
    }

    func testWithoutTheHelperSelectAllLeavesARootTargetOut() {
        var selection = StorageSelection()
        selection.selectAll(in: listed, helperReady: false)
        XCTAssertEqual(selection.keys, ["go", "derived-data", "sim-delete-A", "sim-delete-B"])
    }

    func testSelectAllKeepsTheTreatmentThatWasChecked() {
        var selection = StorageSelection()
        selection.toggle("sim-erase-A", in: listed, helperReady: true)
        selection.selectAll(in: listed, helperReady: true)
        XCTAssertEqual(selection.keys, ["go", "derived-data", "sim-runtime", "sim-erase-A", "sim-delete-B"])
    }

    func testOfTwoTreatmentsSelectAllTakesTheScriptsOwnChoiceElseTheFirst() {
        let simulators = [target("sim-delete-C", exclusive: "sim-C"), target("sim-erase-C", checked: true, exclusive: "sim-C"),
                          target("sim-delete-D", state: .blocked, exclusive: "sim-D"), target("sim-erase-D", exclusive: "sim-D")]
        var selection = StorageSelection()
        selection.selectAll(in: simulators, helperReady: true)
        // The script's choice for C; for D the first that may be checked.
        XCTAssertEqual(selection.keys, ["sim-erase-C", "sim-erase-D"])
    }

    func testSelectNoneClearsEveryCheck() {
        var selection = StorageSelection(defaultsOf: listed, helperReady: true)
        selection.toggle("derived-data", in: listed, helperReady: true)
        selection.selectNone()
        XCTAssertEqual(selection.keys, [])
        XCTAssertEqual(selection.total(in: listed).kilobytes, 0)
    }

    func testWhetherSelectAllWouldChangeAnything() {
        var selection = StorageSelection(defaultsOf: listed, helperReady: true)
        XCTAssertFalse(selection.holdsAll(in: listed, helperReady: true))
        selection.selectAll(in: listed, helperReady: true)
        XCTAssertTrue(selection.holdsAll(in: listed, helperReady: true))
        // The other treatment of a simulator is as much "all" as the first.
        selection.toggle("sim-erase-A", in: listed, helperReady: true)
        XCTAssertTrue(selection.holdsAll(in: listed, helperReady: true))
        selection.toggle("go", in: listed, helperReady: true)
        XCTAssertFalse(selection.holdsAll(in: listed, helperReady: true))
        // A list with nothing to check holds all of it.
        XCTAssertTrue(StorageSelection().holdsAll(in: [target("docker", state: .reportOnly)], helperReady: true))
    }
}

final class RootRemovalPolicyTests: XCTestCase {
    private let runtime = target("sim-runtime", root: true, paths: ["/System/Library/AssetsV2/x.asset", dyld])
    private let cache = target("go", paths: ["/Users/owner/Library/Caches/go-build"])
    private let other = target("sim-dyld-stale", root: true, paths: ["/Library/Developer/CoreSimulator/Caches/dyld/25A1"])

    // Q33: a removal of anything not listed and confirmed is critical.
    func testOnlyAPathListedForAConfirmedRootTargetIsPassedOn() {
        XCTAssertTrue(RootRemovalPolicy.allows(dyld, confirmed: [runtime, cache]))
        // Listed for a root target the owner did not confirm.
        XCTAssertFalse(RootRemovalPolicy.allows("/Library/Developer/CoreSimulator/Caches/dyld/25A1", confirmed: [runtime, cache]))
        XCTAssertTrue(RootRemovalPolicy.allows("/Library/Developer/CoreSimulator/Caches/dyld/25A1", confirmed: [runtime, other]))
        // Confirmed, but not a root target: the script removes that itself and has no reason to ask.
        XCTAssertFalse(RootRemovalPolicy.allows("/Users/owner/Library/Caches/go-build", confirmed: [runtime, cache]))
    }

    func testAPathNearAListedOneIsNotTheListedOne() {
        for path in [dyld + "/", dyld + "/sub", "/Library/Developer/CoreSimulator/Caches/dyld/25G83", dyld + "/../other",
                     "/Library/Developer/CoreSimulator/Caches/dyld", "", "/"] {
            XCTAssertFalse(RootRemovalPolicy.allows(path, confirmed: [runtime]), path)
        }
        XCTAssertFalse(RootRemovalPolicy.allows(dyld, confirmed: []))
    }
}
