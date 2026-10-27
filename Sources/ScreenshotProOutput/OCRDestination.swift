import AppKit
import ScreenshotProCore
import Vision

/// "Copy Text (OCR)": recognizes text with Vision and copies the lines to the clipboard.
@MainActor
public final class OCRDestination: CaptureDestination {
    public let id = DestinationID.ocr
    public let displayName = "Copy Text (OCR)"
    public let symbolName = "text.viewfinder"
    public let priority = 70
    /// The result message when nothing was recognized (the clipboard is left alone).
    public static let noTextMessage = "No text found"

    public init() {}

    public func export(_ capture: Capture, context: ExportContext) async throws -> ExportResult {
        let lines = try await Self.recognizeLines(in: capture.image)
        guard let text = Self.joined(lines) else {
            return .exported(url: nil, message: Self.noTextMessage)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return .exported(url: nil, message: Self.message(lineCount: text.components(separatedBy: "\n").count))
    }

    /// The recognized text lines in Vision's reading order (accurate level, language correction).
    public nonisolated static func recognizeLines(in image: CGImage) async throws -> [String] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: image)
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }

    /// Trims the lines, drops empty ones and joins them with newlines; nil when nothing is left.
    static func joined(_ lines: [String]) -> String? {
        let kept = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: "\n")
    }

    static func message(lineCount: Int) -> String {
        lineCount == 1 ? "Copied 1 line of text" : "Copied \(lineCount) lines of text"
    }
}
