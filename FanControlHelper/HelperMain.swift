import Foundation
import IOKit.pwr_mgt

private final class FanEndpoint: NSObject, FanControlXPC {
    private let owner = UUID().uuidString
    private let controller: FanHelperController?
    private let startupError: String?
    private let startupSafeToUnregister: Bool
    private let handshakeLock = NSLock()
    private var protocolReady = false
    init(controller: FanHelperController?, startupError: String?, startupSafeToUnregister: Bool) {
        self.controller = controller; self.startupError = startupError
        self.startupSafeToUnregister = startupSafeToUnregister
    }
    func disconnected() {
        handshakeLock.lock(); protocolReady = false; handshakeLock.unlock()
        controller?.disconnected(owner: owner)
    }
    func status(observe: Bool, reply: @escaping (Data) -> Void) {
        send(controller?.status(observe: observe) ?? unavailable(), reply: reply)
    }
    func handshake(protocolVersion: Int, observe: Bool, reply: @escaping (Data) -> Void) {
        handshakeLock.lock()
        protocolReady = protocolVersion == FanStatus.currentProtocolVersion
        let ready = protocolReady
        handshakeLock.unlock()
        guard ready else { reject("Fan helper protocol is incompatible; install matching app and helper builds.", reply: reply); return }
        send(controller?.status(observe: observe) ?? unavailable(), reply: reply)
    }
    func begin(profile: Data, reply: @escaping (Data) -> Void) {
        guard requireHandshake(reply: reply) else { return }
        withProfile(profile, reply: reply) { profile, controller in
            controller.begin(owner: self.owner, profile: profile) { self.send($0, reply: reply) }
        }
    }
    func update(session: String, profile: Data, reply: @escaping (Data) -> Void) {
        guard requireHandshake(reply: reply) else { return }
        guard UUID(uuidString: session) != nil else { reject("Invalid session identifier.", reply: reply); return }
        withProfile(profile, reply: reply) { profile, controller in
            controller.updateProfile(owner: self.owner, session: session, profile: profile) { self.send($0, reply: reply) }
        }
    }
    func renew(session: String, reply: @escaping (Bool) -> Void) {
        guard handshakeReady, UUID(uuidString: session) != nil else { reply(false); return }
        reply(controller?.renew(owner: owner, session: session) ?? false)
    }
    func stop(reply: @escaping (Data) -> Void) {
        guard requireHandshake(reply: reply) else { return }
        guard let controller else { send(unavailable(), reply: reply); return }
        controller.stop(owner: owner, reason: FanHelperController.appStopReason) { self.send($0, reply: reply) }
    }
    func prepareForRemoval(reply: @escaping (Data) -> Void) {
        guard requireHandshake(reply: reply) else { return }
        guard let controller else { send(unavailable(), reply: reply); return }
        controller.prepareRemoval(owner: owner) { self.send($0, reply: reply) }
    }
    func confirmExternalRecovery(recoveryID: String, reply: @escaping (Data) -> Void) {
        guard requireHandshake(reply: reply) else { return }
        guard UUID(uuidString: recoveryID) != nil else { reject("Invalid recovery identifier.", reply: reply); return }
        guard let controller else { send(unavailable(), reply: reply); return }
        controller.confirmExternalRecovery(owner: owner, recoveryID: recoveryID) { self.send($0, reply: reply) }
    }
    func restoreAutomatic(recoveryID: String, reply: @escaping (Data) -> Void) {
        guard requireHandshake(reply: reply) else { return }
        guard UUID(uuidString: recoveryID) != nil else { reject("Invalid recovery identifier.", reply: reply); return }
        guard let controller else { send(unavailable(), reply: reply); return }
        controller.restoreAutomatic(owner: owner, recoveryID: recoveryID) { self.send($0, reply: reply) }
    }
    private func withProfile(_ data: Data, reply: @escaping (Data) -> Void,
                             body: (FanProfile, FanHelperController) -> Void) {
        do {
            guard data.count <= 512 else { throw FanControlError.invalid("Oversized fan profile.") }
            let profile = try JSONDecoder().decode(FanProfile.self, from: data)
            try profile.validate()
            guard let controller else { send(unavailable(), reply: reply); return }
            body(profile, controller)
        } catch { reject(error.localizedDescription, reply: reply) }
    }
    private var handshakeReady: Bool {
        handshakeLock.lock(); defer { handshakeLock.unlock() }
        return protocolReady
    }
    private func requireHandshake(reply: @escaping (Data) -> Void) -> Bool {
        guard handshakeReady else {
            reject("Complete a matching protocol handshake on this authenticated connection before changing Fan Control.", reply: reply)
            return false
        }
        return true
    }
    private func reject(_ error: String, reply: @escaping (Data) -> Void) {
        var status = controller?.status(observe: false) ?? unavailable()
        status.requestError = error
        send(status, reply: reply)
    }
    private func unavailable() -> FanStatus {
        var status = FanStatus(serviceGeneration: "unavailable")
        status.mode = .unavailable; status.reason = startupError ?? "Fan helper is unavailable."
        status.safeToUnregister = startupSafeToUnregister
        // Absence of our journal permits idle removal, but is not a fresh
        // observation of the firmware's automatic state.
        status.releaseVerified = false
        return status
    }
    private func send(_ status: FanStatus, reply: (Data) -> Void) {
        reply((try? status.encodedReply()) ?? Data())
    }
}

