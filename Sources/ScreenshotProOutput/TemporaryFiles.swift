import Foundation

/// The app's own folder for temporary exports (mail attachments, share items, "open with").
public enum TemporaryFiles {
    /// Folder name under the system temporary directory.
    public static let folderName = "Screenshot Pro"

    /// `<temporaryDirectory>/Screenshot Pro`, not created until needed.
    public static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// A free URL in `folder` (default: `directory`, created if missing) for `name.fileExtension`.
    public static func makeURL(name: String, fileExtension: String, in folder: URL? = nil) throws -> URL {
        let folder = folder ?? directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = PatternExpander.normalizePath(PatternExpander.safeValue(name))
        return FilenamePattern.availableURL(for: folder.appendingPathComponent("\(safe).\(fileExtension)"))
    }

    /// Removes files in `folder` (default: `directory`) last modified more than `age` seconds ago.
    /// Returns the number of files removed. Only regular files directly inside the folder are touched.
    @discardableResult
    public static func purgeStale(olderThan age: TimeInterval = 24 * 60 * 60, in folder: URL? = nil,
                                  now: Date = Date()) -> Int {
        let folder = folder ?? directory
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var removed = 0
        for url in items {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
