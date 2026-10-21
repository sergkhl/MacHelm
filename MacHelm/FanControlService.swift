import AppKit
import Combine
import ServiceManagement

// Transport callbacks can precede their MainActor work. Revoke cached
// permission synchronously so that queued GUI work cannot use it meanwhile.
private final class FanConnectionValidity: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock(); defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        valid = false
    }
}

@MainActor
final class FanControlService: ObservableObject {
    @Published private(set) var enabled = false { didSet { rememberChoice() } }
    @Published private(set) var busy = false
    // A new one arrives every second. It is announced by hand, so that
    // nothing is redrawn for it while the dashboard is off screen (ADR 0006).
    private(set) var status = FanStatus(serviceGeneration: "disconnected") {
        willSet { if dashboardVisible { objectWillChange.send() } }
        didSet { if fanWarning.value != needsAttention { fanWarning.send(needsAttention) } }
    }
    @Published private(set) var helperDescription = "Helper not set up"
    @Published private(set) var message: String?
    @Published private(set) var profile: FanProfile
    @Published private(set) var helperApproved = false
    @Published private(set) var protocolReady = false
    @Published private(set) var menuBarReadoutEnabled: Bool
    // The menu bar item alone follows it; no view shows it, so no view is told.
    let menuBarReadout = CurrentValueSubject<FanMenuBarReadout, Never>(FanMenuBarReadout(snapshot: nil, capabilities: nil, now: 0))
    // Z-Q8: a recovery hold, or a restoration the helper could not complete
    // while it owns an override, puts a warning sign on the menu bar item,
    // with or without the readout. The item alone follows it, like the readout.
    let fanWarning = CurrentValueSubject<Bool, Never>(false)
    // Z-Q5 and Z-Q7: the macOS notifications for holds.
    let alerts = FanAlerts.shared
    // SR-Q2: a launch that found on saved is waiting to bring Fan Control back.
    @Published private(set) var resumingAtLaunch = false
    // Why such a launch left Fan Control off. It stays until the next press.
    @Published private(set) var launchNote: String?

    private let service = SMAppService.daemon(plistName: FanServiceIdentity.plist)
    private var connection: NSXPCConnection?
    private var connectionValidity: FanConnectionValidity?
    private var session: String?
    private var timer: Timer?
    // A page that shows the readings is on screen.
    private var readingsShown = false
    private var dashboardVisible = false
    private var sleeping = false
    private var resumeAfterWake = false { didSet { rememberChoice() } }
    private var wakeQualification = FanWakeQualification()
    // A begin has been sent and its reply is still to come.
    private var beginning = false { didSet { rememberChoice() } }
    private var launchResume: FanLaunchResume? {
        didSet {
            if resumingAtLaunch != (launchResume != nil) { resumingAtLaunch = launchResume != nil }
            rememberChoice()
        }
    }
    // SR-Q1: what the next launch starts from.
    private var remembered: FanRememberedChoice
    private var observers: [NSObjectProtocol] = []
    private var activation: NSObjectProtocol?
    private var generation = UUID()
    private var statusRequestAt: TimeInterval?
    private var statusRequestToken: UUID?
    private var protocolHandshake: ProtocolHandshake?
    private var operationToken: UUID?
    private var operationFailure: (() -> Void)?
    // The last complete frame received; the readout shows it for up to 3 s.
    private var readoutFrame: (snapshot: FanSnapshot, capabilities: FanCapabilities)?
    private static let profileKey = "FanControlProfile"
    private static let menuBarReadoutKey = "FanControlMenuBarReadout"
    private static let rememberedKey = "FanControlRememberedOn"
    private static let handshakeMaximumAge: TimeInterval = 3

    private struct ProtocolHandshake {
        let connectionGeneration: UUID
        let serviceGeneration: String
        let requestedAt: TimeInterval
    }

