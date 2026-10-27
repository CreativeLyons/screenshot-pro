import ScreenshotProCore
import SwiftUI

/// Hotkeys: one recorder per action, with validation and registration failures shown inline.
struct HotkeysSettingsTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var manager = HotkeyManager.shared
    /// Rejection messages from the last recording attempt, per action.
    @State private var messages: [HotkeyAction: String] = [:]

    var body: some View {
        SettingsTab(restoreDefaults: restoreDefaults) {
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    row(for: action)
                }
            } footer: {
                Text("""
                    Click a field and type the new shortcut. Esc cancels, Delete removes the shortcut. \
                    Shortcuts need Command or Control; F13 to F20 also work on their own.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(for action: HotkeyAction) -> some View {
        let combo = store.settings.hotkeys[action]
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(action.displayName) {
                HStack(spacing: 6) {
                    KeyRecorder(combo: combo,
                                onRecord: { record($0, for: action) },
                                onClear: { clear(action) })
                        .frame(width: 150, height: 24)
                    Button {
                        clear(action)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(combo == nil)
                    .help("Remove this shortcut")
                }
                // The recorder has no text baseline; align the label with the field's center.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .alignmentGuide(.lastTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
            if let message = messages[action] {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if let combo, manager.didFail(combo), !manager.isSuspended {
                Text("\(combo.label) could not be registered. macOS or another app may already use it.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func record(_ combo: KeyCombo, for action: HotkeyAction) {
        guard combo.isAllowedAsGlobalHotkey else {
            messages[action] = "\(combo.label) needs Command or Control (only F13 to F20 work alone)."
            return
        }
        if let other = store.settings.hotkeys.first(where: { $0.key != action && $0.value == combo })?.key {
            messages[action] = "\(combo.label) is already used by \(other.displayName)."
            return
        }
        messages[action] = nil
        store.update { $0.hotkeys[action] = combo }
    }

    private func clear(_ action: HotkeyAction) {
        messages[action] = nil
        store.update { $0.hotkeys[action] = nil }
    }

    private func restoreDefaults() {
        messages = [:]
        store.restore { s, d in s.hotkeys = d.hotkeys }
    }
}
