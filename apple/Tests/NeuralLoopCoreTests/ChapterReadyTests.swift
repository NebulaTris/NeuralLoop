import Foundation
import Testing
@testable import NeuralLoopCore

/// A book whose chapters have the given statuses for every item (e.g. ["done", "working"]).
private func statusBook(_ chapters: [[String: String]]) throws -> Book {
    let list = chapters.enumerated().map { i, status in
        let s = status.map { #""\#($0.key)":"\#($0.value)""# }.joined(separator: ",")
        return #"{"n":\#(i + 1),"title":"Chapter \#(i + 1)","status":{\#(s)}}"#
    }.joined(separator: ",")
    return try JSONDecoder().decode(Book.self, from: Data(#"{"title":"B","chapters":[\#(list)]}"#.utf8))
}

private let ready = ["study": "done", "quiz": "done", "audio": "done", "video": "done"]
private let noMedia = ["study": "done", "quiz": "done", "audio": "skipped", "video": "skipped"]
private let podcastComing = ["study": "done", "quiz": "done", "audio": "working", "video": "todo"]

private func closed(_ n: Int) -> StudyProgress {
    var p = StudyProgress()
    for k in 1...n { p.loop[String(k)] = ["prime": 1, "read": 1, "recall": 1, "map": 1, "space": 1] }
    return p
}

@Test func theChapterYouCanStudyIsAnnouncedOnceItsWholeLoopIsReady() throws {
    // Seen while its podcast was still coming: watched, nothing said yet.
    var step = ChapterReady.step(book: try statusBook([podcastComing, ready]), progress: StudyProgress(), watching: [])
    #expect(step.announce == nil && step.watching == [1])
    // Now everything is there, podcast and video included: say it, once.
    step = ChapterReady.step(book: try statusBook([ready, ready]), progress: StudyProgress(), watching: step.watching)
    #expect(step.announce?.n == 1 && step.watching.isEmpty)
    step = ChapterReady.step(book: try statusBook([ready, ready]), progress: StudyProgress(), watching: step.watching)
    #expect(step.announce == nil)
}

@Test func lockedChaptersAreNeverAnnouncedEvenWhenTheyreReady() throws {
    // Chapter 1 isn't closed, so chapter 2 being ready says nothing.
    var step = ChapterReady.step(book: try statusBook([podcastComing, podcastComing]), progress: StudyProgress(), watching: [])
    step = ChapterReady.step(book: try statusBook([podcastComing, ready]), progress: StudyProgress(), watching: step.watching)
    #expect(step.announce == nil && step.watching == [1])
}

@Test func aChapterAlreadyReadyWhenFirstSeenIsntAnnounced() throws {
    let step = ChapterReady.step(book: try statusBook([ready, podcastComing]), progress: StudyProgress(), watching: [])
    #expect(step.announce == nil && step.watching.isEmpty)
}

@Test func afterYouCloseALoopTheNextChapterIsWatchedAndAnnouncedWhenReady() throws {
    var step = ChapterReady.step(book: try statusBook([ready, podcastComing]), progress: closed(1), watching: [])
    #expect(step.announce == nil && step.watching == [2])
    step = ChapterReady.step(book: try statusBook([ready, noMedia]), progress: closed(1), watching: step.watching)
    #expect(step.announce?.n == 2)  // items not chosen for this chapter don't hold it back
}

@Test func waitingItemsMeanTheChapterIsntReadyYetButFailedOnesDontHoldItBack() throws {
    // Changed on purpose: a failed item is only tried again with "Prepare more", so it no longer counts as coming.
    // Waiting for NotebookLM's limit still does (it's retried on every run).
    let waiting = ["study": "done", "audio": "waiting_quota", "video": "done"]
    let failed = ["study": "done", "audio": "failed", "video": "done"]
    #expect(!ChapterReady.isComplete(try statusBook([waiting]).chapters[0]))
    #expect(!ChapterReady.isComplete(try statusBook([podcastComing]).chapters[0]))
    #expect(ChapterReady.isComplete(try statusBook([failed]).chapters[0]))
    #expect(ChapterReady.isComplete(try statusBook([noMedia]).chapters[0]))
}

@Test func aChapterWhoseVideoFailedIsStillAnnounced() throws {
    let videoFailed = ["study": "done", "quiz": "done", "audio": "done", "video": "failed"]
    var step = ChapterReady.step(book: try statusBook([podcastComing]), progress: StudyProgress(), watching: [])
    step = ChapterReady.step(book: try statusBook([videoFailed]), progress: StudyProgress(), watching: step.watching)
    #expect(step.announce?.n == 1)
}

@Test func duringQuietHoursOrAPauseTheChapterWaitsAndIsAnnouncedAfter() throws {
    var step = ChapterReady.step(book: try statusBook([podcastComing]), progress: StudyProgress(), watching: [])
    // Ready while it's quiet: nothing said, still watched.
    step = ChapterReady.step(book: try statusBook([ready]), progress: StudyProgress(), watching: step.watching, quiet: true)
    #expect(step.announce == nil && step.watching == [1])
    step = ChapterReady.step(book: try statusBook([ready]), progress: StudyProgress(), watching: step.watching, quiet: true)
    #expect(step.announce == nil && step.watching == [1])
    // Quiet is over: said once.
    step = ChapterReady.step(book: try statusBook([ready]), progress: StudyProgress(), watching: step.watching, quiet: false)
    #expect(step.announce?.n == 1 && step.watching.isEmpty)
}

@Test func aChapterIsAnnouncedAtMostOnceEvenWhenPrepareMoreMakesMoreForIt() throws {
    // "Prepare more" turns chapter 1's skipped podcast and video back into to-dos; it was announced already.
    var step = ChapterReady.step(book: try statusBook([podcastComing]), progress: StudyProgress(), watching: [], announced: [1])
    #expect(step.announce == nil && step.watching.isEmpty)
    step = ChapterReady.step(book: try statusBook([ready]), progress: StudyProgress(), watching: [1], announced: [1])
    #expect(step.announce == nil && step.watching.isEmpty)
}

@Test func theAlertSaysWhatsReadyHonestly() throws {
    let both = ChapterReady.message(try statusBook([ready]).chapters[0], book: "Caching")
    #expect(both.title == "Chapter 1 is ready to study")
    #expect(both.body == "“Chapter 1” in Caching: everything is ready, podcast and video included. Pip saved you a spot.")
    #expect(ChapterReady.message(try statusBook([noMedia]).chapters[0], book: "Caching").body
        == "“Chapter 1” in Caching: everything Pip is making for it is ready. Pip saved you a spot.")
    let podcastOnly = try statusBook([["study": "done", "audio": "done", "video": "skipped"]]).chapters[0]
    #expect(ChapterReady.message(podcastOnly, book: "Caching").body
        == "“Chapter 1” in Caching: everything is ready, podcast included. Pip saved you a spot.")
    let videoFailed = try statusBook([["study": "done", "audio": "done", "video": "failed"]]).chapters[0]
    #expect(ChapterReady.message(videoFailed, book: "Caching").body
        == "“Chapter 1” in Caching is ready to study. Pip couldn't make everything for it this time; Prepare more tries again.")
}

@Test func aFinishedBookHasNothingLeftToAnnounce() throws {
    let step = ChapterReady.step(book: try statusBook([ready, ready]), progress: closed(2), watching: [1, 2])
    #expect(step.announce == nil && step.watching.isEmpty)
}
