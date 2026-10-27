import ScreenshotProCapture
import ScreenshotProCore
import ServiceManagement
import SwiftUI

/// General: launch at login, feedback after captures, text hints, Screen Recording status.
struct GeneralSettingsTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var login = LaunchAtLogin.shared
    @State private var screenRecordingGranted = ScreenRecordingPermission.isGranted

    var body: some View {
        SettingsTab(restoreDefaults: restoreDefaults) {
            Section("Startup") {
                Toggle("Launch Screenshot Pro at login", isOn: Binding(
                    get: { login.isOn },
                    set: { login.setEnabled($0) }
                ))
                Text(login.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if login.status == .requiresApproval {
                    Button("Open Login Items Settings") { login.openLoginItemsSettings() }
                }
                if let error = login.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("After a capture") {
                Toggle("Show notifications", isOn: $store.settings.showNotifications)
                Toggle("Play camera sound", isOn: $store.settings.playCameraSound)
            }

            Section("Hints") {
                Toggle("Show text hints in the capture overlay and editor", isOn: $store.settings.showTextHints)
            }

            Section("Screen Recording") {
                LabeledContent("Permission") {
                    Label(screenRecordingGranted ? "Allowed" : "Not allowed",
                          systemImage: screenRecordingGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(screenRecordingGranted ? Color.green : Color.orange)
                }
                HStack {
                    Button("Open System Settings") { ScreenRecordingPermission.openSystemSettings() }
                    Button("Help...") { PermissionWindowController.shared.show() }
                    Spacer()
                    Button("Check Again") { refreshPermission() }
                }
            }
        }
        .onAppear {
            refreshPermission()
            login.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermission()
            login.refresh()
        }
    }

    private func refreshPermission() {
        screenRecordingGranted = ScreenRecordingPermission.isGranted
    }

    private func restoreDefaults() {
        store.restore { s, d in
            s.showNotifications = d.showNotifications
            s.playCameraSound = d.playCameraSound
            s.showTextHints = d.showTextHints
        }
    }
}
