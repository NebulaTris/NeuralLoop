import Testing
@testable import NeuralLoopCore

let twoChapters = [Chapter(n: 1, cards: [Card(front: "a", back: "b")]), Chapter(n: 2, cards: [Card(front: "c", back: "d")])]

@Test func theLoopMovesThroughFiveStepsAndReportsClosingOnce() {
    var p = StudyProgress()
    #expect(Loop.nextStage(p, 1) == .prime)
    let closings = Stage.allCases.map { Loop.complete(&p, 1, $0, now: 1) }
    #expect(closings == [false, false, false, false, true])
    #expect(Loop.nextStage(p, 1) == nil)
    #expect(Loop.complete(&p, 1, .space, now: 2) == false)
}

@Test func chapterTwoUnlocksOnlyAfterChapterOneIsClosed() {
    var p = StudyProgress()
    #expect(Loop.isUnlocked(p, twoChapters, 1) && !Loop.isUnlocked(p, twoChapters, 2))
    Stage.allCases.forEach { _ = Loop.complete(&p, 1, $0, now: 1) }
    #expect(Loop.isUnlocked(p, twoChapters, 2))
}

@Test func lockedChaptersCardsStayOutOfReview() {
    var p = StudyProgress()
    #expect(Cards.due(twoChapters, p, now: 0).map(\.id) == ["1:0"])
    p.cards["1:0"] = FSRS.grade(nil, .good, now: 0)
    #expect(Cards.due(twoChapters, p, now: 0).isEmpty)
    #expect(Cards.due(twoChapters, p, now: 5 * FSRS.dayMs).map(\.id) == ["1:0"])
}

@Test func aChaptersIdeasJoinTheMapOnceMapped() {
    var p = StudyProgress()
    #expect(!Loop.isMapped(p, 1))
    _ = Loop.complete(&p, 1, .map, now: 3)
    #expect(Loop.isMapped(p, 1))
}
