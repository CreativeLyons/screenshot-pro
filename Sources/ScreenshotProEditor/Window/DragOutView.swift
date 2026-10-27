import AppKit
import UniformTypeIdentifiers

/// Writes a prepared PNG for a file promise. Holds only immutable data, so the promise can be
/// fulfilled off the main thread.
final class PNGPromiseWriter: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let data: Data
    let fileName: String

    init(data: Data, fileName: String) {
        self.data = data
        self.fileName = fileName
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            try data.write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

/// A file promise that also offers the PNG data itself, so apps that accept images (not files)
/// can take the drop too.
final class PNGFilePromiseProvider: NSFilePromiseProvider {
    var pngData = Data()

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .png ? pngData : super.pasteboardPropertyList(forType: type)
    }
}

/// The toolbar's drag handle: dragging it drags the flattened image out as a PNG file.
@MainActor
final class DragOutView: NSView, NSDraggingSource {
    /// Supplies the PNG data and file name (without extension) when a drag starts.
    var provideImage: (() -> (Data, String)?)?
    private var writer: PNGPromiseWriter?
    private let imageView = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                  accessibilityDescription: "Drag image")
        imageView.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 28),
        ])
        toolTip = "Drag the image into another app or the Finder"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Drag image out")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let (data, name) = provideImage?() else { return }
        let writer = PNGPromiseWriter(data: data, fileName: name + ".png")
        self.writer = writer
        let provider = PNGFilePromiseProvider(fileType: UTType.png.identifier, delegate: writer)
        provider.pngData = data
        let item = NSDraggingItem(pasteboardWriter: provider)
        let dragImage = NSImage(data: data) ?? imageView.image ?? NSImage()
        let size = fittedSize(dragImage.size, max: 128)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                     width: size.width, height: size.height), contents: dragImage)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func fittedSize(_ s: CGSize, max m: CGFloat) -> CGSize {
        guard s.width > 0, s.height > 0 else { return CGSize(width: 32, height: 32) }
        let f = min(1, m / Swift.max(s.width, s.height))
        return CGSize(width: s.width * f, height: s.height * f)
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
