import Foundation
import IOKit
import Security

// The toolkit helper (ADR 0003): the root program for everything that needs
// root except the fans. It answers four fixed requests from MacHelm and
// from nobody else, and it exits when it is idle and holds nothing.

// The calls `pmset` itself makes. They are not in the SDK's headers.
@_silgen_name("IOPMCopyPMPreferences") private func IOPMCopyPMPreferences() -> Unmanaged<CFMutableDictionary>?
@_silgen_name("IOPMSetPMPreferences") private func IOPMSetPMPreferences(_ preferences: CFDictionary) -> IOReturn
@_silgen_name("IOPMCopySystemPowerSettings") private func IOPMCopySystemPowerSettings() -> Unmanaged<CFDictionary>?
@_silgen_name("IOPMSetSystemPowerSetting") private func IOPMSetSystemPowerSetting(_ key: CFString, _ value: CFTypeRef) -> IOReturn

// macOS's power settings. Every change is read back: a setting that does not
// read as it was asked for is reported, not assumed.
private struct DarwinPowerSystem: PowerSystem {
    private static let sleepDisabledKey = "SleepDisabled"

    private func preferences() throws -> [String: Any] {
        guard let preferences = IOPMCopyPMPreferences()?.takeRetainedValue() as? [String: Any] else {
            throw ToolkitHelperError("macOS did not give its power settings.")
        }
        return preferences
    }

    func sleepDisabled() throws -> Bool {
        guard let settings = IOPMCopySystemPowerSettings()?.takeRetainedValue() as? [String: Any] else {
            throw ToolkitHelperError("macOS did not give its power settings.")
        }
        return (settings[Self.sleepDisabledKey] as? NSNumber)?.boolValue ?? false
    }

    func setSleepDisabled(_ disabled: Bool) throws {
        let value: CFBoolean = disabled ? kCFBooleanTrue : kCFBooleanFalse
        let result = IOPMSetSystemPowerSetting(Self.sleepDisabledKey as CFString, value)
        guard result == kIOReturnSuccess else {
            throw ToolkitHelperError("macOS refused to change SleepDisabled (\(String(result, radix: 16))).")
        }
        guard try sleepDisabled() == disabled else {
            throw ToolkitHelperError("SleepDisabled does not read as it was set.")
        }
    }

    func setTimer(_ timer: SleepTimer, minutes: Int) throws {
        var all = try preferences()
        guard var source = all[timer.source] as? [String: Any] else {
            throw ToolkitHelperError("macOS has no settings for \(timer.source).")
        }
        source[timer.key] = minutes
        all[timer.source] = source
        let result = IOPMSetPMPreferences(all as CFDictionary)
        guard result == kIOReturnSuccess else {
            throw ToolkitHelperError("macOS refused to change the timer (\(String(result, radix: 16))).")
        }
        guard SleepTimers(preferences: try preferences()).minutes[timer] == minutes else {
            throw ToolkitHelperError("The timer does not read as it was set.")
        }
    }
}

// One small file in the app's folder under /Library/Application Support. Its
// presence alone says that this helper set SleepDisabled.
private struct FileJournal: StayAwakeJournal {
    private let folder = "/Library/Application Support/io.github.sergkhl.MacHelm"
    private var path: String { folder + "/toolkit-helper-holds-stay-awake" }

    func load() -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func save(_ set: Bool) throws {
        if set {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
            guard FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o644]) else {
                throw ToolkitHelperError("Cannot write the helper's record.")
            }
        } else if load() {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}

private enum Signing {
    // The team this helper is signed by. An ad-hoc or unsigned build has none and serves nobody.
    static func team() throws -> String {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw ToolkitHelperError("The toolkit helper needs a valid Apple signature.")
        }
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw ToolkitHelperError("An ad-hoc or unsigned toolkit helper serves nobody.")
        }
        return team
    }
}

// One connection's requests. All of them run on the one queue that keeps the controller.
private final class Endpoint: NSObject, ToolkitHelperXPC {
    private let controller: ToolkitHelperController
    private let queue: DispatchQueue
    let client: Int

    init(controller: ToolkitHelperController, queue: DispatchQueue, client: Int) {
        self.controller = controller
        self.queue = queue
        self.client = client
    }

