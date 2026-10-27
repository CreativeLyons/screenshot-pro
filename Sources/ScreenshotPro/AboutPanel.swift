import AppKit

/// The standard About panel with a short licensing note in the credits.
@MainActor
enum AboutPanel {
    static func show() {
        let credits = """
            A native Apple Silicon screenshot tool for macOS.

            Free and open source under the MIT License.
            """
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: credits, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Screenshot Pro",
            .credits: attributed,
        ])
    }
}
