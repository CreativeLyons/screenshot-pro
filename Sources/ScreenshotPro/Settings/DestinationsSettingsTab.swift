import ScreenshotProCore
import ScreenshotProOutput
import SwiftUI

/// Destinations: ask with the picker, or run a fixed list; plus "always copy" and "always save".
struct DestinationsSettingsTab: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        SettingsTab(restoreDefaults: restoreDefaults) {
            Section {
                Toggle("Ask where to send each capture", isOn: $store.settings.askForDestination)
            } footer: {
                Text("Shows a picker after every capture. Turn this off to always use the destinations below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(DestinationRegistry.shared.available, id: \.id) { destination in
                    Toggle(isOn: binding(for: destination.id)) {
                        Label(destination.displayName, systemImage: destination.symbolName)
                    }
                }
            } header: {
                Text("Default destinations")
            } footer: {
                if !store.settings.askForDestination && store.settings.defaultDestinations.isEmpty {
                    Text("No destination is selected, so the picker is shown after each capture.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("All selected destinations run in order; the editor opens last.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(store.settings.askForDestination)

            Section("Always") {
                Toggle("Copy every capture to the clipboard", isOn: $store.settings.alwaysCopyToClipboard)
                Toggle("Save every capture to the output folder", isOn: $store.settings.alwaysSaveToFolder)
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { store.settings.defaultDestinations.contains(id) },
            set: { isOn in
                store.update { s in
                    s.defaultDestinations.removeAll { $0 == id }
                    if isOn { s.defaultDestinations.append(id) }
                }
            }
        )
    }

    private func restoreDefaults() {
        store.restore { s, d in
            s.askForDestination = d.askForDestination
            s.defaultDestinations = d.defaultDestinations
            s.alwaysCopyToClipboard = d.alwaysCopyToClipboard
            s.alwaysSaveToFolder = d.alwaysSaveToFolder
        }
    }
}
