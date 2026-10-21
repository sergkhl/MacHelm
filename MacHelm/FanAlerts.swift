import AppKit
import UserNotifications

// Z-Q5 and Z-Q7: macOS notifications for a recovery hold that waits on the
// owner, and for a hold the helper cleared by itself, which leaves Fan Control
// paused. Permission is asked when Fan Control is turned on, or comes back on
// at launch or after wake, while the owner is at the Mac, so the first alert
// is never the permission prompt.
//
// Each hold and each self-recovery is announced once, across launches; an
// alert is withdrawn once what it describes has ended, and alerts left from
// an earlier run are withdrawn at the first status. A restoration the helper
// could not complete while it owns an override is not a hold, but a fan may
// be left in manual mode too; it is announced once it has lasted ten seconds.
@MainActor
final class FanAlerts: NSObject, UNUserNotificationCenterDelegate {
    // Created before launch finishes, so a click that launches MacHelm reaches it.
    static let shared = FanAlerts()
    // Where a click on an alert leads: the Cooling page. A click that arrives
    // before the dashboard exists waits for it.
    var openCooling: (() -> Void)? {
        didSet { if openPending, let openCooling { openPending = false; openCooling() } }
    }
    static let stuckDelay: TimeInterval = 10
    private var openPending = false
    private var permissionAsked = false
    private var cleanedUp = false
    private var stuckSince: TimeInterval?
    private var stuckAnnounced = false
    private static let holdPrefix = "fan-hold-", recoveredPrefix = "fan-recovered-", stuckID = "fan-not-restored"
    private static let holdKey = "FanAlertsAnnouncedHold", recoveryKey = "FanAlertsAnnouncedRecovery"
    private var announcedHold: String? {
        get { UserDefaults.standard.string(forKey: Self.holdKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.holdKey) }
    }
    private var announcedRecovery: String? {
        get { UserDefaults.standard.string(forKey: Self.recoveryKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.recoveryKey) }
    }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func askPermission() {
        guard !permissionAsked else { return }
        permissionAsked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // Called with each status the app applies from the helper.
    func observe(_ status: FanStatus, holdMessage: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let held = status.externalRecoveryRequired || status.mode == .externalRecoveryRequired
        if held {
            // Announced once the helper's own attempt is no longer running,
            // and still announced through any later attempt on the same hold.
            let id = status.externalRecoveryID ?? "unidentified"
            if status.mode != .restoring, id != announcedHold {
                if let previous = announcedHold { withdraw(Self.holdPrefix + previous) }
                announcedHold = id
                // A hold waiting for disk space says so; the helper retries it.
                let body = status.storageRecoveryPending == true ? status.reason ?? holdMessage : holdMessage
                post(Self.holdPrefix + id, title: "Fan recovery required", body: body)
            }
        } else if let announced = announcedHold {
            announcedHold = nil
            withdraw(Self.holdPrefix + announced)
        }

        // The receipt stays in status until Fan Control is turned on again.
        let recovered = status.selfRecoveryReceipt.flatMap { $0.trigger != .explicit && $0.confirmedAt != nil ? $0.recoveryID : nil }
        if let recovered, recovered != announcedRecovery {
            if let previous = announcedRecovery { withdraw(Self.recoveredPrefix + previous) }
            announcedRecovery = recovered
            post(Self.recoveredPrefix + recovered, title: "Fan Control paused",
                 body: "A fan command could not be confirmed, so the helper returned the fans to automatic and checked them. Turn Fan Control on again to resume.")
        } else if recovered == nil, let announced = announcedRecovery {
            announcedRecovery = nil
            withdraw(Self.recoveredPrefix + announced)
        }

        if !held && status.mode == .restorationFailed && status.ownsOverride {
            let since = stuckSince ?? now
            stuckSince = since
            if !stuckAnnounced, now - since >= Self.stuckDelay {
                stuckAnnounced = true
                post(Self.stuckID, title: "Fans not returned to automatic",
                     body: "MacHelm keeps trying to return its fans to automatic. \(status.reason ?? "Open the Cooling page for the cause.")")
            }
        } else {
            stuckSince = nil
            if stuckAnnounced { stuckAnnounced = false; withdraw(Self.stuckID) }
        }

        if !cleanedUp {
            cleanedUp = true
            let current = Set([announcedHold.map { Self.holdPrefix + $0 }, announcedRecovery.map { Self.recoveredPrefix + $0 },
                               stuckAnnounced ? Self.stuckID : nil].compactMap { $0 })
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let stale = delivered.map(\.request.identifier).filter { $0.hasPrefix("fan-") && !current.contains($0) }
                if !stale.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale) }
            }
        }
    }

    private func post(_ id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func withdraw(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    // Shown while MacHelm is in front too: the Cooling page may not be.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run {
            if let openCooling { openCooling() } else { openPending = true }
        }
    }
}
