# Spec 01 — Pip on your desktop

Status: ready to build (after spec 02) · Read first: `CLAUDE.md`, `docs/specs/03-pip-design-system.md` · Touches: `src-tauri/`, `src/`

## What the person sees

- **Settings → "Pip on your desktop"** card:
  - Toggle **Show Pip on my desktop** (default off; the library shows a one-time tip card "Put Pip on your desktop?" with a
    "Yes, show Pip" button that turns it on)
  - **Corner** picker: a 2×2 grid of mini screens (top left, top right, bottom left, bottom right), the chosen one highlighted;
    clicking a corner moves Pip there immediately (default bottom right)
  - **Size**: Small (96 px) · Medium (140 px, default) · Large (180 px)
  - Toggle **Keep Pip above other windows** (default on)
- The menu-bar/tray menu gains a check item **Show Pip on desktop** that mirrors the toggle.
- When on, a small transparent window shows Pip (animated pose) in the chosen corner, 24 px from the screen edges, above the Dock
  and below the menu bar (it uses the monitor's work area). Pip is visible on every Space/desktop.
- **Click Pip**: a speech bubble appears above Pip (or below, when Pip is in a top corner) with Pip's current line and up to two
  buttons, for example "Review 6 cards" and "Open NeuralLoop". Clicking elsewhere or waiting 12 s closes it.
- **Double-click Pip**: opens the main window.
- **Drag Pip**: moves freely; on release Pip glides to the nearest corner (200 ms), and that corner is saved.
- **Right-click Pip**: menu with Move to top left / top right / bottom left / bottom right, Size ▸, Pause nudges until tomorrow,
  Hide Pip.
- **Nudges**: while Pip is on the desktop, a nudge appears as Pip's speech bubble (Pip hops) for 12 s *instead of* a system
  notification. If Pip is hidden, system notifications work as today.
- **Drop a PDF/EPUB onto Pip**: Pip does a happy hop and the main window opens the import flow from spec 02.

## What Pip shows (pose and line)

A pure Rust function decides it; priority top to bottom:

| Situation | Pose | Line | Bubble buttons |
|---|---|---|---|
| A nudge was just delivered (≤ 15 min) | `hop` for 3 s, then the pose below | the nudge text | the nudge's action |
| A book is being prepared | `study` | "I'm preparing “{title}”. You can start on ready chapters." | Open NeuralLoop |
| A chapter loop was closed in the last 10 min | `hug` | "Loop closed! Chapter {n} is unlocked." | Start chapter {n} |
| Quiet hours | `nap` | "Shh, it's quiet time. See you in the morning." | Open NeuralLoop |
| ≥ 1 reviewed card due | `play` | "{n} cards are ready. About {m} min." | Review {n} cards · Open NeuralLoop |
| A chapter left halfway ≥ 12 h | `play` | "Loose yarn in “{chapter}”. Next: {step}." | Continue · Open NeuralLoop |
| Weekly goal met or all loops closed | `proud` | "All caught up. You're doing great." | Open NeuralLoop |
| Otherwise | `read` | "Hi! I'm here when you want a small study break." | Add a book · Open NeuralLoop |

Pip is never sad, angry, or disappointed (see spec 03). Buttons map to actions: `open_main`, `open_review` (main window, Review
screen of the book with the most due cards), `open_chapter {bookId, n, stage}`, `add_book`.

## Architecture

```
src-tauri/src/companion.rs   window lifecycle, positioning, snapping, state computation + `companion` events
src-tauri/src/settings.rs    Settings gains `companion: CompanionSettings`
src-tauri/src/tray.rs        CheckMenuItem "Show Pip on desktop"
src-tauri/src/nudge.rs       tick(): if companion visible → emit to companion instead of notification
src-tauri/capabilities/companion.json   permissions for the "pip" window only
src-tauri/tauri.conf.json    "pip" window + "macOSPrivateApi": true (required for transparent windows on macOS)
src/pip.html                 the companion page
src/js/companion.js          DOM: render pose, bubble, buttons, drag start, drop target, context menu request
src/js/companion-logic.js    pure: bubble placement, button list, timing
src/companion.css            styles (transparent background, bubble)
src/js/settings.js           the "Pip on your desktop" card
src/js/main.js               handles `companion-action` events in the main window (navigate)
```

### Window (`src-tauri/tauri.conf.json`)

```json
{ "label": "pip", "url": "pip.html", "title": "Pip", "width": 260, "height": 260,
  "transparent": true, "decorations": false, "shadow": false, "resizable": false, "skipTaskbar": true,
  "alwaysOnTop": true, "visibleOnAllWorkspaces": true, "focus": false, "visible": false, "dragDropEnabled": true }
```
and `"app": { "macOSPrivateApi": true, … }`. Window size follows the Size setting: `side = pip + 120` px (room for the bubble).
The page background must be fully transparent (`html, body { background: transparent }`), no scrollbars.

### Rust: `src-tauri/src/companion.rs`

```rust
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Corner { TopLeft, TopRight, BottomLeft, #[default] BottomRight }

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase", default)]
pub struct CompanionSettings { pub enabled: bool, pub corner: Corner, pub size: u32 /* 96 | 140 | 180 */, pub on_top: bool, pub monitor: Option<String> }
// Default: enabled false, BottomRight, 140, on_top true, monitor None

pub struct Rect { pub x: f64, pub y: f64, pub width: f64, pub height: f64 }   // logical pixels

pub fn corner_position(corner: Corner, work_area: &Rect, window: (f64, f64), margin: f64) -> (f64, f64);   // pure
pub fn nearest_corner(window_center: (f64, f64), work_area: &Rect) -> Corner;                               // pure

#[derive(Serialize, Debug, PartialEq)]
pub struct CompanionState { pub pose: &'static str, pub line: String, pub actions: Vec<Action> }
pub fn companion_state(books: &[BookProgress], running: &[String], now: i64, local_hour: u32, settings: &Settings,
                       recent_nudge: Option<(&Nudge, i64)>, recent_close: Option<(u32, i64)>) -> CompanionState;   // pure, the table above

#[tauri::command] pub fn companion_show(app: AppHandle) -> Result<(), String>
#[tauri::command] pub fn companion_hide(app: AppHandle) -> Result<(), String>
#[tauri::command] pub fn companion_set_corner(app: AppHandle, corner: Corner) -> Result<(), String>
#[tauri::command] pub fn companion_set_size(app: AppHandle, size: u32) -> Result<(), String>
#[tauri::command] pub fn companion_state_now(app: AppHandle) -> CompanionState
#[tauri::command] pub fn companion_action(app: AppHandle, action: Action) -> Result<(), String>   // shows main window, emits `companion-action`
#[tauri::command] pub fn companion_context_menu(app: AppHandle) -> Result<(), String>             // native popup menu
```

- Positioning: get the window's current monitor (or the saved `monitor` by name, else primary), use `monitor.work_area()`
  (physical pixels; divide by `scale_factor()` for logical), compute with `corner_position`, set with `LogicalPosition`.
  Re-position on `ScaleFactorChanged` and when monitors change (listen for window `Moved`/`Resized`, and re-check every 60 s).
- Snapping: on `WindowEvent::Moved`, debounce 250 ms (the window stops moving), compute `nearest_corner`, glide there in
  8 steps over 200 ms, save the corner and monitor name.
- Distinguish click vs drag in JS: `mousedown` → if the pointer moves > 4 px, call `getCurrentWindow().startDragging()`;
  otherwise it's a click.
- State: compute on startup, every 60 s, after `pipeline` done events, after `save_progress`, and after a nudge; emit
  `companion` `{pose, line, actions}` to the `pip` window only (`app.emit_to("pip", …)`).
- `nudge::tick`: if `settings.companion.enabled` and the pip window is visible, emit the nudge to the companion
  (`companion-nudge`) and skip the system notification. Record it for `recent_nudge`.
- Refactor so `companion_state` and `nudge::decide` share the "due cards" and "half-done chapter" helpers (no duplication).

### Capabilities (`src-tauri/capabilities/companion.json`)

```json
{ "identifier": "companion", "windows": ["pip"],
  "permissions": ["core:event:default", "core:window:allow-start-dragging"] }
```
Custom commands are callable from any window by default; keep the companion page to the `companion_*` commands only (code review
rule, plus a test that greps `src/js/companion.js` for `invoke(` calls and checks each name starts with `companion_`).

### Frontend

- `src/pip.html`: `<div id="pip" aria-label="Pip" role="img"></div><div id="bubble" role="status" aria-live="polite" hidden></div>`,
  loads `pip-poses.js`, `companion.css`, `js/companion.js` (module).
- `src/js/companion-logic.js` (pure, tested in `src/test/companion.test.mjs`):
  `bubblePlacement(corner) → "above" | "below"` (top corners → below), `bubbleSide(corner) → "left" | "right"` (bubble grows
  toward the screen centre), `visibleButtons(actions) → first two`, `BUBBLE_MS = 12000`, `HOP_MS = 3000`,
  `isDrag(start, current) → distance > 4`.
- `src/js/companion.js`: listens for `companion` and `companion-nudge`; renders `window.PIP[pose]` into `#pip`; click toggles the
  bubble; buttons call `companion_action`; double-click calls `companion_action({type:"open_main"})`; right-click calls
  `companion_context_menu`; drag-drop via `getCurrentWebview().onDragDropEvent` → on a PDF/EPUB drop call
  `companion_action({type:"import_book", path})` (main window opens spec 02's flow); other files → Pip bubble "I can read PDF and
  EPUB books."
- `src/companion.css`: transparent page; Pip centred at the bottom (or top, per corner); bubble uses the app's tokens
  (surface, line, ink, radius 18 px, 14 px text, max width 220 px, tail pointing at Pip); respects
  `prefers-reduced-motion` (no hop, no bubble slide).
- Settings card in `src/js/settings.js`; corner picker is four `button`s with `aria-pressed` and labels "Top left" etc.

## Tests to write first

Rust (`companion.rs` `mod tests`):
- `corner_position` for all four corners on a 1440×900 work area at (0, 25) with a 260×260 window and 24 px margin
- `corner_position` on a second monitor with a negative x origin
- `nearest_corner` for points in each quadrant and exactly at the centre (ties → bottom right)
- `companion_state`: one test per table row, plus priority (preparing beats due cards; nudge beats everything for 15 min)
- `CompanionSettings` defaults and deserialising old settings files without a `companion` key

JavaScript (`src/test/companion.test.mjs`): placement and side for each corner, two-button limit, drag threshold.

Browser (`tests/test_desktop_ui.py`, new `pip.html` fixture with a fake Tauri that records calls and can emit events):
- `test_companion_shows_pose_from_state_event`
- `test_click_opens_bubble_with_buttons_and_closes_after_timeout` (use a short timeout override for tests)
- `test_bubble_button_invokes_companion_action`
- `test_settings_corner_picker_calls_set_corner_and_highlights`
- `test_dropping_a_book_on_pip_requests_import`

## Definition of done

- Tests above written first and passing; `make check` green.
- Manual on macOS (record a 20-second screen capture in the PR):
  transparent (no grey box or shadow), stays above other windows, visible on every Space, each corner option moves Pip at once,
  the choice survives a restart, dragging snaps to the nearest corner, a nudge shows in the bubble with a hop, dropping a PDF
  opens the import preview, reduced motion stops the animations, idle CPU under 1 %.
- `CLAUDE.md` "Contracts" and "File map" updated (new commands, events `companion`, `companion-nudge`, `companion-action`,
  settings `companion`).
