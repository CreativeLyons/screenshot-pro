# Screenshot Pro: architecture

A native Apple Silicon (arm64) menu bar screenshot tool. SwiftPM package,
AppKit UI (SwiftUI only inside the Settings window), macOS 15.0 minimum, Swift 6.4 toolchain in
Swift 5 language mode. Built into `build/Screenshot Pro.app` by `scripts/build-app.sh`.

## License

MIT (see `LICENSE`). All code in this repository is original.

## Modules

| Module | Owns | Depends on |
|---|---|---|
| `ScreenshotProCore` | Models (`Capture`, `CaptureDetails`, `CaptureMode`), `ScreenshotProSettings` + `SettingsStore`, `KeyCombo`, `ImageFormat` + `ImageEncoder`, `CaptureDestination` protocol + `DestinationRegistry`, `ScreenshotProError` | nothing |
| `ScreenshotProCapture` | `CaptureService` (all capture modes), freeze-frame overlay, window detection, window list, `ScreenRecordingPermission` | Core |
| `ScreenshotProOutput` | Standard destinations (file, save as, clipboard, printer, mail, share, OCR, open with), `DestinationPicker`, `FilenamePattern` | Core |
| `ScreenshotProEditor` | `Editor.open`, `EditorDestination`, editor window, document model, elements, renderer, undo, effects | Core, Output |
| `ScreenshotPro` (app) | `main.swift`, app delegate, status item menu, `HotkeyManager`, capture coordinator, Settings window, permission onboarding, notifications, launch at login, About | all |

The public contract of each module is in one file (`CaptureService.swift`,
`OutputContract.swift`, `EditorContract.swift`, plus everything in Core). Those signatures are
fixed; modules may add API but not change it. Only the architecture owner edits Core.

## Capture flow (app coordinator)

1. Hotkey or menu item -> `CaptureCoordinator.capture(mode)`. Ignored while
   `CaptureService.shared.isCapturing`.
2. If `!ScreenRecordingPermission.isGranted`: `await requestAndProbe()`; on false show the
   permission window and stop. (Never show a system prompt under the freeze overlay.)
3. `CaptureService.shared.capture(mode, options:)` with options from settings. nil = cancelled.
4. Region/window captures store `details.screenRect` as `settings.lastRegion`.
5. Optional camera sound.
6. Destinations:
   - `askForDestination` -> `DestinationPicker.pick`; "remember" saves it as
     `defaultDestinations = [id]` and sets `askForDestination = false`.
   - else run `defaultDestinations`.
   - plus `clipboard` if `alwaysCopyToClipboard`, plus `file` if `alwaysSaveToFolder` (no duplicates).
   - Non-editor destinations run first, in priority order; the editor last.
7. Each `ExportResult.exported` with `showNotifications` posts a user notification (file results
   have "Show in Finder" / "Open" actions). Errors show an alert.

## Coordinates

- Quartz global points: origin top-left of the primary display, y down. `CaptureDetails.screenRect`,
  `settings.lastRegion`, `SCWindow.frame`, `CGWindowListCopyWindowInfo` bounds.
- AppKit global points: origin bottom-left of the primary display, y up. `NSScreen.frame`,
  `NSEvent.mouseLocation`, window frames. Convert with the primary screen height.
- Image pixels: `CGImage` width/height. `CaptureDetails.scale` = pixels per point.
- The editor document works in image pixels; the view shows them at `1/scale` points per pixel at
  100% zoom so Retina captures show at true size.

## Capture engine

ScreenCaptureKit only (`SCShareableContent`, `SCScreenshotManager.captureImage(contentFilter:configuration:)`).
`CGWindowListCreateImage` / `CGDisplayCreateImage` are obsoleted in the macOS 15 SDK and must not
be used. Region capture freezes every display first, then shows one borderless non-activating
overlay panel per display at `.screenSaver` level; the result is cropped from the frozen images.
Window hit testing uses `CGWindowListCopyWindowInfo` z-order (layer 0, our PID excluded);
window capture uses `SCContentFilter(desktopIndependentWindow:)`.

## Permissions

- Screen Recording: required for capture. Preflight at launch, request on first capture, probe
  with ScreenCaptureKit, explain with a window that opens System Settings. Expect macOS's monthly
  re-authorization alert.
- Hotkeys: Carbon `RegisterEventHotKey`, no permission. Hotkeys must include Command or Control
  (Option-only combos fail since macOS 15); standalone F13-F16 are allowed.
- Notifications: requested at the first notification.
- Automation (Apple Events) only for the Mail destination.

## Signing and install

`scripts/build-app.sh` signs with the first "Apple Development" identity in the keychain so the
designated requirement is stable and the Screen Recording grant survives rebuilds. Install one
copy only (`/Applications/Screenshot Pro.app`) to avoid TCC confusion.
