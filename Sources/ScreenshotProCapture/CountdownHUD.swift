import AppKit

/// Small countdown shown during the capture delay, at the top right of the display under the
/// pointer (near the menu bar). Esc or a right click cancels when allowed.
@MainActor
final class CountdownHUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let keys = OverlayKeyGrabber()
    private var cancelled = false
    private var monitors: [Any] = []

    private init() {
        let size = CGSize(width: 84, height: 84)
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true

        label.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        label.alignment = .center
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        panel.contentView = background
    }

    /// Counts down `seconds`. Returns false when the user pressed Esc (only when `cancellable`).
    static func run(seconds: TimeInterval, cancellable: Bool = true) async -> Bool {
        let hud = CountdownHUD()
        return await hud.countDown(seconds, cancellable: cancellable)
    }

    private func countDown(_ seconds: TimeInterval, cancellable: Bool) async -> Bool {
        position()
        if cancellable {
            keys.start([.escape]) { [weak self] _ in self?.cancelled = true }
            // Mouse monitors need no permission; the HUD itself ignores the mouse.
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelled = true }
            }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown], handler: { [weak self] event in
                MainActor.assumeIsolated { self?.cancelled = true }
                return event
            }) { monitors.append(local) }
        }
        defer {
            keys.stop()
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
        }

        let end = Date().addingTimeInterval(seconds)
        var shown = false
        while !cancelled {
            let left = end.timeIntervalSinceNow
            if left <= 0 { break }
            label.stringValue = "\(Int(left.rounded(.up)))"
            if !shown { panel.orderFrontRegardless(); shown = true }
            // Wake at the next whole second, or sooner to notice Esc.
            let untilTick = left - left.rounded(.down)
            let nap = min(untilTick > 0.001 ? untilTick : 1, 0.1)
            try? await Task.sleep(for: .seconds(nap))
        }
        panel.orderOut(nil)
        // Let the window server drop the HUD before the screen is frozen.
        if shown { try? await Task.sleep(for: .milliseconds(120)) }
        return !cancelled
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 12))
    }
}
