import Foundation
import Security
#if canImport(FanControlCore)
import FanControlCore
#endif

public enum FanSigning {
    public static func selfIdentity() throws -> (team: String, hash: String) {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw FanControlError.unavailable("Fan Control requires a valid Apple-signed app and bundled helper.")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            throw FanControlError.unavailable("Cannot inspect the app's signing identity.")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              let hash = values[kSecCodeInfoUnique as String] as? Data else {
            throw FanControlError.unavailable("Ad-hoc or unsigned builds cannot authenticate Fan Control. Build app and helper with the same Apple signing team.")
        }
        return (team, hash.map { String(format: "%02x", $0) }.joined())
    }

    public static func requirement(identifier: String, team: String) throws -> String {
        guard [FanServiceIdentity.app, FanServiceIdentity.helper].contains(identifier),
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw FanControlError.invalid("Invalid trusted signing identity.")
        }
        let requirement = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &compiled) == errSecSuccess else {
            throw FanControlError.invalid("Cannot compile the Fan Control signing requirement.")
        }
        return requirement
    }

    public static func verifyBundledHelper(at url: URL) throws {
        let identity = try selfIdentity()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code else {
            throw FanControlError.unavailable("The bundled Fan Control helper is missing.")
        }
        var requirement: SecRequirement?
        let text = try self.requirement(identifier: FanServiceIdentity.helper, team: identity.team)
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw FanControlError.unavailable("The bundled helper does not match this app's signing team and identity.")
        }
    }
}

public enum FanUtilityRegistry {
    // The idle smcwrite helper is intentionally absent. Only the verified GUI
    // identity is registered; this cannot detect every unknown fan writer.
    public static let identities = ["com.crystalidea.macsfancontrol": "Macs Fan Control"]

    public static func runningConflict() -> String? {
        let count = proc_listallpids(nil, 0)
        guard count > 0, count < 131_072 else { return "Process detection unavailable" }
        var processes = [pid_t](repeating: 0, count: Int(count) + 128)
        let capacity = processes.count * MemoryLayout<pid_t>.stride
        let result = proc_listallpids(&processes, Int32(capacity))
        guard result > 0, result < processes.count else { return "Process detection unavailable" }
        for pid in processes.prefix(Int(result)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let url = URL(fileURLWithPath: String(cString: path))
            // Limit code-inspection cost to candidates from the known utility.
            guard url.lastPathComponent == "Macs Fan Control" || url.lastPathComponent == "macsfancontrol" else { continue }
            var code: SecStaticCode?
            var information: CFDictionary?
            guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess, let code,
                  SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
                  let values = information as? [String: Any],
                  let identifier = values[kSecCodeInfoIdentifier as String] as? String,
                  let name = identities[identifier] else {
                return "A possible Macs Fan Control process"
            }
            return name
        }
        return nil
    }
}
