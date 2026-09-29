import Foundation
import Testing
@testable import NeuralLoopCore

private func chapters(ready: Int, of total: Int) -> [Chapter] {
    (1...total).map { n in
        var chapter = Chapter(n: n)
        if n <= ready { chapter.status["study"] = .done }
        return chapter
    }
}

@Test func eachChapterShowsWhereItIs() {
    var p = StudyProgress()
    for stage in Stage.allCases { _ = Loop.complete(&p, 1, stage, now: 1) }
    let dots = Shelf.dots(chapters(ready: 3, of: 4), p)
    #expect(dots == [.closed, .open, .ready, .preparing])
}

@Test func studyTimeAddsUpAcrossBooks() {
    let log = Shelf.combinedLog([["2026-09-28": 600, "2026-09-27": 60], ["2026-09-28": 300]])
    #expect(log == ["2026-09-28": 900, "2026-09-27": 60])
}

@Test func aBookKeepsItsCoverColourEveryLaunch() {
    #expect(Shelf.coverIndex("MCP illustrated guidebook", count: 5) == Shelf.coverIndex("MCP illustrated guidebook", count: 5))
    #expect(Set(["A", "B", "C", "D", "E", "F"].map { Shelf.coverIndex($0, count: 5) }).count > 1)
    #expect((0..<5).contains(Shelf.coverIndex("", count: 5)))
}
