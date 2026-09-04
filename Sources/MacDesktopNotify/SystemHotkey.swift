import Carbon
import Foundation
import Observation

/// A system-registered global hotkey (RegisterEventHotKey), not an NSEvent
/// monitor. The difference is the whole point:
///
/// - `NSEvent.addGlobalMonitorForEvents` can only *observe* keys, never
///   consume them, and requires Accessibility trust to see them at all — a
///   toggle built on it is a switch that silently does nothing.
/// - `RegisterEventHotKey` is the API the system built for exactly this. It
///   works without any permission prompt and the keystroke never reaches the
///   foreground app.
@MainActor
final class SystemHotkey {
    /// Carbon's handler context. The pointer given to Carbon is retained by
    /// us (`passRetained`) and stored here so it lives exactly as long as the
    /// registration; Carbon never manages it.
    private final class Box {
        let action: () -> Void
        let signature: OSType
        let id: UInt32
        fileprivate var retainedPointer: UnsafeMutableRawPointer?

        init(action: @escaping () -> Void, signature: OSType, id: UInt32) {
            self.action = action
            self.signature = signature
            self.id = id
        }
    }

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var box: Box?
    /// Exposed so the app delegate can tell which keys Carbon currently owns:
    /// while a ⌘n registration is live, the NSEvent monitor path must stand
    /// down for that key or the action would fire twice.
    private(set) var keyCode: UInt32 = 0
    /// Carbon teardown in `deinit` touches non-Sendable refs from a nonisolated
    /// context; these mirrors exist only for that path. The main-actor state
    /// above remains the source of truth while the object is alive.
    private nonisolated(unsafe) var carbonReferenceForTeardown: EventHotKeyRef?
    private nonisolated(unsafe) var carbonHandlerForTeardown: EventHandlerRef?

    /// Registers a hotkey; returns nil if registration failed (already taken).
    static func register(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        signature: OSType,
        id: UInt32,
        action: @escaping () -> Void
    ) -> SystemHotkey? {
        let hotkey = SystemHotkey()
        guard hotkey.install(keyCode: keyCode, carbonModifiers: carbonModifiers, signature: signature, id: id, action: action) else {
            return nil
        }
        return hotkey
    }

    private init() {}

    deinit {
        // Safe in practice: the class is MainActor-confined and dies with its
        // single owner (the app delegate) at teardown, when no Carbon events
        // can arrive anymore. The mirrors below are written only alongside the
        // isolated originals.
        if let carbonReferenceForTeardown { UnregisterEventHotKey(carbonReferenceForTeardown) }
        if let carbonHandlerForTeardown { RemoveEventHandler(carbonHandlerForTeardown) }
    }

    private func install(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        signature: OSType,
        id: UInt32,
        action: @escaping () -> Void
    ) -> Bool {
        let box = Box(action: action, signature: signature, id: id)
        let boxPointer = Unmanaged.passRetained(box).toOpaque()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // A C function pointer cannot capture context; the box travels as the
        // handler's user data and is matched by signature/id so a stray
        // hot-key event from another owner cannot fire this action.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let box = Unmanaged<Box>.fromOpaque(userData).takeUnretainedValue()
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                UInt32(kEventParamDirectObject),
                UInt32(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotkeyID
            )
            guard status == noErr, hotkeyID.signature == box.signature, hotkeyID.id == box.id else {
                return noErr
            }
            MainActor.assumeIsolated {
                box.action()
            }
            return noErr
        }

        guard InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            boxPointer,
            &handler
        ) == noErr else {
            Unmanaged<Box>.fromOpaque(boxPointer).release()
            return false
        }

        let hotkeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        guard RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        ) == noErr else {
            RemoveEventHandler(handler)
            handler = nil
            Unmanaged<Box>.fromOpaque(boxPointer).release()
            return false
        }
        reference = ref
        self.keyCode = keyCode
        carbonReferenceForTeardown = ref
        carbonHandlerForTeardown = handler
        box.retainedPointer = boxPointer
        self.box = box
        return true
    }

    func unregister() {
        if let ref = reference {
            UnregisterEventHotKey(ref)
            reference = nil
        }
        if let installed = handler {
            RemoveEventHandler(installed)
            handler = nil
        }
        // Clear the deinit mirrors alongside the isolated originals: left
        // set, deinit would unregister a second time through a dangling
        // Carbon reference on every mid-run replacement of this object
        // (each toggle of the hotkey setting drops and recreates it).
        carbonReferenceForTeardown = nil
        carbonHandlerForTeardown = nil
        // Balance the passRetained: Carbon no longer holds the pointer after
        // both entry points above are torn down.
        if let pointer = box?.retainedPointer {
            Unmanaged<Box>.fromOpaque(pointer).release()
        }
        box = nil
    }
}

extension SystemHotkey {
    /// N in Carbon virtual key codes.
    static let nKeyCode: UInt32 = 45
    /// 1 / 2 / 3 in Carbon virtual key codes — the ⌘-number action shortcuts.
    static let actionKeyCodes: [UInt32] = [18, 19, 20]
    /// Control + Option in Carbon's modifier vocabulary.
    static let controlOptionModifiers: UInt32 = UInt32(controlKey | optionKey)
    /// Command alone in Carbon's modifier vocabulary.
    static let commandModifiers: UInt32 = UInt32(cmdKey)
}
