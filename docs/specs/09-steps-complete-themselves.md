# Spec 09 — Steps that complete themselves

Status: done · Read first: `CLAUDE.md` (the progress.json contract), specs 04 and 07 · Touches: `apple/`

## Why

Every step of a chapter's loop used to finish only when the person pressed "I've done this step" (remaking the map
from memory was the one exception). That's a chore after real work, and it's easy to press without doing the step.
Now each step watches for the real thing (listening, reading, answering, reviewing) and ticks itself off, with the
same gentle "nicely done" from Pip. The button stays everywhere as a manual override: it's the person's book.

The signals must resist false positives: dragging a scrubber, leaving a podcast running in an empty room, flipping
through pages, or leaving the app open on a page all look like studying to a naive counter. Each rule below says what
counts and what doesn't.

## Rules

| Step | Done when | Doesn't count |
|---|---|---|
| Listen & watch (`prime`) | ≥ 85% of the podcast **or** ≥ 85% of the video has really played | seeking or scrubbing past a part, playing faster than 2×, replaying the same part twice, a video playing in a hidden or minimized window or while the app is in the background |
| Read | ≥ 85% of the pages (PDF) or ~300-word sections (text) count as read **and** the last one was reached | time with no keyboard, mouse, trackpad, or scroll input in the last 90 s; time while the app isn't active or the reading window isn't key and visible; pages turned faster than 600 words a minute |
| Recall | a recall answer in your own words is checked (by the recall model or word matching) and is a real try (≥ 5 words, ≥ 3 different ones), **or** every quiz question is answered | an empty or throwaway answer |
| Map | the mind map is remade from memory (unchanged) | |
| Remember (`space`) | every card of the chapter has been reviewed at least once (`reps ≥ 1` or a `last`), here or on another device | |

Always: a step is never ticked off in a chapter that's still locked, and nothing ever un-completes a step.

### Listening (`PlayCoverage`, `Listening`)

