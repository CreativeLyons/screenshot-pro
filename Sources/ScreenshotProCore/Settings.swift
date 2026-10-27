import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation

/// Actions that can have a global hotkey. Raw values are the settings keys.
public enum HotkeyAction: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case region, window, fullScreen, lastRegion, allScreens, windowFromList, openClipboard, history

    public var displayName: String {
        switch self {
        case .region: return "Capture Region"
        case .window: return "Capture Window"
        case .fullScreen: return "Capture Full Screen"
        case .lastRegion: return "Capture Last Region"
        case .allScreens: return "Capture All Screens"
        case .windowFromList: return "Capture Window from List"
        case .openClipboard: return "Open Image from Clipboard"
        case .history: return "Show Screenshot Filmstrip"
        }
    }

    /// The capture this action starts; nil for actions that do not capture.
    public var captureMode: CaptureMode? {
        switch self {
        case .region: return .region
        case .window: return .window
        case .fullScreen: return .fullScreen
        case .lastRegion: return .lastRegion
        case .allScreens: return .allScreens
        case .windowFromList: return .windowFromList
        case .openClipboard: return .clipboard
        case .history: return nil
        }
    }
}

/// Thumbnail size in the screenshot filmstrip.
public enum HistoryStripSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    public var displayName: String { rawValue.capitalized }
}

/// The screen edge the screenshot filmstrip docks to.
public enum HistoryStripEdge: String, Codable, CaseIterable, Sendable {
    case left, right
}

/// An sRGB color that can be stored in settings and element files.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public static let red = RGBAColor(red: 1, green: 0, blue: 0)
    public static let green = RGBAColor(red: 0, green: 0.7, blue: 0)
    public static let blue = RGBAColor(red: 0, green: 0.35, blue: 1)
    public static let yellow = RGBAColor(red: 1, green: 1, blue: 0)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

