# Screenshot Pro: product spec (v0.1)

What we build for v0.1, implemented the Mac way (Command instead of Ctrl, standard macOS
menus, sheets). Where the docs conflict, this file wins.

## 1. App shell (module ScreenshotPro)

- Menu bar only (`LSUIElement`), status item with a template-style glyph. Stay a pure accessory
  app even while editors are open (flipping the activation policy makes the Dock and Spaces jump); editor and Settings windows still come forward.
- Status menu: Capture Region, Capture Last Region, Capture Window, Capture Window from List >
  (submenu of windows), Capture Full Screen, Capture All Screens, separator, Open Image from
  Clipboard, Open Image File..., separator, Quick settings submenu (Ask for destination, Capture
  mouse pointer, Show magnifier, Play camera sound, Show notifications as checkmark items),
  Settings... (⌘,), About Screenshot Pro, Quit (⌘Q). Each capture item shows its hotkey.
  A warning item "Screen Recording permission needed..." appears at the top when not granted.
- Global hotkeys (Carbon, see `HotkeyManager`) for every `HotkeyAction`; defaults in
  `ScreenshotProSettings.defaultHotkeys` (⌘F12 region, ⇧⌘F12 window, F13 full screen, ⌥⌘F12 last region).
  Registration failures are listed in Settings > Hotkeys with a warning.
- Settings window (SwiftUI in an NSWindow, tabs): General (launch at login via SMAppService,
  notifications, sound, text hints), Hotkeys (recorder control per action, clear button, rejects
  combos without ⌘/⌃ unless F13-F20, rejects duplicates, "Restore defaults"), Capture (mouse
  pointer, magnifier, window shadow, delay 0-10 s), Output (folder chooser, filename pattern
  field with live preview and placeholder help, format, quality slider, prompt for quality,
  copy path, avoid overwrite), Destinations (ask vs default destinations checklist, always copy,
  always save), Editor (default colors, line thickness, font, expand canvas amount 100-1000 step
  100, auto-resize large screenshots, pixel size, blur radius), Printing.
- Permission window: explains Screen Recording, "Open System Settings" button, "Try Again" button,
  stale-entry note. Shown when a capture fails for permission.
- Notifications (UserNotifications) after exports when enabled: title = destination message,
  body = file name; clicking a file notification reveals it in Finder.
- Reopen (launching the app again while running) opens Settings so a hidden menu bar item is
  never a dead end.
- Capture coordinator flow: see ARCHITECTURE.md "Capture flow".

## 2. Capture (module ScreenshotProCapture)

All capture uses ScreenCaptureKit (ARCHITECTURE.md "Capture engine"). Modes:

- **Region**: freeze all displays, overlay per display. Dim the frozen
  screen except the selection; crosshair lines across the display; drag to select with live size
  label (pixel size) near the selection; magnifier (zoomer) beside the cursor showing the pixels
  under it enlarged with a center pixel marker and the cursor position, flipping side near screen
  edges; arrow keys move the cursor by 1 pt (⇧ = 10), Space/Enter can start/finish a selection
  from the keyboard; Esc cancels; a click without drag (under 3 px) on a
  window selects that window's frame as the region; selection can span displays. Optional hint
  text ("Drag to select, click a window, Esc to cancel") when showHints.
- **Window**: same overlay, window under the cursor highlighted (frame outline + title label);
  click captures that window via `SCContentFilter(desktopIndependentWindow:)` (so covered parts
  render), shadow per `windowShadow`. Space toggles between region and window mode.
- **Last region**: capture `lastRegion` immediately without an overlay (falls back to Region when
  none or off-screen).
- **Window from list**: the app shows a submenu; `CaptureService` needs an API to list capturable
  windows (title, app name, app icon, windowID) and to capture one by id. Add these as public API.
- **Full screen**: the display under the mouse pointer. **All screens**: all displays composed in
  global layout at the highest scale.
