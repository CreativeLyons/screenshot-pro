// swift-tools-version: 6.0
import PackageDescription

// Screenshot Pro: a native Apple Silicon screenshot tool, free and open source.
// Module layout (each module owns its own folder under Sources/):
//   ScreenshotProCore     - models, settings, filename patterns, shared protocols (no UI)
//   ScreenshotProCapture  - ScreenCaptureKit capture, region/window selection overlay
//   ScreenshotProOutput   - destinations: file, clipboard, print, share, OCR, picker
//   ScreenshotProEditor   - annotation editor window, drawable elements, effects
//   ScreenshotPro         - the app: menu bar item, hotkeys, settings window, coordinator
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
]

let package = Package(
    name: "ScreenshotPro",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ScreenshotPro", targets: ["ScreenshotPro"]),
    ],
    targets: [
        .target(name: "ScreenshotProCore", swiftSettings: swiftSettings),
        .target(name: "ScreenshotProCapture", dependencies: ["ScreenshotProCore"], swiftSettings: swiftSettings),
        .target(name: "ScreenshotProOutput", dependencies: ["ScreenshotProCore"], swiftSettings: swiftSettings),
        .target(name: "ScreenshotProEditor", dependencies: ["ScreenshotProCore", "ScreenshotProOutput"], swiftSettings: swiftSettings),
        .executableTarget(
            name: "ScreenshotPro",
            dependencies: ["ScreenshotProCore", "ScreenshotProCapture", "ScreenshotProOutput", "ScreenshotProEditor"],
            swiftSettings: swiftSettings
        ),
        .testTarget(name: "ScreenshotProCoreTests", dependencies: ["ScreenshotProCore"], swiftSettings: swiftSettings),
        .testTarget(name: "ScreenshotProEditorTests", dependencies: ["ScreenshotProEditor", "ScreenshotProCore"], swiftSettings: swiftSettings),
        .testTarget(name: "ScreenshotProOutputTests", dependencies: ["ScreenshotProOutput", "ScreenshotProCore"], swiftSettings: swiftSettings),
        .testTarget(name: "ScreenshotProCaptureTests", dependencies: ["ScreenshotProCapture", "ScreenshotProCore"], swiftSettings: swiftSettings),
    ]
)
