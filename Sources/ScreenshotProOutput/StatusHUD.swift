import AppKit

/// A small pill near the pointer for work that has no window of its own, such as "Copy Text"
/// from the destination picker: a spinner while it runs, then the result for a moment.
/// Shown whatever the notification setting is; it ignores the mouse and never takes focus.
@MainActor
public final class StatusHUD {
    public static let shared = StatusHUD()
    /// The panel's (never displayed) title, so the self-test can find it.
    public static let title = "Status HUD"
    /// How long a result stays up before it fades.
    public static let resultSeconds: TimeInterval = 1.6
    static let accent = NSColor(srgbRed: 0.24, green: 0.80, blue: 0.40, alpha: 1)

    private let panel: NSPanel
    private let background = NSVisualEffectView()
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private var generation = 0

    private init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.title = Self.title
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true

        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor

        let row = NSStackView(views: [spinner, icon, label])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    /// Shows `text` with a spinner until the next call.
    public func showProgress(_ text: String) {
        generation += 1
        icon.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        present(text)
    }

    /// Shows `text` with a symbol (green when `success`), then fades out.
    public func showResult(_ text: String, symbol: String, success: Bool = true) {
        generation += 1
        let current = generation
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = success ? Self.accent : .secondaryLabelColor
        icon.isHidden = false
        present(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resultSeconds) { [weak self] in
            guard let self, self.generation == current else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    guard self.generation == current else { return }
                    self.panel.orderOut(nil)
                }
            })
        }
    }

    public func hide() {
        generation += 1
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        panel.orderOut(nil)
    }

    private func present(_ text: String) {
        label.stringValue = text
        panel.alphaValue = 1
        let size = background.fittingSize
        // Placed under the pointer when it appears; later states keep its center, so the pill
        // does not chase the pointer.
        let origin = panel.isVisible
            ? CGPoint(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height)
            : Self.origin(for: size, mouse: NSEvent.mouseLocation, screens: NSScreen.screens.map(\.visibleFrame))
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Centered just below the pointer, kept inside the screen under the pointer.
    static func origin(for size: CGSize, mouse: CGPoint, screens: [CGRect]) -> CGPoint {
        let screen = screens.first { $0.contains(mouse) } ?? screens.first ?? CGRect(origin: .zero, size: size)
        var x = mouse.x - size.width / 2
        var y = mouse.y - 24 - size.height
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        y = min(max(y, screen.minY + 8), screen.maxY - size.height - 8)
        return CGPoint(x: x, y: y)
    }
}
