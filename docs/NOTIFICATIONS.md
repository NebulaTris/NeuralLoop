# How NeuralLoop's notifications work

This page explains every notification NeuralLoop can send: why it goes out, how it's built, where the code lives, and
how to change or move it. It's written for the next person or agent working on it. The rules here match the code
and its tests. If you change one, change the other in the same commit (CLAUDE.md, golden rule 6).

Notifications are Mac only. The iPad app sends none: it has no `Notifier`, no `Nudger`, and its project target
excludes those files (`apple/project.yml`).

## The three kinds, and the one switch above them

| Kind | What it says | When it goes out | Its switch (Settings → Nudges) |
|---|---|---|---|
| **Chapter ready** | "Chapter 2 is ready to study" | Once per chapter, when the chapter you can study next is completely prepared, podcast and video included | "When my next chapter is ready" |
| **Gentle nudge** | "🐾 4 cards are ready" / "🧶 Loose yarn in “Caching”" | At most once a day, when something small is worth doing | "Gentle nudges" |
| **Silly mode** | "🎻 Pip is playing a tiny sad violin", then "😿…", then "😱 FAHHH! A whole day?!" | After hours away, one step at a time, only when something is ready | "Silly sounds and a sad Pip when I've been away" |

**"Notifications from Pip" is the master switch.** Off means nothing at all: no chapter-ready, no nudges, no Silly
mode. In code, every scheduled notification asks `NudgeSettings.allows(.chapterReady | .nudges | .silly)`, which
checks the master switch first.

Two more things can make a notification appear, both on request:

- **Test buttons in Settings → Nudges** ("Send a test nudge", "Try" on each Silly mode step). They always go out,
  even with the master switch off, because you pressed them. They're never recorded in the history, so they don't
  use up a real nudge.
- **Development flags** (`-NLTestNudge sadViolin|sadMeow|shocked|gentle`). These also always go out.

## Where the code lives

All the decisions are pure, tested code in `NeuralLoopCore`. The app only gathers inputs, stores state, and talks
to macOS.