    func powerState(protocolVersion: Int, reply: @escaping (Data) -> Void) {
        queue.async { [controller] in
            guard protocolVersion == ToolkitHelperIdentity.protocolVersion else {
                return reply(ToolkitHelperReply(error: "MacHelm and its toolkit helper are of different versions.").encoded())
            }
            reply(controller.state().encoded())
        }
    }

    func holdStayAwake(_ hold: Bool, reply: @escaping (Data) -> Void) {
        queue.async { [controller, client] in reply(controller.hold(hold, client: client).encoded()) }
    }

    func setSleepTimer(_ timer: String, minutes: Int, reply: @escaping (Data) -> Void) {
        queue.async { [controller] in reply(controller.setTimer(timer, minutes: minutes).encoded()) }
    }

    func removeDirectory(atPath path: String, reply: @escaping (Data) -> Void) {
        queue.async { [controller] in reply(controller.remove(path: path).encoded()) }
    }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    private let requirement: String
    private let controller: ToolkitHelperController
    private let queue: DispatchQueue
    private var connections = 0
    private var nextClient = 0

    init(requirement: String, controller: ToolkitHelperController, queue: DispatchQueue) {
        self.requirement = requirement
        self.controller = controller
        self.queue = queue
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Foundation checks every message against the identity the kernel
        // gives for the sender. Set before resume: nothing answers a process
        // that is not MacHelm signed by this helper's team.
        connection.setCodeSigningRequirement(requirement)
        let client: Int = queue.sync {
            connections += 1
            nextClient += 1
            return nextClient
        }
        connection.exportedInterface = NSXPCInterface(with: ToolkitHelperXPC.self)
        connection.exportedObject = Endpoint(controller: controller, queue: queue, client: client)
        let gone: () -> Void = { [weak self] in self?.gone(client) }
        connection.invalidationHandler = gone
        connection.interruptionHandler = gone
        connection.resume()
        return true
    }

    // MacHelm quit, crashed or lost its connection: what was held for it is cleared.
    private func gone(_ client: Int) {
        queue.async {
            self.controller.clientGone(client)
            self.connections = max(0, self.connections - 1)
            self.exitWhenIdle()
        }
    }

    // Idle and holding nothing, the helper leaves. launchd starts it again for the next request.
    func exitWhenIdle() {
        queue.asyncAfter(deadline: .now() + 10) {
            if self.connections == 0, self.controller.isIdle { exit(0) }
        }
    }
}

@main
private enum ToolkitHelperMain {
    static func main() {
        do {
            guard CommandLine.arguments.count == 1, geteuid() == 0 else {
                throw ToolkitHelperError("The toolkit helper must be started by its approved root launch daemon.")
            }
            let team = try Signing.team()
            let requirement = "anchor apple generic and identifier \"\(ToolkitHelperIdentity.app)\" and certificate leaf[subject.OU] = \"\(team)\""
            var compiled: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &compiled) == errSecSuccess else {
                throw ToolkitHelperError("Cannot compile the signing requirement.")
            }
            let queue = DispatchQueue(label: "MacHelm.toolkit-helper")
            let controller = ToolkitHelperController(power: DarwinPowerSystem(), journal: FileJournal(), remover: RootRemover())
            // A hold left by a run that ended without releasing it is cleared before anything is served.
            queue.sync { controller.start() }
            // launchd stops the helper with the terminate signal, as when the
            // owner turns MacHelm off under Login Items & Extensions. What
            // the helper set must not outlive it: nothing would start it
            // again to clear it. The handler runs on the controller's queue.
            signal(SIGTERM, SIG_IGN)
            let stopped = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
            stopped.setEventHandler {
                controller.stopping()
                exit(0)
            }
            stopped.resume()
            let delegate = Listener(requirement: requirement, controller: controller, queue: queue)
            let listener = NSXPCListener(machServiceName: ToolkitHelperIdentity.helper)
            listener.delegate = delegate
            listener.resume()
            delegate.exitWhenIdle()
            withExtendedLifetime((delegate, stopped)) { RunLoop.current.run() }
        } catch {
            fputs("ToolkitHelper: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
