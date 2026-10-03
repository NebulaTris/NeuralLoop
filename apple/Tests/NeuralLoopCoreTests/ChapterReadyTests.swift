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

@Test func failedOrWaitingItemsMeanTheChapterIsntReadyYet() throws {
    let waiting = ["study": "done", "audio": "waiting_quota", "video": "done"]
    let failed = ["study": "done", "audio": "failed", "video": "done"]
    #expect(!ChapterReady.isComplete(try statusBook([waiting]).chapters[0]))
    #expect(!ChapterReady.isComplete(try statusBook([failed]).chapters[0]))
    #expect(ChapterReady.isComplete(try statusBook([noMedia]).chapters[0]))
}

@Test func aFinishedBookHasNothingLeftToAnnounce() throws {
    let step = ChapterReady.step(book: try statusBook([ready, ready]), progress: closed(2), watching: [1, 2])
    #expect(step.announce == nil && step.watching.isEmpty)
}
