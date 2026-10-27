import CoreGraphics
import Foundation

/// The ".sspro" element file: JSON holding the unannotated base image as base64 PNG, the
/// scale, the counter state and the element list. Our own format.
enum DocumentFile {
    static let fileExtension = "sspro"
    static let formatName = "sspro"
    static let currentVersion = 1

    enum FileError: LocalizedError {
        case notAnElementFile
        case unsupportedVersion(Int)
        case badImage

        var errorDescription: String? {
            switch self {
            case .notAnElementFile: return "The file is not a Screenshot Pro element file."
            case .unsupportedVersion(let v): return "The element file version \(v) is not supported."
            case .badImage: return "The element file's image could not be read."
            }
        }
    }

    private struct Payload: Codable {
        var format: String
        var version: Int
        var scale: Double
        var counterStart: Int
        var counterGroup: Int
        var nextSequence: Int
        var image: EmbeddedImage
        var elements: [Element]
    }

    static func encode(_ doc: EditorDocument) throws -> Data {
        let payload = Payload(format: formatName, version: currentVersion, scale: Double(doc.scale),
                              counterStart: doc.counterStart, counterGroup: doc.counterGroup,
                              nextSequence: doc.nextSequence, image: EmbeddedImage(doc.image),
                              elements: doc.elements)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> EditorDocument {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw FileError.notAnElementFile
        }
        guard payload.format == formatName else { throw FileError.notAnElementFile }
        guard payload.version <= currentVersion else { throw FileError.unsupportedVersion(payload.version) }
        var doc = EditorDocument(image: payload.image.cgImage, scale: CGFloat(payload.scale))
        doc.elements = payload.elements
        doc.counterStart = payload.counterStart
        doc.counterGroup = payload.counterGroup
        let maxSequence = payload.elements.map(\.sequence).max() ?? 0
        doc.nextSequence = max(payload.nextSequence, maxSequence + 1)
        return doc
    }

    static func write(_ doc: EditorDocument, to url: URL) throws {
        try encode(doc).write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> EditorDocument {
        try decode(Data(contentsOf: url))
    }
}

/// Elements on the pasteboard: the element list plus the id of the document they came from
/// (pasting into the same document offsets them by 10 px).
struct ElementClipboard: Codable {
    static let pasteboardType = "com.screenshotpro.elements"
    var sourceDocument: UUID
    var elements: [Element]
}
