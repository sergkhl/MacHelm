import Foundation

// The app's side of "Fan Control starts as you left it". The helper does not
// compile this file.

// SR-Q1 (owner, 2026-10-11): the saved choice is the owner's last one. It is
// on while Fan Control is on, is being turned on, or is waiting to come back
// after a sleep or a launch. Quitting keeps it, and so do a force-quit and a
// crash, which run no code. Whatever else ends control saves off, because
// Fan Control then has to be turned on again by hand.
public struct FanRememberedChoice: Equatable {
    public private(set) var on: Bool
    private var quitting = false

    public init(saved: Bool) { on = saved }

    // Returns the value to save when the choice changed, nil otherwise.
    public mutating func observe(enabled: Bool, beginning: Bool, resumePending: Bool) -> Bool? {
        guard !quitting else { return nil }
        return set(enabled || beginning || resumePending)
    }

    // Quit releases the fans; that is not the owner turning Fan Control off.
    public mutating func beginQuit() { quitting = true }

    // A release at quit that was not confirmed, or that the helper finished
    // by its own recovery, is not brought back by the next launch.
    public mutating func releaseAtQuitUnconfirmed() -> Bool? { set(false) }

    private mutating func set(_ value: Bool) -> Bool? {
        guard value != on else { return nil }
        on = value
        return value
    }
}

// SR-Q2 (owner, 2026-10-11): with on saved, a launch brings Fan Control back
// by the rule that follows a wake: three healthy readings in a row, every fan
// automatic, no hold and no other fan utility.
// SR-Q7 (owner, 2026-10-11): for 30 seconds from launch it keeps waiting for
// those readings, whatever else it sees: a helper that reads not approved or
// does not answer, a passing fault label, a reading that is not healthy, fans
// that are not automatic yet. Each of these starts the count again. At the
// end it stays off and says what was in the way. Only a recovery hold, the
// helper's own recovery and another fan utility end it at once.
public struct FanLaunchResume {
    public static let helperWait: TimeInterval = 30

    public enum Decision: Equatable {
        case wait
        case begin
        case stayOff(String)
    }

    private static let lead = "Fan Control was on when MacHelm last ran."
    private let deadline: TimeInterval
    private var qualification = FanWakeQualification()

    public init(launchedAt: TimeInterval) { deadline = launchedAt + Self.helperWait }

    // `helperReady` is a fresh compatibility check on the current connection
    // with no other request in flight; only then does `status` describe the
    // helper as it is now.
    public mutating func consider(helperApproved: Bool, helperReady: Bool, status: FanStatus,
                                  now: TimeInterval, conflict: String?) -> Decision {
        guard helperApproved else {
            qualification.reset()
            return notYet("its helper is not approved", now: now)
        }
        guard helperReady else {
            qualification.reset()
            return notYet("the helper was not ready", now: now)
        }
        if status.externalRecoveryRequired || status.mode == .externalRecoveryRequired {
            return .stayOff("\(Self.lead) A recovery hold is in place, so it stays off.")
        }
        // After the helper's own recovery Fan Control stays off until the owner
        // turns it on again. The app may not have been running to save that.
        // The helper keeps the receipt until the next begin, which would drop
        // it, but only in memory: a restarted helper no longer has it.
        if status.selfRecoveryReceipt != nil {
            return .stayOff("\(Self.lead) Since then a fan command could not be confirmed and the helper returned the fans to automatic, so it stays off.")
        }
        if let conflict {
            return .stayOff("\(Self.lead) Another fan utility is in the way (\(conflict)), so it stays off.")
        }
        if status.mode == .unavailable || status.mode == .restorationFailed {
            qualification.reset()
            return notYet("the helper reports a fault: \(status.reason ?? status.mode.title)", now: now)
        }
        do {
            if try qualification.observe(status, now: now, conflict: nil) { return .begin }
            return notYet("three healthy readings in a row did not come", now: now)
        } catch FanControlError.ownership {
            return notYet("the fans are not all automatic, or the helper still holds them", now: now)
        } catch {
            return notYet("the fan readings were not healthy: \(error.localizedDescription)", now: now)
        }
    }

    // Inside the wait this is not an answer yet; at its end it is the reason.
    private func notYet(_ obstacle: String, now: TimeInterval) -> Decision {
        guard now >= deadline else { return .wait }
        let reason = obstacle.hasSuffix(".") ? String(obstacle.dropLast()) : obstacle
        return .stayOff("\(Self.lead) It could not be turned on within \(Int(Self.helperWait)) seconds, so it stays off: \(reason).")
    }
}
