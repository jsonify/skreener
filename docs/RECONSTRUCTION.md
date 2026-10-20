# Skreener — Clean-room reconstruction of CleanShot X's feature set

This document maps what the shipped **CleanShot X 4.8.8** bundle (`pl.maketheweb.cleanshotx`)
contains, as established with REA static analysis, onto the components of **Skreener**, an
independent re-implementation. No CleanShot code, nibs, sounds, images or other assets are
copied. The app was used only to work out *what* the product does. Skreener's *how* is new code
built on public Apple frameworks.

## Evidence

| Evidence ID | Operation | What it established |
|---|---|---|
| `ev_72538edab9bd…c13610` | `inspect_macho` (arm64 slice, SHA-256 `09f00cb3…f19b50`) | 75 linked libraries: ScreenCaptureKit (weak), AVFoundation, Vision, CoreImage, CoreData, WebKit, SwiftUI (weak), ServiceManagement, LocalAuthentication, UserNotifications; embedded Sparkle, Sentry, LetsMove, plus private frameworks AudioLoop, InsiderKit, Lava, Legit, VectorBoolean |
| `ev_6092942d…8403a` | `inspect_native_dispatch_metadata` | 1,195 ObjC/Swift classes (598 unique names), 4,529 method implementations, 2,621 ivars. Coverage is *partial*: some ivar offsets are unresolved, and no Swift conformance or vtable records were recovered |
| (IB decode) | `decode_interface_builder` | 18 nib archives: MainMenu, Preferences, RecordingPreferences, VideoConverter, ANResizeControlViewController, Changelog, RenewLicense, Acknowledgments, and the share extensions |
| (strings) | `strings -a` on main binary | Menu titles, URL-scheme command names, preference labels |
| Info.plist / PlugIns | `plutil` | LSUIElement menu-bar app, `cleanshot://` URL scheme, camera/mic usage, document types (images, video, `com.cleanshot.document`), 4 app extensions (Annotate share, Pin share, Quick Look preview, Quick Look thumbnail) |

Confidence levels used below:

- **Observed** means it is present in the shipped artifact.
- **Inferred** means behavior is deduced from class or string names.
- **Unknown** means nothing in the static evidence settles it.

Nothing here comes from running CleanShot.

## Feature map