    private struct ProtocolHeader: Decodable {
        let protocolVersion: Int
        let serviceGeneration: String
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.profileKey),
           let saved = try? JSONDecoder().decode(FanProfile.self, from: data),
           (try? saved.validate()) != nil {
            profile = saved
        } else { profile = .standard }
        // M-Q3: on unless switched off in Settings.
        menuBarReadoutEnabled = UserDefaults.standard.object(forKey: Self.menuBarReadoutKey) as? Bool ?? true
        remembered = FanRememberedChoice(saved: UserDefaults.standard.bool(forKey: Self.rememberedKey))
        if remembered.on {
            // SR-Q2: the timer brings Fan Control back, by the rule that follows a wake.
            launchResume = FanLaunchResume(launchedAt: ProcessInfo.processInfo.systemUptime)
            resumingAtLaunch = true
        }
        refreshHelperStatus()
        // The tick renews the control lease and keeps the handshake fresh, so
        // it must also fire while a menu, a modal panel or a window drag keeps
        // the run loop out of its default mode.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        })
        // Coming back from System Settings is when an approval there shows.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshHelperStatus() }
        }
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let activation { NotificationCenter.default.removeObserver(activation) }
        connection?.invalidate()
    }

    var subtitle: String {
        if recoveryRequired { return "Recovery required" }
        if helperApproved && !helperProtocolReady { return "Checking helper…" }
        if enabled { return status.mode.title }
        if busy { return "Waiting for helper…" }
        if status.ownsOverride { return "Restoration needs attention" }
        guard helperApproved else { return "Set up helper to enable" }
        if resumingAtLaunch { return "Turning on as you left it…" }
        return launchNote == nil ? "Off" : "Stayed off, see Cooling"
    }

    var recoveryRequired: Bool {
        status.externalRecoveryRequired || status.mode == .externalRecoveryRequired
    }

    // A hold, or fans the helper owns but could not return to automatic.
    var needsAttention: Bool {
        recoveryRequired || (status.mode == .restorationFailed && status.ownsOverride)
    }

    var helperProtocolReady: Bool {
        guard protocolReady, helperApproved, connection != nil, connectionValidity?.isValid == true,
              let handshake = protocolHandshake else { return false }
        let age = ProcessInfo.processInfo.systemUptime - handshake.requestedAt
        return handshake.connectionGeneration == generation && handshake.serviceGeneration == status.serviceGeneration
            && age >= 0 && age < Self.handshakeMaximumAge
    }

    var canMutateHelper: Bool { helperProtocolReady && !busy && !sleeping }

    var canSaveProfile: Bool {
        !busy && !sleeping && !recoveryRequired && (session == nil || helperProtocolReady)
    }

    // Neither recovery request is offered while the helper's own attempt runs.
    var canVerifyExternalRecovery: Bool {
        recoveryRequired && canMutateHelper && !enabled && session == nil
            && status.sessionID == nil && status.externalRecoveryID?.isEmpty == false
            && status.mode != .restoring
    }

    // The helper releases only a record from this boot and its own build.
    // For any other record external recovery is the only way out.
    var restoreAutomaticOffered: Bool { recoveryRequired && status.restoreAutomaticOffered == true }
    var canRestoreAutomatic: Bool { canVerifyExternalRecovery && restoreAutomaticOffered }

    // Why the latest attempt on the current hold did not clear it.
    var lastRestoreFailure: String? {
        guard recoveryRequired, let receipt = status.selfRecoveryReceipt,
              receipt.recoveryID == status.externalRecoveryID else { return nil }
        return receipt.failure
    }

    private var holdMessage: String {
        restoreAutomaticOffered
            ? "A fan command could not be confirmed. Open the Cooling page and choose Restore automatic now, or set both fans to Auto in your independent fan utility, quit it, then verify external recovery."
            : "Set both fans to Auto in your independent fan utility, quit it, then verify external recovery on the Cooling page."
    }

    // M-Q3: the readout is shown whenever the helper is approved, unless it
    // is switched off here. While shown, the helper reads one frame a second.
    func setMenuBarReadout(_ shown: Bool) {
        menuBarReadoutEnabled = shown
        UserDefaults.standard.set(shown, forKey: Self.menuBarReadoutKey)
        if shown { requestStatus() }
    }

    private func refreshMenuBarReadout() {
        let readout = FanMenuBarReadout(snapshot: readoutFrame?.snapshot, capabilities: readoutFrame?.capabilities,
                                        now: ProcessInfo.processInfo.systemUptime)
        if readout != menuBarReadout.value { menuBarReadout.send(readout) }
    }

    func setReadingsShown(_ shown: Bool) {
        readingsShown = shown
        refreshHelperStatus()
        if shown { requestStatus() }
    }

    // The dashboard came on screen, or left it.
    func setDashboardVisible(_ visible: Bool) {
        guard visible != dashboardVisible else { return }
        dashboardVisible = visible
        guard visible else { return }
        refreshHelperStatus()
        // The views catch up with the statuses that were not announced.
        objectWillChange.send()
    }

    // Asks Service Management whether the helper is approved. Each answer is
    // a round trip through two system daemons that holds the main thread for
    // about 26 ms (measured 2026-10-13), so it is asked for when something
    // can have changed, not every second: at launch, when the dashboard or
    // the menu opens, when MacHelm becomes the active app, after waking, after
    // setting up or removing the helper, and when its connection is lost.
    func refreshHelperStatus() {
        let (description, approved): (String, Bool)
        switch service.status {
        case .notRegistered: (description, approved) = ("Helper not set up", false)
        case .enabled: (description, approved) = ("Helper approved", true)
        case .requiresApproval: (description, approved) = ("Administrator approval required", false)
        case .notFound:
            let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(FanServiceIdentity.plist)")
            let bundled = FileManager.default.fileExists(atPath: helperURL.path)
                && FileManager.default.fileExists(atPath: plist.path)
            (description, approved) = (bundled ? "Helper not registered" : "Bundled helper not found", false)
        @unknown default: (description, approved) = ("Helper status unavailable", false)
        }
        if description != helperDescription { helperDescription = description }
        if approved != helperApproved { helperApproved = approved }
        if !helperApproved {
            protocolReady = false
            resumeAfterWake = false; wakeQualification.reset()
        }
    }

    func setUpHelper() {
        guard !busy else { return }
        do {
            try FanSigning.verifyBundledHelper(at: helperURL)
            // A fresh bundled daemon can report notFound before it has a
            // registration. Verify the nested signature first, then let
            // Service Management report the actual registration result.
            if service.status == .notRegistered || service.status == .notFound { try service.register() }
            refreshHelperStatus()
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            message = helperApproved ? nil : "Approve the Fan Control helper in System Settings → Login Items & Extensions."
            if helperApproved { requestStatus() }
        } catch {
            let failure = error as NSError
            refreshHelperStatus()
            if service.status == .requiresApproval {
                // Registration can create the consent entry while launch is
                // denied. This is pending approval, not a missing helper.
                message = "Approve the Fan Control helper in System Settings → Login Items & Extensions."
                SMAppService.openSystemSettingsLoginItems()
            } else {
                message = "Helper setup failed: \(failure.localizedDescription) (\(failure.domain), \(failure.code))."
            }
        }
    }

    func openHelperSettings() { SMAppService.openSystemSettingsLoginItems() }

    func toggle() {
        guard !busy else { return }
        resumeAfterWake = false
        // A press replaces a pending launch resume and clears its note.
        launchResume = nil; launchNote = nil
        guard !recoveryRequired else {
            message = holdMessage
            return
        }
        guard canMutateHelper else { requestProtocolCheck(); return }
        if enabled { release() } else { enable() }
    }

    private func enable() {
        guard !recoveryRequired else {
            message = "Resolve the recovery hold on the Cooling page before enabling Fan Control."
            return
        }
        guard helperApproved, !sleeping else {
            message = "Set up and approve the bundled helper before enabling Fan Control."
            return
        }
        guard canMutateHelper else { requestProtocolCheck(); return }
        // Z-Q7: asked while the owner is here, not when a hold first happens.
        alerts.askPermission()
        do {
            try profile.validate()
            let data = try JSONEncoder().encode(profile)
            let proxy = try mutatingRemote()
            let requestGeneration = generation
            busy = true; message = nil
            beginning = true
            let token = startOperation()
            proxy.begin(profile: data) { [weak self] data in
                Task { @MainActor in
                    guard let self, self.operationToken == token, self.generation == requestGeneration else { return }
                    self.finishOperation()
                    guard self.apply(data, requestGeneration: requestGeneration), self.helperProtocolReady,
                          !self.recoveryRequired, self.status.requestError == nil,
                          let session = self.status.sessionID else { self.enabled = false; self.beginning = false; return }
                    self.session = session; self.enabled = true; self.beginning = false
                }
            }
        } catch { transportFailed(error.localizedDescription) }
    }

    func saveProfile(start: Double, maximum: Double) {
        guard !busy else { return }
        guard !recoveryRequired else {
            message = "Fan settings are locked until the recovery hold is resolved."
            return
        }
        guard session == nil || canMutateHelper else { requestProtocolCheck(); return }
        let next = FanProfile(start: start, maximum: maximum)
        do {
            try next.validate()
            let data = try JSONEncoder().encode(next)
            if let session {
                let proxy = try mutatingRemote()
                let requestGeneration = generation
                busy = true
                let token = startOperation()
                proxy.update(session: session, profile: data) { [weak self] response in
                    Task { @MainActor in
                        guard let self, self.operationToken == token, self.generation == requestGeneration else { return }
                        self.finishOperation()
                        guard self.apply(response, requestGeneration: requestGeneration), self.helperProtocolReady,
                              !self.recoveryRequired, self.status.requestError == nil else { return }
                        self.profile = next
                        UserDefaults.standard.set(data, forKey: Self.profileKey)
                    }
                }
            } else {
                profile = next
                UserDefaults.standard.set(data, forKey: Self.profileKey)
                message = nil
            }
        } catch { message = error.localizedDescription }
    }

    func removeHelper() {
        guard !busy else { return }
        resumeAfterWake = false
        launchResume = nil; launchNote = nil
        guard !recoveryRequired else {
            message = "Resolve the recovery hold before removing the helper."
            return
        }
        refreshHelperStatus()
        if service.status == .notRegistered { return }
        guard canMutateHelper else { requestProtocolCheck(); return }
        do {
            let proxy = try mutatingRemote()
            let requestGeneration = generation
            busy = true
            let token = startOperation()
            proxy.prepareForRemoval { [weak self] data in
                Task { @MainActor in
                    guard let self, self.operationToken == token, self.generation == requestGeneration else { return }
                    self.finishOperation()
                    guard self.apply(data, requestGeneration: requestGeneration), !self.recoveryRequired,
                          self.status.requestError == nil else { return }
                    self.enabled = false; self.session = nil
                    if self.status.safeToUnregister { self.unregisterIdleHelper() }
                    else {
                        self.message = "Helper removal is blocked until the owning session has verified automatic restoration."
                        self.invalidateConnection()
                    }
                }
            }
        } catch { message = error.localizedDescription; busy = false }
    }

    private func unregisterIdleHelper() {
        guard status.safeToUnregister, !recoveryRequired else { return }
        guard helperProtocolReady else {
            message = "The helper compatibility check expired. Review its status and choose Remove helper again."
            requestStatus()
            return
        }
        let requestGeneration = generation
        busy = true
        Task {
            guard generation == requestGeneration, helperProtocolReady, !recoveryRequired, status.safeToUnregister else {
                busy = false
                message = "The helper state changed before removal. Review its status and choose Remove helper again."
                return
            }
            do {
                try await service.unregister()
                invalidateConnection()
                session = nil; enabled = false
                status = FanStatus(serviceGeneration: "disconnected")
                message = "Fan Control helper removed."
            } catch { message = error.localizedDescription; invalidateConnection() }
            busy = false; refreshHelperStatus()
        }
    }

    // Called only by its own confirmation dialog. Asks the helper for one
    // bounded attempt to return the recorded fans to automatic; the helper
    // clears the hold only after its release writes and settle check confirm.
    func restoreAutomatic(recoveryID: String) {
        guard !busy else { return }
        guard recoveryRequired, !recoveryID.isEmpty, status.externalRecoveryID == recoveryID else {
            message = "The recovery state changed. Review the current state and try again."
            return
        }
        guard helperProtocolReady else { requestProtocolCheck(); return }
        guard canRestoreAutomatic else {
            if status.mode == .restoring {
                message = "The helper is returning the fans to automatic. Wait for it to finish, then review the result."
            } else {
                message = restoreAutomaticOffered
                    ? "Restoring automatic control needs an approved, connected helper and no active control session."
                    : holdMessage
            }
            return
        }
        resumeAfterWake = false; wakeQualification.reset()
        do {
            let proxy = try mutatingRemote()
            let requestGeneration = generation
            busy = true; message = nil
            // Losing this connection cancels the attempt, so the limit must
            // outlast it: up to 1 s before the first write, a release write of
            // up to about 1 s for each fan and the unlock, and the 1 s settle check.
            let token = startOperation(timeout: 10)
            proxy.restoreAutomatic(recoveryID: recoveryID) { [weak self] data in
                Task { @MainActor in
                    guard let self, self.operationToken == token, self.generation == requestGeneration else { return }
                    self.finishOperation()
                    if self.recoveryRequired && self.status.externalRecoveryID != recoveryID {
                        self.message = "The recovery state changed during the attempt. Review it and try again."
                        return
                    }
                    guard self.apply(data, requestGeneration: requestGeneration) else { return }
                    self.enabled = false; self.session = nil
                    self.resumeAfterWake = false; self.wakeQualification.reset()
                    guard self.status.requestError == nil, !self.recoveryRequired, self.status.externalRecoveryID == nil,
                          !self.status.ownsOverride, self.status.sessionID == nil,
                          self.status.releaseVerified, self.status.safeToUnregister else {
                        self.message = self.status.requestError ?? self.status.reason
                            ?? "The fans could not be confirmed automatic. Recovery is still required."
                        return
                    }
                    self.message = "Fans returned to automatic and checked. Fan Control is off."
                }
            }
        } catch { transportFailed(error.localizedDescription) }
    }

    // Called only by the explicit confirmation dialog. The captured ID is
    // never replaced with a newer status ID on behalf of the owner.
    func confirmExternalRecovery(recoveryID: String) {
        guard !busy else { return }
        guard recoveryRequired, !recoveryID.isEmpty, status.externalRecoveryID == recoveryID else {
            message = "The recovery state changed. Review the current state and confirm external recovery again."
            return
        }
        guard helperProtocolReady else { requestProtocolCheck(); return }
        guard canVerifyExternalRecovery else {
            message = status.mode == .restoring
                ? "The helper is returning the fans to automatic. Wait for it to finish, then review the result."
                : "External recovery needs an approved, connected helper and no active control session."
            return
        }
        resumeAfterWake = false; wakeQualification.reset()
        do {
            let proxy = try mutatingRemote()
            let requestGeneration = generation
            busy = true; message = nil
            let token = startOperation()
            proxy.confirmExternalRecovery(recoveryID: recoveryID) { [weak self] data in
                Task { @MainActor in
                    guard let self, self.operationToken == token, self.generation == requestGeneration else { return }
                    self.finishOperation()
                    // A background status reply can reveal a new recovery hold
                    // while this request is in flight. Preserve that newer hold.
                    if self.recoveryRequired && self.status.externalRecoveryID != recoveryID {
                        self.message = "The recovery state changed during verification. Review it and confirm again."
                        return
                    }
                    guard self.apply(data, requestGeneration: requestGeneration), self.status.requestError == nil else { return }
                    self.enabled = false; self.session = nil
                    self.resumeAfterWake = false; self.wakeQualification.reset()
                    guard !self.recoveryRequired, self.status.externalRecoveryID == nil,
                          !self.status.ownsOverride, self.status.sessionID == nil,
                          self.status.releaseVerified, self.status.safeToUnregister else {
                        self.message = self.status.reason ?? "External recovery is still required. The helper has not verified automatic fan control."
                        return
                    }
                    self.message = "External recovery verified. Fan Control is off."
                }
            }
        } catch { transportFailed(error.localizedDescription) }
    }

    func releaseForQuit(completion: @escaping () -> Void) {
        // SR-Q1: quitting keeps the saved choice.
        remembered.beginQuit()
        resumeAfterWake = false
        timer?.invalidate()
        // The durable recovery hold survives GUI exit. Do not turn quitting
        // into another stop/restoration request or an implicit confirmation.
        if recoveryRequired { completion(); return }
        // Keep the helper alive if restoration stalls. Its independent watchdog
        // and durable record continue; this timeout is not a restoration receipt.
        guard session != nil || status.ownsOverride || busy else { completion(); return }
        release { [weak self] safe in
            // A release that was not confirmed, or that the helper finished by
            // its own recovery, is not brought back by the next launch.
            if !safe, let self, let changed = self.remembered.releaseAtQuitUnconfirmed() {
                UserDefaults.standard.set(changed, forKey: Self.rememberedKey)
            }
            completion()
        }
    }

    private func release(completion: @escaping (Bool) -> Void = { _ in }) {
        let ending = session
        enabled = false; session = nil
        guard !recoveryRequired else {
            resumeAfterWake = false; wakeQualification.reset()
            message = "Recovery is required; Fan Control remains off."
            completion(false)
            return
        }
        do {
            // Sleep/quit may request a release using an existing fresh handshake;
            // they never establish a connection and then send an unchecked stop.
            let proxy = try mutatingRemote(allowWhileSleeping: true)
            let requestGeneration = generation
            busy = true
            let token = startOperation(onTimeout: { completion(false) })
            proxy.stop { [weak self] data in
                Task { @MainActor in
                    guard let self, self.operationToken == token, self.generation == requestGeneration else { return }
                    self.finishOperation()
                    let decoded = self.apply(data, requestGeneration: requestGeneration)
                    let safe = decoded && !self.recoveryRequired && self.status.requestError == nil && self.status.safeToUnregister
                    if !safe { self.message = self.status.reason ?? "Automatic restoration is still pending." }
                    // A session the helper ended by returning its fans to
                    // automatic after an unconfirmed command stays off; it
                    // is not resumed after wake.
                    completion(safe && !self.status.endedBySelfRecovery(session: ending))
                }
            }
        } catch { transportFailed(error.localizedDescription); completion(false) }
    }

    private func tick() {
        // An approval that is being waited for in front of the owner is looked for every second.
        if dashboardVisible && !helperApproved { refreshHelperStatus() }
        refreshMenuBarReadout()
        guard !sleeping else { return }
        if !helperProtocolReady {
            if protocolReady { protocolReady = false }
            // Ordinary sleep may age the handshake. Keep accepted wake intent,
            // negotiate read-only, and do no lease/control work on this tick.
            if helperApproved { requestStatus() }
            // SR-Q2: the wait for the helper after a launch has a limit.
            considerLaunchResumption()
            return
        }
        if helperProtocolReady, !recoveryRequired, let session {
            do {
                let proxy = try mutatingRemote()
                let requestGeneration = generation
                proxy.renew(session: session) { [weak self] accepted in
                    Task { @MainActor in
                        guard let self, self.generation == requestGeneration, self.session == session else { return }
                        if !accepted { self.transportFailed("The control lease ended. Resolve the reported fault and re-enable Fan Control.") }
                    }
                }
            } catch { transportFailed(error.localizedDescription) }
        }
        // Idle checks use observe:false. They establish/refresh compatibility
        // without requesting native control or extending a control lease.
        if helperApproved { requestStatus() }
        // Only a timer tick may consume existing wake intent. A negotiation
        // callback itself never enables Fan Control.
        considerWakeResumption()
        considerLaunchResumption()
    }

    private func requestProtocolCheck() {
        protocolReady = false
        message = helperApproved
            ? "Fan controls are locked until the connected helper passes a fresh compatibility check."
            : "Set up and approve the bundled helper before using fan controls."
        requestStatus()
    }

    private func requestStatus() {
        guard helperApproved, !sleeping else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let sent = statusRequestAt {
            if now - sent >= Self.handshakeMaximumAge {
                transportFailed("Fan helper response timed out; restoration cannot yet be confirmed.")
            }
            return
        }
        do {
            let proxy = try statusRemote()
            statusRequestAt = now
            let token = UUID(); statusRequestToken = token
            let requestGeneration = generation
            proxy.handshake(protocolVersion: FanStatus.currentProtocolVersion,
                            observe: enabled || readingsShown || resumeAfterWake || recoveryRequired
                                || menuBarReadoutEnabled || launchResume != nil) { [weak self] data in
                Task { @MainActor in
                    guard let self, self.generation == requestGeneration, self.statusRequestToken == token else { return }
                    self.statusRequestAt = nil; self.statusRequestToken = nil
                    let age = ProcessInfo.processInfo.systemUptime - now
                    guard age >= 0, age < Self.handshakeMaximumAge else {
                        self.transportFailed("Fan helper status arrived too late to authorize fan controls.")
                        return
                    }
                    guard self.apply(data, requestGeneration: requestGeneration) else { return }
                    guard self.status.requestError == nil else {
                        self.protocolReady = false
                        self.resumeAfterWake = false; self.wakeQualification.reset()
                        return
                    }
                    self.protocolHandshake = ProtocolHandshake(connectionGeneration: requestGeneration,
                                                               serviceGeneration: self.status.serviceGeneration,
                                                               requestedAt: now)
                    if !self.protocolReady { self.protocolReady = true }
                    // Learning compatibility does not replay an owner action
                    // or enable control. Existing accepted wake intent can be
                    // qualified on subsequent timer ticks.
                    if self.enabled && self.status.sessionID != self.session {
                        self.enabled = false; self.session = nil; self.resumeAfterWake = false
                    }
                    if self.resumeAfterWake && [.unavailable, .restorationFailed, .externalRecoveryRequired].contains(self.status.mode) {
                        self.resumeAfterWake = false; self.wakeQualification.reset()
                    }
                }
            }
        } catch { transportFailed(error.localizedDescription) }
    }

    // Only read-only negotiation is allowed to create an authenticated connection.
    private func statusRemote() throws -> FanControlXPC {
        if connection == nil {
            protocolReady = false; protocolHandshake = nil
            let identity = try FanSigning.selfIdentity()
            try FanSigning.verifyBundledHelper(at: helperURL)
            let connection = NSXPCConnection(machServiceName: FanServiceIdentity.helper, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPC.self)
            connection.setCodeSigningRequirement(try FanSigning.requirement(identifier: FanServiceIdentity.helper, team: identity.team))
            let currentGeneration = generation
            let validity = FanConnectionValidity()
            connection.invalidationHandler = { [weak self] in
                validity.invalidate()
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    self.transportFailed("Fan helper disconnected. Automatic restoration has not been confirmed.")
                }
            }
            connection.interruptionHandler = connection.invalidationHandler
            self.connectionValidity = validity
            connection.resume(); self.connection = connection
        }
        guard let connection, let validity = connectionValidity, validity.isValid else {
            throw FanControlError.unavailable("Fan helper connection is unavailable.")
        }
        return try proxy(for: connection, requestGeneration: generation, validity: validity)
    }

    private func mutatingRemote(allowWhileSleeping: Bool = false) throws -> FanControlXPC {
        guard helperProtocolReady, allowWhileSleeping || !sleeping, let connection, let validity = connectionValidity,
              validity.isValid else {
            throw FanControlError.unavailable("A fresh compatibility check on the same helper connection is required before fan controls can be used.")
        }
        // This accessor neither creates a new connection nor requests status.
        // Its caller must return without the mutation when the check fails.
        return try proxy(for: connection, requestGeneration: generation, validity: validity)
    }

    private func proxy(for connection: NSXPCConnection, requestGeneration: UUID,
                       validity: FanConnectionValidity) throws -> FanControlXPC {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            validity.invalidate()
            Task { @MainActor in
                guard let self, self.generation == requestGeneration else { return }
                self.transportFailed(error.localizedDescription)
            }
        }) as? FanControlXPC else { throw FanControlError.unavailable("Fan helper connection is unavailable.") }
        return proxy
    }

    private var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Library/HelperTools/FanControlHelper") }

    @discardableResult private func apply(_ data: Data, requestGeneration: UUID) -> Bool {
        guard generation == requestGeneration, connection != nil, connectionValidity?.isValid == true else { return false }
        guard data.count <= FanStatus.maximumReplyBytes, let header = try? JSONDecoder().decode(ProtocolHeader.self, from: data) else {
            transportFailed("Incompatible or malformed Fan Control helper reply.")
            return false
        }
        guard header.protocolVersion == FanStatus.currentProtocolVersion else {
            transportFailed("The connected Fan Control helper uses protocol \(header.protocolVersion); this app requires protocol \(FanStatus.currentProtocolVersion). Install the helper bundled with this version of MacHelm.")
            return false
        }
        guard !header.serviceGeneration.isEmpty, let received = try? JSONDecoder().decode(FanStatus.self, from: data) else {
            transportFailed("Incompatible or malformed Fan Control helper reply.")
            return false
        }
        if let handshake = protocolHandshake,
           handshake.connectionGeneration == requestGeneration,
           handshake.serviceGeneration != received.serviceGeneration {
            transportFailed("The Fan Control helper changed during this connection. A new compatibility check is required.")
            return false
        }
        // Recovery fields cannot update GUI state until both protocol version
        // and the authenticated connection's service generation are checked.
        status = received
        if let snapshot = received.snapshot, let capabilities = received.capabilities {
            readoutFrame = (snapshot, capabilities)
        }
        refreshMenuBarReadout()
        let said = received.requestError ?? received.reason
        if said != message { message = said }
        if recoveryRequired {
            // Discard any status request begun before this hold was applied.
            // Its delayed reply must not replace the new recovery state.
            statusRequestAt = nil; statusRequestToken = nil
            enabled = false; session = nil; resumeAfterWake = false
            wakeQualification.reset()
        }
        alerts.observe(received, holdMessage: holdMessage)
        return true
    }

    private func transportFailed(_ reason: String) {
        let failedOperation = operationFailure
        enabled = false; session = nil; busy = false; resumeAfterWake = false; beginning = false
        operationToken = nil; operationFailure = nil; statusRequestAt = nil; statusRequestToken = nil
        message = reason
        status.mode = recoveryRequired ? .externalRecoveryRequired : (status.ownsOverride ? .restorationFailed : .unavailable)
        status.snapshot = nil; status.releaseVerified = false; status.safeToUnregister = false
        status.fanProbe = nil
        invalidateConnection()
        // A helper that was removed or lost its approval shows as a lost connection.
        refreshHelperStatus()
        // Quit must also complete when XPC fails before its six-second timer.
        // This callback reports failure, never a restoration receipt.
        failedOperation?()
    }

    private func invalidateConnection() {
        connectionValidity?.invalidate(); connectionValidity = nil
        generation = UUID()
        protocolReady = false; protocolHandshake = nil
        statusRequestAt = nil; statusRequestToken = nil
        connection?.invalidate(); connection = nil
    }

    private func startOperation(timeout: TimeInterval = 6, onTimeout: @escaping () -> Void = {}) -> UUID {
        let token = UUID(); operationToken = token; operationFailure = onTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.operationToken == token else { return }
            self.transportFailed("Fan helper operation timed out; automatic restoration is not confirmed.")
        }
        return token
    }
    private func finishOperation() { operationToken = nil; operationFailure = nil; busy = false }

    private func willSleep() {
        sleeping = true
        resumeAfterWake = enabled
        wakeQualification.reset()
        if recoveryRequired { resumeAfterWake = false; enabled = false; session = nil; return }
        if enabled || status.ownsOverride {
            release { [weak self] safe in
                if !safe { self?.resumeAfterWake = false }
            }
        }
    }
    private func didWake() {
        sleeping = false
        wakeQualification.reset()
        if !helperProtocolReady { protocolReady = false }
        refreshHelperStatus(); requestStatus()
        if !helperApproved { resumeAfterWake = false }
    }
    // SR-Q2: only a timer tick may bring Fan Control back after a launch. A
    // lost connection inside the wait does not end it; the limit does.
    private func considerLaunchResumption() {
        guard var resume = launchResume else { return }
        let ready = canMutateHelper
        let decision = resume.consider(helperApproved: helperApproved, helperReady: ready, status: status,
                                       now: ProcessInfo.processInfo.systemUptime,
                                       conflict: ready ? FanUtilityRegistry.runningConflict() : nil)
        switch decision {
        case .wait: launchResume = resume
        // The begin is sent first, so the saved choice stays on across the hand-over.
        case .begin: enable(); launchResume = nil
        case .stayOff(let reason): launchNote = reason; launchResume = nil
        }
    }
    // SR-Q1: the saved choice follows what the app is doing; quitting freezes it.
    private func rememberChoice() {
        if let changed = remembered.observe(enabled: enabled, beginning: beginning,
                                            resumePending: resumeAfterWake || launchResume != nil) {
            UserDefaults.standard.set(changed, forKey: Self.rememberedKey)
        }
    }
    private func considerWakeResumption() {
        guard resumeAfterWake, canMutateHelper, !recoveryRequired else { return }
        do {
            if try wakeQualification.observe(status, now: ProcessInfo.processInfo.systemUptime,
                                              conflict: FanUtilityRegistry.runningConflict()) {
                resumeAfterWake = false; enable()
            }
        } catch { resumeAfterWake = false; message = error.localizedDescription }
    }
}
