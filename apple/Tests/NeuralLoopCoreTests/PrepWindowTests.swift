import Foundation
import Testing
@testable import NeuralLoopCore

/// A book with `count` chapters whose items all have `status` unless `overrides` says otherwise ("n:item": status).
private func book(_ count: Int, _ status: String = "done", _ overrides: [String: String] = [:]) throws -> Book {
    let items = ["study", "graph", "quiz", "cards", "mindmap", "audio", "video"]
    let list = (1...count).map { n in
        let s = items.map { #""\#($0)":"\#(overrides["\(n):\($0)"] ?? status)""# }.joined(separator: ",")
        return #"{"n":\#(n),"title":"Chapter \#(n)","status":{\#(s)}}"#
    }.joined(separator: ",")
    return try JSONDecoder().decode(Book.self, from: Data(#"{"title":"B","chapters":[\#(list)]}"#.utf8))
}

private let allSteps: [String: Double] = ["prime": 1, "read": 1, "recall": 1, "map": 1, "space": 1]

/// Progress with chapters 1…closed closed, and `read` set on the chapter after them when asked.
private func progress(closed: Int = 0, readNext: Bool = false) -> StudyProgress {
    var p = StudyProgress()
    if closed > 0 { for n in 1...closed { p.loop[String(n)] = allSteps } }
    if readNext { p.loop[String(closed + 1)] = ["prime": 1, "read": 1] }
    return p
}

@Test func aNewBookGetsChapterOneWholeAndChapterTwosQuickItems() throws {
    let window = PrepWindow.make(book: try book(10, "todo"), progress: StudyProgress(), everything: false)
    #expect(window.chaptersSpec == "1-2" && window.mediaSpec == "1")
    // Before the book is even split there are no chapters yet: the same start.
    let unsplit = PrepWindow.make(book: nil, progress: StudyProgress(), everything: false)
    #expect(unsplit.chaptersSpec == "1-2" && unsplit.mediaSpec == "1")
}

@Test func finishingReadingWidensTheWindowByOneChapter() throws {
    let b = try book(10)
    let reading = PrepWindow.make(book: b, progress: progress(closed: 2), everything: false)
    #expect(reading.chaptersSpec == "1-4" && reading.mediaSpec == "1-3")
    let read = PrepWindow.make(book: b, progress: progress(closed: 2, readNext: true), everything: false)
    #expect(read.chaptersSpec == "1-5" && read.mediaSpec == "1-4")
}

@Test func theWindowStopsAtTheLastChapter() throws {
    let b = try book(3)
    #expect(PrepWindow.make(book: b, progress: progress(closed: 2, readNext: true), everything: false).chaptersSpec == "1-3")
    let done = PrepWindow.make(book: b, progress: progress(closed: 3), everything: false)
    #expect(done.chaptersSpec == "1-3" && done.mediaSpec == "1-3")
    let one = PrepWindow.make(book: try book(1), progress: StudyProgress(), everything: false)
    #expect(one.chaptersSpec == "1" && one.mediaSpec == "1")
}

@Test func makeEverythingNowMeansEveryChapterAndAllMedia() throws {
    let window = PrepWindow.make(book: try book(10), progress: StudyProgress(), everything: true)
    #expect(window == .everything && window.chaptersSpec == "all" && window.mediaSpec == "all")
    #expect(PrepWindow.wantsEverything(setting: true, media: "1-2"))
    #expect(PrepWindow.wantsEverything(setting: false, media: "all"))  // Prepare more
    #expect(!PrepWindow.wantsEverything(setting: false, media: "1-2"))
}

@Test func mediaItemsCountOnlyForMediaChapters() throws {
    let window = PrepWindow.make(book: try book(10), progress: StudyProgress(), everything: false)  // text 1-2, media 1
    #expect(window.includes(chapter: 1, item: "video") && window.includes(chapter: 2, item: "quiz"))
    #expect(!window.includes(chapter: 2, item: "audio") && !window.includes(chapter: 3, item: "study"))
    #expect(PrepWindow.everything.includes(chapter: 99, item: "video"))
}

@Test func thereIsWorkOnlyInsideTheWindow() throws {
    let start = PrepWindow.make(book: nil, progress: StudyProgress(), everything: false)  // text 1-2, media 1
    // Chapter 3 still to do, chapter 2's podcast not chosen yet: nothing to do now.
    #expect(!start.hasWork(try book(4, "done", ["3:quiz": "todo", "2:audio": "skipped", "4:study": "skipped"])))
    // Chapter 2's quiz still to do.
    #expect(start.hasWork(try book(4, "done", ["2:quiz": "todo"])))
    // Skipped inside the window must be brought back.
    #expect(start.hasWork(try book(4, "done", ["2:study": "skipped"])))
    #expect(start.hasWork(try book(4, "done", ["1:video": "skipped"])))
    // Failed items wait for Prepare more.
    #expect(!start.hasWork(try book(4, "done", ["1:video": "failed"])))
    // An item left being made by a run that stopped is tidied up wherever it is.
    #expect(start.hasWork(try book(4, "done", ["4:video": "working"])))
}

@Test func autoResumeOnlyLooksInsideTheWindow() throws {
    let start = PrepWindow.make(book: nil, progress: StudyProgress(), everything: false)
    let later = try book(4, "done", ["3:quiz": "todo"])
    #expect(!AutoResume.hasWork(later, window: start, usage: nil, logModified: 0, now: 0))
    #expect(AutoResume.hasWork(later, usage: nil, logModified: 0, now: 0))  // the whole book by default
    // Waiting on a limit outside the window is no reason to start, even once the limit has lifted.
    let waitingLater = try book(4, "done", ["3:audio": "waiting_quota"])
    #expect(!AutoResume.hasWork(waitingLater, window: start, usage: nil, logModified: 0, now: 1e12))
    let waitingNow = try book(4, "done", ["1:audio": "waiting_quota"])
    #expect(AutoResume.hasWork(waitingNow, window: start, usage: nil, logModified: 0, now: 1e12))
}

@Test func aRunThatEndsWithTheWindowMovedStartsAgainRightAway() {
    let narrow = PrepWindow(textThrough: 2, mediaThrough: 1)
    let wider = PrepWindow(textThrough: 3, mediaThrough: 2)
    #expect(PrepWindow.startAgain(ranWith: narrow, now: wider, code: 0, hasWork: true))
    #expect(!PrepWindow.startAgain(ranWith: wider, now: wider, code: 0, hasWork: true))  // the 5-minute look does it
    #expect(!PrepWindow.startAgain(ranWith: narrow, now: wider, code: 0, hasWork: false))
    #expect(!PrepWindow.startAgain(ranWith: narrow, now: wider, code: 1, hasWork: true))  // failures keep their back-off
}

@Test func aChapterStillAheadIsOneWithItemsNotPreparedYet() throws {
    let b = try book(3, "done", ["2:audio": "skipped", "3:study": "skipped"])
    #expect(!PrepWindow.isAhead(b.chapters[0]))
    #expect(PrepWindow.isAhead(b.chapters[1]) && PrepWindow.isAhead(b.chapters[2]))
}

@Test func notYetIsNeitherAnErrorNorNotChosen() {
    let words = PrepWindow.notYet("The podcast")
    #expect(words == "The podcast: Pip will prepare this when you get close.")
    #expect(!words.contains("chosen") && !words.contains("couldn't"))
}
