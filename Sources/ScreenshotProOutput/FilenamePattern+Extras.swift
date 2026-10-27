import Foundation
import ScreenshotProCore

public extension FilenamePattern {
    /// Expands `pattern` with an explicit environment (clock, time zone, user, host, variables).
    ///
    /// The result is a relative path without extension. Placeholder values never contain `/`,
    /// so only a `/` written literally in the pattern creates subfolders.
    static func expand(_ pattern: String, details: CaptureDetails, counter: Int,
                       environment: FilenameEnvironment) -> String {
        PatternExpander.expand(pattern, details: details, counter: counter, environment: environment, safe: true)
    }

    /// Expands `pattern` as plain text, without file-name safety (for print footers and labels).
    static func expandText(_ pattern: String, details: CaptureDetails, counter: Int = 1,
                           environment: FilenameEnvironment = .current) -> String {
        PatternExpander.expand(pattern, details: details, counter: counter, environment: environment, safe: false)
    }

    /// True when `pattern` uses `${NUM}`, so a save consumes a counter value.
    static func usesCounter(_ pattern: String) -> Bool {
        PatternExpander.usesCounter(pattern)
    }

    /// `uniqueURL` with an explicit `${NUM}` counter and environment.
    static func uniqueURL(folder: URL, pattern: String, details: CaptureDetails, format: ImageFormat,
                          avoidOverwrite: Bool, counter: Int,
                          environment: FilenameEnvironment = .current) -> URL {
        let name = expand(pattern, details: details, counter: counter, environment: environment)
        let url = folder.appendingPathComponent(name + "." + format.fileExtension, isDirectory: false)
        return avoidOverwrite ? availableURL(for: url) : url
    }

    /// `url` itself when nothing exists there, otherwise the first free "name (2).ext",
    /// "name (3).ext"... in the same folder.
    static func availableURL(for url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        func candidate(_ suffix: String) -> URL {
            let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            return folder.appendingPathComponent(name, isDirectory: false)
        }
        for n in 2...9999 {
            let next = candidate("(\(n))")
            if !fileManager.fileExists(atPath: next.path) { return next }
        }
        return candidate("(\(UUID().uuidString.prefix(8)))")
    }
}
