import ActivityCore
import Foundation
import XCTest
@testable import ClaudeCore

final class ClaudeDiscoveryTests: XCTestCase {
    private let first = UUID(uuidString: "7520ec9c-2023-4561-9833-1d4f7ff875ac")!
    private let second = UUID(uuidString: "932a1670-9656-4045-a086-994aa44df524")!
    private let host = "local_9ead3883-563f-420c-beb9-a1187e7960d6"

    func testTwoDesktopConversationsInOneProjectKeepTheirOwnJobsAndWorkers() {
        let shellA = output(first, "bi3z9n1pt")
        let shellB = output(second, "b2kzwgi33")
        let alpha = root(first, pid: 200, started: 5, title: "First", host: host)
        let beta = root(second, pid: 300, started: 10, title: "Second")
        var frame = ClaudeDiscoveryFrame()
        frame.inventory.value = [alpha.0.record, beta.0.record]
        frame.registrations.value = [alpha.0, beta.0]
        frame.processes.value = [alpha.1, beta.1, process(201, parent: 200, started: 6, outputs: [shellA]),
                                 process(202, parent: 201, started: 7), process(301, parent: 300, started: 11, outputs: [shellB])]
        frame.taskRecords.value = [shellA: 7, shellB: 12]
        var discovery = ClaudeReconciler()
        let conversations = discovery.update(frame).conversations
        XCTAssertEqual(conversations.map(\.title), ["First", "Second"])
        XCTAssertEqual(conversations.map(\.path), ["/tmp/project", "/tmp/project"])
        XCTAssertEqual(conversations.map { $0.jobs.flatMap(\.processes).map(\.id.pid) }, [[201, 202], [301]])
        XCTAssertEqual(conversations.first?.location, .desktop(ClaudeDesktopID(host)))

        frame.processes.value.removeAll { [201, 202].contains($0.identity.pid) }
        XCTAssertEqual(discovery.update(frame).conversations.map(\.title), ["Second"])
    }

    func testInventoryKeepsPIDLessWaitingSessionAndSeparateAttachID() throws {
        let payload = """
        [{"id":"14bc06df","kind":"background","state":"blocked","sessionId":"\(first)","name":"Approval"},
         {"id":"23ac81e0","kind":"background","state":"working"},
         {"kind":"interactive","sessionId":"\(second)","status":"waiting","waitingFor":"permission prompt"}]
        """
        var frame = ClaudeDiscoveryFrame()
        frame.inventory = ClaudeDiscovery.decodeInventory(Data(payload.utf8))
        var discovery = ClaudeReconciler()
        let snapshot = discovery.update(frame)
        XCTAssertEqual(snapshot.inventory, .complete)
        let wait = try XCTUnwrap(snapshot.conversations.first { $0.sessionID == first })
        XCTAssertEqual(wait.activity, .needsInput)
        XCTAssertNil(wait.worker)
        XCTAssertEqual(wait.location, .detached(try XCTUnwrap(ClaudeAttachID("14bc06df"))))
        XCTAssertEqual(snapshot.conversations.first { $0.sessionID == second }?.waitingFor, "permission prompt")
        XCTAssertTrue(snapshot.conversations.contains { $0.id == .detached(ClaudeAttachID("23ac81e0")!) })
    }

    func testStoppedAndFinishedBackgroundSessionsRequireALiveWorker() {
        var frame = ClaudeDiscoveryFrame()
        frame.inventory.value = [ClaudeSessionRecord(id: "14bc06df", sessionId: first.uuidString, kind: "background", state: "done"),
                                 ClaudeSessionRecord(id: "23ac81e0", sessionId: second.uuidString, kind: "background", state: "stopped")]
        var discovery = ClaudeReconciler()
        XCTAssertTrue(discovery.update(frame).conversations.isEmpty)
        let live = process(220, parent: 1, started: 7)
        frame.processes.value = [live]
        frame.inventory.value[0].pid = live.identity.pid
        frame.inventory.value[0].startedAt = 7_020
        XCTAssertEqual(discovery.update(frame).conversations.first?.worker, live.identity)
    }

