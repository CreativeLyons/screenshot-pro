import ScreenshotProCore
import SwiftUI

/// Printing: how the Print destination places the image on the page.
struct PrintingSettingsTab: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        SettingsTab(restoreDefaults: restoreDefaults) {
            Section("Page layout") {
                Toggle("Shrink to fit the page", isOn: $store.settings.printFitToPage)
                Toggle("Enlarge to fill the page", isOn: $store.settings.printAllowEnlarge)
                Toggle("Rotate when the image fits the page better", isOn: $store.settings.printAllowRotate)
                Toggle("Center on the page", isOn: $store.settings.printCenter)
            }
            Section("Footer") {
                Toggle("Print date, time and title below the image", isOn: $store.settings.printFooter)
            }
        }
    }

    private func restoreDefaults() {
        store.restore { s, d in
            s.printFitToPage = d.printFitToPage
            s.printCenter = d.printCenter
            s.printAllowRotate = d.printAllowRotate
            s.printAllowEnlarge = d.printAllowEnlarge
            s.printFooter = d.printFooter
        }
    }
}
