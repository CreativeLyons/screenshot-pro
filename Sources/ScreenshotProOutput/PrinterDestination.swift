import AppKit
import ScreenshotProCore

/// "Print...": the standard print panel with the image laid out per the printing settings.
@MainActor
public final class PrinterDestination: CaptureDestination {
    public let id = DestinationID.printer
    public let displayName = "Print..."
    public let symbolName = "printer"
    public let priority = 40

    public init() {}

    public func export(_ capture: Capture, context: ExportContext) async throws -> ExportResult {
        let settings = SettingsStore.shared.settings
        let options = PrintLayout.Options(fitToPage: settings.printFitToPage, allowEnlarge: settings.printAllowEnlarge,
                                          center: settings.printCenter, allowRotate: settings.printAllowRotate)
        let footer = settings.printFooter ? Self.footerText(for: capture.details) : nil
        let view = PrintImageView(capture: capture, options: options, footer: footer)

        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.orientation = capture.image.width > capture.image.height && settings.printAllowRotate ? .landscape : .portrait
        view.frame = NSRect(origin: .zero, size: PrintImageView.printableSize(info))

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = capture.details.title ?? "Screenshot"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsPreview, .showsPaperSize, .showsOrientation, .showsScaling])

        let success: Bool
        if let window = context.window {
            success = await PrintRunner().run(operation, for: window)
        } else {
            OutputSupport.activateForModal()
            success = operation.run()
        }
        return success ? .exported(url: nil, message: "Sent to the printer") : .cancelled
    }

    /// "<long date> <time> - <title>", in the user's locale.
    static func footerText(for details: CaptureDetails, locale: Locale = .current,
                           timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        let title = (details.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(formatter.string(from: details.date)) - \(title.isEmpty ? "Screenshot" : title)"
    }
}

/// Where the image goes on the page. Pure geometry so it can be tested.
struct PrintLayout: Equatable {
    struct Options: Equatable {
        var fitToPage: Bool
        var allowEnlarge: Bool
        var center: Bool
        var allowRotate: Bool
    }

    /// The image's bounding rect in a flipped (y down) area starting at the origin.
    var rect: CGRect
    /// True when the image is drawn rotated by 90 degrees (the rect is the rotated footprint).
    var rotated: Bool

    /// Lays out an image of `imageSize` points in `area`. Rotation happens only when the image
    /// and the area differ in orientation; scaling keeps the aspect ratio.
    static func compute(imageSize: CGSize, area: CGSize, options: Options) -> PrintLayout {
        guard imageSize.width > 0, imageSize.height > 0, area.width > 0, area.height > 0 else {
            return PrintLayout(rect: .zero, rotated: false)
        }
        let imageLandscape = imageSize.width > imageSize.height
        let areaLandscape = area.width > area.height
        let rotated = options.allowRotate && imageSize.width != imageSize.height
            && area.width != area.height && imageLandscape != areaLandscape
        let footprint = rotated ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize

        var scale = min(area.width / footprint.width, area.height / footprint.height)
        if scale < 1 && !options.fitToPage { scale = 1 }
        if scale > 1 && !options.allowEnlarge { scale = 1 }
        let size = CGSize(width: footprint.width * scale, height: footprint.height * scale)
        let origin = options.center
            ? CGPoint(x: (area.width - size.width) / 2, y: (area.height - size.height) / 2)
            : .zero
        return PrintLayout(rect: CGRect(origin: origin, size: size), rotated: rotated)
    }
}

/// A one-page view that draws the capture per `PrintLayout` and an optional footer line.
final class PrintImageView: NSView {
    static let footerFont = NSFont.systemFont(ofSize: 10)
    static let footerGap: CGFloat = 6

    private let image: CGImage
    private let imageSize: CGSize
    private let options: PrintLayout.Options
    private let footer: String?

    init(capture: Capture, options: PrintLayout.Options, footer: String?) {
        image = capture.image
        imageSize = capture.pointSize
        self.options = options
        self.footer = footer
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Paper size minus margins.
    static func printableSize(_ info: NSPrintInfo) -> CGSize {
        CGSize(width: max(info.paperSize.width - info.leftMargin - info.rightMargin, 1),
               height: max(info.paperSize.height - info.topMargin - info.bottomMargin, 1))
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        // Follow paper and orientation changes made in the print panel.
        if let info = NSPrintOperation.current?.printInfo {
            setFrameSize(Self.printableSize(info))
        }
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { bounds }

    private var footerHeight: CGFloat {
        guard footer != nil else { return 0 }
        return ceil(Self.footerFont.ascender - Self.footerFont.descender) + Self.footerGap
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let area = CGSize(width: bounds.width, height: max(bounds.height - footerHeight, 1))
        let layout = PrintLayout.compute(imageSize: imageSize, area: area, options: options)

        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: layout.rect.midX, y: layout.rect.midY)
        if layout.rotated { context.rotate(by: .pi / 2) }
        let drawn = layout.rotated
            ? CGSize(width: layout.rect.height, height: layout.rect.width)
            : layout.rect.size
        // The view is flipped; flip back so the CGImage is upright.
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: -drawn.width / 2, y: -drawn.height / 2, width: drawn.width, height: drawn.height))
        context.restoreGState()

        if let footer {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingMiddle
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.footerFont, .foregroundColor: NSColor.black, .paragraphStyle: style,
            ]
            // The area above reserves footerHeight, so the line always fits below the image.
            let rect = CGRect(x: 0, y: layout.rect.maxY + Self.footerGap,
                              width: bounds.width, height: footerHeight - Self.footerGap)
            (footer as NSString).draw(in: rect, withAttributes: attributes)
        }
    }
}

/// Runs a print operation as a sheet and reports whether it printed.
@MainActor
final class PrintRunner: NSObject {
    private var continuation: CheckedContinuation<Bool, Never>?

    func run(_ operation: NSPrintOperation, for window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            operation.runModal(for: window, delegate: self,
                               didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                            contextInfo: UnsafeMutableRawPointer?) {
        continuation?.resume(returning: success)
        continuation = nil
    }
}
