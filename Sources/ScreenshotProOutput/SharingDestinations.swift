import AppKit
import ScreenshotProCore

/// "Send as Mail": a temp PNG attached to a new message in the default mail client.
@MainActor
public final class MailDestination: NSObject, CaptureDestination, NSSharingServiceDelegate {
    public let id = DestinationID.mail
    public let displayName = "Send as Mail"
    public let symbolName = "envelope"
    public let priority = 50

    /// Kept while a compose window is being prepared.
    private var activeService: NSSharingService?

    public override init() { super.init() }

    public var isAvailable: Bool {
        guard let service = NSSharingService(named: .composeEmail) else { return false }
        let probe = TemporaryFiles.directory.appendingPathComponent("probe.png")
        return service.canPerform(withItems: [probe])
    }

    public func export(_ capture: Capture, context: ExportContext) async throws -> ExportResult {
        guard let service = NSSharingService(named: .composeEmail) else {
            throw ScreenshotProError.destinationUnavailable(displayName)
        }
        let url = try OutputSupport.writeTemporaryPNG(capture)
        guard service.canPerform(withItems: [url]) else {
            throw ScreenshotProError.destinationUnavailable(displayName)
        }
        let title = (capture.details.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        service.subject = title.isEmpty ? "Screenshot" : title
        service.delegate = self
        activeService = service
        service.perform(withItems: [url])
        return .exported(url: url, message: "Created a mail message")
    }

    public nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { activeService = nil }
    }

    public nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any],
                                           error: Error) {
        MainActor.assumeIsolated { activeService = nil }
    }
}

/// "Share...": the system share picker for a temp PNG.
@MainActor
public final class ShareDestination: CaptureDestination {
    public let id = DestinationID.share
    public let displayName = "Share..."
    public let symbolName = "square.and.arrow.up"
    public let priority = 60

    public init() {}

    public func export(_ capture: Capture, context: ExportContext) async throws -> ExportResult {
        let url = try OutputSupport.writeTemporaryPNG(capture)
        let session = SharePickerSession(items: [url])
        guard let service = await session.show(in: context.window) else { return .cancelled }
        return .exported(url: url, message: "Shared with \(service.title)")
    }
}

/// Shows an `NSSharingServicePicker` from a window's content view, or from a small transient
/// window at the mouse when there is none, and reports the chosen service.
@MainActor
final class SharePickerSession: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    static let anchorTimeout: TimeInterval = 120

    private let items: [Any]
    private var continuation: CheckedContinuation<NSSharingService?, Never>?
    private var anchorWindow: NSWindow?
    private var keepAlive: SharePickerSession?

    init(items: [Any]) {
        self.items = items
    }

    func show(in window: NSWindow?) async -> NSSharingService? {
        let view: NSView
        let rect: NSRect
        if let content = window?.contentView {
            view = content
            rect = NSRect(x: content.bounds.midX - 1, y: content.bounds.maxY - 2, width: 2, height: 2)
        } else {
            let anchor = Self.makeAnchorWindow()
            anchorWindow = anchor
            OutputSupport.activateForModal()
            anchor.orderFrontRegardless()
            view = anchor.contentView!
            rect = view.bounds
        }
        keepAlive = self
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
    }

    private static func makeAnchorWindow() -> NSWindow {
        let mouse = NSEvent.mouseLocation
        let panel = NSPanel(contentRect: NSRect(x: mouse.x - 1, y: mouse.y - 1, width: 2, height: 2),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func finishSharing() {
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
        keepAlive = nil
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                          didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            continuation?.resume(returning: service)
            continuation = nil
            if service == nil {
                finishSharing()
            } else {
                // Some services never report back; do not keep the anchor window forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.anchorTimeout) { [weak self] in
                    MainActor.assumeIsolated { self?.finishSharing() }
                }
            }
        }
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                          delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated { finishSharing() }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any],
                                    error: Error) {
        MainActor.assumeIsolated { finishSharing() }
    }
}

/// "Open in Preview": a temp PNG opened in Preview, or the default image app.
@MainActor
public final class OpenWithDestination: CaptureDestination {
    public let id = DestinationID.openWith
    public let displayName = "Open in Preview"
    public let symbolName = "photo"
    public let priority = 80

    static let previewBundleID = "com.apple.Preview"

    public init() {}

    public func export(_ capture: Capture, context: ExportContext) async throws -> ExportResult {
        let url = try OutputSupport.writeTemporaryPNG(capture)
        let workspace = NSWorkspace.shared
        if let preview = workspace.urlForApplication(withBundleIdentifier: Self.previewBundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            if (try? await workspace.open([url], withApplicationAt: preview, configuration: configuration)) != nil {
                return .exported(url: url, message: "Opened in Preview")
            }
        }
        guard workspace.open(url) else {
            throw ScreenshotProError.destinationUnavailable("An app to open images")
        }
        return .exported(url: url, message: "Opened \(url.lastPathComponent)")
    }
}
