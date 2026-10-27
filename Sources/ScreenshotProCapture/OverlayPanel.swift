import AppKit
import QuartzCore

/// Borderless, non-activating full-screen panel for one display (docs/analysis/03 section 2.2.1).
final class OverlayPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Allow covering the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Everything the overlay views draw, in Quartz global points. Each view shows its share.
struct OverlayState {
    enum Mode { case region, window }

    var mode: Mode = .region
    var cursor: CGPoint = .zero
    /// Current selection (region mode), pixel aligned.
    var selection: CGRect?
    var selectionPixels: (width: Int, height: Int)?
    /// Window under the cursor (window mode).
    var highlight: WindowInfo?
    var highlightPixels: (width: Int, height: Int)?
    var showCrosshair = true
    /// Magnifier switched on for the whole session (setting, or Z).
    var showMagnifier = false
    /// Magnifier shown while Shift is held.
    var magnifierHeld = false
    var hint: String?
}

/// Receives the overlay views' input, in Quartz global points.
@MainActor
protocol OverlayInputHandler: AnyObject {
    func overlayMouseMoved(to point: CGPoint, in view: OverlayView)
    func overlayMouseDown(at point: CGPoint)
    func overlayMouseDragged(to point: CGPoint)
    func overlayMouseUp(at point: CGPoint)
    func overlayRightMouseDown()
    func overlayKeyDown(_ event: NSEvent)
    func overlayModifiersChanged(_ flags: NSEvent.ModifierFlags)
}

/// Layer-hosting view that shows one display's frozen image and the selection chrome.
final class OverlayView: NSView {
    let display: FrozenDisplay
    weak var handler: OverlayInputHandler?

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let sizeLabel: LabelLayer
    private let windowLabel: LabelLayer
    private let hintLabel: LabelLayer
    private let magnifier: MagnifierLayer
    private var trackingArea: NSTrackingArea?

    private static let accent = CGColor(srgbRed: 0.24, green: 0.80, blue: 0.40, alpha: 0.9)
    private static let crosshairColor = CGColor(srgbRed: 0.24, green: 0.80, blue: 0.40, alpha: 0.45)
    /// Light dimming, so the screen stays readable around the selection.
    private static let idleDim = CGColor(gray: 0, alpha: 0.10)
    private static let selectionDim = CGColor(gray: 0, alpha: 0.22)

