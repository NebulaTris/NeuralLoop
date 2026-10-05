import Foundation
import Testing
@testable import NeuralLoopCore

@Test func aPageNeedsAtLeastSixSecondsOrSkimmingSpeed() {
    #expect(ReadingCredit.needed(words: 0) == 6)      // a picture, or a blank page
    #expect(ReadingCredit.needed(words: 30) == 6)
    #expect(ReadingCredit.needed(words: 300) == 30)   // 600 words a minute is fast skimming
    #expect(ReadingCredit.needed(words: 600) == 60)
}

@Test func timeOnlyCountsWhileSomeoneIsThereAndLooking() {
    #expect(ReadingCredit.earning(now: 100, lastInput: 50, appActive: true, windowVisible: true))
    #expect(!ReadingCredit.earning(now: 200, lastInput: 50, appActive: true, windowVisible: true))  // idle 150 s
    #expect(!ReadingCredit.earning(now: 100, lastInput: nil, appActive: true, windowVisible: true))
    #expect(!ReadingCredit.earning(now: 100, lastInput: 99, appActive: false, windowVisible: true))
    #expect(!ReadingCredit.earning(now: 100, lastInput: 99, appActive: true, windowVisible: false))
}

@Test func idleTimeEarnsNothing() {
    var r = ReadingRecord()
    do { let result = ReadingCredit.credit(&r, visible: [0], seconds: 1, pageCount: 3, earning: false); #expect(!result) }
    #expect(r == ReadingRecord())
}

@Test func secondsAreSharedByThePagesOnScreen() {
    var r = ReadingRecord()
    do { let result = ReadingCredit.credit(&r, visible: [0, 1], seconds: 1, pageCount: 3, earning: true); #expect(result) }
    #expect(r.pages == ["0": 0.5, "1": 0.5] && r.count == 3 && r.last == 1)
    // A long pause between ticks (the Mac slept) counts as a couple of seconds at most.
    ReadingCredit.credit(&r, visible: [2], seconds: 600, pageCount: 3, earning: true)
    #expect(r.pages["2"] == 2 && r.last == 2)
    // Pages that don't exist are ignored.
    do { let result = ReadingCredit.credit(&r, visible: [7, -1], seconds: 1, pageCount: 3, earning: true); #expect(!result) }
}

@Test func flippingThroughFasterThanSkimmingDoesNotCount() {
    var r = ReadingRecord()
    let needs = Array(repeating: ReadingCredit.needed(words: 400), count: 10)  // 40 s each
    for page in 0..<10 { for _ in 0..<5 { ReadingCredit.credit(&r, visible: [page], seconds: 1, pageCount: 10, earning: true) } }
    let progress = ReadingCredit.progress(r, needs: needs)
    #expect(progress.counted == 0 && progress.reachedLast && !progress.done)
}

@Test func readingMostPagesAndReachingTheEndIsDone() {
    var r = ReadingRecord()
    let needs = Array(repeating: 6.0, count: 20)
    for page in 0..<17 { for _ in 0..<6 { ReadingCredit.credit(&r, visible: [page], seconds: 1, pageCount: 20, earning: true) } }
    var progress = ReadingCredit.progress(r, needs: needs)
    #expect(progress.counted == 17 && !progress.reachedLast && !progress.done)  // 85%, but not the end yet
    ReadingCredit.credit(&r, visible: [19], seconds: 1, pageCount: 20, earning: true)
    progress = ReadingCredit.progress(r, needs: needs)
    #expect(progress.reachedLast && progress.done && progress.fraction == 0.85)
}

@Test func reachingTheEndWithoutReadingIsNotDone() {
    var r = ReadingRecord()
    for page in 0..<20 { ReadingCredit.credit(&r, visible: [page], seconds: 1, pageCount: 20, earning: true) }
    let progress = ReadingCredit.progress(r, needs: Array(repeating: 6.0, count: 20))
    #expect(progress.reachedLast && progress.counted == 0 && !progress.done)
}

@Test func aChapterWithNoPagesIsNeverDoneByReading() {
    #expect(!ReadingCredit.progress(nil, needs: []).done)
    #expect(ReadingCredit.progress(nil, needs: [6, 6]) == ReadingProgress(counted: 0, total: 2, reachedLast: false))
}

@Test func aPageIsOnScreenWhenEnoughOfItShows() {
    let spans = [ReadingCredit.Span(page: 0, top: 0, bottom: 1000), ReadingCredit.Span(page: 1, top: 1000, bottom: 2000),
                 ReadingCredit.Span(page: 2, top: 2000, bottom: 3000)]
    #expect(ReadingCredit.visible(spans, top: 0, bottom: 800) == [0])
    #expect(ReadingCredit.visible(spans, top: 900, bottom: 1700) == [1])          // a sliver of page 0 doesn't count
    #expect(ReadingCredit.visible(spans, top: 500, bottom: 1500) == [0, 1])
    let tall = [ReadingCredit.Span(page: 0, top: 0, bottom: 5000)]
    #expect(ReadingCredit.visible(tall, top: 2000, bottom: 2800) == [0])          // a page taller than the window
    #expect(ReadingCredit.visible(spans, top: 0, bottom: 0).isEmpty)
}

@Test func textIsSplitIntoSectionsOfAboutThreeHundredWords() {
    let para = Array(repeating: "word", count: 120).joined(separator: " ")
    let blocks = ["# Title", para, para, para, "![a figure](img/01-01.png)", para, para]
    let sections = ReadingCredit.sections(blocks)
    #expect(sections == [[0, 1, 2, 3], [4, 5, 6]])
    #expect(ReadingCredit.words("Hello, *wide* world  —  ok") == 4)
    #expect(ReadingCredit.sections([]) == [])
}

@Test func readingProgressRoundTripsAndSkipsBadEntries() throws {
    let p = try progress(#"{"reading":{"3":{"pages":{"0":12.25,"1":"x","2":7},"count":30,"last":2},"4":"nope"}}"#)
    #expect(p.reading["3"] == ReadingRecord(pages: ["0": 12.25, "2": 7], count: 30, last: 2) && p.reading["4"] == nil)
    let again = try JSONDecoder().decode(StudyProgress.self, from: JSONEncoder().encode(p))
    #expect(again.reading["3"]?.pages["0"] == 12.3 && again.reading["3"]?.count == 30)
}

@Test func readingOnTwoDevicesKeepsTheMostOfEachPage() throws {
    let mac = try progress(#"{"reading":{"1":{"pages":{"0":10,"1":3},"count":5,"last":1}}}"#)
    let ipad = try progress(#"{"reading":{"1":{"pages":{"1":8,"4":6},"count":5,"last":4}}}"#)
    let merged = StudyProgress.merged([mac, ipad])
    #expect(merged.reading["1"] == ReadingRecord(pages: ["0": 10, "1": 8, "4": 6], count: 5, last: 4))
    #expect(StudyProgress.merged([merged, mac]) == merged)
}
