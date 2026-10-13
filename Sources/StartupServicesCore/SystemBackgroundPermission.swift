import Foundation
import ServiceManagement

// The macOS switch under Login Items & Extensions, read through the
// LaunchAgents this feature installed. It is only read, never changed.
public struct SystemBackgroundPermission: BackgroundPermissionReading {
    public init() {}

    public func permission(forInstalled plists: [URL]) -> BackgroundPermission {
        var allowed = false
        for url in plists {
            switch SMAppService.statusForLegacyPlist(at: url) {
            case .requiresApproval: return .blocked
            case .enabled: allowed = true
            default: break
            }
        }
        return allowed ? .allowed : .unknown
    }
}