| # | Feature | Evidence (class / string names) | Confidence | Skreener component | Status |
|---|---|---|---|---|---|
| 1 | Menu-bar app with status menu | `LSUIElement`, `StatusMenuController`, `StatusMenuPopup`, `CSMenuItem` | Observed | `StatusBarController` | ✅ v1 |
| 2 | Global hotkeys (configurable) | `ShortcutsViewController`, `KeyboardShortcutRecognizable*`, `HotkeyMigrator` | Observed | `HotkeyCenter` (Carbon) | ✅ v1 (fixed defaults) · recorder UI in v2 |
| 3 | Capture area, with dimensions, crosshair and snapping | `ScreenCapture`, `CrosshairController`, `SnappingController`, `(Loupe)`, `areaMoveBy:softSnapping:` | Observed / inferred | `SelectionController` | ✅ v1 (no loupe or snapping yet) |
| 4 | Capture previous area | "Capture Previous Area", `capture-previous-area` | Observed | `Coordinator.capturePreviousArea` | ✅ v1 |
| 5 | Capture fullscreen | "Capture Fullscreen", `capture-fullscreen` | Observed | `Coordinator.captureFullscreen` | ✅ v1 |
| 6 | Capture window, with or without shadow | `CSWindowFilter`, `ScreenCaptureKit.ContentCache` | Observed | window mode in `SelectionController` | ✅ v1 |
| 7 | Freeze screen during selection | `Freezer`, `FreezerController` | Inferred | — | v2 |
| 8 | Self-timer | `SelfTimerOverlay`, `SelfTimerDelegate`, `countdown` sound | Observed | — | v2 |
| 9 | Scrolling capture (auto, classic, Vision-stitched) — **done in v1.3, see below** | `ScrollingGrabber`, `AutomaticScrollingGrabber`, `ClassicScrollingGrabber`, `VisionScrollingGrabber`, `SCONScroll*` | Observed | — | v3 (largest open item) |
| 10 | OCR / Capture Text, with or without line breaks | `OCR`, "Capture Text With/Without Line Breaks", Vision linked | Observed | `TextRecognizer` | ✅ v1 |
| 11 | Quick Access Overlay (floating thumbnail with actions; drag out) | `OneOverlay`, `OneControlsView`, `FloatingOverlay`, "Show Quick Access Overlay", "Save All Overlays", "Restore Recently Closed" | Observed | `QuickAccessManager` / `QuickAccessPanel` | ✅ v1 |
| 12 | Annotation editor | `AnnotateController`, `ANCanvasController`, tools `ANArrow` (4 arrow generators), `ANLine`, `ANRectangle`, `ANFilledRectangle`, `ANEllipse`, `ANText`, `ANTextEmojiLayer`, `ANHighlighter`, `ANDraw`, `ANPixelate`, `ANCounter`, `ANSpotlight`, `ANCropController`, `ANZoomController` | Observed | `Annotate/*` | ✅ v1: arrow, line, rect, filled rect, ellipse, text, highlighter, pen, pixelate, counter, crop, select/move, undo/redo · spotlight, emoji, zoom in v2 |
| 13 | Annotation background / padding ("beautify") | `ANBackground*`, `ANBackgroundSettingsGradientsHeaderView`, `ANAlignmentSelector`, `ANShadow` | Observed | — | v2 |
| 14 | Editable annotation document format | `AnnotateDocument`, UTI `com.cleanshot.document` | Observed | — | v3 (own `.skreener` format) |
| 15 | Pin to screen | `Pin*`, "Pin to the Screen", `FOLockButton`, `FOCloseButton`, `FODragButton` | Observed | `PinPanel` | ✅ v1 (resize, opacity, copy/save) |
| 16 | Screen recording (video), with system audio, mic, camera, clicks and keystrokes | `ScreenRecorder`, `RecorderController`, `AudioMixer`, `CameraOverlay`, `CursorHighlighter`, `KeyboardOverlay`, `VUMeter`, "Record Computer Audio" | Observed | `ScreenRecorder` | ✅ v1: video + system audio + mic (macOS 15+) · camera, click highlights and keystrokes in v2 |
| 17 | GIF recording / export | `GIFUtility`, `Gifsicle`, bundled `gifsicle` binary, `GIFTrimmer` | Observed | — | v2 (ImageIO GIF encoder instead of gifsicle) |
| 18 | Video editor / trimmer / converter | `VideoEditorController`, `LegacyVideoTrimmer`, `VideoConverter`, `AudioRemover` | Observed | — | v2 |
| 19 | Capture history | `MediaHistoryController`, `HistoryThumbnail`, `QLMediaHistory`, CoreData linked | Observed | `HistoryStore` + `HistoryView` (file-based) | ✅ v1 |
| 20 | Hide desktop icons | `IconOverlay`, `IconOverlayController`, `hide/show/toggle-desktop-icons` | Observed | `DesktopIconHider` | ✅ v1 |
| 21 | URL-scheme automation API | `cleanshot://` plus commands `capture-fullscreen`, `capture-previous-area`, `scrolling-capture`, `open-from-clipboard`, `add-quick-access-overlay`, `restore-recently-closed`, `toggle-desktop-icons`… | Observed | `skreener://` in `URLCommand` | ✅ v1 |
| 22 | Cloud upload and share links | `CloudAPI`, `S3MultiPartUpload`, `UploadQueueController`, Alamofire | Observed | — | Out of scope (needs a backend) |
| 23 | Share extensions (Annotate / Pin from other apps) | `AnnotateShareExtension.appex`, `PinShareExtension.appex` | Observed | — | v3 (needs an Xcode project) |
| 24 | Quick Look preview/thumbnail for own document type | `QuickLookExtension.appex`, `QuickLookThumbnailingExtension.appex` | Observed | — | v3 |
| 25 | Settings window | `Preferences.nib`, `RecordingPreferences.nib`, `PreferencesToolbar` | Observed | `SettingsView` (SwiftUI) | ✅ v1 |
| 26 | Onboarding | `Onboarding`, `ON*View` | Observed | — | v2 |
| 27 | Launch at login | `LaunchAtLogin`, `ONLaunchAtLoginView` | Observed | `SMAppService` toggle | ✅ v1 |
| 28 | Licensing, updates, telemetry | `Legit`, `RenewLicense`, Sparkle, Sentry | Observed | — | Not reproduced |

