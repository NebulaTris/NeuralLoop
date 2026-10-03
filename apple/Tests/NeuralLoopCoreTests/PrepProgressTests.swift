import Foundation
import Testing
@testable import NeuralLoopCore

private let minute = 60_000.0

private func feed(_ json: String) throws -> PrepActivity {
    try #require(PrepActivity.read(Data(json.utf8)))
}

private let sample = #"""
{"updated": 1000000, "ended": false, "pid": 7,
 "items": [
   {"n": 1, "item": "audio", "by": "NotebookLM", "step": "NotebookLM is recording the podcast", "started": 1000000, "updated": 1000000, "done": null, "total": null, "expected": 480},
   {"n": 1, "item": "quiz", "by": "Ollama", "step": "Voicing the podcast", "started": 1000000, "updated": 1000000, "done": 12, "total": 40, "expected": null}
 ],
 "queue": [{"n": 1, "item": "video"}, {"n": 2, "item": "audio"}, {"n": 2, "item": "video"}]}
"""#

@Test func theFeedSaysWhatsBeingMadeAndWhatsInLine() throws {
    let a = try feed(sample)
    #expect(a.item(1, "audio")?.by == "NotebookLM" && a.item(2, "audio") == nil)
    #expect(a.place(1, "video") == 0 && a.place(2, "video") == 2 && a.place(1, "audio") == nil)
    #expect(PrepProgress.placeText(0) == "Next up" && PrepProgress.placeText(1) == "2nd in line" && PrepProgress.placeText(2) == "3rd in line")
    #expect(PrepActivity.read(Data("nope".utf8)) == nil)
    let odd = try feed(#"{"items": [{"n": "x"}, {"n": 2, "item": "audio", "by": "NotebookLM", "started": 5}], "queue": "no"}"#)
    #expect(odd.items.count == 1 && odd.queue.isEmpty && !odd.ended)  // a bad entry is skipped, not fatal
}

@Test func countedWorkShowsHowFarAlongAndHowLongIsLeft() throws {
    let item = try #require(try feed(sample).item(1, "quiz"))
    let p = PrepProgress.of(item, now: 1_000_000 + 4 * minute)  // 12 lines in 4 minutes: 20 s a line
    #expect(abs((p.fraction ?? 0) - 0.3) < 0.001)
    #expect(p.detail == "12 of 40 · about 9 min left" && !p.slow)  // 28 lines at 20 s
}

@Test func notebookLMWorkIsTimedAgainstHowLongItUsuallyTakes() throws {
    let item = try #require(try feed(sample).item(1, "audio"))
    let early = PrepProgress.of(item, now: 1_000_000 + 2 * minute)
    #expect((early.fraction ?? 0) > 0.15 && (early.fraction ?? 1) < 0.35)  // a quarter of the usual time
    #expect(early.detail == "About 6 min left")
    let nearly = PrepProgress.of(item, now: 1_000_000 + 7.6 * minute)
    #expect(nearly.detail == "Almost there" && (nearly.fraction ?? 1) < 0.95)
    let slow = PrepProgress.of(item, now: 1_000_000 + 15 * minute)
    #expect(slow.slow && (slow.fraction ?? 1) < 0.99 && (slow.fraction ?? 0) > (nearly.fraction ?? 1))
    #expect(slow.detail.contains("longer than usual"))
}

@Test func withNoCountAndNoEstimateTheBarJustMovesAndSaysWhenItStarted() throws {
    let a = try feed(#"{"items": [{"n": 1, "item": "video", "by": "Ollama", "step": "Writing the explainer", "started": 0, "updated": 0}]}"#)
    let p = PrepProgress.of(try #require(a.item(1, "video")), now: 3 * minute)
    #expect(p.fraction == nil && p.detail == "Started 3 min ago" && p.step == "Writing the explainer")
}

@Test func aFeedFromAFinishedRunIsntLive() throws {
    #expect(try feed(#"{"ended": true, "items": [], "queue": []}"#).isLive == false)
    #expect(try feed(sample).isLive)
}
