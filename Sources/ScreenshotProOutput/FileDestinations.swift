import AppKit
import ScreenshotProCore
import UniformTypeIdentifiers

/// "Save": writes straight to the output folder with the filename pattern, no dialog.
@MainActor
public final class FileDestination: CaptureDestination {
    public let id = DestinationID.file
    public let displayName = "Save"
    public let symbolName = "square.and.arrow.down"
    public let priority = 10

    public init() {}

    public func export(_ capture: Capture, context: ExportContext) async throws -> ExportResult {
        let store = SettingsStore.shared
        let settings = store.settings
        let format = settings.outputFormat
        var quality = QualityPolicy.clamped(settings.jpegQuality)
        if QualityPolicy.needsPrompt(format: format, promptForQuality: settings.promptForQuality) {
            guard let chosen = await QualityPrompt.ask(format: format, initial: quality, window: context.window) else {
                return .cancelled
            }
            quality = chosen
        }

        let url = FilenamePattern.uniqueURL(folder: settings.outputFolderURL, pattern: settings.filenamePattern,
                                            details: capture.details, format: format,
                                            avoidOverwrite: settings.avoidOverwrite,
                                            counter: settings.outputFileCounter)
        try ImageEncoder.write(capture.image, to: url, format: format, quality: quality, scale: capture.details.scale)

        if FilenamePattern.usesCounter(settings.filenamePattern) {
            store.update { $0.outputFileCounter += 1 }
        }
        if settings.copyPathAfterSave {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.path, forType: .string)
        }
        return .exported(url: url, message: "Saved \(url.lastPathComponent)")
    }
}

/// "Save as...": a save panel in the output folder with a format popup.
@MainActor
public final class SaveAsDestination: CaptureDestination {
    public let id = DestinationID.saveAs
    public let displayName = "Save as..."
    public let symbolName = "square.and.arrow.down.on.square"
    public let priority = 20

    public init() {}

    public func export(_ capture: Capture, context: ExportContext) async throws -> ExportResult {
        let settings = SettingsStore.shared.settings
        let expanded = FilenamePattern.expand(settings.filenamePattern, details: capture.details,
                                              counter: settings.outputFileCounter)
        let chooser = SavePanelFormatChooser(format: settings.outputFormat)
        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = Self.startFolder(output: settings.outputFolderURL, expandedName: expanded)
        panel.nameFieldStringValue = (expanded as NSString).lastPathComponent + "." + settings.outputFormat.fileExtension
        chooser.attach(to: panel)

        let response: NSApplication.ModalResponse
        if let window = context.window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            OutputSupport.activateForModal()
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return .cancelled }

        let format = ImageFormat(fileExtension: url.pathExtension) ?? chooser.format
        var quality = QualityPolicy.clamped(settings.jpegQuality)
        if QualityPolicy.needsPrompt(format: format, promptForQuality: settings.promptForQuality) {
            guard let chosen = await QualityPrompt.ask(format: format, initial: quality, window: context.window) else {
                return .cancelled
            }
            quality = chosen
        }
        try ImageEncoder.write(capture.image, to: url, format: format, quality: quality, scale: capture.details.scale)
        return .exported(url: url, message: "Saved \(url.lastPathComponent)")
    }

    /// The output folder plus any subfolders the pattern names, when those already exist.
    static func startFolder(output: URL, expandedName: String) -> URL {
        let sub = (expandedName as NSString).deletingLastPathComponent
        guard !sub.isEmpty else { return output }
        let candidate = output.appendingPathComponent(sub, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return candidate
        }
        return output
    }
}

/// When to ask for quality and the valid range.
public enum QualityPolicy {
    /// True when the format is lossy and the settings ask for a prompt.
    public static func needsPrompt(format: ImageFormat, promptForQuality: Bool) -> Bool {
        promptForQuality && format.supportsQuality
    }

    /// Clamps a stored quality to 1...100 (0 would produce unusable files).
    public static func clamped(_ quality: Int) -> Int {
        min(max(quality, 1), 100)
    }

    /// Replaces a known image extension on `name` with `format`'s, or appends it.
    public static func renamed(_ name: String, to format: ImageFormat) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = (!ext.isEmpty && ImageFormat(fileExtension: ext) != nil) ? ns.deletingPathExtension : name
        return stem + "." + format.fileExtension
    }
}

/// The format popup shown as the save panel's accessory view.
@MainActor
final class SavePanelFormatChooser: NSObject {
    private(set) var format: ImageFormat
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(format: ImageFormat) {
        self.format = format
        super.init()
    }

    func attach(to panel: NSSavePanel) {
        self.panel = panel
        for f in ImageFormat.allCases {
            popup.addItem(withTitle: f.displayName)
            popup.lastItem?.representedObject = f.rawValue
        }
        popup.selectItem(at: ImageFormat.allCases.firstIndex(of: format) ?? 0)
        popup.target = self
        popup.action = #selector(formatChanged(_:))

        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        row.frame = NSRect(x: 0, y: 0, width: 280, height: 40)
        panel.accessoryView = row
        panel.allowedContentTypes = [format.utType]
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let newFormat = ImageFormat(rawValue: raw), let panel else { return }
        format = newFormat
        panel.allowedContentTypes = [newFormat.utType]
        panel.nameFieldStringValue = QualityPolicy.renamed(panel.nameFieldStringValue, to: newFormat)
    }
}

/// The "image quality" dialog for lossy formats.
@MainActor
enum QualityPrompt {
    /// Asks for a quality 1...100; nil when cancelled. "Don't ask again" turns the prompt off.
    static func ask(format: ImageFormat, initial: Int, window: NSWindow?) async -> Int? {
        let alert = NSAlert()
        alert.messageText = "\(format.displayName) Quality"
        alert.informativeText = "Higher quality gives larger files."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let slider = NSSlider(value: Double(initial), minValue: 1, maxValue: 100, target: nil, action: nil)
        slider.numberOfTickMarks = 0
        let value = NSTextField(labelWithString: "\(initial)")
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let tracker = SliderTracker(label: value)
        slider.target = tracker
        slider.action = #selector(SliderTracker.changed(_:))
        let row = NSStackView(views: [slider, value])
        row.orientation = .horizontal
        row.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        alert.accessoryView = row

        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            OutputSupport.activateForModal()
            response = alert.runModal()
        }
        withExtendedLifetime(tracker) {}
        guard response == .alertFirstButtonReturn else { return nil }
        if alert.suppressionButton?.state == .on {
            SettingsStore.shared.update { $0.promptForQuality = false }
        }
        return QualityPolicy.clamped(Int(slider.doubleValue.rounded()))
    }

    @MainActor
    final class SliderTracker: NSObject {
        let label: NSTextField
        init(label: NSTextField) { self.label = label }
        @objc func changed(_ sender: NSSlider) {
            label.stringValue = "\(Int(sender.doubleValue.rounded()))"
        }
    }
}