private final class FanListener: NSObject, NSXPCListenerDelegate {
    private let requirement: String
    private let controller: FanHelperController?
    private let startupError: String?
    private let startupSafeToUnregister: Bool
    init(requirement: String, controller: FanHelperController?, startupError: String?, startupSafeToUnregister: Bool) {
        self.requirement = requirement; self.controller = controller; self.startupError = startupError
        self.startupSafeToUnregister = startupSafeToUnregister
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Foundation checks each message against the kernel-supplied XPC audit
        // identity, avoiding PID races and client-claimed bundle IDs. Set before
        // resume; no endpoint is callable by a nonmatching signed process.
        connection.setCodeSigningRequirement(requirement)
        let endpoint = FanEndpoint(controller: controller, startupError: startupError,
                                   startupSafeToUnregister: startupSafeToUnregister)
        connection.exportedInterface = NSXPCInterface(with: FanControlXPC.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { endpoint.disconnected() }
        connection.interruptionHandler = { endpoint.disconnected() }
        connection.resume()
        return true
    }
}

private final class FanPowerObserver {
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var root: io_connect_t = 0
    private let controller: FanHelperController
    private let queue = DispatchQueue(label: "MacHelm.fan.sleep")
    private var pending: Set<Int> = []

    init(controller: FanHelperController) throws {
        self.controller = controller
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, type, argument in
            guard let context else { return }
            let observer = Unmanaged<FanPowerObserver>.fromOpaque(context).takeUnretainedValue()
            observer.receive(type, token: Int(bitPattern: argument))
        }, &notifier)
        guard root != 0, let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            throw FanControlError.unavailable("Cannot observe system sleep; Fan Control remains unavailable.")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if let port { IONotificationPortDestroy(port) }
        if root != 0 { IOServiceClose(root) }
    }

    private func receive(_ type: UInt32, token: Int) {
        // IOKit IOMessage.h's iokit_common_msg macros are not imported to Swift.
        if type == 0xe0000270 { IOAllowPowerChange(root, token); return }
        if type == 0xe0000300 { controller.systemDidWake(); return }
        guard type == 0xe0000280 else { return }
        queue.async { [self] in
            pending.insert(token)
            controller.systemWillSleep { [weak self] in self?.queue.async { self?.allow(token) } }
            // A kernel call may stall; the power deadline is not a restoration
            // receipt. The journal and pending/error status remain authoritative.
            queue.asyncAfter(deadline: .now() + FanHelperController.sleepAllowanceSeconds) { [weak self] in self?.allow(token) }
        }
    }

    private func allow(_ token: Int) {
        guard pending.remove(token) != nil else { return }
        IOAllowPowerChange(root, token)
    }
}