## Unknowns that static evidence did not settle

- Exact interaction details of area selection: modifier keys, arrow-key nudging, and snapping thresholds.
- How the scrolling-capture stitching works internally. `VisionScrollingGrabber` suggests Vision-based image registration, but no pseudocode was examined.
- Encoder parameters for video and GIF (bitrate, palette strategy).
- Default hotkeys. Skreener uses ⌘⇧ + digit; the matching macOS screenshot shortcuts must be disabled.

If any of these matter, the next REA step is to open the binary with Hopper and run
`analyze_function` on the relevant `ScrollingGrabber` / `SnappingController` methods. That
still means re-implementing the behavior, not transcribing the code.

## Skreener architecture (v1)

```
Sources/Skreener/
  App/           main.swift, AppDelegate, StatusBarController, MainMenu, URLCommand, Coordinator
  Capture/       ScreenCapturer (ScreenCaptureKit), SelectionController (area/window picker), TextRecognizer (Vision)
  Overlay/       QuickAccessManager/Panel, PinPanel, Toast
  Annotate/      AnnotationDocument, Annotation, AnnotationRenderer, AnnotationCanvas, AnnotateWindowController
  Recording/     ScreenRecorder (SCStream → AVAssetWriter), RecordingBorder
  Library/       HistoryStore, HistoryView, DesktopIconHider, Settings, SettingsView, HotkeyCenter, Sound, Clipboard
```

## Skreener-only additions (v1.1)

Not present in CleanShot's class inventory (`ev_6092942d…8403a`). Bounded search: no barcode,
redaction, foreground-mask, color-sampler or change-watch classes among the 598 names.

| Feature | Implementation |
|---|---|
| QR/barcode decoding inside Capture Text | `VisionTools.barcodes` (`VNDetectBarcodesRequest`) |
| Auto-Redact | `VisionTools.sensitiveText`: OCR + regex/NSDataDetector + Luhn check → pixelate annotations |
| Lift Subject | `VisionTools.liftSubject` (`VNGenerateForegroundInstanceMaskRequest`, macOS 14) |
| Screen color picker | `NSColorSampler` → hex |
| Watch Area | `AreaWatcher`: 1 s polling + `ImageDiff.changedFraction` (160 px thumbnails, 0.4% threshold) |
| OCR confirmation sound | Synthesized in `Sound.synthesizeTick`. Modeled on the measured profile of CleanShot's `ocr.aif` (≈40 ms burst at 800–1000 Hz, peak ≈0.34, sharp release); no audio copied |

## Capture toolbar and recorder (v1.2)

