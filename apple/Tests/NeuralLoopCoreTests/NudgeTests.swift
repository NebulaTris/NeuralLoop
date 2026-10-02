import Foundation
import Testing
@testable import NeuralLoopCore

private let dayMs = 86_400_000.0
private let nowMs = 10 * dayMs

private func book(_ titles: [Int: String] = [:]) throws -> Book {
    let chapters = titles.map { #"{"n":\#($0.key),"title":"\#($0.value)"}"# }.joined(separator: ",")
    return try JSONDecoder().decode(Book.self, from: Data(#"{"title":"B","chapters":[\#(chapters)]}"#.utf8))
}

private func withDueCards(reps: Int, count: Int) throws -> (book: Book, progress: StudyProgress) {
    var p = StudyProgress()
    for i in 0..<count { p.cards["1:\(i)"] = CardState(s: 1, d: 5, reps: reps, last: 0, due: nowMs - 1) }
    return (try book(), p)
}

private func decide(_ books: [(book: Book, progress: StudyProgress)], _ history: NudgeHistory = NudgeHistory(),
                    hour: Int = 18, settings: NudgeSettings = NudgeSettings()) -> Nudge? {
    Nudges.decide(books: books, settings: settings, history: history, now: nowMs, hour: hour, today: "dayMs-1")
}

@Test func quietHoursWrapPastMidnight() {
    #expect(Nudges.inQuietHours(hour: 23, start: 22, end: 8) && Nudges.inQuietHours(hour: 3, start: 22, end: 8))
    #expect(!Nudges.inQuietHours(hour: 12, start: 22, end: 8) && !Nudges.inQuietHours(hour: 9, start: 9, end: 9))
}

@Test func threeOrMoreDueCardsAreWorthANudge() throws {
    let nudge = decide([try withDueCards(reps: 1, count: 4)])
    #expect(nudge?.title == "🐾 4 cards are ready" && nudge?.body.contains("1 min") == true)
    #expect(decide([try withDueCards(reps: 1, count: 2)]) == nil)
    #expect(decide([try withDueCards(reps: 0, count: 10)]) == nil)  // never-reviewed cards aren't due
}

@Test func atMostOneADayNeverInQuietHoursAndOffMeansOff() throws {
    let books = [try withDueCards(reps: 1, count: 5)]
    var sentToday = NudgeHistory()
    sentToday.lastSentDay = "dayMs-1"
    #expect(decide(books, sentToday) == nil && decide(books, hour: 23) == nil)
    var off = NudgeSettings()
    off.enabled = false
    #expect(decide(books, settings: off) == nil)
    var paused = NudgeSettings()
    paused.pausedUntil = nowMs + 1
    #expect(decide(books, settings: paused) == nil)
}

@Test func backsOffAfterTwoIgnoredNudgesAndGoesWeeklyWhenAway() throws {
    let books = [try withDueCards(reps: 1, count: 5)]
    var history = NudgeHistory()
    history.sent(now: nowMs - 2 * dayMs, day: "a")
    history.sent(now: nowMs - dayMs, day: "b")
    history.sent(now: nowMs - dayMs / 2, day: "c")
    #expect(history.ignoredInARow == 2 && decide(books, history) == nil)
    history.engaged(now: nowMs - 1)
    #expect(history.ignoredInARow == 0)
    var away = NudgeHistory()
    away.lastEngaged = nowMs - 8 * dayMs
    away.lastSent = nowMs - 3 * dayMs
    #expect(decide(books, away) == nil)
}

@Test func aHalfDoneChapterGetsALooseYarnNudge() throws {
    var p = StudyProgress()
    p.loop["2"] = ["prime": nowMs - dayMs, "read": nowMs - dayMs]
    let nudge = decide([(try book([2: "Caching"]), p)])
    #expect(nudge?.title == "🧶 Loose yarn in “Caching”" && nudge?.body == "Next: recall it in your own words. Pip saved your spot.")
    p.loop["2"] = ["prime": nowMs - 1000]
    #expect(decide([(try book([2: "Caching"]), p)]) == nil)  // touched too recently
}

private func away(days: Double) -> NudgeHistory {
    var history = NudgeHistory()
    history.lastEngaged = nowMs - days * dayMs
    return history
}

@Test func theLongerYoureAwayTheSillierPipGets() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    #expect(decide(books, away(days: 1))?.mood == .gentle)
    #expect(decide(books, away(days: 2.5))?.mood == .sadViolin)
    #expect(decide(books, away(days: 5))?.mood == .sadMeow)
    #expect(decide(books, away(days: 8))?.mood == .shocked)
    #expect(decide(books, NudgeHistory())?.mood == .gentle)  // never opened yet: nothing to miss
}

@Test func aSillyNudgeStillSaysWhatsReady() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    let violin = try #require(decide(books, away(days: 3)))
    #expect(violin.title == "🎻 Pip is playing a tiny sad violin")
    #expect(violin.body == "4 cards are ready. About 1 min with Pip, then you're done for today.")
    let shocked = try #require(decide(books, away(days: 9)))
    #expect(shocked.title == "😱 FAHHH! 9 days?!" && shocked.body.hasPrefix("4 cards are ready."))
    #expect(decide(books, away(days: 1))?.title == "🐾 4 cards are ready")
}

@Test func afterAFewDaysAwayPipNudgesEvenWithNothingDue() throws {
    let nothingDue = [(try book([1: "Caching"]), StudyProgress())]
    #expect(decide(nothingDue, away(days: 1)) == nil)
    let nudge = try #require(decide(nothingDue, away(days: 5)))
    #expect(nudge.mood == .sadMeow && nudge.body == "Your books miss you. Even five minutes counts.")
    #expect(decide([], away(days: 5)) == nil)  // no books, nothing to come back to
}

@Test func theDramaCanBeTurnedDownOrOff() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    var noFahhh = NudgeSettings()
    noFahhh.fahhh = false
    #expect(decide(books, away(days: 8), settings: noFahhh)?.mood == .sadMeow)
    var calm = NudgeSettings()
    calm.sillySounds = false
    #expect(decide(books, away(days: 8), settings: calm)?.mood == .gentle)
    #expect(decide(books, away(days: 8), settings: calm)?.title == "🐾 4 cards are ready")
    #expect(decide([(try book([1: "Caching"]), StudyProgress())], away(days: 5), settings: calm) == nil)
}

@Test func settingsSavedBeforeSillySoundsKeepTheirQuietHours() throws {
    let old = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"enabled":true,"quietStart":21,"quietEnd":9,"pausedUntil":0}"#.utf8))
    #expect(old.quietStart == 21 && old.quietEnd == 9 && old.sillySounds && old.fahhh)
}

@Test func everyMoodHasATestNudgeForSettings() {
    for mood in NudgeMood.allCases { #expect(Nudge.sample(mood).mood == mood) }
    #expect(Nudge.sample(.shocked).title == "😱 FAHHH! 7 days?!")
    #expect(Nudge.sample(.gentle).title == "🐾 Hi from Pip")
}