@main
struct FanHelperMain {
    static func main() {
        do {
            let identity = try FanSigning.selfIdentity()
            if CommandLine.arguments.dropFirst() == ["--check-signing"] {
                let policy = "manual-mode-acknowledgement=two-probes-1s; target-acknowledgement=two-probes-1s; release-acknowledgement=two-probes-1s; acknowledgement-final-pair=late; target-deadband=\(Int(FanHelperController.targetDeadbandRPM))rpm; sleep-allowance=\(Int(FanHelperController.sleepAllowanceSeconds))s; out-of-range-frame=skip-within-\(Int(FanSafetyGate.completeFrameLimitSeconds))s; unconfirmed-command=one-bounded-release-attempt"
                #if FAN_CONTROL_QUALIFICATION
                print("FanControlHelper team=\(identity.team) cdhash=\(identity.hash); qualification=enabled; \(policy); no service registration or hardware access.")
                #else
                print("FanControlHelper team=\(identity.team) cdhash=\(identity.hash); \(policy); no service registration or hardware access.")
                #endif
                return
            }
            let arguments = Array(CommandLine.arguments.dropFirst())
            #if FAN_CONTROL_QUALIFICATION
            if arguments == ["--qualification-schema"] {
                print(String(decoding: try FanQualificationHardware.schemaJSON(), as: UTF8.self))
                return
            }
            #endif
            if arguments.first == "--read-only" {
                let count = try FanReadOnlyQualification.sampleCount(arguments: arguments)
                let result = try FanReadOnlyQualification.capture(sampleCount: count)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
                return
            }
            guard CommandLine.arguments.count == 1, geteuid() == 0 else {
                throw FanControlError.unavailable("The fan helper must be launched by its approved root launch daemon.")
            }
            let requirement = try FanSigning.requirement(identifier: FanServiceIdentity.app, team: identity.team)
            var controller: FanHelperController?
            var power: FanPowerObserver?
            var startupError: String?
            var persistence: FanRecoveryStore?
            var startupSafeToUnregister = false
            do {
                let store = try FanRecoveryStore()
                persistence = store
                #if FAN_CONTROL_QUALIFICATION
                let qualificationHardware = FanQualificationHardware(delegating: try AppleFanHardware())
                controller = try FanHelperController(hardware: qualificationHardware, persistence: store,
                                                     bootID: FanSystemIdentity.sysctlString("kern.bootsessionuuid"),
                                                     artifactIdentity: identity.hash, conflict: FanUtilityRegistry.runningConflict,
                                                     qualificationProvenance: { qualificationHardware.provenance },
                                                     modeDiagnosticTiming: FanModeDiagnosticTiming())
                controller?.setQualificationAcknowledgementWithholder { qualificationHardware.withholdsAcknowledgement(of: $0) }
                #else
                controller = try FanHelperController(hardware: AppleFanHardware(), persistence: store,
                                                     bootID: FanSystemIdentity.sysctlString("kern.bootsessionuuid"),
                                                     artifactIdentity: identity.hash, conflict: FanUtilityRegistry.runningConflict,
                                                     modeDiagnosticTiming: FanModeDiagnosticTiming())
                #endif
                if let controller { power = try FanPowerObserver(controller: controller) }
            } catch {
                controller = nil; startupError = error.localizedDescription
                if let persistence {
                    // Unsupported/read-failed hardware must not trap an idle
                    // service on the system. An unreadable or owned journal
                    // blocks removal; verified absence needs no fan reset.
                    do { startupSafeToUnregister = try persistence.load() == nil }
                    catch { startupSafeToUnregister = false }
                }
            }
            let delegate = FanListener(requirement: requirement, controller: controller, startupError: startupError,
                                       startupSafeToUnregister: startupSafeToUnregister)
            let listener = NSXPCListener(machServiceName: FanServiceIdentity.helper)
            listener.delegate = delegate
            listener.resume()
            withExtendedLifetime((delegate, power)) { RunLoop.current.run() }
        } catch {
            fputs("FanControlHelper disarmed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
