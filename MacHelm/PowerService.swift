import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt
import Security
import ServiceManagement

// Reading the timers needs no root; `pmset -g` reads the same way.
@_silgen_name("IOPMCopyPMPreferences") private func IOPMCopyPMPreferences() -> Unmanaged<CFMutableDictionary>?

// MacHelm's side of the toolkit helper (ADR 0003). One connection, kept
// open while stay-awake is held: the helper clears the hold when it drops.
// Otherwise it is open for as long as a request waits for its reply, and
// closed after, so that the helper can leave.
final class ToolkitHelperClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    // Counts the connections made, so that a callback knows whether it speaks for the current one.
    private var made = 0
    private var waiting = 0
    private var held = false
    // The connection was lost while it was open; whatever was held is gone.
    var onLost: (@Sendable () -> Void)?

    // The team this app is signed by; nil for an ad-hoc build, which the helper would refuse anyway.
    static let team: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return team
    }()

    private func proxy(_ failed: @escaping () -> Void) -> ToolkitHelperXPC? {
        lock.lock(); defer { lock.unlock() }
        if connection == nil, let team = Self.team {
            let made = NSXPCConnection(machServiceName: ToolkitHelperIdentity.helper, options: .privileged)
            made.remoteObjectInterface = NSXPCInterface(with: ToolkitHelperXPC.self)
            // Only the helper of this app's own team is talked to.
            made.setCodeSigningRequirement(
                "anchor apple generic and identifier \"\(ToolkitHelperIdentity.helper)\" and certificate leaf[subject.OU] = \"\(team)\"")
            self.made += 1
            let mine = self.made
            // A dropped connection's callback may come late. It closes its own
            // connection only, never a newer one that has taken its place.
            let lost: () -> Void = { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let dropped = self.made == mine ? self.connection : nil
                if dropped != nil { self.connection = nil }
                self.lock.unlock()
                guard let dropped else { return }
                dropped.invalidationHandler = nil
                dropped.interruptionHandler = nil
                dropped.invalidate()
                self.onLost?()
            }
            made.interruptionHandler = lost
            made.invalidationHandler = lost
            made.resume()
            connection = made
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in failed() } as? ToolkitHelperXPC
    }

    // nil when the helper did not answer.
    private func ask(_ request: @escaping (ToolkitHelperXPC, @escaping (Data) -> Void) -> Void,
                     completion: @escaping @Sendable (ToolkitHelperReply?) -> Void) {
        lock.lock()
        waiting += 1
        lock.unlock()
        // The error handler and the reply cannot both run, but either may come late: only the first counts.
        let once = Once { [weak self] reply in
            completion(reply)
            self?.answered()
        }
        guard let proxy = proxy({ once.call(nil) }) else { return once.call(nil) }
        request(proxy) { once.call(ToolkitHelperReply.decoded($0)) }
    }

    private func answered() {
        lock.lock(); defer { lock.unlock() }
        waiting -= 1
        closeIfIdle()
    }

    // Stay-awake is held over the connection, or no longer. Without a hold the
    // connection closes once nothing waits for a reply, a root removal's included.
    func setHeld(_ held: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.held = held
        closeIfIdle()
    }

    // Under the lock. A request counts itself as waiting under the same lock
    // before it takes the connection, so none can start between the decision
    // that nothing waits and the close.
    private func closeIfIdle() {
        guard waiting == 0, !held else { return }
        drop()
    }

    // Under the lock. The handlers go first, so closing calls nothing back.
    private func drop() {
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
    }

    func powerState(_ completion: @escaping @Sendable (ToolkitHelperReply?) -> Void) {
        ask({ $0.powerState(protocolVersion: ToolkitHelperIdentity.protocolVersion, reply: $1) }, completion: completion)
    }

    func holdStayAwake(_ hold: Bool, completion: @escaping @Sendable (ToolkitHelperReply?) -> Void) {
        ask({ $0.holdStayAwake(hold, reply: $1) }, completion: completion)
    }

    func setSleepTimer(_ timer: SleepTimer, minutes: Int, completion: @escaping @Sendable (ToolkitHelperReply?) -> Void) {
        ask({ $0.setSleepTimer(timer.rawValue, minutes: minutes, reply: $1) }, completion: completion)
    }

    func removeDirectory(atPath path: String, completion: @escaping @Sendable (ToolkitHelperReply?) -> Void) {
        ask({ $0.removeDirectory(atPath: path, reply: $1) }, completion: completion)
    }

    // Nothing is held and nothing waits: the helper may exit.
    func close() {
        lock.lock(); defer { lock.unlock() }
        drop()
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (ToolkitHelperReply?) -> Void)?

    init(_ completion: @escaping @Sendable (ToolkitHelperReply?) -> Void) {
        self.completion = completion
    }

    func call(_ reply: ToolkitHelperReply?) {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?(reply)
    }
}