| File | What it does |
|---|---|
| `apple/Sources/NeuralLoopCore/Nudges.swift` | `NudgeSettings` (every switch, quiet hours, Silly mode's steps, volume; lenient decoding of older saved settings), `NudgeHistory` (what was sent and when, and the last visit), `SillyStep`, `NudgeMood`, `Nudge` (title, body, mood, the silly wording), and `Nudges.decide(...)`, the whole nudge policy |
| `apple/Sources/NeuralLoopCore/ChapterReady.swift` | `ChapterReady.step(...)`: which chapter to announce, if any; `isComplete`; `current` |
| `apple/Sources/NeuralLoopCore/NudgeDelivery.swift` | `NudgeMoment` (screen locked, something full screen in front, microphone in use) and `showsBigPip(...)`: whether a silly nudge also gets the big on-screen Pip |
| `apple/App/Services/Library.swift` | `enum Nudger`: settings and history in UserDefaults, `tick` (every ~5 minutes), `send`, `engaged`/`studying` (visits), `scheduledAllowed`, `watchingChapters`. `Library.announce` runs `ChapterReady` on every shelf refresh (every 4 s) |
| `apple/App/Services/Notifier.swift` | The only code that talks to `UNUserNotificationCenter`: asking permission (`ask`, `permission`, `openSystemSettings`), `post` (title, body, sound, optional Pip picture), and the click handler (opens the book, or the library) |
| `apple/App/Services/NudgeSounds.swift` | Each mood's sound file and Pip pose; draws the Pip picture attached to silly notifications |
| `apple/App/Services/NudgeOverlay.swift` | The big on-screen Pip: a floating card that plays the sound and shrinks away when it ends; `moment()` reads the system state for `NudgeDelivery` |
| `apple/App/Services/BookSession.swift` | The study clock calls `Nudger.studying()`, so studying counts as a visit |
| `apple/App/Views/SettingsView.swift` | `NudgesPage` (all the switches, quiet hours, the steps editor, volume, tests) and `NotificationsAllowed` (permission status, with a button that opens System Settings) |
| `apple/App/Views/GuidedTour.swift` | The last page of the tour asks for notification permission |

Tests: `NudgeTests.swift`, `ChapterReadyTests.swift`, and `NudgeDelivery`'s tests inside `NudgeTests.swift`, all in
`apple/Tests/NeuralLoopCoreTests/`. Run them with `cd apple && swift test`.

## Chapter ready, step by step

The shelf refreshes every 4 seconds. Each time, `Library.announce` runs this for every book:

1. **Find the current chapter** (`ChapterReady.current`): the first chapter that is unlocked
   (`Loop.isUnlocked`: chapter 1, or the one after a closed loop) and whose own loop isn't closed. Locked chapters
   are never considered, however ready they are.
2. **Is it complete?** (`ChapterReady.isComplete`) Every item must be `done`, or `skipped` (not chosen for this
   chapter). `todo`, `working`, `waiting_quota`, and `failed` all count as still coming, so a chapter whose podcast
   is still recording, or waiting on NotebookLM's limit, isn't ready yet.
3. **Watch, then announce.** If the current chapter isn't complete, it goes on the watch list. If it is complete
   and was on the watch list, the notification goes out and it comes off the list. A chapter that was already
   complete the first time the app looked is never announced, so there's no burst of alerts after an update or a
   relaunch.
4. **Remember the watch list** across launches in UserDefaults (`chapterReadyWatching`, `[bookId: [chapter]]`),
   pruned to books still on the shelf.

The notification goes out only if `settings.allows(.chapterReady)` and `Nudger.scheduledAllowed`. Clicking it opens
that book (`Notifier`'s click handler, through `Library.path`).

There's no "your whole book is ready" notification. It was removed: the only alert that matters is the next
chapter you can actually study.

## Gentle nudges and Silly mode: `Nudges.decide`

`Nudger.tick` runs about every 5 minutes, from the library's background loop. It passes in every book with its
progress, the settings, the history, the time, the hour, and whether NeuralLoop is the app in front. `decide`
returns one `Nudge` or nothing. In order:

1. **Off, paused, or quiet:** nothing. That covers the master switch, "Pause until tomorrow", and quiet hours
   (default 22:00–08:00, and they wrap past midnight).
2. **What's ready** (the "news"):
   - **Cards due:** at least 3 reviewed cards are due, which gives "🐾 N cards are ready".
   - **Loose yarn:** otherwise, the chapter you most recently left partway through, at least 12 hours ago. It only
     counts if that chapter is fully prepared (`ChapterReady.isComplete`), so Pip never nudges you towards a
     podcast that isn't there yet.
3. **Silly mode first**, if all of these hold:
   - silly sounds are allowed;
   - NeuralLoop isn't in front;
   - there's a book;
   - a Silly mode step is due (`sillyStep`):
     - The steps count hours since your last visit. The default steps are 🎻 at 8 h, 😿 at 12 h, and 😱 at 24 h,
       and the person can change them.
     - The step that goes is the latest one whose hours have passed, unless it (or a later one) already went this
       absence.
     - Steps that share an hour go one at a time.
     - A step that quiet hours swallowed is skipped, not stacked.
     - If a repeat is set, the last step can repeat every N hours.
   - **With news,** the news is retold the silly way ("🎻 Pip is playing a tiny sad violin" with the cards line as
     the body).
   - **With no news,** a warm "Pip's ready when you are" goes out at most once a week. Otherwise nothing.
4. **Then the gentle nudge**, if nudges are allowed:
   - At most one a day (`lastSentDay`).
   - After two ignored nudges in a row, every other day.
   - After a week away, weekly only.
   - The nudge itself is the news.

Silly steps never touch the gentle back-off. They have their own history fields (`lastSillySent`, `lastStepId`,
`lastMissedYou`), so a run of silly steps doesn't silence the usual nudges.

**A visit** (`NudgeHistory.engaged`) is any of:

- NeuralLoop coming to the front;
- leaving it;
- a minute of studying.

A visit resets the hours-away clock and the ignored count.

### Delivery: the notification, and maybe the big Pip

`Nudger.send` records the nudge in the history (unless it's a test), then:

- **Silly nudges:**
  - The big Pip appears only if `NudgeDelivery.showsBigPip` agrees: the "Arrives as" setting is on, the screen
    isn't locked, nothing is full screen in front, and the microphone isn't in use (a call is likely). The big Pip
    then plays the sound at the chosen volume, and the notification arrives silently.
  - Otherwise the notification carries the sound itself, which keeps to Focus and the system's alert volume.
- **Picture:** the notification gets a picture of the sad or shocked Pip, drawn only when it will actually be used
  and deleted if attaching it fails.
- **Sounds:**
  - Each mood's sound is `NeuralLoop-<name>.caf`, looked up first in the app's Resources and then in
    `~/Library/Sounds`, falling back to the default chime.
  - `scripts/install-nudge-sounds.sh` makes them (tags stripped, even loudness, IMA4).
  - NOTICE.md records that the bundled ones have no known licence.

**Known limit:** macOS doesn't let an app read Focus without the Communication Notifications entitlement, which an
ad-hoc signed app can't have. During a quiet Focus (no call, nothing full screen), the big Pip can still appear.

## What's stored

All of it is in the app's UserDefaults (`app.neuralloop.books`):

| Key | Contents |
|---|---|
| `nudgeSettings` | JSON of `NudgeSettings`: `enabled` (master), `chapterReady`, `nudges`, `quietStart`, `quietEnd`, `pausedUntil`, `sillySounds`, `steps` (`[{id, sound, hours}]`), `repeatHours`, `bigPip`, `volume`. Decoding is lenient: a missing key takes its default; a bad step is skipped; an old `fahhh: false` removes that step |
| `nudgeHistory` | JSON of `NudgeHistory`: `lastSent`, `lastSentDay`, `ignoredInARow` (gentle only), `lastEngaged` (last visit), `lastMood`, `lastSillySent`, `lastStepId`, `lastMissedYou` |
| `chapterReadyWatching` | `[bookId: [chapter numbers]]`, the chapters `ChapterReady` is waiting on |

## Development builds never spam

`Nudger.scheduledAllowed` is false in Debug builds unless they're launched with `-NLNotify YES`. Without that, test
copies of the app (for screenshots or debugging) send no scheduled nudges and no chapter-ready alerts, even while
the real app is also running. Tests from Settings and `-NLTestNudge` still go, because they're asked for.

Before this, a development copy running next to the real app could send its own nudges and its own chapter alerts.
That was one source of "random" notifications.

## Permission

- **When it's asked:**
  - `Notifier.start()` asks once at launch.
  - The guided tour's last page has an "Allow notifications" button.
  - Settings → Nudges shows the current status.
- **When it's off:** macOS won't show its prompt again once permission is denied, so the button then opens System
  Settings → Notifications for NeuralLoop (`Notifier.openSystemSettings`).

## How to test

- **Unit tests:** `cd apple && swift test --filter "NudgeTests|ChapterReadyTests"`.
- **By hand, with a Debug build:**
  - `open NeuralLoop.app --args -NLOpenSettings YES -NLSettingsPage Nudges` opens the settings.
  - `-NLTestNudge shocked` shows the big Pip and the notification.
  - `-NLNudgePictures /tmp/pics` writes each silly picture.
  - `-NLNotify YES` lets a Debug build send scheduled notifications.
- **To check chapter-ready without waiting:** with the app running (`-NLNotify YES` for Debug), watch a book whose
  chapter 1 podcast is still being made. The alert should come once, right after the last item for chapter 1
  finishes, and never for chapter 2 until chapter 1's loop is closed.

## Moving it somewhere else

To bring notifications to another platform (Windows, Linux, a server push), reuse the pure core as is
(`Nudges.decide`, `ChapterReady.step`, `NudgeDelivery.showsBigPip`, `NudgeSettings`, `NudgeHistory`). The new
platform layer then needs to provide five things:

1. **A timer** every few minutes that calls `decide` with the books, settings, history, time, hour, and whether the
   app is in front. A second, faster check (every few seconds while books are being prepared) runs
   `ChapterReady.step` per book.
2. **Storage** for `nudgeSettings`, `nudgeHistory`, and `chapterReadyWatching`.
3. **A way to post** a notification with a title, body, optional sound, and optional picture, plus click handling.
4. **Visit signals:** app activated, app left, studying.
5. **Optionally,** the system state for `NudgeMoment` and an overlay window for the big Pip.

## History of the rules (why they are the way they are)

- **"Chapter N is ready" fired for every chapter as soon as its reading guide existed,** locked or not, and without
  its podcast or video. It now follows `ChapterReady`.
- **"Your book is ready" was removed.** It was noise next to the chapter alert.
- **Chapter alerts ignored the nudge switches.** There's now a master switch, and every kind has its own switch
  beneath it.
- **Silly steps used to count as ignored gentle nudges,** which silenced the usual nudges for days. They now have
  their own history.
- **Silly steps used to fire with nothing to do.** They now need news; otherwise there's a weekly "ready when you
  are".
- **Development builds could send scheduled notifications** alongside the real app. They now need `-NLNotify YES`.
