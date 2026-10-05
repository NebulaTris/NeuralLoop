// "Just ahead" (spec 08): which chapters Pip prepares now, a little ahead of the reader, so NotebookLM's allowance and
// the Mac's time go to chapters the person is about to study. Finished work always stays; the pipeline only makes
// what's inside the window (`--chapters`, `--media`) and brings skipped items back when the window reaches them.

import Foundation

public struct PrepWindow: Equatable, Sendable {
    /// Text items (reading guide, maps, quiz, cards) for chapters up to this number; nil = every chapter.
    public var textThrough: Int?
    /// Podcast and video for chapters up to this number; nil = every chapter.
    public var mediaThrough: Int?

    public init(textThrough: Int?, mediaThrough: Int?) { (self.textThrough, self.mediaThrough) = (textThrough, mediaThrough) }

    /// "Make everything now": every chapter, podcasts and videos included.
    public static let everything = PrepWindow(textThrough: nil, mediaThrough: nil)

    static let mediaItems: Set<String> = ["audio", "video"]

    /// Settings → Your AI → "Prepare whole books right away", or this book's "Prepare more" (meta.json
    /// `options.media == "all"`).
    public static func wantsEverything(setting: Bool, media: String) -> Bool { setting || media == "all" }

    /// The window for where the reader is. F is the first chapter that's open and not closed (the last chapter when
    /// every loop is closed). Text goes one chapter past F, media up to F; once F's Read step is done, both reach one
    /// chapter further. A new book (no chapters yet, or no progress) gets chapter 1 whole and chapter 2's quick items.
    public static func make(book: Book?, progress: StudyProgress, everything: Bool) -> PrepWindow {
        if everything { return .everything }
        guard let book, let last = book.chapters.last else { return PrepWindow(textThrough: 2, mediaThrough: 1) }
        let chapters = book.chapters
        let frontier = ChapterReady.current(book: book, progress: progress) ?? last
        let index = chapters.firstIndex { $0.n == frontier.n } ?? 0
        let read = progress.loop[String(frontier.n)]?["read"] != nil
        let through = { (ahead: Int) in chapters[min(index + ahead, chapters.count - 1)].n }
        return PrepWindow(textThrough: through(read ? 2 : 1), mediaThrough: through(read ? 1 : 0))
    }

    /// For `--chapters`.
    public var chaptersSpec: String { Self.spec(textThrough) }
    /// For `--media`.
    public var mediaSpec: String { Self.spec(mediaThrough) }

    static func spec(_ through: Int?) -> String {
        guard let through else { return "all" }
        return through < 1 ? "none" : through == 1 ? "1" : "1-\(through)"
    }

    /// Whether this run should make `item` for chapter `n` (media items only for media chapters).
    public func includes(chapter n: Int, item: String) -> Bool {
        if let textThrough, n > textThrough { return false }
        if Self.mediaItems.contains(item), let mediaThrough, n > mediaThrough { return false }
        return true
    }

    /// Work a run would do right now: an item to make inside the window, or one skipped inside it (it comes back), or
    /// an item a stopped run left being made (wherever it is; the next run tidies it). Failed items wait for Prepare
    /// more; items waiting on a limit are `AutoResume`'s to judge.
    public func hasWork(_ book: Book) -> Bool {
        book.chapters.contains { chapter in
            chapter.status.contains { item, status in
                status == .working || ([.todo, .skipped].contains(status) && includes(chapter: chapter.n, item: item))
            }
        }
    }

    /// When a run ends well while the reader moved on (the window is wider than the one it ran with) and there's
    /// work in the new window, start another right away instead of waiting for the next look in a few minutes.
    public static func startAgain(ranWith: PrepWindow, now: PrepWindow, code: Int32, hasWork: Bool) -> Bool {
        code == 0 && hasWork && ranWith != now
    }

    /// What to say about an item that isn't made yet because its chapter is still ahead (status `skipped`): not an
    /// error, and not something the person left out.
    public static func notYet(_ what: String) -> String { "\(what): Pip will prepare this when you get close." }
}
