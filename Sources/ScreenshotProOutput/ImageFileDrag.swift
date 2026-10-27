import AppKit

/// Drags an image out as a real file. Apps that take files (Finder, Mail, chat and AI apps such
/// as Claude, browsers) all accept a file URL, which file promises and raw PNG data do not
/// reliably reach in Chromium-based apps.
@MainActor
enum ImageFileDrag {
    /// Starts the drag session from `view`; `frame` is the drag image's frame in `view`.
    @discardableResult
    static func begin(fileURL: URL, preview: NSImage?, frame: CGRect, from view: NSView, event: NSEvent,
                      source: NSDraggingSource) -> NSDraggingSession {
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(frame, contents: preview ?? NSWorkspace.shared.icon(forFile: fileURL.path))
        let session = view.beginDraggingSession(with: [item], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        return session
    }

    /// One file in a drag, with the picture shown for it.
    struct File {
        var url: URL
        var preview: NSImage?
    }

    /// Drags several files at once; their pictures fan out a little from `frame`, the first on top.
    @discardableResult
    static func begin(_ files: [File], frame: CGRect, from view: NSView, event: NSEvent,
                      source: NSDraggingSource) -> NSDraggingSession? {
        guard !files.isEmpty else { return nil }
        let items = files.enumerated().map { i, file -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
            let step = CGFloat(min(i, 4)) * 6
            item.setDraggingFrame(frame.offsetBy(dx: step, dy: -step),
                                  contents: file.preview ?? NSWorkspace.shared.icon(forFile: file.url.path))
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
        return session
    }

    /// `size` scaled down to fit `maxSide`, never up.
    static func fitted(_ size: CGSize, maxSide: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxSide, height: maxSide) }
        let f = min(1, maxSide / max(size.width, size.height))
        return CGSize(width: size.width * f, height: size.height * f)
    }
}