// Keep Awake, the battery level and the four sleep timers.
@MainActor
final class PowerService: ObservableObject {
    // The owner's last choice (Q20): it starts as it was left.
    @Published private(set) var keepAwakeOn: Bool
    // What is in force now.
    @Published private(set) var status: KeepAwakeStatus = .off
    @Published var batteryLevel: Int {
        didSet {
            guard batteryLevel != oldValue else { return }
            UserDefaults.standard.set(batteryLevel, forKey: Self.levelKey)
            evaluate()
        }
    }
    @Published private(set) var timers = SleepTimers()
    @Published private(set) var helper: ToolkitHelperState = .notSetUp
    @Published private(set) var onBattery = false
    // In percent; nil for a Mac without a battery.
    @Published private(set) var charge: Int?
    // Why the latest change did not take.
    @Published private(set) var notice: String?

    private static let onKey = "KeepAwakeOn"
    private static let levelKey = "KeepAwakeBatteryLevel"

    let client = ToolkitHelperClient()
    private let service = SMAppService.daemon(plistName: ToolkitHelperIdentity.plist)
    private var assertion: IOPMAssertionID = 0
    // What the helper was last asked to hold, and whether it confirmed.
    private var holdAsked = false
    private var holdConfirmed = false
    // Counts the requests to hold or release, so that only the latest one's reply is acted on.
    private var holdRequest = 0
    // Counts the later attempts, so that only the latest one asks again.
    private var retry = 0
    private var source: CFRunLoopSource?
    private var observers: [NSObjectProtocol] = []

