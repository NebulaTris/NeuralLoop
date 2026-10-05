import Foundation
import Testing
@testable import NeuralLoopCore

private func quizChapter(_ n: Int, questions: Int) -> Chapter {
    var chapter = Chapter(n: n)
    chapter.quiz = Array(repeating: QuizQuestion(q: "?", options: ["a", "b"], a: 0, hint: "", why: []), count: questions)
    return chapter
}

@Test func theQuizCountsAsRecallOnceEveryQuestionIsAnswered() {
    var p = StudyProgress()
    let chapter = quizChapter(1, questions: 3)
    #expect(!AutoSteps.quizFinished(p, chapter))
    p.setQuiz("1", QuizProgress(i: 2, results: [true, false]).json, now: 1)
    #expect(!AutoSteps.quizFinished(p, chapter))
    p.setQuiz("1", QuizProgress(i: 3, results: [true, false, true]).json, now: 2)
    #expect(AutoSteps.quizFinished(p, chapter))
    #expect(!AutoSteps.quizFinished(p, Chapter(n: 1)))  // no quiz, nothing to finish
}

@Test func rememberIsDoneWhenEveryCardHasBeenReviewedOnce() {
    var p = StudyProgress()
    let chapter = Chapter(n: 2, cards: [Card(front: "a", back: "b"), Card(front: "c", back: "d")])
    #expect(!AutoSteps.cardsAllSeen(p, chapter))
    p.cards["2:0"] = FSRS.grade(nil, .again, now: 5)
    #expect(!AutoSteps.cardsAllSeen(p, chapter) && AutoSteps.cardsSeen(p, chapter) == 1)
    p.cards["2:1"] = CardState(last: 9)  // a review from another device, counted by its time
    #expect(AutoSteps.cardsAllSeen(p, chapter))
    p.cards["2:1"] = CardState()          // an empty entry isn't a review
    #expect(!AutoSteps.cardsAllSeen(p, chapter))
    #expect(!AutoSteps.cardsAllSeen(p, Chapter(n: 2)))  // no cards, nothing to review
}

@Test func aStepCompletesItselfOnlyInAnOpenChapterAndOnlyOnce() {
    var p = StudyProgress()
    do { let result = Loop.completeIfOpen(&p, twoChapters, 2, .read, now: 1); #expect(result == nil) }  // chapter 2 is locked
    #expect(p.loop["2"] == nil)
    do { let result = Loop.completeIfOpen(&p, twoChapters, 1, .read, now: 5); #expect(result == false) }
    do { let result = Loop.completeIfOpen(&p, twoChapters, 1, .read, now: 9); #expect(result == nil) }  // already done: left as it was
    #expect(p.loop["1"]?["read"] == 5)
    for stage in [Stage.prime, .recall, .map] { _ = Loop.completeIfOpen(&p, twoChapters, 1, stage, now: 10) }
    do { let result = Loop.completeIfOpen(&p, twoChapters, 1, .space, now: 11); #expect(result == true) }  // this one closed the loop
    do { let result = Loop.completeIfOpen(&p, twoChapters, 9, .read, now: 12); #expect(result == nil) }    // no such chapter
}

@Test func aCheckedRecallAnswerCountsOnlyWhenItsARealTry() {
    #expect(!AutoSteps.isRealAnswer(""))
    #expect(!AutoSteps.isRealAnswer("idk"))
    #expect(!AutoSteps.isRealAnswer("a s d f"))
    #expect(AutoSteps.isRealAnswer("Caches keep recent data close to the processor."))
}

@Test func playingAndReadingNeverTouchUpdatedAt() {
    var p = StudyProgress()
    p.updatedAt = 7
    p.recordPlay(1, .audio, from: 0, to: 1, rate: 1, wallSeconds: 1)
    p.creditReading(1, visible: [0], seconds: 1, pageCount: 2, earning: true)
    #expect(p.updatedAt == 7 && p.watch["1"]?.audio.spans == [[0, 1]] && p.reading["1"]?.pages == ["0": 1])
}