Evidence (strings in `ev_72538edab9bd…c13610`'s binary and classes in `ev_6092942d…8403a`): "Aspect ratio",
"Ratio", "Size", `OneRatioControl`, `OneSizeControl`, `ResolutionMenuItem`, `CountDownOverlay`, `PausableTimer`,
"Restart Recording", "Discard", "Highlight Clicks", `CursorHighlighter`, "Show Keystrokes", `KeyboardOverlay`,
`CameraOverlay` (+ shape, size, flip settings), "Start GIF Recording" / "Start Video Recording", "Hide desktop icons",
"Record Computer Audio", "Record Microphone", "Drag to record a part of the screen.", "Select Window", "Padding",
"Background", "Shadow".

| Feature | Skreener component |
|---|---|
| ⌘⇧5-style toolbar (screenshot and record × screen, window, area) | `CaptureSession`, `CaptureToolbar` |
| Adjustable selection, handles, ratio/size presets, nudging | `CaptureSession` |
| Options menu | `CaptureOptionsMenu` |
| Window backgrounds + padding | `WindowStyler` |
| Countdown | `CountdownOverlay` |
| Recording controls: pause, restart, discard | `RecordingControlBar`, `RecordingWriter.pause/resume` (host-clock retiming) |
| Click highlights / keystrokes / camera bubble (recorded) | `ClickHighlighter`, `KeystrokeOverlay`, `CameraOverlay`, kept in the video by excluding only Skreener's other windows from the `SCContentFilter` |
| GIF output | `GIFExporter` (ImageIO, 15 fps, ≤960 px) |

## Scrolling capture (v1.3)

Evidence:

- **Classes** (`ev_6092942d…8403a`):
  - `ScrollingGrabber` has a single `captureAndCompare` method and fields `shotA`, `shotB`, `lastComparedShot`, `lastMatch`, `mergedImage`, `headerHeight`, `heightDiff`, `matchNotFoundCount`, `timer`, `captureRect`, `horizontalMode` and `windowID`.
  - Its subclasses are `AutomaticScrollingGrabber` (`matches`, `finalMatch`, `isPaused`), `ClassicScrollingGrabber` and `VisionScrollingGrabber`.
  - Direction detection: `ScrollingGrabberDirectionDetectionDelegate`, plus `horizontalMatches` / `verticalMatches` / `isDetecting` on `SGOverlay`.
- **Imports** (`ev_72538edab9bd…c13610`): `CGEventCreateScrollWheelEvent2`, `CGEventPost`, `CGEventTapCreate`, `AXIsProcessTrustedWithOptions`, `VNTranslationalImageRegistrationRequest`, `vDSP_*` and `vImage*`.
- **Strings:** "Drag to capture the scrolling part of the screen.", "Auto-Scroll needs accessibility permissions", "Please slow down...", "Screenshot is very large", "Move cursor here to start scrolling", and the onboarding text about scrolling slowly, one direction only, and excluding scroll bars.

How the observed design maps to Skreener's implementation:

| Observed design | Skreener |
|---|---|
| Timer → `captureAndCompare` → merged image | `ScrollingCaptureController` (120 ms tick) → `ScrollStitcher.add` |
| Classic matcher (vImage/vDSP) | Exact per-line FNV hashes, offset voting, verification on lines with content; scroll-bar edge ignored |
| Vision matcher | `VNTranslationalImageRegistrationRequest` proposal, confirmed by 16-block luminance signatures; coarse signature search as a last resort |
| `headerHeight` | Sticky header/footer detected per match; the footer is appended once at the end |
| Vertical/horizontal detection | Two stitchers run until one matches, then that axis is locked |
| Auto-Scroll via synthetic wheel events | Pixel-unit `CGEvent` scroll at the cursor, wait for it to settle, capture, match; adaptive step on overshoot; auto-finish when nothing moves |
| `isPaused` + "Move cursor here…" | Auto-Scroll pauses while the cursor is outside the area |

Verified on synthetic pages:

- **Exact frames:** pixel-identical results, vertical and horizontal, with sticky header and footer and a moving overlay scroll bar.
- **Noisy frames (±3 per channel):** correct offsets on every step, about 40 ms per frame.
- **Error cases:** "too fast", "backwards" and recovery all detected correctly.
