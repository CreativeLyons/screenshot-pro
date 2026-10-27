import AppKit
import ScreenshotProCore
import SwiftUI

/// Editor: defaults for new elements, canvas expansion, resizing and obfuscation.
struct EditorSettingsTab: View {
    @ObservedObject private var store = SettingsStore.shared
    private let fontFamilies = NSFontManager.shared.availableFontFamilies

    var body: some View {
        SettingsTab(restoreDefaults: restoreDefaults) {
            Section("New elements") {
                ColorPicker("Line color", selection: $store.settings.editorLineColor.cgColor)
                ColorPicker("Fill color", selection: $store.settings.editorFillColor.cgColor)
                Stepper(value: $store.settings.editorLineThickness, in: 1...20, step: 1) {
                    LabeledContent("Line thickness") {
                        Text("\(Int(store.settings.editorLineThickness)) px").monospacedDigit()
                    }
                }
                Toggle("Drop shadow", isOn: $store.settings.editorShadow)
            }

            Section("Text") {
                Picker("Font", selection: $store.settings.editorFontName) {
                    if !fontFamilies.contains(store.settings.editorFontName) {
                        Text(store.settings.editorFontName).tag(store.settings.editorFontName)
                    }
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Stepper(value: $store.settings.editorFontSize, in: 6...144, step: 1) {
                    LabeledContent("Font size") {
                        Text("\(Int(store.settings.editorFontSize)) pt").monospacedDigit()
                    }
                }
                ColorPicker("Text color", selection: $store.settings.editorTextColor.cgColor)
            }

            Section("Image") {
                Stepper(value: $store.settings.expandCanvasAmount, in: 100...1000, step: 100) {
                    LabeledContent("Expand canvas by") {
                        Text("\(store.settings.expandCanvasAmount) px").monospacedDigit()
                    }
                }
                Toggle("Automatically resize large screenshots to fit the screen",
                       isOn: $store.settings.autoResizeLargeScreenshots)
                LabeledContent("Auto crop tolerance") {
                    sliderRow(value: $store.settings.autoCropTolerance.asDouble, range: 0...255,
                              text: "\(store.settings.autoCropTolerance)")
                }
            }

            Section("Obfuscation") {
                LabeledContent("Pixel size") {
                    sliderRow(value: $store.settings.pixelSize, range: 2...64,
                              text: "\(Int(store.settings.pixelSize)) px")
                }
                LabeledContent("Blur radius") {
                    sliderRow(value: $store.settings.blurRadius, range: 1...50,
                              text: "\(Int(store.settings.blurRadius)) px")
                }
            }
        }
    }

    private func sliderRow(value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        HStack {
            Slider(value: value, in: range, step: 1)
            Text(text).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }

    private func restoreDefaults() {
        store.restore { s, d in
            s.editorLineColor = d.editorLineColor
            s.editorFillColor = d.editorFillColor
            s.editorLineThickness = d.editorLineThickness
            s.editorShadow = d.editorShadow
            s.editorFontName = d.editorFontName
            s.editorFontSize = d.editorFontSize
            s.editorTextColor = d.editorTextColor
            s.editorQuickColors = d.editorQuickColors
            s.expandCanvasAmount = d.expandCanvasAmount
            s.autoResizeLargeScreenshots = d.autoResizeLargeScreenshots
            s.pixelSize = d.pixelSize
            s.blurRadius = d.blurRadius
            s.autoCropTolerance = d.autoCropTolerance
        }
    }
}