/// Excalidraw's open-color shades, a little brighter than pastel so they still read on a
/// busy screenshot. The editor's default colors.
public enum Palette {
    public static func hex(_ v: UInt32) -> RGBAColor {
        RGBAColor(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    public static let red = hex(0xFF6B6B)
    public static let orange = hex(0xFFA94D)
    public static let yellow = hex(0xFFD43B)
    public static let green = hex(0x51CF66)
    public static let teal = hex(0x38D9A9)
    public static let blue = hex(0x4DABF7)
    public static let violet = hex(0x9775FA)
    public static let pink = hex(0xF783AC)
    public static let ink = hex(0x1E1E1E)

    /// The editor toolbar's quick colors.
    public static let quickColors = [red, orange, yellow, green, blue, violet, ink, RGBAColor.white]
}

/// Every user preference. Stored as one JSON blob in UserDefaults, so adding a field only needs
/// a default value here: missing keys decode to their defaults (see `init(from:)`).
public struct ScreenshotProSettings: Codable, Equatable, Sendable {
    // MARK: General
    public var launchAtLogin = false
    public var showNotifications = true
    public var playCameraSound = false
    /// Show hint text in the editor and capture overlay.
    public var showTextHints = true

    // MARK: Hotkeys (nil = no hotkey)
    public var hotkeys: [HotkeyAction: KeyCombo] = ScreenshotProSettings.defaultHotkeys

    public static let defaultHotkeys: [HotkeyAction: KeyCombo] = [
        .region: KeyCombo(keyCode: UInt32(kVK_F12), modifiers: [.command]),
        .window: KeyCombo(keyCode: UInt32(kVK_F12), modifiers: [.command, .shift]),
        .fullScreen: KeyCombo(keyCode: UInt32(kVK_F13), modifiers: []),
        .lastRegion: KeyCombo(keyCode: UInt32(kVK_F12), modifiers: [.command, .option]),
        .history: KeyCombo(keyCode: UInt32(kVK_F12), modifiers: [.command, .control]),
    ]

    // MARK: Capture
    public var captureMousePointer = false
    /// Magnifier next to the crosshair for the whole region selection. When off, it shows
    /// only while Shift is held. (Stored under a new key: the old "showMagnifier" meant
    /// always on and defaulted to true.)
    public var alwaysShowMagnifier = false
    /// Include the window shadow in window captures (transparent margin around the window).
    public var windowShadow = false
    /// Seconds to wait before capturing (0 = immediately).
    public var captureDelay: Double = 0
    /// The last selected region in global Quartz points, for "Capture Last Region".
    public var lastRegion: CGRect?

    // MARK: After capture
    /// Show the destination picker after each capture.
    public var askForDestination = true
    /// Destinations (by id) used when not asking. Runs all of them; the editor last.
    public var defaultDestinations: [String] = ["editor"]
    /// Additionally copy every capture to the clipboard.
    public var alwaysCopyToClipboard = false
    /// Additionally save every capture to the output folder.
    public var alwaysSaveToFolder = false
    /// Screen captures kept in the screenshot filmstrip (0 = keep none).
    public var historyLimit = 10
    public var historyStripSize: HistoryStripSize = .small
    /// The strip tucks into a small tab at the screen edge and slides out on hover, like the Dock.
    public var historyAutoHide = false
    /// The strip (or its tab) was open at quit; it comes back at launch.
    public var historyStripOpen = false
    public var historyStripEdge: HistoryStripEdge = .left
    /// Top of the strip (and its tab) below the top of the screen, as a fraction of the screen's
    /// usable height (0 = top). Set by dragging the strip's grab bar or its tab.
    public var historyStripTop: Double = 0
    /// Top-left corner of the strip while it floats away from the screen edges, in global
    /// AppKit screen coordinates (y up). Set by dropping the grab bar out in the open; nil while
    /// docked at `historyStripEdge`. A floating strip is always pinned (auto-hide off).
    public var historyStripFloatingTopLeft: CGPoint?

    // MARK: Output
    public var outputFolder: String = ScreenshotProSettings.defaultOutputFolder
    public var filenamePattern = "Screenshot ${YYYY}-${MM}-${DD} ${hh}.${mm}.${ss}"
    public var outputFormat: ImageFormat = .png
    /// 0...100, for JPEG, HEIC and AVIF.
    public var jpegQuality = 85
    /// Ask for quality each time a lossy format is saved.
    public var promptForQuality = false
    /// Copy the saved file's path to the clipboard after saving directly.
    public var copyPathAfterSave = false
    /// Never overwrite: add " (2)", " (3)"... when the name exists.
    public var avoidOverwrite = true
    /// Next value for the ${NUM} placeholder (incremented after each use).
    public var outputFileCounter = 1

    public static var defaultOutputFolder: String {
        (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures"))
            .appendingPathComponent("Screenshot Pro").path
    }

    // MARK: Editor
    public var editorLineColor: RGBAColor = Palette.red
    public var editorFillColor: RGBAColor = .clear
    public var editorLineThickness: Double = 2
    public var editorShadow = true
    public var editorFontName = "Helvetica Neue"
    public var editorFontSize: Double = 18
    public var editorTextColor: RGBAColor = Palette.red
    /// Quick colors shown in the editor toolbar.
    public var editorQuickColors: [RGBAColor] = Palette.quickColors
    /// Pixel amount for Image > Expand Canvas (100...1000).
    public var expandCanvasAmount = 100
    /// Scale captures larger than the screen down to fit when opening the editor.
    public var autoResizeLargeScreenshots = false
    /// Pixelate cell size and blur radius defaults for obfuscation.
    public var pixelSize: Double = 12
    public var blurRadius: Double = 10
    /// Color tolerance for auto crop (0...255).
    public var autoCropTolerance = 10

    // MARK: Printing
    public var printFitToPage = true
    public var printCenter = true
    public var printAllowRotate = true
    public var printAllowEnlarge = false
    public var printFooter = false

    public init() {}

    // Tolerant decoding: every key is optional and falls back to the default above.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        func read<T: Decodable>(_ key: String, _ keyPath: WritableKeyPath<ScreenshotProSettings, T>) {
            if let v = try? c.decode(T.self, forKey: AnyKey(key)) { self[keyPath: keyPath] = v }
        }
        read("launchAtLogin", \.launchAtLogin)
        read("showNotifications", \.showNotifications)
        read("playCameraSound", \.playCameraSound)
        read("showTextHints", \.showTextHints)
        read("hotkeys", \.hotkeys)
        read("captureMousePointer", \.captureMousePointer)
        read("alwaysShowMagnifier", \.alwaysShowMagnifier)
        read("windowShadow", \.windowShadow)
        read("captureDelay", \.captureDelay)
        read("lastRegion", \.lastRegion)
        read("askForDestination", \.askForDestination)
        read("defaultDestinations", \.defaultDestinations)
        read("alwaysCopyToClipboard", \.alwaysCopyToClipboard)
        read("alwaysSaveToFolder", \.alwaysSaveToFolder)
        read("historyLimit", \.historyLimit)
        read("historyStripSize", \.historyStripSize)
        read("historyAutoHide", \.historyAutoHide)
        read("historyStripOpen", \.historyStripOpen)
        read("historyStripEdge", \.historyStripEdge)
        read("historyStripTop", \.historyStripTop)
        read("historyStripFloatingTopLeft", \.historyStripFloatingTopLeft)
        read("outputFolder", \.outputFolder)
        read("filenamePattern", \.filenamePattern)
        read("outputFormat", \.outputFormat)
        read("jpegQuality", \.jpegQuality)
        read("promptForQuality", \.promptForQuality)
        read("copyPathAfterSave", \.copyPathAfterSave)
        read("avoidOverwrite", \.avoidOverwrite)
        read("outputFileCounter", \.outputFileCounter)
        read("editorLineColor", \.editorLineColor)
        read("editorFillColor", \.editorFillColor)
        read("editorLineThickness", \.editorLineThickness)
        read("editorShadow", \.editorShadow)
        read("editorFontName", \.editorFontName)
        read("editorFontSize", \.editorFontSize)
        read("editorTextColor", \.editorTextColor)
        read("editorQuickColors", \.editorQuickColors)
        read("expandCanvasAmount", \.expandCanvasAmount)
        read("autoResizeLargeScreenshots", \.autoResizeLargeScreenshots)
        read("pixelSize", \.pixelSize)
        read("blurRadius", \.blurRadius)
        read("autoCropTolerance", \.autoCropTolerance)
        read("printFitToPage", \.printFitToPage)
        read("printCenter", \.printCenter)
        read("printAllowRotate", \.printAllowRotate)
        read("printAllowEnlarge", \.printAllowEnlarge)
        read("printFooter", \.printFooter)
        // The first palette was pure red, green, blue...: settings still holding those defaults
        // move to the softer Excalidraw palette. Colors the user picked are kept.
        if editorQuickColors == [.red, .green, .blue, .yellow, .black, .white] { editorQuickColors = Palette.quickColors }
        if editorLineColor == .red { editorLineColor = Palette.red }
        if editorTextColor == .red { editorTextColor = Palette.red }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// The output folder as a URL, with "~" expanded.
    public var outputFolderURL: URL {
        URL(fileURLWithPath: (outputFolder as NSString).expandingTildeInPath, isDirectory: true)
    }
}

/// Observable access to the settings. Every change is saved immediately.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()
    static let defaultsKey = "ScreenshotPro.settings.v1"

    private let defaults: UserDefaults

    @Published public var settings: ScreenshotProSettings {
        didSet { if settings != oldValue { save() } }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: SettingsStore.defaultsKey),
           let decoded = try? JSONDecoder().decode(ScreenshotProSettings.self, from: data) {
            settings = decoded
        } else {
            settings = ScreenshotProSettings()
        }
    }

    public func update(_ change: (inout ScreenshotProSettings) -> Void) {
        var s = settings
        change(&s)
        settings = s
    }

    public func resetToDefaults() {
        settings = ScreenshotProSettings()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: SettingsStore.defaultsKey)
        }
    }
}
