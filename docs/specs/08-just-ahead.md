# Spec 08: Just ahead

Status: done · Read first: `CLAUDE.md`, specs 04 and 06 (practice 3) · Touches: `apple/` (the pipeline already had what it needs)

## Why

A book run used to make the text items (reading guide, concept map, quiz, flashcards, mind map) for every chapter, and
podcasts and videos for chapters 1–2. Chapters unlock one at a time, so most of that work waits weeks to be used, and some
of it never is. Each NotebookLM podcast or video takes a big share of the five-hour allowance; on the local engine a
chapter takes minutes of the Mac's time. Preparing each chapter just before the reader reaches it saves both, and the
chapter they're on still comes first.

## Rules (`NeuralLoopCore/PrepWindow.swift`)

- **Frontier F**: the first chapter that is open and whose loop isn't closed (`ChapterReady.current`). When every loop is
  closed, F is the last chapter.
- **Window**: before F's Read step is done, text items for chapters 1…F+1 and podcast + video for 1…F. Once Read is done
  on F, both reach one chapter further (1…F+2 and 1…F+1), so the next chapter's podcast starts while you recall, map,
  and review. Clamped to the chapter count.
- **New book** (no chapters yet, or no progress): text 1–2, media 1: chapter 1 whole, plus chapter 2's quick items.
- **Make everything now**: Settings → Your AI → "Prepare whole books right away" (UserDefaults `prepareEverything`,
  off by default), or this book's Prepare more (meta.json `options.media == "all"`) → every chapter, all media.
- The window becomes `--chapters` and `--media` specs: `"1"`, `"1-3"`, `"all"`, `"none"`.
- **Finished work stays finished.** The pipeline never redoes done items. `BookState.apply_selection` turns `todo`
  items outside the window into `skipped` and brings `skipped` items inside it back to `todo`. NotebookLM sources are
  added only for chapters with items that aren't skipped.
- **Work** (`PrepWindow.hasWork`): an item inside the window that's `todo` or `skipped` (it must come back), or an item
  left `working` anywhere (a stopped run; the next run tidies it). `failed` items wait for Prepare more (`--retry`).
  Items waiting on a limit count only inside the window, and only once the limit has lifted (`AutoResume.hasWork`).

## When runs start (`Library`)

- Adding a book: a run for the new-book window.
- Every automatic look (at launch and every ~5 minutes): a run when the window has work and the back-off allows it
  (`AutoResume.mayStart`: unchanged).
- Finishing a study step (`BookSession.complete` → `Library.studyMoved(in:)`): the shelf is read again and a run starts
  if the window now has work and no run is going for that book.
- A run that ends well after the reader moved on (the window it ran with differs from the one now) and leaves work in
  the new window starts another run right away (`PrepWindow.startAgain`), not after the next look. Failures keep their
  back-off.
- Turning on "Prepare whole books right away" starts runs for books with work.
- Prepare more: every chapter and all media, failed items retried; remembered in meta.json as before.
- The iPad never runs the pipeline; it just shows what sync brings.

## What the screens say

A chapter's items being `skipped` now nearly always means "not yet", never an error and never something the person left out.

- The chapter list: an open chapter whose guide isn't prepared yet says "Pip will prepare it when you get close".
- A locked chapter with items not prepared yet adds: "Pip will prepare it when you get close, so your allowance goes to
  the chapters you're about to study."
- An item card for a skipped item uses `PrepWindow.notYet(what)`: "The podcast: Pip will prepare this when you get close."

## Edge cases

- A run already going when the reader moves on finishes with the window it started with; the next run picks up the
  wider one right away.
- Turning the switch off again narrows the window for later runs; nothing already made is removed.
- Books made before this change may have `todo` items for every chapter: those outside the window are left alone (no
  run just to mark them skipped); the next run marks them.
- Chapters numbered from 1 in reading order (the pipeline's numbering); the window uses chapter numbers.

## Tests

- `apple/Tests/NeuralLoopCoreTests/PrepWindowTests.swift`: new book, reading done, clamping, make everything now, media
  only for media chapters, work only inside the window, auto-resume inside the window, starting again after a run, a
  chapter still ahead, the not-yet words.
- `PipelineRunTests.aRunPreparesOnlyTheChaptersJustAhead`: `--chapters` and `--media` from a window.
- `pipeline/tests/test_pipeline.py::test_chapters_prepared_just_ahead_come_back_when_the_window_widens`: a later run
  with a wider `--chapters` makes the skipped chapter and keeps the finished one.
