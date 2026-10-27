import Carbon.HIToolbox
import Combine
import ScreenshotProCore

/// Global hotkeys through Carbon's RegisterEventHotKey. It is old but still the supported way to
/// get system-wide shortcuts without Accessibility permission, and the hotkey is swallowed so
/// the frontmost app never sees it.
///
/// The manager remembers the last set of bindings so it can be suspended while the Settings
/// window records a new shortcut (otherwise pressing an existing hotkey would start a capture
/// instead of reaching the recorder) and resumed afterwards.
@MainActor
final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    /// One global shortcut and what it does.
    struct Hotkey {
        var combo: KeyCombo
        var action: () -> Void
    }

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    nonisolated static let signatureCode: OSType = 0x5350_524F // "SPRO"
    private let signature = HotkeyManager.signatureCode
    private var bindings: [Hotkey] = []
    private var suspendCount = 0

    /// Combos that failed to register (usually taken by macOS or another app), for the UI.
    @Published private(set) var failed: [KeyCombo] = []

    /// True while registrations are paused (a shortcut recorder is active).
    var isSuspended: Bool { suspendCount > 0 }

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            // Other handlers (the capture overlay's temporary keys) share this event target.
            guard hotKeyID.signature == HotkeyManager.signatureCode else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            // Run the action after the Carbon callback returns, so it may show menus or windows.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotkeyManager.shared.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// Replaces all registrations with `bindings`. Returns the combos that could not be registered.
    /// While suspended, the bindings are stored and registered on `resume()`.
    @discardableResult
    func register(_ bindings: [Hotkey]) -> [KeyCombo] {
        self.bindings = bindings
        guard !isSuspended else { return failed }
        return registerStoredBindings()
    }

    /// Unregisters every hotkey until the matching `resume()`. Calls nest.
    func suspend() {
        suspendCount += 1
        if suspendCount == 1 { unregisterAll() }
    }

    /// Re-registers the stored bindings once every `suspend()` has been balanced.
    func resume() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        if suspendCount == 0 { registerStoredBindings() }
    }

    /// True when `combo` failed to register the last time the bindings were applied.
    func didFail(_ combo: KeyCombo) -> Bool { failed.contains(combo) }

    @discardableResult
    private func registerStoredBindings() -> [KeyCombo] {
        unregisterAll()
        var failures: [KeyCombo] = []
        for binding in bindings {
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.combo.keyCode, binding.combo.carbonModifiers,
                                             EventHotKeyID(signature: signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[id] = ref
                handlers[id] = binding.action
            } else {
                failures.append(binding.combo)
            }
        }
        failed = failures
        return failures
    }

    private func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }
}
