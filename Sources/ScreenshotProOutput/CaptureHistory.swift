import AppKit
import ScreenshotProCore
import ImageIO

/// One screenshot kept in the history.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The PNG's file name inside the entry's own folder (a readable name for drag and drop).
    public var fileName: String
    public var date: Date
    public var mode: CaptureMode
    public var title: String?
    public var appName: String?
    public var scale: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
}

/// The most recent screen captures, kept as PNG files so they survive relaunches and can be
/// dragged into other apps as real files. Newest first, at most `limit` entries.
///
/// Layout: `<directory>/index.json` plus one folder per entry, `<directory>/<id>/<name>.png`.
@MainActor
public final class CaptureHistory {
    public static let shared = CaptureHistory()
    /// Posted on the main thread after entries are added or removed.
    public static let didChange = Notification.Name("ScreenshotPro.CaptureHistory.didChange")

    public nonisolated static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Screenshot Pro/History", isDirectory: true)
    }

    public private(set) var directory: URL
    public private(set) var entries: [HistoryEntry] = []
    /// The image of the newest entry while it is in memory anyway, so the post-capture preview
    /// can find its file (only one is kept: full-screen images are large).
    private var recentImages: [UUID: CGImage] = [:]
    private var thumbnails: [UUID: NSImage] = [:]

    public init(directory: URL = CaptureHistory.defaultDirectory) {
        self.directory = directory
        load()
    }

    /// Points the history at another folder (the self-test uses its own).
    public func use(directory: URL) {
        self.directory = directory
        recentImages.removeAll()
        thumbnails.removeAll()
        load()
        changed()
    }

    private var limit: Int { max(0, SettingsStore.shared.settings.historyLimit) }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    // MARK: Reading

    public func fileURL(for entry: HistoryEntry) -> URL {
        directory.appendingPathComponent(entry.id.uuidString, isDirectory: true).appendingPathComponent(entry.fileName)
    }

    /// The saved file of an entry added this session whose image is `image`, if any.
    public func fileURL(forImage image: CGImage) -> URL? {
        guard let id = recentImages.first(where: { $0.value === image })?.key,
              let entry = entries.first(where: { $0.id == id }) else { return nil }
        return fileURL(for: entry)
    }

    /// The entry as a capture, ready for any destination; nil when its file is gone.
    public func capture(for entry: HistoryEntry) -> Capture? {
        guard let image = recentImages[entry.id] ?? ImageEncoder.load(fileURL(for: entry)) else { return nil }
        let details = CaptureDetails(mode: entry.mode, date: entry.date, title: entry.title, appName: entry.appName,
                                     scale: CGFloat(entry.scale))
        return Capture(image: image, details: details)
    }

    /// A downsampled image for the strip, cached.
    public func thumbnail(for entry: HistoryEntry, maxPixelSize: Int = 480) -> NSImage? {
        if let cached = thumbnails[entry.id] { return cached }
        let url = fileURL(for: entry)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        thumbnails[entry.id] = image
        return image
    }

    // MARK: Changing

    /// Saves `capture` as the newest entry and trims the history to the limit. Encoding runs
    /// off the main thread. Returns nil when the history is off or the file could not be written.
    @discardableResult
    public func add(_ capture: Capture) async -> HistoryEntry? {
        guard limit > 0 else { return nil }
        let base = OutputSupport.baseName(for: capture, settings: SettingsStore.shared.settings)
        var name = PatternExpander.normalizePath(PatternExpander.safeValue(base))
        if name.isEmpty { name = "Screenshot" }
        let entry = HistoryEntry(id: UUID(), fileName: name + "." + ImageFormat.png.fileExtension,
                                 date: capture.details.date, mode: capture.details.mode,
                                 title: capture.details.title, appName: capture.details.appName,
                                 scale: Double(capture.details.scale),
                                 pixelWidth: capture.image.width, pixelHeight: capture.image.height)
        let url = fileURL(for: entry)
        let image = capture.image
        let scale = capture.details.scale
        let written = await Task.detached(priority: .userInitiated) {
            (try? ImageEncoder.write(image, to: url, format: .png, scale: scale)) != nil
        }.value
        guard written else { return nil }
        entries.insert(entry, at: 0)
        recentImages = [entry.id: image]
        save()
        trim()
        changed()
        return entry
    }

    public func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        deleteFiles(of: entries.remove(at: index))
        save()
        changed()
    }

    public func clear() {
        entries.forEach(deleteFiles)
        entries.removeAll()
        save()
        changed()
    }

    /// Drops entries beyond the limit (also after the limit was lowered).
    public func trim() {
        guard entries.count > limit else { return }
        while entries.count > limit {
            deleteFiles(of: entries.removeLast())
        }
        save()
        changed()
    }

    // MARK: Storage

    private func load() {
        entries = []
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        // Entries whose file was removed behind our back are dropped.
        entries = decoded.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
        } catch {
            NSLog("Screenshot Pro: could not save the screenshot history: %@", error.localizedDescription)
        }
    }

    private func deleteFiles(of entry: HistoryEntry) {
        recentImages[entry.id] = nil
        thumbnails[entry.id] = nil
        try? FileManager.default.removeItem(at: fileURL(for: entry).deletingLastPathComponent())
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
