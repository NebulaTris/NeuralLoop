// "Chapter 2 is ready": said once ever per chapter, only for the chapter you can study next (chapter 1, or the one after
// the last closed loop), and only when everything Pip is making for it is settled (made, not chosen, or failed; nothing
// still coming). A chapter is watched while it's still being made and announced when that finishes, so one that was
// already ready when the app first looked (or one that's still locked) is never announced. During quiet hours or a
// pause it stays watched and is announced when the quiet ends.

import Foundation

public enum ChapterReady {
    /// Nothing for this chapter is still coming: every item is made, wasn't chosen, or failed (a failed item is only
    /// tried again with "Prepare more", so the chapter is studied with what's there). Items to do, being made, or
    /// waiting on a limit are still coming.
    public static func isComplete(_ chapter: Chapter) -> Bool {
        !chapter.status.values.contains { [.todo, .working, .waiting].contains($0) }
    }

    /// The chapter you'd study next: the first open one whose loop isn't closed.
    public static func current(book: Book, progress: StudyProgress) -> Chapter? {
        book.chapters.first { Loop.isUnlocked(progress, book.chapters, $0.n) && !Loop.isClosed(progress, $0.n) }
    }

    /// One look at a book. `watching`: chapters seen still being made while they were current (kept by the app
    /// between looks). `announced`: chapters already announced (never again, even if "Prepare more" makes more for
    /// them). `quiet`: quiet hours or a pause (`NudgeSettings.isQuiet`): a ready chapter keeps waiting until it's over.
    /// Returns the chapter to announce, if any, and what to keep watching.
    public static func step(book: Book, progress: StudyProgress, watching: Set<Int>, announced: Set<Int> = [],
                            quiet: Bool = false) -> (announce: Chapter?, watching: Set<Int>) {
        guard let chapter = current(book: book, progress: progress), !announced.contains(chapter.n) else { return (nil, []) }
        if !isComplete(chapter) { return (nil, [chapter.n]) }
        guard watching.contains(chapter.n) else { return (nil, []) }
        return quiet ? (nil, [chapter.n]) : (chapter, [])
    }

    /// The alert's words: podcast and video are named only when they're really there, and a chapter with something
    /// that couldn't be made says so plainly.
    public static func message(_ chapter: Chapter, book: String) -> (title: String, body: String) {
        let title = "Chapter \(chapter.n) is ready to study"
        let name = "“\(chapter.title)” in \(book)"
        if chapter.status.values.contains(.failed) {
            return (title, "\(name) is ready to study. Pip couldn't make everything for it this time; Prepare more tries again.")
        }
        let media = [("audio", "podcast"), ("video", "video")].filter { chapter.status[$0.0] == .done }.map(\.1)
        let what = media.isEmpty ? "everything Pip is making for it is ready"
            : "everything is ready, \(media.joined(separator: " and ")) included"
        return (title, "\(name): \(what). Pip saved you a spot.")
    }
}
