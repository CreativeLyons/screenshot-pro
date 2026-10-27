import AppKit
import ScreenshotProCapture

/// Explains the Screen Recording permission and helps the user grant it.
///
/// Shown when a capture cannot run for lack of permission, and from the menu's warning item.
/// "Try Again" re-probes ScreenCaptureKit, because a grant made while the app runs is not always
/// visible to the preflight check until relaunch.
@MainActor
final class PermissionWindowController: NSWindowController {
    static let shared = PermissionWindowController()

    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let tryAgainButton = NSButton(title: "Try Again", target: nil, action: nil)
    private let reopenButton = NSButton(title: "Quit & Reopen", target: nil, action: nil)
    private var isChecking = false
    private static let textWidth: CGFloat = 400

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Screen Recording Permission"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Brings the window forward on the current Space.
    func show() {
        setStatus("")
        if window?.isVisible != true { window?.center() }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent(in window: NSWindow) {
        let icon = NSImageView(image: NSImage(systemSymbolName: "rectangle.dashed.badge.record",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let headline = NSTextField(wrappingLabelWithString: "Screenshot Pro needs permission to capture your screen.")
        headline.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)

        let body = NSTextField(wrappingLabelWithString: """
            macOS only lets apps take screenshots with your approval. Open System Settings, go to \
            Privacy & Security > Screen & System Audio Recording, and turn on Screenshot Pro. \
            Then come back and click Try Again. If macOS asks you to quit the app, click \
            Quit & Reopen.
            """)

        let stale = NSTextField(wrappingLabelWithString: """
            If Screenshot Pro is already switched on but captures still fail, the entry belongs \
            to an older build. Select it, remove it with the minus (-) button, then add the app \
            again with the plus (+) button or by capturing once more.
            """)
        stale.textColor = .secondaryLabelColor

        let monthly = NSTextField(wrappingLabelWithString: """
            macOS may ask again about once a month whether Screenshot Pro may keep capturing \
            the screen. Choose Allow to keep going.
            """)
        monthly.textColor = .secondaryLabelColor

        statusLabel.textColor = .systemRed
        // Hidden while empty: a hidden arranged view leaves no gap above the buttons.
        statusLabel.isHidden = true

        let openButton = NSButton(title: "Open System Settings", target: self, action: #selector(openSettings))
        openButton.keyEquivalent = "\r"
        tryAgainButton.target = self
        tryAgainButton.action = #selector(tryAgain)
        // A grant made while the app runs often only takes effect after a relaunch.
        reopenButton.target = self
        reopenButton.action = #selector(quitAndReopen)
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.setViews([closeButton, reopenButton], in: .leading)
        buttons.setViews([tryAgainButton, openButton], in: .trailing)

        let labels = [headline, body, stale, monthly, statusLabel]
        let text = NSStackView(views: labels)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 10

        let top = NSStackView(views: [icon, text])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 16
        // Hug the icon and text horizontally, so the stacks' widths are fully determined.
        top.setHuggingPriority(.defaultHigh, for: .horizontal)
        text.setHuggingPriority(.defaultHigh, for: .horizontal)

        let root = NSStackView(views: [top, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 20
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 520),
            buttons.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            text.widthAnchor.constraint(equalToConstant: Self.textWidth),
        ])
        for label in labels {
            label.preferredMaxLayoutWidth = Self.textWidth
            label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        window.contentView = content
        fitWindowToContent()
    }

    /// Resizes the window to its content (keeping the top edge), so showing or hiding the
    /// status line leaves no empty band.
    private func fitWindowToContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.height > 0 else { return }
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: window.isVisible)
    }

    /// Quietly re-probes while the window is open (called when the app becomes active, e.g. on
    /// returning from System Settings) and closes it once capturing works.
    func recheckIfVisible() {
        guard window?.isVisible == true, !isChecking else { return }
        isChecking = true
        Task {
            let granted = await ScreenRecordingPermission.requestAndProbe()
            isChecking = false
            if granted { close() }
        }
    }

    @objc private func openSettings() {
        ScreenRecordingPermission.openSystemSettings()
    }

    @objc private func tryAgain() {
        guard !isChecking else { return }
        isChecking = true
        tryAgainButton.isEnabled = false
        setStatus("Checking...", color: .secondaryLabelColor)
        Task {
            let granted = await ScreenRecordingPermission.requestAndProbe()
            isChecking = false
            tryAgainButton.isEnabled = true
            if granted {
                setStatus("")
                close()
            } else {
                setStatus("""
                    Capturing is still not allowed. If you just turned the switch on, click \
                    Quit & Reopen.
                    """)
            }
        }
    }

    /// Shows a status message under the explanation; an empty message hides the line.
    private func setStatus(_ message: String, color: NSColor = .systemRed) {
        statusLabel.stringValue = message
        statusLabel.textColor = color
        statusLabel.isHidden = message.isEmpty
        fitWindowToContent()
    }

    @objc private func quitAndReopen() {
        AppRelauncher.relaunch()
    }

    @objc private func closeWindow() {
        close()
    }
}
