import ScreenshotProCore
import SwiftUI

/// The Settings tabs, so a tab can be selected from code.
enum SettingsTabID: String, CaseIterable {
    case general, hotkeys, capture, output, destinations, editor, printing
}

/// The selected Settings tab.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTabID = .general
}

/// The Settings window content: one tab per area of `ScreenshotProSettings`.
struct SettingsView: View {
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTabID.general)
            HotkeysSettingsTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
                .tag(SettingsTabID.hotkeys)
            CaptureSettingsTab()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                .tag(SettingsTabID.capture)
            OutputSettingsTab()
                .tabItem { Label("Output", systemImage: "folder") }
                .tag(SettingsTabID.output)
            DestinationsSettingsTab()
                .tabItem { Label("Destinations", systemImage: "arrow.up.right.square") }
                .tag(SettingsTabID.destinations)
            EditorSettingsTab()
                .tabItem { Label("Editor", systemImage: "pencil.and.outline") }
                .tag(SettingsTabID.editor)
            PrintingSettingsTab()
                .tabItem { Label("Printing", systemImage: "printer") }
                .tag(SettingsTabID.printing)
        }
        .frame(width: 600, height: 540)
    }
}

/// Lays out one tab: a grouped form with a "Restore Defaults" button underneath.
struct SettingsTab<Content: View>: View {
    var restoreDefaults: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Form { content }
                .formStyle(.grouped)
            if let restoreDefaults {
                HStack {
                    Spacer()
                    Button("Restore Defaults", action: restoreDefaults)
                }
                .padding([.horizontal, .bottom], 20)
            }
        }
    }
}

extension SettingsStore {
    /// Copies the given fields from a fresh `ScreenshotProSettings` (one tab's "Restore Defaults").
    func restore(_ apply: @escaping (inout ScreenshotProSettings, ScreenshotProSettings) -> Void) {
        let defaults = ScreenshotProSettings()
        update { apply(&$0, defaults) }
    }
}

/// Bridges `RGBAColor` (settings) and `CGColor` (SwiftUI ColorPicker).
extension Binding where Value == RGBAColor {
    var cgColor: Binding<CGColor> {
        Binding<CGColor>(
            get: { wrappedValue.cgColor },
            set: { color in
                guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                      let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
                      let c = converted.components, c.count >= 3 else { return }
                wrappedValue = RGBAColor(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]),
                                         alpha: Double(converted.alpha))
            }
        )
    }
}

/// Bridges an `Int` setting to a `Double` for sliders.
extension Binding where Value == Int {
    var asDouble: Binding<Double> {
        Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = Int($0.rounded()) })
    }
}
