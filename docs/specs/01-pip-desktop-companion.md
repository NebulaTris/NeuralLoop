# Spec 01 — Pip on your desktop

Status: not started (work queue item 5, after spec 02) · Read first: `CLAUDE.md`, `docs/specs/03-pip-design-system.md`,
`docs/NOTIFICATIONS.md` · Touches: `apple/Sources/NeuralLoopCore`, `apple/App` (Mac only, behind `#if os(macOS)`)

## What the person sees

- **Settings → "Pip on your desktop"** card:
  - Toggle **Show Pip on my desktop** (default off; the library shows a one-time tip card "Put Pip on your desktop?" with a
    "Yes, show Pip" button that turns it on)
  - **Corner** picker: a 2×2 grid of mini screens (top left, top right, bottom left, bottom right), the chosen one highlighted;
    clicking a corner moves Pip there immediately (default bottom right)
  - **Size**: Small (96 px) · Medium (140 px, default) · Large (180 px)
  - Toggle **Keep Pip above other windows** (default on)
- The menu-bar panel (`QuickPanel`) gains a toggle **Show Pip on desktop** that mirrors the setting.
- When on, a small transparent window shows Pip (animated pose) in the chosen corner, 24 px from the screen edges, above the Dock
  and below the menu bar (it uses the monitor's work area). Pip is visible on every Space/desktop.
- **Click Pip**: a speech bubble appears above Pip (or below, when Pip is in a top corner) with Pip's current line and up to two
  buttons, for example "Review 6 cards" and "Open NeuralLoop". Clicking elsewhere or waiting 12 s closes it.
- **Double-click Pip**: opens the main window.
- **Drag Pip**: moves freely; on release Pip glides to the nearest corner (200 ms), and that corner is saved.
- **Right-click Pip**: menu with Move to top left / top right / bottom left / bottom right, Size ▸, Pause nudges until tomorrow,
  Hide Pip.
- **Nudges**: while Pip is on the desktop, a usual (gentle) nudge appears as Pip's speech bubble (Pip hops) for 12 s
  *instead of* a system notification, but only when the moment is right by the same rules as the big on-screen Pip
  (`NudgeDelivery`: the screen isn't locked, nothing in front fills a display, no app is recording); otherwise the system
  notification comes as today. Silly mode's nudges keep their own big Pip and sound; the desktop Pip never takes the
  `sad` or `shocked` pose. If Pip is hidden, notifications work as today.
- **Drop a PDF/EPUB onto Pip**: Pip does a happy hop and the main window opens the import flow from spec 02.

## What Pip shows (pose and line)

A pure function in `NeuralLoopCore` decides it; priority top to bottom:

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

Pip is never angry or disappointed, and the desktop Pip is never sad (see spec 03; the sad poses belong to Silly mode's
nudges only). Buttons map to actions: `.openMain`, `.openReview` (main window, Remember step of the book with the most due
cards), `.openChapter(bookId:, n:, stage:)`, `.addBook`.

## Architecture

Logic stays pure and tested in `NeuralLoopCore`; the window and its view stay thin in `apple/App` (golden rule 2).

```
apple/Sources/NeuralLoopCore/Companion.swift     pure: settings, corner geometry, snapping, what Pip shows, bubble layout
apple/Tests/CompanionTests.swift                 Swift Testing, written first
apple/App/Services/DesktopPip.swift              the NSPanel: show/hide, place, drag and snap, drop target, context menu
apple/App/Views/DesktopPipView.swift             PipView + speech bubble + buttons (thin)
apple/App/Views/SettingsView.swift               the "Pip on your desktop" card (Settings → Nudges)
apple/App/Views/QuickPanel.swift                 the "Show Pip on desktop" toggle
apple/App/Services/Library.swift                 Nudger: hands a gentle nudge to the desktop Pip when it's showing
```

### Core: `Companion.swift`

```swift
public enum Corner: String, Codable, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

public struct CompanionSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var corner = Corner.bottomRight
    public var size = 140.0          // 96 | 140 | 180
    public var onTop = true
    public var screen: String?       // the display's name, else the main display
}                                    // lenient decoding: a missing or bad key keeps its default

public enum Companion {
    public static func origin(_ corner: Corner, visibleFrame: CGRect, window: CGSize, margin: CGFloat = 24) -> CGPoint
    public static func nearestCorner(to center: CGPoint, in visibleFrame: CGRect) -> Corner   // ties → bottom right
    public static func state(books: [(book: Book, progress: StudyProgress)], preparing: [String], now: Double, hour: Int,
                             settings: NudgeSettings, recentNudge: (Nudge, Double)?, recentClose: (Int, Double)?) -> CompanionState
    public static func bubbleBelow(_ corner: Corner) -> Bool       // top corners → below
    public static func bubbleGrowsLeft(_ corner: Corner) -> Bool   // toward the screen's centre
    public static func isDrag(from: CGPoint, to: CGPoint) -> Bool  // moved more than 4 pt
    public static let bubbleSeconds = 12.0, hopSeconds = 3.0
}

public struct CompanionState: Equatable, Sendable { public let pose: String; public let line: String; public let actions: [CompanionAction] }
```

- `state` is the table above. It shares the "cards due" and "chapter left halfway" helpers with `Nudges.decide`
  (`Nudges.reviewedCardsDue` and friends), and quiet hours with `NudgeSettings.isQuiet`: no duplicated rules.
- The poses come from `PipPose` (`read`, `hop`, `nap`, `play`, `hug`, `study`, `proud`); never `sad` or `shocked`.
- Settings live in UserDefaults next to the nudge settings, decoded leniently like them.

### App: the window (`DesktopPip.swift`, Mac only)

- A borderless, non-activating `NSPanel` (like `NudgeOverlay`'s): clear background, no shadow, `hidesOnDeactivate = false`,
  `collectionBehavior = [.canJoinAllSpaces, .stationary]`, level `.floating` when "Keep Pip above other windows" is on, else
  `.normal`. Side = Pip's size + 120 pt (room for the bubble). It never takes focus from the app in front.
- Placement: the chosen display's `visibleFrame` (above the Dock, below the menu bar) through `Companion.origin`. Re-place on
  `NSApplication.didChangeScreenParametersNotification` and when the display goes away (fall back to the main display).
- Drag: a click that moves more than 4 pt (`Companion.isDrag`) drags the panel; on release, `nearestCorner`, glide there in
  200 ms (instantly under Reduce Motion), and save the corner and display.
- Content: `DesktopPipView` hosts `PipView(pose:size:)` (spec 03; Reduce Motion stills it) and the bubble (`Theme` colours,
  18 pt radius, at most 220 pt wide, a tail pointing at Pip). The bubble is announced to VoiceOver; every button is
  keyboard-reachable with a visible focus ring.
- Click toggles the bubble; double-click opens the main window; right-click shows the menu (`NSMenu`). Bubble buttons and
  menu items go through `Library` (open a book's step, open the picker), then bring the main window forward.
- Drop: the panel accepts file URLs; a PDF or EPUB goes to `Library.add` (spec 02's preview once it exists) with a happy hop;
  anything else gets the bubble "I can read PDF and EPUB books."
- State refresh: at launch, every 60 s, when a run ends, when progress is saved, and after a nudge. Keep idle CPU under 1 %
  (`PipView` already draws at most 30 frames a second).
- Nudges: in the `Nudger`, a gentle nudge goes to the desktop Pip's bubble instead of `Notifier` only when the desktop Pip is
  showing and `NudgeOverlay.moment()` says the moment is right (the `NudgeMoment` rules in `NudgeDelivery`); otherwise
  it's a notification as today. Silly nudges are untouched. Update `docs/NOTIFICATIONS.md` in the same commit.

## Tests to write first

Swift Testing (`apple/Tests/CompanionTests.swift`):
- `origin` for all four corners on a 1440×875 visible frame at (0, 0) with a 260×260 window and a 24 pt margin
- `origin` on a second display with a negative x origin
- `nearestCorner` for points in each quadrant and exactly at the centre (ties → bottom right)
- `state`: one test per table row, plus priority (preparing beats due cards; a nudge beats everything for 15 min), and never
  a `sad` or `shocked` pose
- bubble placement and side for each corner, the two-button limit, the drag threshold
- `CompanionSettings` defaults, and decoding settings saved before the companion existed

The window, drag, and drop are checked by hand (below); the views stay thin enough not to need tests.

## Definition of done

- Tests above written first and passing; `make check` green.
- Manual on macOS (record a 20-second screen capture in the PR):
  transparent (no grey box or shadow), stays above other windows when asked, visible on every Space, each corner option moves Pip at once,
  the choice survives a restart, dragging snaps to the nearest corner, a nudge shows in the bubble with a hop, dropping a PDF
  opens the import preview, reduced motion stops the animations, idle CPU under 1 %.
- `CLAUDE.md` "File map" updated (`Companion.swift`, `DesktopPip.swift`, `DesktopPipView.swift`) and the companion
  settings noted under "Contracts" (UserDefaults); `docs/NOTIFICATIONS.md` says when a nudge becomes Pip's bubble.
