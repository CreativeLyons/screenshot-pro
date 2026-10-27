import ScreenshotProCore
import SwiftUI

/// Capture: mouse pointer, magnifier, window shadow and the delay before capturing.
struct CaptureSettingsTab: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        SettingsTab(restoreDefaults: restoreDefaults) {
            Section("Capture") {
                Toggle("Capture mouse pointer", isOn: $store.settings.captureMousePointer)
                Toggle("Always show the magnifier while selecting a region", isOn: $store.settings.alwaysShowMagnifier)
                Text("When off, hold Shift while selecting to show it. Z switches it on or off for one capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Include window shadow in window captures", isOn: $store.settings.windowShadow)
            }
            Section("Screenshot Filmstrip") {
                Stepper(value: $store.settings.historyLimit, in: 0...50) {
                    LabeledContent("Keep the last") {
                        Text(store.settings.historyLimit == 0 ? "None (off)" : "\(store.settings.historyLimit) screenshots")
                            .monospacedDigit()
                    }
                }
                Picker("Thumbnail size", selection: $store.settings.historyStripSize) {
                    ForEach(HistoryStripSize.allCases, id: \.self) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Auto-hide the filmstrip", isOn: $store.settings.historyAutoHide)
                Text("Screen captures are kept in a filmstrip you open from the menu bar or with its hotkey: click one to open it, \u{2318}-click to copy it, drag it into any app, right click for more. Drag its grab bar anywhere: dropped near a screen edge it docks there and auto-hides, tucking into a small tab that slides out when you point at it, like the Dock; dropped anywhere else it stays pinned where you left it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Delay") {
                Stepper(value: $store.settings.captureDelay, in: 0...10, step: 1) {
                    LabeledContent("Wait before capturing") {
                        Text(delayText)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var delayText: String {
        let seconds = Int(store.settings.captureDelay)
        switch seconds {
        case 0: return "No delay"
        case 1: return "1 second"
        default: return "\(seconds) seconds"
        }
    }

    private func restoreDefaults() {
        store.restore { s, d in
            s.captureMousePointer = d.captureMousePointer
            s.alwaysShowMagnifier = d.alwaysShowMagnifier
            s.windowShadow = d.windowShadow
            s.captureDelay = d.captureDelay
            s.historyLimit = d.historyLimit
            s.historyStripSize = d.historyStripSize
            s.historyAutoHide = d.historyAutoHide
        }
    }
}
