import Carbon.HIToolbox
import Foundation

/// Temporary global hotkeys for the few keys the overlay must never miss (Esc, Return, Space).
///
/// With cooperative activation (macOS 14+) keyboard focus can stay with the previous app even
/// though our non-activating panel is key (docs/analysis/03 section 2.2). Carbon hotkeys need no
/// permission and reach us regardless of focus. Registered only while an overlay or countdown
/// is visible. Our handler is installed after the app's own hotkey handler, so it runs first;
/// it consumes only events carrying its own signature.
@MainActor
final class OverlayKeyGrabber {
    enum Key: UInt32, CaseIterable {
        case escape = 1, enter, keypadEnter, space

        var keyCode: UInt32 {
            switch self {
            case .escape: return UInt32(kVK_Escape)
            case .enter: return UInt32(kVK_Return)
            case .keypadEnter: return UInt32(kVK_ANSI_KeypadEnter)
            case .space: return UInt32(kVK_Space)
            }
        }
    }

    nonisolated private static let signature: OSType = 0x5350_4F56 // "SPOV"
    private static weak var active: OverlayKeyGrabber?

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var onKey: ((Key) -> Void)?

    /// Starts grabbing `keys`; `onKey` runs on the main actor.
    func start(_ keys: [Key], onKey: @escaping (Key) -> Void) {
        stop()
        self.onKey = onKey
        OverlayKeyGrabber.active = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == OverlayKeyGrabber.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let key = Key(rawValue: id) else { return }
                    OverlayKeyGrabber.active?.onKey?(key)
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        for key in keys {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key.keyCode, 0, EventHotKeyID(signature: OverlayKeyGrabber.signature, id: key.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
        }
    }

    func stop() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        onKey = nil
        if OverlayKeyGrabber.active === self { OverlayKeyGrabber.active = nil }
    }
}
