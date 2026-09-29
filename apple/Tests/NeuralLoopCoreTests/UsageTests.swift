import Foundation
import Testing
@testable import NeuralLoopCore

let usageLine = #"NotebookLM usage: {"known": true, "available": true, "fiveHour": {"remaining": 55.9, "resetsAt": "2026-09-29T10:21:40.110085+00:00"}, "weekly": {"remaining": 90.2, "resetsAt": "2026-10-04T13:21:40.110172+00:00"}, "podcast": false, "video": true}"#

@Test func readsNotebookLMUsage() throws {
    let usage = try #require(NotebookLMUsage.parse(usageLine))
    #expect(usage.known && usage.available && !usage.podcast && usage.video)
    #expect(usage.fiveHour?.remaining == 55.9 && usage.weekly?.remaining == 90.2)
    let reset = try #require(usage.fiveHour?.resetDate)
    #expect(Int(reset.timeIntervalSince1970) == 1790677300)  // date -u -j -f … "2026-09-29T10:21:40" +%s
    #expect(NotebookLMUsage.parse("NotebookLM usage: {\"known\": false}")?.known == false)
    #expect(NotebookLMUsage.parse("nothing") == nil)
}

@Test func knowsWhenAWaitingItemCanBeTriedAgain() throws {
    let usage = try #require(NotebookLMUsage.parse(usageLine))
    #expect(usage.canMake("video") && !usage.canMake("audio") && usage.canMake("quiz"))
}
