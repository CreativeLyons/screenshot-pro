import AppKit

/// Where a finished image goes: a file, the clipboard, the printer, the editor, another app...
///
/// Destinations are registered once at launch (see `DestinationRegistry`) and referenced in
/// settings by their stable `id`. The capture flow, the destination picker and the editor's
/// toolbar/File menu all export through this one protocol.
@MainActor
public protocol CaptureDestination: AnyObject {
    /// Stable identifier stored in settings, e.g. "file", "clipboard". Never change once shipped.
    var id: String { get }
    /// Name shown in menus and the picker, e.g. "Save as...".
    var displayName: String { get }
    /// SF Symbol name used in menus and toolbars.
    var symbolName: String { get }
    /// Sort order in menus (lower first).
    var priority: Int { get }
    /// False hides it from the picker (e.g. Mail when no mail client is configured).
    var isAvailable: Bool { get }
    /// True for the editor destination: when chosen with others, it runs last and the
    /// other destinations then run from inside the editor instead of immediately.
    var isEditor: Bool { get }

    func export(_ capture: Capture, context: ExportContext) async throws -> ExportResult
}

public extension CaptureDestination {
    var priority: Int { 100 }
    var isAvailable: Bool { true }
    var isEditor: Bool { false }
}

/// Extra information for an export, mostly for UI placement.
@MainActor
public struct ExportContext {
    /// Window to attach sheets to (the editor), or nil for app-modal panels.
    public weak var window: NSWindow?
    /// True when exporting from the editor (so the editor destination is skipped, and
    /// "file" saves can update the editor's document URL).
    public var fromEditor: Bool

    public init(window: NSWindow? = nil, fromEditor: Bool = false) {
        self.window = window
        self.fromEditor = fromEditor
    }
}

public enum ExportResult: Equatable {
    /// Done. `url` is set for file-based destinations; `message` is for the notification.
    case exported(url: URL?, message: String)
    /// The user cancelled (e.g. closed the save panel); not an error.
    case cancelled
}

/// The set of destinations the app knows about. The app target registers concrete ones.
@MainActor
public final class DestinationRegistry {
    public static let shared = DestinationRegistry()
    public private(set) var all: [CaptureDestination] = []

    public init() {}

    public func register(_ destination: CaptureDestination) {
        all.removeAll { $0.id == destination.id }
        all.append(destination)
        all.sort { ($0.priority, $0.displayName) < ($1.priority, $1.displayName) }
    }

    public func destination(id: String) -> CaptureDestination? {
        all.first { $0.id == id }
    }

    public var available: [CaptureDestination] { all.filter(\.isAvailable) }
}
