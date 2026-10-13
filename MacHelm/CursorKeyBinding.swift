import Carbon
import Foundation

/// One fixed global shortcut, registered without activating MacHelm.
@MainActor
final class CursorKeyBinding {
    static let label = "⌃⌥⌘H"

    private static let identifier = EventHotKeyID(signature: 0x4D484355, id: 1) // MHCU
    private let action: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed = false

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func start() throws {
        guard handler == nil else { return }
        let events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let installation = events.withUnsafeBufferPointer { buffer in
            InstallEventHandler(GetApplicationEventTarget(), Self.receiveEvent,
                                buffer.count, buffer.baseAddress,
                                Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        guard installation == noErr else {
            stop()
            throw CursorKeyBindingError.failed(operation: "install", status: installation)
        }

        // Exclusive registration reports a collision instead of making two
        // applications react to the same combination.
        let registration = RegisterEventHotKey(UInt32(kVK_ANSI_H),
                                               UInt32(controlKey | optionKey | cmdKey),
                                               Self.identifier, GetApplicationEventTarget(),
                                               OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registration == noErr else {
            stop()
            throw CursorKeyBindingError.failed(operation: "register", status: registration)
        }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        pressed = false
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private nonisolated static let receiveEvent: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        // Carbon delivers this application-target handler from the main event
        // loop. Do not dispatch asynchronously: the EventRef is borrowed.
        guard Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
        return MainActor.assumeIsolated {
            Unmanaged<CursorKeyBinding>.fromOpaque(context).takeUnretainedValue().handle(event)
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &identifier)
        guard result == noErr,
              identifier.signature == Self.identifier.signature,
              identifier.id == Self.identifier.id else {
            return OSStatus(eventNotHandledErr)
        }

        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            if !pressed {
                pressed = true
                action()
            }
        case UInt32(kEventHotKeyReleased):
            pressed = false
        default:
            return OSStatus(eventNotHandledErr)
        }
        return noErr
    }
}

private enum CursorKeyBindingError: LocalizedError {
    case failed(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .failed(_, let status) where status == eventHotKeyExistsErr:
            return "The cursor shortcut is already in use by another app. You can still use the dashboard."
        case .failed(let operation, let status):
            return "Could not \(operation) the cursor shortcut (error \(status)). You can still use the dashboard."
        }
    }
}
