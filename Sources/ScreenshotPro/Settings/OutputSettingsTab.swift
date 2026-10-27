import AppKit
import ScreenshotProCore
import ScreenshotProOutput
import SwiftUI

/// Output: where and how "Save" writes files.
struct OutputSettingsTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var showsPatternHelp = false

    /// Sample metadata for the filename preview.
    private static let sampleDetails = CaptureDetails(
        mode: .window, date: Date(), title: "Welcome to Safari", appName: "Safari",
        screenRect: CGRect(x: 100, y: 100, width: 1280, height: 800), scale: 2)

    var body: some View {
        SettingsTab(restoreDefaults: restoreDefaults) {
            Section("Folder") {
                LabeledContent("Save to") {
                    HStack {
                        Text((store.settings.outputFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(store.settings.outputFolder)
                        Button("Choose...", action: chooseFolder)
                        Button {
                            revealFolder()
                        } label: {
                            Image(systemName: "arrow.right.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }
            }

            Section("File name") {
                HStack {
                    // Only the pattern is monospaced, not its label.
                    TextField(text: $store.settings.filenamePattern) { Text("Pattern").font(.body) }
                        .font(.system(.body, design: .monospaced))
                    Button {
                        showsPatternHelp.toggle()
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Placeholders")
                    .popover(isPresented: $showsPatternHelp, arrowEdge: .bottom) {
                        PatternHelp()
                    }
                }
                LabeledContent("Example") {
                    Text(previewName)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Stepper(value: $store.settings.outputFileCounter, in: 0...999_999) {
                    LabeledContent("Next ${NUM} value") {
                        Text("\(store.settings.outputFileCounter)").monospacedDigit()
                    }
                }
            }

            Section("Format") {
                Picker("Format", selection: $store.settings.outputFormat) {
                    ForEach(ImageFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $store.settings.jpegQuality.asDouble, in: 0...100, step: 1)
                        Text("\(store.settings.jpegQuality)%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!store.settings.outputFormat.supportsQuality)
                Toggle("Ask for quality each time a JPEG, HEIC or AVIF is saved",
                       isOn: $store.settings.promptForQuality)
            }

            Section("After saving") {
                Toggle("Copy the file path to the clipboard", isOn: $store.settings.copyPathAfterSave)
                Toggle("Never overwrite: add a number when the name exists", isOn: $store.settings.avoidOverwrite)
            }
        }
    }

    private var previewName: String {
        let s = store.settings
        let name = FilenamePattern.expand(s.filenamePattern, details: Self.sampleDetails, counter: s.outputFileCounter)
        return "\(name).\(s.outputFormat.fileExtension)"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder where captures are saved."
        panel.directoryURL = store.settings.outputFolderURL
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            store.update { $0.outputFolder = url.path }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    private func revealFolder() {
        let url = store.settings.outputFolderURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func restoreDefaults() {
        store.restore { s, d in
            s.outputFolder = d.outputFolder
            s.filenamePattern = d.filenamePattern
            s.outputFormat = d.outputFormat
            s.jpegQuality = d.jpegQuality
            s.promptForQuality = d.promptForQuality
            s.copyPathAfterSave = d.copyPathAfterSave
            s.avoidOverwrite = d.avoidOverwrite
        }
    }
}

/// The placeholder reference shown from the "?" button next to the pattern field.
private struct PatternHelp: View {
    private static let rows: [(String, String)] = [
        ("${YYYY} ${MM} ${DD}", "Capture year, month, day"),
        ("${hh} ${mm} ${ss}", "Capture hour (24 h), minute, second"),
        ("${capturetime}", "Capture date and time"),
        ("${capturetime:d\"yyyy-MM-dd\"}", "Capture time in a custom date format"),
        ("${now}", "Date and time of saving"),
        ("${NUM}", "Counter, 6 digits (increments on each use)"),
        ("${title}", "Window title or capture name"),
        ("${app}", "Name of the captured app"),
        ("${user}", "Your account name"),
        ("${hostname}", "This Mac's name"),
        ("${RRR}", "Random letters and digits, one per R"),
    ]

    private static let options: [(String, String)] = [
        ("p-6,0", "Pad: ${NUM:p-2,0} gives 01, 02 (negative pads on the left)"),
        ("s0,10", "Substring: start, length (negative counts from the end)"),
        ("rold,new", "Replace every \"old\" with \"new\""),
        ("l / u", "Lower case / upper case"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Placeholders").font(.headline)
            grid(Self.rows)
            Text("Options: ${name:option;option}").font(.headline)
            grid(Self.options)
            Text("A literal / in the pattern creates subfolders, for example ${YYYY}-${MM}/${title}.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 440)
    }

    private func grid(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text(row.1).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