- The shared players (`MediaCenter`) already observe time every quarter second; about once a second while playing, the
  stretch just played (media time from → to, the player's rate, the wall time that passed) goes to `PlayRecorder`.
- `PlayCoverage.add(from:to:rate:wallSeconds:)` keeps a stretch only if it moved forwards, the rate is at most 2, and media
  time moved no further than `rate × wall + 0.75 s` (and never more than 2× wall time, whatever the player claims). A jump
  further than that is a seek. Kept stretches are joined as a union, so replays add nothing.
- The played share is the union's length inside `[0, duration]` over the duration; 0 while the length isn't known.
- Audio counts while playing even with the window in the background (it's a podcast). Video counts only while a view
  showing it is visible: its window visible, not minimized or covered, some of it on screen, and the app active (the
  player's own full-screen window counts). On the iPad: the scene in the foreground.
- With the book open, its `BookSession` records the stretch and checks the step. With the book closed (playing from the
  menu bar or the shelf), `PlayRecorder` gathers stretches and writes them to the book's `progress.json` every 15 s, and
  ticks the step off there too (only in an open chapter).

### Reading (`ReadingCredit`)

- Once a second, while the Read step is on screen, the step asks: is the app active, is the reading window key and
  visible (not minimized or covered), and was there input in the last 90 s? On the Mac, input comes from
  `CGEventSource.secondsSinceLastEventType` (keyboard, mouse, trackpad, scrolling; no permission needed), counted only while
  the app is active and its window key. On the iPad, scrolling the chapter or the PDF is the input.
- If so, that second is shared between the pages on screen: a page is on screen when at least 40% of it shows, or it
  fills at least 40% of the view. A tick never credits more than 2 s (a late timer, a Mac that slept).
- A page counts as read when its credited time ≥ `max(6 s, words ÷ 600 × 60 s)`. 600 words a minute is fast skimming;
  turning pages faster than that never adds up. A picture-only or blank page needs the 6 s minimum.
- PDF chapters: pages from PDFKit, words from each page's text (read off the main thread). Text (EPUB Markdown) chapters:
  blocks grouped into sections of about 300 words, each measured in the chapter's scroll view.

### What the person sees

- While a step isn't done, a small ring and a few plain words: "Heard 62% of the podcast · watched 40% of the video",
  "Read 40% · 12 of 30 pages", "Quiz: 3 of 8 answered", "Reviewed 4 of 10 cards", with one line on what finishes it.
- When a step ticks itself off: a "Nicely done!" card with Pip (and a button on to the next step) for eight seconds, or the
  usual "Loop closed!" hug when it closed the loop. Reduce Motion fades instead of sliding.

## Storage (progress.json)

```json
"watch":   {"3": {"audio": [[0, 312.4], [400, 610]], "video": [[0, 95]]}},
"reading": {"3": {"pages": {"0": 41.5, "1": 38}, "count": 30, "last": 1}}
```

- `watch.<n>.audio|video`: sorted, joined `[start, end]` seconds of media time, to a tenth of a second.
- `reading.<n>.pages`: credited seconds per page or section (0-based index as a string, a tenth of a second); `count`:
  how many pages or sections the chapter had; `last`: the furthest one reached while reading.
- Both are left out while empty, so older files stay byte for byte the same. Decoding is lenient: a bad span, page, or
  chapter is skipped.
- Merging across devices: spans by union, page seconds by max, `count` and `last` by max. They don't move `updatedAt`
  (like study time), and while tracking the app writes them at most every 15 s.

## Files

- Core (pure, tested): `PlayCoverage.swift` (`PlayCoverage`, `WatchProgress`, `Listening`), `ReadingCredit.swift`
  (`ReadingRecord`, `ReadingProgress`, `ReadingCredit`), `AutoSteps.swift` (`quizFinished`, `cardsSeen`/`cardsAllSeen`,
  `isRealAnswer`, `Loop.completeIfOpen`, `StudyProgress.recordPlay`/`addWatching`/`creditReading`), `Progress.swift`
  (fields, encoding, merge), `Remake.swift` (`QuizProgress(i:results:)`).
- App: `Services/MediaCenter.swift` (measuring, `PlaySource`), `Services/PlayRecorder.swift`, `Services/BookSession.swift`
  (`earn`, `Earned`, tracking saves), `Views/StepTracking.swift` (`ViewProbe`, `ReadingTracker`, `StepProgressRow`),
  `Views/Steps.swift` (each step's progress and hooks), `Views/BookView.swift` (the "nicely done" card).

## Tests (`apple/Tests/NeuralLoopCoreTests`)

- `PlayCoverageTests`: straight play covers it all; a seek doesn't count the skipped part; scrubbing counts nothing;
  > 2× doesn't count, 2× does, a player claiming 1× while jumping doesn't; replays don't double count; backwards, still,
  paused, NaN add nothing; clipping to the length; tidying spans from a file; the 85% rule for podcast or video; lenient
  round trip; union merge across devices; files without watching or reading encode unchanged.
- `ReadingCreditTests`: minimum and skimming-speed needs; idle, inactive, or hidden time earns nothing; seconds shared
  between visible pages, capped per tick, unknown pages ignored; flipping faster than skimming counts nothing; 85% and the
  last page is done, 85% without the end isn't; reaching the end without reading isn't; empty chapters; which pages are on
  screen; ~300-word sections; lenient round trip; max merge across devices.
- `AutoStepsTests`: the quiz counts once every question is answered; Remember needs every card once; a step completes
  only in an open chapter and only once; a real recall try; playing and reading never touch `updatedAt`.

## Signals that can't be measured perfectly

- A finger resting on an iPad without scrolling looks like no input; 90 s of grace covers a long page at normal speed.
- On the Mac, the input clock is system-wide; it's only trusted while NeuralLoop is active with the reading window key.
- The menu-bar panel's video counts only when the app is active, so a video watched there may count less than it played.
- Picture in picture on the iPad doesn't count once the app is in the background.