    init() {
        let defaults = UserDefaults.standard
        keepAwakeOn = defaults.bool(forKey: Self.onKey)
        let saved = defaults.integer(forKey: Self.levelKey)
        batteryLevel = KeepAwakePolicy.levels.contains(saved) ? saved : KeepAwakePolicy.defaultLevel
        client.onLost = { [weak self] in
            Task { @MainActor in self?.helperLost() }
        }
        watchPowerSource()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        })
        update()
    }

    // MARK: State

    // Reads the helper's registration, the power source and the timers, and
    // puts in force what the switch asks for.
    func refresh() {
        update()
    }

    private func update() {
        readHelper()
        readPowerSource()
        readTimers()
        evaluate()
    }

    // The registration alone; Keep Awake is not touched.
    func readHelper() {
        let registration: ToolkitHelperRegistration
        switch service.status {
        case .enabled: registration = .enabled
        case .requiresApproval: registration = .requiresApproval
        case .notRegistered: registration = .notRegistered
        case .notFound: registration = .notFound
        @unknown default: registration = .notRegistered
        }
        helper = .reading(registration, signed: ToolkitHelperClient.team != nil, bundled: Self.helperBundled)
    }

    // The helper and its launch daemon definition, as the app holds them.
    private static var helperBundled: Bool {
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents/Library")
        return FileManager.default.fileExists(atPath: contents.appendingPathComponent("HelperTools/ToolkitHelper").path)
            && FileManager.default.fileExists(atPath: contents.appendingPathComponent("LaunchDaemons/" + ToolkitHelperIdentity.plist).path)
    }

    private func watchPowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let service = Unmanaged<PowerService>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                service.readPowerSource()
                service.evaluate()
            }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
    }

    private func readPowerSource() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        onBattery = (IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String) == kIOPMBatteryPowerKey
        var read: Int?
        for source in IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef] {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int, let full = description[kIOPSMaxCapacityKey] as? Int,
                  full > 0 else { continue }
            read = current * 100 / full
        }
        charge = read
    }

    private func readTimers() {
        timers = SleepTimers(preferences: (IOPMCopyPMPreferences()?.takeRetainedValue() as? [String: Any]) ?? [:])
    }

    // MARK: Keep Awake

    func setKeepAwake(_ on: Bool) {
        guard on != keepAwakeOn else { return }
        keepAwakeOn = on
        UserDefaults.standard.set(on, forKey: Self.onKey)
        notice = nil
        // The owner's own press asks the helper afresh, whatever failed before.
        if on, holdAsked, !holdConfirmed { holdAsked = false }
        refresh()
    }

    // Puts in force what the policy says for the state the Mac is in now.
    private func evaluate() {
        let effect = KeepAwakePolicy.effect(on: keepAwakeOn, onBattery: onBattery, charge: charge, level: batteryLevel,
                                            helperAvailable: helper == .ready)
        setAssertion(effect.preventsIdleSleep)
        if effect.holdsStayAwake != holdAsked {
            holdAsked = effect.holdsStayAwake
            holdConfirmed = false
            let asked = holdAsked
            holdRequest += 1
            let request = holdRequest
            if asked { client.setHeld(true) }
            client.holdStayAwake(asked) { [weak self] reply in
                Task { @MainActor in self?.held(request, asked, reply) }
            }
        }
        // Until the helper confirms, only the idle assertion is in force.
        status = effect.status == .on && !holdConfirmed ? .idleOnly : effect.status
    }

    // The reply to an earlier request says nothing about what is wanted now:
    // on, off and on again in quick succession must end as the last one says.
    private func held(_ request: Int, _ asked: Bool, _ reply: ToolkitHelperReply?) {
        guard request == holdRequest, asked == holdAsked else { return }
        if asked {
            holdConfirmed = reply?.stayAwakeHeld == true && reply?.error == nil
            if holdConfirmed {
                // What failed before has been put right.
                notice = nil
            } else {
                notice = reply?.error ?? "The toolkit helper did not answer. The Mac will still sleep when the lid is closed."
                client.setHeld(false)
                askAgainLater()
            }
        } else {
            if let error = reply?.error { notice = error }
            client.setHeld(false)
        }
        evaluate()
    }

    // The helper restarted or its connection dropped: it has cleared the hold.
    private func helperLost() {
        guard holdAsked else { return }
        holdConfirmed = false
        evaluate()
        askAgainLater()
    }

    // A hold that failed stays asked for, so that nothing asks for it again
    // at once: a helper that keeps failing must not be asked in a loop. Half
    // a minute later it is tried once more, if Keep Awake still wants it.
    private func askAgainLater() {
        retry += 1
        let attempt = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, attempt == self.retry, self.holdAsked, !self.holdConfirmed else { return }
            self.holdAsked = false
            self.update()
        }
    }

    private func setAssertion(_ on: Bool) {
        if on, assertion == 0 {
            var made: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "MacHelm Keep Awake" as CFString, &made) == kIOReturnSuccess {
                assertion = made
            }
        } else if !on, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    // MARK: Sleep timers

    // Q33: the timer is written with the value chosen, and read back.
    func setTimer(_ timer: SleepTimer, minutes: Int) {
        guard helper == .ready, timers.minutes[timer] != minutes else { return }
        notice = nil
        client.setSleepTimer(timer, minutes: minutes) { [weak self] reply in
            Task { @MainActor in
                guard let self else { return }
                if reply?.error != nil || reply == nil {
                    self.notice = reply?.error ?? "The toolkit helper did not answer. The timer is unchanged."
                } else {
                    self.notice = nil
                }
                self.readTimers()
            }
        }
    }

    // MARK: The helper

    func setUpHelper() {
        notice = nil
        do {
            if service.status == .notRegistered || service.status == .notFound { try service.register() }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            } else {
                notice = "The toolkit helper could not be set up: \(error.localizedDescription)"
            }
        }
        refresh()
    }

    func openHelperSettings() { SMAppService.openSystemSettingsLoginItems() }

    // What it holds is released first; removing it then leaves nothing set.
    func removeHelper() {
        notice = nil
        let unregister: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.client.close()
                do { try await self.service.unregister() } catch {
                    self.notice = "The toolkit helper could not be removed: \(error.localizedDescription)"
                }
                self.refresh()
            }
        }
        client.setHeld(false)
        guard holdAsked else { return unregister() }
        holdAsked = false
        holdConfirmed = false
        client.holdStayAwake(false) { _ in unregister() }
    }

    // MARK: Quit

    // Quit MacHelm ends Keep Awake's hold; the switch stays saved. Should
    // the helper not answer, it clears the hold itself when the app is gone.
    func releaseForQuit(completion: @escaping @Sendable () -> Void) {
        setAssertion(false)
        guard holdAsked else { return completion() }
        holdAsked = false
        let once = Once { _ in completion() }
        client.holdStayAwake(false) { once.call($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { once.call(nil) }
    }
}