    func testDetachedRegistrationCanSupplyWorkerAndAttachIDWhenInventoryIsUnavailable() {
        let root = process(200, parent: 1, started: 5)
        let record = ClaudeSessionRecord(jobId: "14bc06df", sessionId: first.uuidString, pid: 200, kind: "bg", status: "idle")
        var frame = ClaudeDiscoveryFrame(inventory: .init(value: [], quality: .unavailable))
        frame.processes.value = [root]
        frame.registrations.value = [ClaudeRegistration(record: record, worker: root.identity, terminal: nil)]
        var discovery = ClaudeReconciler()
        let snapshot = discovery.update(frame)
        XCTAssertEqual(snapshot.conversations.first?.worker, root.identity)
        XCTAssertEqual(snapshot.conversations.first?.location, .detached(ClaudeAttachID("14bc06df")!))
    }

    func testSelectedProfileKeepsDesktopAndOmitsOtherCLIRegistrationsAndProcesses() {
        let desktop = root(first, pid: 200, started: 5, title: "Desktop", host: host)
        let work = process(300, parent: 1, started: 10)
        let other = process(400, parent: 1, started: 20)
        let selected = ClaudeSessionRecord(id: "14bc06df", sessionId: second.uuidString, pid: 300,
                                           kind: "background", state: "blocked", name: "Work")
        let registrations = [
            desktop.0,
            ClaudeRegistration(record: selected, worker: work.identity, terminal: nil),
            ClaudeRegistration(record: .init(jobId: "23ac81e0", sessionId: UUID().uuidString, pid: 400,
                                              kind: "bg", status: "waiting", name: "Other profile"), worker: other.identity, terminal: nil)
        ]
        let shell = output(first, "b055a1l6o")
        var frame = ClaudeDiscoveryFrame(restrictToKnownConversations: true)
        frame.inventory.value = [selected]
        frame.registrations.value = ClaudeDiscovery.registrationsInScope(registrations, cliInventory: [selected], desktopOnly: false)
        frame.processes.value = [desktop.1, work, other, process(201, parent: 200, started: 6, outputs: [shell]),
                                 process(401, parent: 1, started: 22, marker: UUID())]
        frame.taskRecords.value = [shell: 7]
        var discovery = ClaudeReconciler()
        let snapshot = discovery.update(frame)
        XCTAssertEqual(snapshot.conversations.map(\.title), ["Work", "Desktop"])
        XCTAssertEqual(snapshot.conversations.last?.location, .desktop(ClaudeDesktopID(host)))

        frame.inventory.value = []
        frame.registrations.value = ClaudeDiscovery.registrationsInScope(registrations, cliInventory: [], desktopOnly: false)
        XCTAssertEqual(discovery.update(frame).conversations.map(\.title), ["Desktop"])
    }

    func testLiveAndHistoricalEvidenceDoNotCrossProcessGenerations() {
        let shell = output(first, "b7607rzh4")
        let alpha = root(first, pid: 200, started: 5, title: "First", host: host)
        let original = process(201, parent: 200, started: 6, outputs: [shell])
        var frame = ClaudeDiscoveryFrame()
        frame.registrations.value = [alpha.0]
        frame.processes.value = [alpha.1, original]
        frame.taskRecords.value = [shell: 6]
        var discovery = ClaudeReconciler()
        XCTAssertEqual(discovery.update(frame).conversations.first?.jobs.count, 1)

        // A registration on a reused PID and its old receipt cannot describe a new process.
        frame.processes.value = [process(200, parent: 1, started: 20), process(201, parent: 200, started: 21, outputs: [shell])]
        XCTAssertTrue(discovery.update(frame).conversations.isEmpty)
        XCTAssertTrue(discovery.active.isEmpty)
    }