- **Clipboard / file**: read an image (NSPasteboard / NSOpenPanel with image types), scale from DPI
  (144 dpi = 2x), title = file name.
- Mouse pointer: when `includeCursor`, captured with `showsCursor` in the same freeze.
- Delay: wait `delay` seconds before freezing (show a small countdown HUD near the menu bar).
- `CaptureDetails`: title = window title (window mode) or frontmost app name; appName; screenRect
  in Quartz points; scale; date.
- Overlay recipe and pitfalls (non-activating panels, arming delay, focus fixes,
  multiple scales, no private SPI).

## 3. Destinations (module ScreenshotProOutput)

Ids in `DestinationID`. Priority order and picker shortcut letters:

| id | name | key | behavior |
|---|---|---|---|
| editor | Open in Editor | E | (ScreenshotProEditor) |
| file | Save | S | save directly to `outputFolder` with `filenamePattern`, `outputFormat`, quality (prompt if `promptForQuality`), avoid overwrite, increment `${NUM}` counter; optional copy path to clipboard |
| saveAs | Save as... | A | NSSavePanel in the output folder with the expanded name, format popup accessory |
| clipboard | Copy to Clipboard | C | PNG + TIFF on the pasteboard, image point size = pixels / scale |
| printer | Print... | P | NSPrintOperation with the printing settings (fit to page, center, rotate, enlarge, footer with date/title) |
| mail | Send as Mail | M | save a temp PNG, compose in the default mail client via `NSSharingService(named: .composeEmail)` |
| share | Share... | H | NSSharingServicePicker |
| ocr | Copy Text (OCR) | O | Swift Vision `RecognizeTextRequest`, text lines to the clipboard; "no text found" message. After a capture a small HUD near the pointer shows "Reading text..." and then the result, whatever the notification setting |
| openWith | Open in Preview | V | save temp file, open with Preview (or default image app) |

- **Destination picker**: a floating preview near the mouse: the capture
  (drag it into any app as a PNG file, double-click to edit), then a row of large buttons for
  Copy, Save, Copy Text and Edit (Return = Copy) and More for the other destinations plus
  "Always Do This Without Asking". Keyboard letters still trigger every destination; Esc, a
  click elsewhere or a right click dismisses.
- **Recent screenshots**: the last `historyLimit` (default 10) screen captures saved as PNGs in
  Application Support, shown in a strip at the left screen edge (menu item and hotkey). Click
  reopens it in the capture window (destination picker; the choice runs as after a capture),
  Command-click copies, drag drops the file into another app, right click lists every destination, an x on
  hover removes one, Clear All removes all. Thumbnail size small (default), medium or large.
  Auto-hide (pin button or Settings) tucks it into an edge tab with the app mark, revealed on
  hover or click like the Dock; it reopens at launch if it was open at quit. A grab bar at the
  top (and the tab) drags it anywhere; on release it snaps to the nearer left or right edge
  and keeps that height. Right click on either offers Move to Other Edge, Reset Position, Close.
- **Overlay escape hatch**: Esc or a right click (Control-click, other buttons) cancels a
  capture at any point, including the delay countdown.
- **Filename pattern**: placeholders `${YYYY} ${MM} ${DD} ${hh} ${mm} ${ss}
  ${capturetime} ${now} ${NUM} ${title} ${user} ${hostname} ${R..}` plus `${app}` (Mac addition),
  options `p` (pad), `d` (date format, map .NET patterns to Unicode), `s` (substring),
  `r` (replace), `l`/`u` (lower/upper case) as described in 02. Environment variables do not
  shadow built-ins. Filename-safe: replace `/` and `:` and control characters, trim, cap at 200
  characters. `/` in the pattern is allowed to create subfolders only when it is a literal in the
  pattern, never from a placeholder value. Default pattern: settings default.
- Unit tests for FilenamePattern in `Tests/ScreenshotProOutputTests`.

## 4. Editor (module ScreenshotProEditor)

v0.1 scope:

