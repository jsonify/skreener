# Skreener

A menu-bar screenshot and screen-recording app for macOS 14+. It is a clean-room reconstruction of
CleanShot X's feature set. See [docs/RECONSTRUCTION.md](docs/RECONSTRUCTION.md) for the
evidence-backed feature map and roadmap.

## Build & run

```bash
./scripts/build-app.sh          # → build/Skreener.app (signed with your Apple Development identity if present)
open build/Skreener.app
```

On first capture, macOS asks for **Screen & System Audio Recording** permission. Grant it, then
quit and reopen Skreener.

## Shortcuts

| Action | Hotkey | URL |
|---|---|---|
| Capture area (Space toggles window mode, click captures window under cursor) | ⌘⇧4 | `skreener://capture-area` |
| Capture fullscreen | ⌘⇧3 | `skreener://capture-fullscreen` |
| Capture toolbar, window mode | ⌘⇧5 | `skreener://capture-window` |
| Capture previous area | ⌘⇧7 | `skreener://capture-previous-area` |
| Capture text (OCR → clipboard) | ⌘⇧2 | `skreener://capture-text` |
| Capture toolbar, record mode / stop recording | ⌘⇧6 | `skreener://record-screen` |
| Pick color from screen (hex → clipboard) | ⌘⇧8 | `skreener://pick-color` |
| Watch area: auto-capture when it changes (again to stop) | ⌘⇧9 | `skreener://watch-area` |

> macOS reserves ⌘⇧3/4/5/6 for its own screenshot tools. Turn those off in System Settings ›
> Keyboard › Keyboard Shortcuts… › Screenshots, and quit CleanShot X if it's running, or they win.

Other URL commands: `open-annotate`, `open-from-clipboard`, `pin-from-clipboard`, `annotate-last`,
`pin-last`, `restore-recently-closed`, `open-history`, `open-settings`,
`hide-/show-/toggle-desktop-icons`.

## Capture toolbar (⌘⇧5 / ⌘⇧6)

A floating bar at the bottom of the screen, like macOS's own ⌘⇧5, with these controls:

- **Screenshot**: Entire Screen, Selected Window or Selected Portion. **Record**: the same three targets.
- **Area selections stay adjustable**: drag the 8 handles, drag inside to move, use the arrows to nudge (⇧ moves 10, ⌥ resizes), or type W × H.
  Pick an aspect ratio (16:9, 4:3, 3:2, 1:1, 9:16) or a size preset (720p, 1080p, square, portrait…). ⇧ while dragging keeps it square.
  Return or double-click confirms. Space cycles screen → window → area. S/R switch between screenshot and record.
- **Window mode**: camera cursor, blue highlight, and the app's icon, name and size.
- **Options menu**:
  - Output: Quick Access, clipboard, save folder (Desktop, Documents, Downloads, Pictures or other).
  - Timer: 3, 5 or 10 s.
  - Screenshots: window shadow, "capture as shown" (keeps menus and tooltips), backgrounds (wallpaper or gradients) with padding, freeze screen.
  - Recording: MP4 or GIF, 24, 30 or 60 fps, microphone device, computer audio, camera (device, circle or rounded shape, size), mouse pointer, click highlights, keystrokes, and hiding desktop icons.
  - Remember last selection.
- **While recording**: a floating bar with stop, pause/resume, restart, discard and an elapsed timer. The menu-bar item shows the time too.
  Click highlights, keystrokes and the camera bubble appear in the video; the controls and border don't.
  Keystrokes need the Accessibility permission. Window recordings capture just that window, without the overlays.

## Freeze screen

With **Freeze screen while selecting** on (the default, in Settings › General), area, window and text
captures snapshot every display the instant the shortcut fires, before Skreener shows anything.
You select on that frozen image, so tooltips, hover states and open menus or dropdowns are kept.
Window captures from a frozen screen are cropped as they looked, including any menu over them.

## Beyond CleanShot

- **QR / barcode reading**: Capture Text (⌘⇧2) decodes any QR code or barcode in the area, copies its payload and offers to open links.
- **Auto-Redact** (editor toolbar, eye-slash): finds emails, phone numbers, Luhn-valid card numbers, AWS/GitHub/Slack/API tokens, JWTs, IPs and SSNs with on-device OCR and pixelates them in one undoable step.
- **Lift Subject** (editor toolbar): cuts the main subject out onto a transparent background, copies it, and opens it in a new editor.
- **Screen color picker** (⌘⇧8): copies the hex value of any pixel.
- **Watch Area** (⌘⇧9): select a region (build log, download, chat) and Skreener captures it automatically the moment it changes.

## Annotation editor keys

V select · A arrow · L line · R rectangle · F filled rectangle · O ellipse · T text · H highlighter ·
P pen · X pixelate · N counter · C crop (Return applies) · Shift constrains · Delete removes ·
⌘Z / ⇧⌘Z undo/redo · ⌘C copy · ⌘S save as.
