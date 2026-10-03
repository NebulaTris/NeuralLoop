// "Chapter 2 is ready": said once, only for the chapter you can study next (chapter 1, or the one after the last
// closed loop), and only when its whole loop is ready, podcast and video included. A chapter is watched while it's
// still being made and announced when that finishes, so one that was already ready when the app first looked (or one
// that's still locked) is never announced.

import Foundation

public enum ChapterReady {
    /// Every item is made, or wasn't chosen for this chapter. Failed or waiting items still count as coming.
    public static func isComplete(_ chapter: Chapter) -> Bool {
        !chapter.status.values.contains { [.todo, .working, .failed, .waiting].contains($0) }
    }

    /// The chapter you'd study next: the first open one whose loop isn't closed.
    public static func current(book: Book, progress: StudyProgress) -> Chapter? {
        book.chapters.first { Loop.isUnlocked(progress, book.chapters, $0.n) && !Loop.isClosed(progress, $0.n) }
    }

    /// One look at a book. `watching`: chapters seen still being made while they were current (kept by the app
    /// between looks). Returns the chapter to announce, if any, and what to keep watching.
    public static func step(book: Book, progress: StudyProgress, watching: Set<Int>) -> (announce: Chapter?, watching: Set<Int>) {
        guard let chapter = current(book: book, progress: progress) else { return (nil, []) }
        if !isComplete(chapter) { return (nil, [chapter.n]) }
        return (watching.contains(chapter.n) ? chapter : nil, [])
    }
}