    func testSurvivingIndependentProcessRetainsOwnerUntilItEnds() throws {
        let shell = output(first, "b055a1l6o")
        let alpha = root(first, pid: 200, started: 5, title: "Known owner")
        var frame = ClaudeDiscoveryFrame()
        frame.registrations.value = [alpha.0]
        frame.processes.value = [alpha.1, process(203, parent: 200, started: 7, outputs: [shell])]
        frame.taskRecords.value = [shell: 7]
        var discovery = ClaudeReconciler()
        _ = discovery.update(frame)

        frame.registrations.value = []
        frame.processes.value = [process(203, parent: 1, started: 7)]
        frame.taskRecords.value = [:]
        let closed = try XCTUnwrap(discovery.update(frame).conversations.first)
        XCTAssertEqual(closed.title, "Known owner")
        XCTAssertEqual(closed.activity, .closed)
        XCTAssertEqual(closed.jobs.first?.processes.map(\.id.pid), [203])
        XCTAssertNil(closed.location)

        frame.processes.value = [process(203, parent: 1, started: 23)]
        XCTAssertTrue(discovery.update(frame).conversations.isEmpty)
    }

    func testConflictingMarkerAndDescriptorHaveUnknownOwner() {
        let shell = output(first, "b1ev9qfoo")
        let alpha = root(first, pid: 200, started: 5, title: "First")
        let beta = root(second, pid: 300, started: 8, title: "Second")
        var frame = ClaudeDiscoveryFrame()
        frame.registrations.value = [alpha.0, beta.0]
        frame.processes.value = [alpha.1, beta.1, process(201, parent: 200, started: 6, marker: second, outputs: [shell]),
                                 process(401, parent: 1, started: 22, marker: UUID())]
        frame.taskRecords.value = [shell: 7]
        var discovery = ClaudeReconciler()
        let snapshot = discovery.update(frame)
        XCTAssertEqual(snapshot.conversations.map(\.id), [.unknown])
        XCTAssertEqual(snapshot.conversations.first?.jobs.flatMap(\.processes).map(\.id.pid), [201, 401])
    }

    func testForegroundWritersAndHistoricalReceiptsAloneAreNotJobs() {
        let live = output(first, "b1ev9qfoo")
        let historical = output(first, "b7607rzh4")
        let alpha = root(first, pid: 200, started: 5, title: "First")
        var frame = ClaudeDiscoveryFrame()
        frame.registrations.value = [alpha.0]
        frame.processes.value = [alpha.1, process(201, parent: 200, started: 6, marker: first, outputs: [live])]
        frame.taskRecords.value = [historical: 6]
        var discovery = ClaudeReconciler()
        XCTAssertTrue(discovery.update(frame).conversations.isEmpty)
    }

    func testPartialInventoryStillShowsVerifiedWorkAndFailedProcessReadKeepsItStale() {
        let alpha = root(first, pid: 200, started: 5, title: "First", host: host)
        let shell = output(first, "b055a1l6o")
        let partial = """
        [{"id":"14bc06df","kind":"background","state":"blocked","name":"Needs me"},{"pid":"bad"}]
        """
        var frame = ClaudeDiscoveryFrame()
        frame.inventory = ClaudeDiscovery.decodeInventory(Data(partial.utf8))
        frame.registrations.value = [alpha.0]
        frame.processes.value = [alpha.1, process(203, parent: 200, started: 7, outputs: [shell])]
        frame.taskRecords.value = [shell: 7]
        var discovery = ClaudeReconciler()
        let available = discovery.update(frame)
        XCTAssertEqual(available.inventory, .partial)
        XCTAssertEqual(available.conversations.map(\.title), ["Needs me", "First"])

        frame = ClaudeDiscoveryFrame(inventory: .init(value: [], quality: .unavailable),
                                      processes: .init(value: [], quality: .unavailable))
        let stale = discovery.update(frame)
        XCTAssertEqual(stale.processes, .unavailable)
        XCTAssertEqual(stale.conversations.map(\.title), ["Needs me", "First"])
        XCTAssertTrue(stale.conversations.allSatisfy { $0.location == nil })
        XCTAssertEqual(discovery.update(ClaudeDiscoveryFrame()), ClaudeSnapshot())
    }