    init(display: FrozenDisplay, size: CGSize, backingScale: CGFloat) {
        self.display = display
        sizeLabel = LabelLayer(scale: backingScale)
        windowLabel = LabelLayer(scale: backingScale)
        hintLabel = LabelLayer(scale: backingScale)
        magnifier = MagnifierLayer(scale: backingScale)
        super.init(frame: CGRect(origin: .zero, size: size))

        let root = CALayer()
        root.frame = bounds
        root.contentsScale = backingScale
        layer = root
        wantsLayer = true

        imageLayer.contents = display.image
        imageLayer.contentsGravity = .resize
        imageLayer.frame = bounds

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = OverlayView.idleDim
        dimLayer.frame = bounds

        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = OverlayView.accent
        outlineLayer.frame = bounds

        crosshairLayer.fillColor = nil
        crosshairLayer.strokeColor = OverlayView.crosshairColor
        crosshairLayer.lineWidth = 1
        crosshairLayer.lineDashPattern = [5, 4]
        crosshairLayer.frame = bounds

        for sub in [imageLayer, dimLayer, outlineLayer, crosshairLayer, sizeLabel, windowLabel, hintLabel, magnifier] {
            root.addSublayer(sub)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Lays out every layer for `state`. Floating parts appear only on the cursor's display.
    func apply(_ state: OverlayState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let b = bounds
        let frame = display.frame
        let cursorHere = frame.contains(state.cursor)
        let cursor = CoordinateSpace.viewPoint(fromQuartz: state.cursor, display: frame)

        // Dim everything except the selection or the highlighted window.
        let hole = state.selection ?? (state.mode == .window ? state.highlight?.bounds : nil)
        let dimPath = CGMutablePath()
        dimPath.addRect(b)
        if let hole {
            let local = CoordinateSpace.viewRect(fromQuartz: hole, display: frame)
            dimPath.addRect(local)
            let width: CGFloat = state.mode == .window ? 2 : 1
            outlineLayer.lineWidth = width
            outlineLayer.path = CGPath(rect: local.insetBy(dx: -width / 2, dy: -width / 2), transform: nil)
        } else {
            outlineLayer.path = nil
        }
        dimLayer.path = dimPath
        dimLayer.fillColor = hole == nil ? OverlayView.idleDim : OverlayView.selectionDim

        // Crosshair lines across this display, on pixel centers.
        if state.showCrosshair, cursorHere {
            let s = max(display.scale, 1)
            let x = ((cursor.x * s).rounded(.down) + 0.5) / s
            let y = ((cursor.y * s).rounded(.down) + 0.5) / s
            let path = CGMutablePath()
            path.move(to: CGPoint(x: b.minX, y: y)); path.addLine(to: CGPoint(x: b.maxX, y: y))
            path.move(to: CGPoint(x: x, y: b.minY)); path.addLine(to: CGPoint(x: x, y: b.maxY))
            crosshairLayer.path = path
        } else {
            crosshairLayer.path = nil
        }

        if cursorHere, let selection = state.selection, let px = state.selectionPixels {
            let size = sizeLabel.set("\(px.width) x \(px.height)", fontSize: 13)
            let local = CoordinateSpace.viewRect(fromQuartz: selection, display: frame)
            sizeLabel.frame = CGRect(origin: OverlayLayout.sizeLabelOrigin(selection: local, size: size, bounds: b), size: size)
            sizeLabel.isHidden = false
        } else {
            sizeLabel.isHidden = true
        }

        if cursorHere, state.mode == .window, let window = state.highlight {
            var text = window.displayTitle ?? "Window"
            if text.count > 60 { text = String(text.prefix(59)) + "..." }
            if let px = state.highlightPixels { text += "   \(px.width) x \(px.height)" }
            let size = windowLabel.set(text, fontSize: 12)
            let local = CoordinateSpace.viewRect(fromQuartz: window.bounds, display: frame)
            windowLabel.frame = CGRect(origin: OverlayLayout.windowLabelOrigin(window: local, size: size, bounds: b), size: size)
            windowLabel.isHidden = false
        } else {
            windowLabel.isHidden = true
        }

        if cursorHere, state.showMagnifier || state.magnifierHeld, state.mode == .region {
            let diameter = OverlayLayout.magnifierDiameter(displaySize: b.size, scale: display.scale)
            let pixel = CoordinateSpace.pixel(atQuartz: state.cursor, display: frame, scale: display.scale)
            let point = (Int(state.cursor.x.rounded(.down)), Int(state.cursor.y.rounded(.down)))
            let size = magnifier.update(image: display.image, pixel: pixel, diameter: diameter,
                                        caption: "\(point.0), \(point.1)")
            magnifier.frame = CGRect(origin: OverlayLayout.magnifierOrigin(cursor: cursor, size: size, bounds: b), size: size)
            magnifier.isHidden = false
        } else {
            magnifier.isHidden = true
        }

        if cursorHere, let hint = state.hint {
            let size = hintLabel.set(hint, fontSize: 13)
            hintLabel.frame = CGRect(origin: OverlayLayout.hintOrigin(size: size, bounds: b, cursor: cursor), size: size)
            hintLabel.isHidden = false
        } else {
            hintLabel.isHidden = true
        }
    }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // activeAlways: our app is usually not active while the overlay is up.
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    private func quartzLocation(of event: NSEvent) -> CGPoint {
        let global = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        return CoordinateSpace.quartzPoint(fromAppKit: global, primaryHeight: CoordinateSpace.primaryDisplayHeight)
    }

    override func mouseMoved(with event: NSEvent) {
        handler?.overlayMouseMoved(to: quartzLocation(of: event), in: self)
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is a right click: cancel.
        if event.modifierFlags.contains(.control) {
            handler?.overlayRightMouseDown()
            return
        }
        handler?.overlayMouseDown(at: quartzLocation(of: event))
    }

    override func mouseDragged(with event: NSEvent) {
        handler?.overlayMouseDragged(to: quartzLocation(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        handler?.overlayMouseUp(at: quartzLocation(of: event))
    }

    override func rightMouseDown(with event: NSEvent) {
        handler?.overlayRightMouseDown()
    }

    override func otherMouseDown(with event: NSEvent) {
        handler?.overlayRightMouseDown()
    }

    override func flagsChanged(with event: NSEvent) {
        handler?.overlayModifiersChanged(event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        handler?.overlayKeyDown(event)
    }
}

/// A rounded dark label.
final class LabelLayer: CALayer {
    private let text = CATextLayer()

    init(scale: CGFloat) {
        super.init()
        contentsScale = scale
        backgroundColor = CGColor(gray: 0.08, alpha: 0.78)
        cornerRadius = 5
        isHidden = true
        text.contentsScale = scale
        text.alignmentMode = .left
        text.truncationMode = .end
        addSublayer(text)
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Sets the text and returns the label's size.
    @discardableResult
    func set(_ string: String, fontSize: CGFloat) -> CGSize {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let attributed = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.white])
        text.string = attributed
        let measured = attributed.size()
        let textSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
        text.frame = CGRect(x: 7, y: 3, width: textSize.width, height: textSize.height)
        return CGSize(width: textSize.width + 14, height: textSize.height + 6)
    }
}

/// Round zoomer: enlarged source pixels, a center pixel marker and a caption below.
final class MagnifierLayer: CALayer {
    private let lens = CALayer()
    private let pixels = CALayer()
    private let marker = CAShapeLayer()
    private let caption: LabelLayer
    private static let captionGap: CGFloat = 4

    init(scale: CGFloat) {
        caption = LabelLayer(scale: scale)
        super.init()
        contentsScale = scale
        isHidden = true
        lens.masksToBounds = true
        lens.backgroundColor = CGColor(gray: 0, alpha: 1)
        lens.borderColor = CGColor(srgbRed: 0.24, green: 0.80, blue: 0.40, alpha: 0.9)
        lens.borderWidth = 1.5
        pixels.magnificationFilter = .nearest
        pixels.contentsGravity = .resize
        marker.fillColor = nil
        marker.strokeColor = CGColor(srgbRed: 1, green: 0.15, blue: 0.15, alpha: 1)
        marker.lineWidth = 1.5
        lens.addSublayer(pixels)
        lens.addSublayer(marker)
        addSublayer(lens)
        caption.isHidden = false
        addSublayer(caption)
    }

    override init(layer: Any) {
        caption = (layer as? MagnifierLayer)?.caption ?? LabelLayer(scale: 2)
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows the pixels around `pixel` of `image`. Returns the total size (lens plus caption).
    func update(image: CGImage, pixel: (x: Int, y: Int), diameter d: CGFloat, caption text: String) -> CGSize {
        let captionSize = caption.set(text, fontSize: 11)
        let total = CGSize(width: max(d, captionSize.width), height: d + MagnifierLayer.captionGap + captionSize.height)
        let lensOrigin = CGPoint(x: (total.width - d) / 2, y: total.height - d)
        lens.frame = CGRect(origin: lensOrigin, size: CGSize(width: d, height: d))
        lens.cornerRadius = d / 2
        caption.frame = CGRect(origin: CGPoint(x: (total.width - captionSize.width) / 2, y: 0), size: captionSize)

        let samples = CGFloat(OverlayLayout.magnifierSamples)
        let cell = d / samples
        let source = OverlayLayout.magnifierSource(pixel: pixel, imageWidth: image.width, imageHeight: image.height)
        if source.visible.isEmpty {
            pixels.contents = nil
        } else {
            pixels.contents = image.cropping(to: source.visible)
            // Bottom-left layer coordinates; the source rect is top-left.
            pixels.frame = CGRect(x: (source.visible.minX - source.wanted.minX) * cell,
                                  y: (source.wanted.maxY - source.visible.maxY) * cell,
                                  width: source.visible.width * cell, height: source.visible.height * cell)
        }
        let center = CGFloat(OverlayLayout.magnifierSamples / 2) * cell
        marker.frame = CGRect(x: 0, y: 0, width: d, height: d)
        marker.path = CGPath(rect: CGRect(x: center, y: center, width: cell, height: cell), transform: nil)
        return total
    }
}
