// Same cases as pipeline/site/test/core.test.mjs, so the Swift and JavaScript schedulers agree.
import Testing
@testable import NeuralLoopCore

let day = FSRS.dayMs

@Test func newCardsFollowFSRSStartingStability() {
    #expect((FSRS.grade(nil, .good, now: 0).due / day).rounded() == 4)
    #expect((FSRS.grade(nil, .easy, now: 0).due / day).rounded() == 14)
}

@Test func againBringsACardBackInTenMinutes() {
    let reviewed = FSRS.grade(FSRS.grade(nil, .good, now: 0), .again, now: 5 * day)
    #expect(reviewed.due - 5 * day == 10 * 60_000)
    #expect(reviewed.reps == 2)
}

@Test func rememberingOnScheduleGrowsTheInterval() {
    let first = FSRS.grade(nil, .good, now: 0)
    let second = FSRS.grade(first, .good, now: first.due)
    #expect(second.due - first.due > first.due)
}

@Test func matchesTheJavaScriptSchedulerExactly() {
    // Values computed with pipeline/site/src/core/fsrs.js for the same reviews.
    let second = FSRS.grade(FSRS.grade(nil, .good, now: 0), .good, now: 4 * day)
    #expect(abs(second.s - 14.808100506496405) < 1e-9)
    #expect(abs(second.d - 5.1236762) < 1e-9)
    #expect(second.due / day == 19)
    let lapse = FSRS.grade(second, .again, now: second.due + 2 * day)
    #expect(abs(lapse.s - 3.208136884166) < 1e-9)
    #expect(abs(lapse.d - 6.8260892378) < 1e-9)
}

@Test func aReviewDatedBeforeTheLastOneCountsAsNoTimeElapsed() {
    // Another device's clock ran ahead, so `last` is later than now: the card must stay sane, not collapse to NaN.
    let first = FSRS.grade(nil, .good, now: 10 * day)
    let early = FSRS.grade(first, .good, now: 9 * day)
    let sameMoment = FSRS.grade(first, .good, now: 10 * day)
    #expect(early.s.isFinite && early.d.isFinite && early.due.isFinite)
    #expect(abs(early.s - sameMoment.s) < 1e-9)
    #expect(early.s >= first.s)
    let lapse = FSRS.grade(first, .again, now: 9 * day)
    #expect(lapse.s.isFinite && lapse.s >= 0.1)
}