    func testReceiptDecodingOnlyUsesStructuredMatchingSessionAndTask() {
        let shell = output(first, "b055a1l6o")
        let transcript = """
        {"type":"user","sessionId":"\(second)","timestamp":"2026-11-16T03:00:00.000Z","toolUseResult":{"backgroundTaskId":"b055a1l6o"}}
        {"type":"user","sessionId":"\(first)","timestamp":"2026-11-16T03:10:00.000Z","toolUseResult":{"agentId":"b055a1l6o"}}
        {"type":"user","sessionId":"\(first)","timestamp":"2026-11-16T03:20:00.000Z","toolUseResult":{"backgroundTaskId":"b055a1l6o"}}
        """
        let receipts = ClaudeTaskRecords.receipts(in: Data(transcript.utf8), for: [shell])
        XCTAssertEqual(receipts, [shell: 1_794_799_200])
    }

    func testInvalidActionIdentifiersAndForeignOutputPathsAreRejected() {
        XCTAssertNil(ClaudeAttachID("--resume"))
        XCTAssertNil(ClaudeDesktopID(first.uuidString))
        XCTAssertNil(ClaudeDesktopID(host + "?resume=test"))
        let roots: Set<String> = ["/private/tmp/claude-501"]
        let suffix = "\(first)/tasks/b055a1l6o.output"
        XCTAssertEqual(ClaudeTaskOutput(path: "/private/tmp/claude-501/-tmp-project/\(suffix)", roots: roots), output(first, "b055a1l6o"))
        XCTAssertNil(ClaudeTaskOutput(path: "/private/tmp/other/-tmp-project/\(suffix)", roots: roots))
    }

    func testCommandTimeoutIncludesTimeAfterStandardOutputCloses() {
        let start = ProcessInfo.processInfo.systemUptime
        let result = ClaudeCommand.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec >&-; exec /bin/sleep 3"], timeout: 0.1)
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testInstallationHonorsConfiguredPathsAndBothDarwinTemporaryPathForms() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let installation = ClaudeInstallation(environment: ["CLAUDE_CONFIG_DIR": "~/example claude", "CLAUDE_CODE_TMPDIR": "/tmp/custom"], home: home)
        XCTAssertEqual(installation.configDirectory.path, "/Users/example/example claude")
        XCTAssertEqual(installation.environment["CLAUDE_CONFIG_DIR"], installation.configDirectory.path)
        XCTAssertTrue(installation.outputRoots.contains("/private/tmp/claude-\(getuid())"))
        XCTAssertTrue(installation.outputRoots.contains("/tmp/claude-\(getuid())"))
        XCTAssertTrue(installation.outputRoots.contains("/tmp/custom/claude-\(getuid())"))
    }

    private func output(_ id: UUID, _ task: String) -> ClaudeTaskOutput {
        ClaudeTaskOutput(sessionID: id, projectKey: "-tmp-project", taskID: task)
    }

    private func root(_ session: UUID, pid: Int32, started: UInt64, title: String, host: String? = nil)
        -> (ClaudeRegistration, ClaudeObservedProcess) {
        let worker = process(pid, parent: 1, started: started)
        let record = ClaudeSessionRecord(sessionId: session.uuidString, pid: pid, kind: "interactive", status: "idle",
                                         name: title, cwd: "/tmp/project", entrypoint: "claude-desktop", hostSessionId: host)
        return (ClaudeRegistration(record: record, worker: worker.identity, terminal: nil), worker)
    }

    private func process(_ pid: Int32, parent: Int32, started: UInt64, marker: UUID? = nil, outputs: Set<ClaudeTaskOutput> = [])
        -> ClaudeObservedProcess {
        ClaudeObservedProcess(identity: ProcessIdentity(pid: pid, startedAt: started), parent: parent, name: "sleep",
                              startedAt: TimeInterval(started), sessionMarker: marker, outputs: outputs)
    }
}
