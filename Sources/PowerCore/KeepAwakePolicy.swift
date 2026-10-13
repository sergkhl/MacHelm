import Foundation

public enum KeepAwakeStatus: Equatable, Sendable {
    case off
    // In force, with the lid closed as well.
    case on
    // Without the toolkit helper: the Mac does not sleep by itself, and closing the lid still sleeps it.
    case idleOnly
    // On battery at or below the level: the Mac may sleep.
    case paused(charge: Int, level: Int)
}

// What Keep Awake puts in force for the state the Mac is in.
public struct KeepAwakeEffect: Equatable, Sendable {
    // The app's own assertion, which ends with the app.
    public var preventsIdleSleep: Bool
    // The helper's hold, which also covers a closed lid.
    public var holdsStayAwake: Bool
    public var status: KeepAwakeStatus

    public init(preventsIdleSleep: Bool, holdsStayAwake: Bool, status: KeepAwakeStatus) {
        self.preventsIdleSleep = preventsIdleSleep
        self.holdsStayAwake = holdsStayAwake
        self.status = status
    }
}

public enum KeepAwakePolicy {
    // The battery level, in percent.
    public static let levels = Array(stride(from: 5, through: 50, by: 5))
    public static let defaultLevel = 20

    // Q21 and Q30: on battery, at or below the level, it pauses and the Mac
    // may sleep; on the power adapter the level does not count.
    public static func effect(on: Bool, onBattery: Bool, charge: Int?, level: Int, helperAvailable: Bool) -> KeepAwakeEffect {
        guard on else { return KeepAwakeEffect(preventsIdleSleep: false, holdsStayAwake: false, status: .off) }
        if onBattery, let charge, charge <= level {
            return KeepAwakeEffect(preventsIdleSleep: false, holdsStayAwake: false, status: .paused(charge: charge, level: level))
        }
        return KeepAwakeEffect(preventsIdleSleep: true, holdsStayAwake: helperAvailable, status: helperAvailable ? .on : .idleOnly)
    }

    public static func note(_ status: KeepAwakeStatus) -> String {
        switch status {
        case .off: return "The Mac sleeps as its timers say."
        case .on: return "The Mac stays awake, also with the lid closed. The display still turns off."
        case .idleOnly: return "The Mac does not sleep by itself. Closing the lid still sleeps it: that needs the toolkit helper."
        case .paused(let charge, let level):
            return "Paused at \(charge)% on battery (level \(level)%). In force again on the power adapter."
        }
    }
}

// When Sleep Now asks macOS for the sleep (L32). A sleep that was asked for
// is called off by any touch in its first five seconds, and the finger that
// pressed Sleep Now is such a touch: on 2026-10-12 two presses of three were
// called off a tenth of a second after they began.
public enum SleepNowWait {
    // Trackpad and keyboard must have been still for this long.
    public static let still: TimeInterval = 1
    // After this long the sleep is asked for whatever the hands do.
    public static let limit: TimeInterval = 5
    // How often the press looks again.
    public static let pace: TimeInterval = 0.1

    // `idle` is the time since the last input, nil where macOS does not say;
    // `waited` the time since the press.
    public static func asks(idle: TimeInterval?, waited: TimeInterval) -> Bool {
        guard waited < limit else { return true }
        // A press that was no input, as one by VoiceOver, leaves the hands
        // still from long before: the stillness counts from the press at the earliest.
        let quiet = idle.flatMap { $0.isFinite && $0 >= 0 ? min($0, waited) : nil } ?? waited
        return quiet >= still
    }
}

// Sleep Now from the press to the owner's return (L32, and the review of the
// four changes on 2026-10-12). Lifting Keep Awake's hold for a sleep must not
// end with the hold back while the Mac is asleep: this Mac wakes by itself
// for seconds at a time with its display off, MacHelm's timers run then,
// and a hold set then keeps the Mac from sleeping again.
public struct SleepNowCourse: Equatable, Sendable {
    // The press that waits for still hands, by its number.
    public private(set) var waiting: Int?
    // The hold is lifted for a sleep; Keep Awake is not put in force meanwhile.
    public private(set) var lifted = false
    // macOS said that the Mac is going to sleep.
    public private(set) var began = false
    private var presses = 0
    private var sleeps = 0

    public init() {}

    // Sleep Now was pressed. nil while an earlier press still waits.
    public mutating func press() -> Int? {
        guard waiting == nil else { return nil }
        presses += 1
        waiting = presses
        return presses
    }

    // Whether this press still waits. A sleep or a wake in between ends the wait.
    public func waits(_ press: Int) -> Bool {
        waiting == press
    }

    // The wait is over and macOS is asked for the sleep, with Keep Awake's
    // hold lifted first where it is held. The number is this sleep's.
    public mutating func ask(lifting: Bool) -> Int {
        waiting = nil
        sleeps += 1
        began = false
        if lifting { lifted = true }
        return sleeps
    }

    // macOS: the Mac is going to sleep. A press that still waited is
    // dropped, so that the Mac does not sleep again after its wake.
    public mutating func sleepBegins() {
        waiting = nil
        began = true
    }

    // A wake, or the displays coming on. Whether everything is read again
    // and Keep Awake put in force. After Sleep Now only the owner's return
    // does that: a wake the Mac makes by itself has the display off.
    public mutating func wake(displayAwake: Bool) -> Bool {
        waiting = nil
        if lifted, !displayAwake { return false }
        lifted = false
        began = false
        return true
    }

    // Thirty seconds after a sleep was asked for. Whether Keep Awake comes
    // back: only where that sleep never began, and no later one was asked for.
    public mutating func fallback(_ sleep: Int) -> Bool {
        guard lifted, !began, sleep == sleeps else { return false }
        lifted = false
        return true
    }

    // The owner is at the Mac: a page appeared, the menu opened, Keep Awake was switched.
    public mutating func ownerIsHere() {
        lifted = false
        began = false
    }
}
