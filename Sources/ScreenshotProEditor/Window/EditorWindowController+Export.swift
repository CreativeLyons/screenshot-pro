import AppKit
import ScreenshotProCore
import ScreenshotProOutput
import UniformTypeIdentifiers

/// Exporting through destinations, saving, element files and the close confirmation.
extension EditorWindowController {
    /// Base image plus all elements at full pixel resolution.
    func flattenedImage() -> CGImage? {
        DocumentRenderer.flatten(session.document, cache: canvas.filterCache)
    }

    /// The flattened image with the original capture details.
    func flattenedCapture() -> Capture? {
        guard let image = flattenedImage() else { return nil }
        var d = details
        d.scale = session.document.scale
        return Capture(image: image, details: d)
    }

    func showErrorSheet(_ error: Error) {
        guard let window else {
            NSAlert(error: error).runModal()
            return
        }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: Destinations

    /// Exports the flattened image to a registered destination. Returns true when exported.
    @discardableResult
    func export(to id: String) async -> Bool {
        canvas.finishTextEditing(commit: true)
        guard let destination = DestinationRegistry.shared.destination(id: id), destination.isAvailable else {
            showErrorSheet(ScreenshotProError.destinationUnavailable(Self.destinationNames[id] ?? id))
            return false
        }
        guard let capture = flattenedCapture() else {
            showErrorSheet(ScreenshotProError.writeFailed("the image could not be rendered"))
            return false
        }
        do {
            let result = try await destination.export(capture, context: ExportContext(window: window, fromEditor: true))
            switch result {
            case .exported(let url, let message):
                session.markSaved()
                if let url, id == DestinationID.file || id == DestinationID.saveAs {
                    documentURL = url
                    updateTitle()
                }
                showMessage(message)
                return true
            case .cancelled:
                return false
            }
        } catch {
            showErrorSheet(error)
            return false
        }
    }

    private static let destinationNames: [String: String] = [
        DestinationID.file: "Save", DestinationID.saveAs: "Save as", DestinationID.clipboard: "Copy to Clipboard",
        DestinationID.printer: "Print", DestinationID.mail: "Send as Mail", DestinationID.share: "Share",
        DestinationID.ocr: "Copy Text (OCR)", DestinationID.openWith: "Open with",
    ]

    /// Save: to the document URL when there is one, else through the "file" destination.
    @discardableResult
    func save() async -> Bool {
        canvas.finishTextEditing(commit: true)
        guard let url = documentURL else { return await export(to: DestinationID.file) }
        do {
            if url.pathExtension.lowercased() == DocumentFile.fileExtension {
                try DocumentFile.write(session.document, to: url)
            } else {
                guard let image = flattenedImage() else { throw ScreenshotProError.writeFailed("rendering failed") }
                let format = ImageFormat(fileExtension: url.pathExtension) ?? settings.outputFormat
                try ImageEncoder.write(image, to: url, format: format, quality: settings.jpegQuality,
                                       scale: session.document.scale)
            }
            session.markSaved()
            showMessage("Saved \(url.lastPathComponent)")
            return true
        } catch {
            showErrorSheet(error)
            return false
        }
    }

    @objc func editorSave(_ sender: Any?) { Task { await save() } }
    @objc func editorSaveAs(_ sender: Any?) { Task { await export(to: DestinationID.saveAs) } }
    @objc func editorCopyToClipboard(_ sender: Any?) { Task { await export(to: DestinationID.clipboard) } }
    @objc func editorPrint(_ sender: Any?) { Task { await export(to: DestinationID.printer) } }
    @objc func editorMail(_ sender: Any?) { Task { await export(to: DestinationID.mail) } }
    @objc func editorShare(_ sender: Any?) { Task { await export(to: DestinationID.share) } }
    @objc func editorOCR(_ sender: Any?) { Task { await export(to: DestinationID.ocr) } }

    // MARK: Element files

    static var elementFileType: UTType {
        UTType(filenameExtension: DocumentFile.fileExtension, conformingTo: .json) ?? .json
    }

    /// Writes the whole document (base image and elements) as a ".sspro" file.
    @objc func editorSaveElements(_ sender: Any?) {
        guard let window else { return }
        canvas.finishTextEditing(commit: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.elementFileType]
        panel.nameFieldStringValue = baseFileName + "." + DocumentFile.fileExtension
        let doc = session.document
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try DocumentFile.write(doc, to: url)
                showMessage("Saved elements to \(url.lastPathComponent)")
            } catch {
                showErrorSheet(error)
            }
        }
    }

    /// Adds the elements of a ".sspro" file to this image (selected).
    @objc func editorLoadElements(_ sender: Any?) {
        guard let window else { return }
        canvas.finishTextEditing(commit: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.elementFileType]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let loaded = try DocumentFile.read(url)
                // Keep elements the same size on screen when the scales differ.
                let f = session.document.scale / loaded.scale
                let elements = loaded.elements.map { e -> Element in
                    var out = ElementGeometry.transform(e, by: CGAffineTransform(scaleX: f, y: f))
                    out.style = e.style.scaled(by: f)
                    return out
                }
                session.addLoaded(elements, name: "Load Elements")
                selectTool(.select)
            } catch {
                showErrorSheet(error)
            }
        }
    }

    // MARK: Closing

    /// Save / Don't Save / Cancel sheet for a modified window.
    func askToSaveBeforeClosing() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to this screenshot?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    if await self.save() { self.closeNow() }
                }
            case .alertThirdButtonReturn:
                closeNow()
            default:
                break
            }
        }
    }

    func closeNow() {
        closeConfirmed = true
        window?.close()
    }
}