- Window: title "<capture title> - Screenshot Pro", unified toolbar, left vertical tools
  palette, top properties bar (context sensitive, shows only fields of the selected elements or
  current tool), scrolling canvas over a checkerboard, status bar with size and zoom popup.
  Window sizes to the capture (limited to the visible screen) and remembers its frame.
- Zoom levels 25, 50, 66.7, 75, 100, 200, 300, 400, 600 %; ⌘+ / ⌘- / ⌘0 (100 %) / ⌘9 (fit);
  pinch and ⌘-scroll zoom. 100 % = true size (pixels / scale points).
- Tools with single-key shortcuts (no modifier, only when no text field has focus):
  Select (Esc / V), Rectangle R, Ellipse E, Line L, Arrow A, Freehand F, Text T, Speech bubble S,
  Counter N, Highlight H, Obfuscate O (blur / pixelate;
  B and P select obfuscate with that mode), Crop C, Image from file (menu only).
- Element types, defaults and rendering (shadow convention included),
  defaults overridden by the settings' editor defaults and by remembered last-used values.
- Selection: click to select, ⇧-click to add, ⌘A select all, 8 resize handles, drag to
  move, arrow keys nudge 1 px (⇧ = 10), Delete/Backspace deletes, ⇧ while drawing constrains
  (squares, circles, 45 degree lines). Rubber-band selection is a Mac addition (allowed).
- Text editing in place (NSTextView overlay), ⌘↩ confirms, Esc cancels; font family, size,
  bold, italic, alignment in the properties bar; text box auto-grows.
- Counter: auto-incrementing numbers; "Reset counter" sets the next number to the start value.
- Crop: drag a crop rectangle, Enter/✓ applies, Esc cancels; auto crop item.
- Undo/redo (⌘Z / ⇧⌘Z) via snapshot-of-value-document model, continuous gestures merged.
- Edit menu: Cut, Copy, Paste, Duplicate (⌘D), Delete, Select All, Copy Image (flattened),
  Paste image from clipboard as an image element.
- Object menu: Bring to Front, Bring Forward, Send Backward, Send to Back; Add counter reset.
- Image menu: Crop, Auto Crop, Resize..., Rotate CW/CCW (⌘R / ⌘L, as in Preview; ⌘, stays Settings), Expand Canvas (settings amount),
  Clear background, Remove transparency.
- Effects menu: Border (⌘B), Drop Shadow (⌘Q is Quit on Mac: use ⌥⌘S) with "Drop Shadow..." to
  open settings, Torn Edges (⌥⌘T) with "Torn Edges..." settings, Grayscale (⌥⌘G), Invert (⌥⌘I).
  Effects move elements with the image (EffectGeometry).
- File menu: Save (⌘S: to the document URL if any, else `file` destination), Save As (⇧⌘S),
  Copy to Clipboard (⇧⌘C), Print (⌘P), Send as Mail (⇧⌘M), Share, Copy Text (OCR), Close (⌘W),
  Save/Load elements (`.sspro` JSON with embedded PNG).
- Destinations toolbar: Save, Copy, Print, Share, OCR, Undo, Redo.
- Closing a modified window asks to save (Save / Don't Save / Cancel); closing never quits the app.
- Drag the flattened image out of the canvas (from a toolbar drag handle) as a PNG file promise.
- Extras: Expand canvas amount, Resize dialog (25/33/50 %, width, height), text hints.

## 5. Not in v0.1

Imgur and other cloud uploads, Office/OneNote destinations, editor tabs, fixed-size and live OCR
capture modes, element picking inside windows (Accessibility), emoji element, cut-edge element,
redact-text, plugins, update checks, localization beyond English, HDR capture, video.

## 6. Quality bar

- arm64 only, macOS 15+, zero deprecated-API warnings, no private SPI.
- `swift build` with no warnings in our code; unit tests for pure logic (filename patterns,
  settings decoding, document model and undo, geometry conversions, effects on small test images).
- Every module's public contract unchanged.
