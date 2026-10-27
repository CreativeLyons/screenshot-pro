# Screenshot Pro

A free, open source screenshot tool for macOS, built natively for Apple silicon. It lives in
the menu bar: capture a region, a window or the whole screen with a global hotkey, then
annotate it in an editor, save it, copy it, print it or share it.

Built on current macOS APIs (ScreenCaptureKit, SwiftUI settings, UserNotifications,
SMAppService). No Rosetta, no account, no telemetry.

## Download

Grab the latest `ScreenshotPro-<version>-arm64.dmg` from
[Releases](https://github.com/CreativeLyons/screenshot-pro/releases), open it and drag
**Screenshot Pro** into **Applications**. Requires a Mac with Apple silicon
and macOS 15 or later.

The app is not notarized by Apple yet, so macOS blocks it the first time:

1. Open Screenshot Pro from Applications. macOS says it cannot verify the developer; click
   **Done** (or **OK**).
2. Open **System Settings > Privacy & Security**, scroll down to the message about
   Screenshot Pro and click **Open Anyway**, then confirm.

Or, from Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Screenshot Pro.app"
```

## Features

- Menu bar app (no Dock icon) with global hotkeys for every capture mode.
- Capture modes: region (freeze-frame overlay; hold Shift for the magnifier), last region,
  window (hover to pick), window from a list, full screen (display under the pointer), all
  screens, image from the clipboard, image file. Esc or a right click cancels a capture,
  also during the countdown.
- After capture: a preview with large buttons for Copy, Save, Copy Text (OCR) and Edit, and
  More for save as, print, mail, share and open with. Drag the preview into any app, or
  double-click it to edit. Or skip the preview and use a fixed list of destinations.
  Optional "always copy" and "always save".
- Recent screenshots: the last 10 screen captures (configurable) in a sidebar at the left
  edge of the screen. Click one to bring it back up in the capture window, Command-click to
  copy it, drag it into any app (Claude, Finder, Mail...), right click for every destination,
  hover for an x to remove it, or Clear All. Small, medium or large thumbnails. The pin button turns on auto-hide: the sidebar then tucks into a slim
  tab at the screen edge and slides out when you point at it, like the Dock. Drag the grab
  bar at its top (or the tab) to move it; it snaps to the left or right edge.
- Annotation editor: shapes, arrows, text, speech bubbles, counters, highlight, blur and
  pixelate, crop, effects (border, drop shadow, torn edges, grayscale, invert), undo and redo.
- Filename patterns with placeholders such as `${YYYY}-${MM}-${DD} ${title}`.
- Notifications after export; clicking a saved-file notification shows the file in Finder.
- Launch at login, quick settings in the menu, optional camera sound.
- Open images (or saved `.sspro` annotation files) with the app from Finder to edit them.

## Requirements (building from source)

- A Mac with Apple silicon, macOS 15 or later.
- Xcode with the Swift 6 toolchain (command line tools are enough to build).

## Build

```sh
scripts/build-app.sh
```

This builds a release binary for arm64 and assembles `build/Screenshot Pro.app`, signed
with the first "Apple Development" certificate in your keychain. A stable signature matters:
macOS ties the Screen Recording permission to it, so the grant survives rebuilds. Without a
certificate the app is signed ad hoc and you have to grant the permission again after every
build. Set `SIGN_IDENTITY` to pick a specific identity and `CONFIG=debug` for a debug build.

`scripts/make-dmg.sh` builds an ad hoc signed app and packages it as
`build/ScreenshotPro-<version>-arm64.dmg` for a release.

`swift build` alone compiles the package, but the app must run as a bundled `.app`: macOS
does not list unbundled executables for Screen Recording, and notifications need a bundle.

## Install from source

Copy `build/Screenshot Pro.app` to `/Applications` and launch it from there. Keep only that
one copy: two copies with the same bundle identifier confuse the macOS permission database
and notification routing. After rebuilding, copy the new build over the installed one.

## First run

1. A camera viewfinder icon appears in the menu bar. Launching the app again while it runs
   opens Settings, in case the menu bar item is hidden.
2. The first capture asks for Screen Recording permission. Turn on Screenshot Pro in
   System Settings > Privacy & Security > Screen & System Audio Recording, then choose
   "Try Again" in the permission window (or quit and reopen the app).
3. If the switch is on but captures still fail, the entry belongs to an older signature:
   remove it with the minus button and add the app again.
4. macOS asks about once a month whether the app may keep capturing the screen. Choose Allow.

## Default hotkeys

| Action | Hotkey |
|---|---|
| Capture Region | ⌘F12 |
| Capture Window | ⇧⌘F12 |
| Capture Full Screen | F13 |
| Capture Last Region | ⌥⌘F12 |
| Show Recent Screenshots | ⌃⌘F12 |

Change them in Settings > Hotkeys. (An existing install keeps its saved hotkeys, so set the
Recent Screenshots one there.) Since macOS 15, global hotkeys need Command or Control;
F13 to F20 also work on their own. A shortcut that macOS or another app already uses is
flagged in red.

## Testing

`swift test` runs the unit tests. The app also has a self-test mode that drives the editor,
effects, undo, export, Settings, destination picker and capture code paths, and saves
snapshots of its own windows (no Screen Recording permission needed for those):

```bash
SCREENSHOTPRO_SELFTEST_DIR=/tmp/sp-selftest "build/Screenshot Pro.app/Contents/MacOS/ScreenshotPro"
```

Add `SCREENSHOTPRO_SELFTEST_ONLY=capture` to run only the capture steps. Real screen captures need
an unlocked, awake display. Results land in `report.txt` next to the PNGs.

## Project layout

| Path | Contents |
|---|---|
| `Sources/ScreenshotProCore` | Models, settings, key combos, image formats, the destination protocol |
| `Sources/ScreenshotProCapture` | ScreenCaptureKit capture, region and window overlay, window list, permission helpers |
| `Sources/ScreenshotProOutput` | Destinations (file, clipboard, print, mail, share, OCR...), destination picker, filename patterns |
| `Sources/ScreenshotProEditor` | The annotation editor and effects |
| `Sources/ScreenshotPro` | The app: menu bar item, hotkeys, capture coordinator, Settings, permission window, notifications |
| `Tests/` | Unit tests for the pure logic |
| `Resources/` | `Info.plist` template and app icon |
| `scripts/` | `build-app.sh`, `make-dmg.sh` and the icon generator |
| `docs/` | Architecture and product spec |

## License

Screenshot Pro is free and open source under the [MIT License](LICENSE).
