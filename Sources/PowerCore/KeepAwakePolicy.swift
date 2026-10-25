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
