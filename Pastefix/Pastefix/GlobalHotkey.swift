import AppKit
import Carbon.HIToolbox

/// A fixed global hotkey (Cmd-Shift-C) via Carbon RegisterEventHotKey.
/// No Accessibility permission required. Rebindable hotkeys are a Plan 2b concern.
final class GlobalHotkey {
    private let onFire: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x50465831 // 'PFX1'

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
    }

    deinit { unregister() }

    func register() {
        guard hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                // Retain across the async hop so onFire can never run on a freed instance;
                // takeRetainedValue() in the block balances this passRetained.
                let retained = Unmanaged.passRetained(hotkey)
                DispatchQueue.main.async {
                    retained.takeRetainedValue().onFire()
                }
                return noErr
            },
            1, &eventType, selfPtr, &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_C),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
    }
}
