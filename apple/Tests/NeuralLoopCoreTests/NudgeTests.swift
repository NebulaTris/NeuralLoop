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
    away.sent(now: nowMs - 3 * dayMs, day: "a", mood: .shocked, step: 2)  // the silly ladder ran its course
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

private let hourMs = 3_600_000.0

/// Away `hours`, with the ladder's step `sentStep` (0 = the first) already sent since the last visit.
private func away(hours: Double, sentStep: Int? = nil) -> NudgeHistory {
    var history = NudgeHistory()
    history.lastEngaged = nowMs - hours * hourMs
    if let sentStep { history.sent(now: nowMs - 1, day: "earlier", mood: .sadViolin, step: sentStep) }
    return history
}

private func with(_ steps: [SillyStep], repeatEvery: Double = 0) -> NudgeSettings {
    var settings = NudgeSettings()
    (settings.steps, settings.repeatHours) = (steps, repeatEvery)
    return settings
}

@Test func theDefaultLadderIsAViolinASongThenAFahhh() {
    #expect(NudgeSettings().steps.map(\.sound) == [.sadViolin, .sadMeow, .shocked])
    #expect(NudgeSettings().steps.map(\.hours) == [8, 12, 24] && NudgeSettings().repeatHours == 0)
}

@Test func theLongerYoureAwayTheSillierPipGets() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    #expect(decide(books, away(hours: 5))?.mood == .gentle)  // the usual nudge
    #expect(decide(books, away(hours: 9))?.mood == .sadViolin)
    #expect(decide(books, away(hours: 15))?.mood == .sadMeow)
    #expect(decide(books, away(hours: 25))?.mood == .shocked)
    #expect(decide(books, NudgeHistory())?.mood == .gentle)  // never opened yet: nothing to miss
}

@Test func eachStepComesOncePerAbsenceAndOpeningTheAppStartsOver() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    var violinSent = away(hours: 9, sentStep: 0)
    violinSent.lastSentDay = "dayMs-1"
    #expect(decide(books, violinSent) == nil)  // already played, and today's nudge is spent
    #expect(decide(books, away(hours: 13, sentStep: 0))?.mood == .sadMeow)
    #expect(decide(books, away(hours: 25, sentStep: 1))?.mood == .shocked)
    var fahhhSent = away(hours: 30, sentStep: 2)
    fahhhSent.lastSentDay = "dayMs-1"
    #expect(decide(books, fahhhSent) == nil)
    var back = NudgeHistory()
    back.lastEngaged = nowMs - 40 * hourMs
    back.sent(now: nowMs - 15 * hourMs, day: "yesterday", mood: .shocked, step: 2)
    back.engaged(now: nowMs - 9 * hourMs)  // opened the app since: the ladder starts again
    #expect(decide(books, back)?.mood == .sadViolin)
}

@Test func aGentleNudgeInBetweenDoesntRestartTheLadder() throws {
    var history = away(hours: 9, sentStep: 0)
    history.sent(now: nowMs - 1, day: "dayMs-1")  // a usual nudge after the violin
    #expect(history.lastStep == 0)
    #expect(decide([try withDueCards(reps: 1, count: 4)], history) == nil)
}

@Test func sillyNudgesSkipTheOneADayLimitButNeverQuietHours() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    var morningNudge = away(hours: 9)
    morningNudge.lastSentDay = "dayMs-1"
    #expect(decide(books, morningNudge)?.mood == .sadViolin)
    #expect(decide(books, away(hours: 9), hour: 23) == nil)
    #expect(decide(books, away(hours: 13))?.mood == .sadMeow)  // the violin's hour passed quietly: straight to the song
}

@Test func stepsCanBeRetimedReusedRemovedAndKeptInOrder() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    let onlyFahhh = with([SillyStep(.shocked, after: 2)])
    #expect(decide(books, away(hours: 3), settings: onlyFahhh)?.mood == .shocked)
    #expect(decide(books, away(hours: 1), settings: onlyFahhh)?.mood == .gentle)
    let twoViolins = with([SillyStep(.sadViolin, after: 4), SillyStep(.sadViolin, after: 1)])  // any order
    #expect(decide(books, away(hours: 1.5), settings: twoViolins)?.step == 0)
    let second = try #require(decide(books, away(hours: 4.5, sentStep: 0), settings: twoViolins))
    #expect(second.mood == .sadViolin && second.step == 1)
    #expect(decide(books, away(hours: 30), settings: with([]))?.mood == .gentle)  // no steps: just the usual nudges
}

@Test func theLastStepCanRepeatEveryFewHours() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    let everySix = with(SillyStep.defaults, repeatEvery: 6)
    var fahhhSent = NudgeHistory()
    fahhhSent.lastEngaged = nowMs - 29 * hourMs
    fahhhSent.sent(now: nowMs - 5 * hourMs, day: "dayMs-1", mood: .shocked, step: 2)
    #expect(decide(books, fahhhSent, settings: everySix) == nil)  // only five hours since
    fahhhSent.lastSent = nowMs - 6 * hourMs
    #expect(decide(books, fahhhSent, settings: everySix)?.mood == .shocked)
    #expect(decide(books, fahhhSent) == nil)  // no repeat by default
}

@Test func aSillyNudgeStillSaysWhatsReady() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    let violin = try #require(decide(books, away(hours: 9)))
    #expect(violin.title == "🎻 Pip is playing a tiny sad violin")
    #expect(violin.body == "4 cards are ready. About 1 min with Pip, then you're done for today.")
    let shocked = try #require(decide(books, away(hours: 25)))
    #expect(shocked.title == "😱 FAHHH! A whole day?!" && shocked.body.hasPrefix("4 cards are ready."))
    #expect(decide(books, away(hours: 3), settings: with([SillyStep(.shocked, after: 2)]))?.title == "😱 FAHHH! 3 hours?!")
    #expect(decide(books, away(hours: 75), settings: with([SillyStep(.shocked, after: 72)]))?.title == "😱 FAHHH! 3 days?!")
    #expect(decide(books, away(hours: 5))?.title == "🐾 4 cards are ready")
}

@Test func afterHalfADayAwayPipNudgesEvenWithNothingDue() throws {
    let nothingDue = [(try book([1: "Caching"]), StudyProgress())]
    #expect(decide(nothingDue, away(hours: 5)) == nil)
    let nudge = try #require(decide(nothingDue, away(hours: 15)))
    #expect(nudge.mood == .sadMeow && nudge.body == "Your books miss you. Even five minutes counts.")
    #expect(decide([], away(hours: 15)) == nil)  // no books, nothing to come back to
}

@Test func sillyModeCanBeTurnedOff() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    var calm = NudgeSettings()
    calm.sillySounds = false
    #expect(decide(books, away(hours: 25), settings: calm)?.mood == .gentle)
    #expect(decide(books, away(hours: 25), settings: calm)?.title == "🐾 4 cards are ready")
    #expect(decide([(try book([1: "Caching"]), StudyProgress())], away(hours: 15), settings: calm) == nil)
}

@Test func settingsSavedBeforeStepsKeepWhatTheyHad() throws {
    let old = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"enabled":true,"quietStart":21,"quietEnd":9,"pausedUntil":0}"#.utf8))
    #expect(old.quietStart == 21 && old.quietEnd == 9 && old.sillySounds && old.bigPip && old.volume == 0.8)
    #expect(old.steps.map(\.sound) == [.sadViolin, .sadMeow, .shocked])
    let noFahhh = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"fahhh":false}"#.utf8))
    #expect(noFahhh.steps.map(\.sound) == [.sadViolin, .sadMeow])
    let odd = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"steps":[{"sound":"gentle","hours":3},{"sound":"sadMeow","hours":900}],"repeatHours":-4}"#.utf8))
    #expect(odd.steps.map(\.sound) == [.sadMeow] && odd.steps[0].hours == 168 && odd.repeatHours == 0)
    let broken = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"steps":"nope","quietStart":20}"#.utf8))
    #expect(broken.quietStart == 20 && broken.steps == NudgeSettings().steps)
    let roundTrip = try JSONDecoder().decode(NudgeSettings.self, from: JSONEncoder().encode(with([SillyStep(.shocked, after: 2)], repeatEvery: 3)))
    #expect(roundTrip.steps.map(\.hours) == [2] && roundTrip.repeatHours == 3)
    let history = try JSONDecoder().decode(NudgeHistory.self, from: Data(#"{"lastSent":1,"lastSentDay":"d","lastEngaged":2,"ignoredInARow":0}"#.utf8))
    #expect(history.lastStep == nil)
}

@Test func aSillyNudgeSplitsIntoABigEmojiAndItsWords() {
    let violin = Nudge.sample(.sadViolin)
    #expect(violin.emoji == "🎻" && violin.words == "Pip is playing a tiny sad violin")
    #expect(Nudge(title: "No emoji here", body: "").emoji == "" && Nudge(title: "No emoji here", body: "").words == "No emoji here")
}

@Test func everyMoodHasATestNudgeForSettings() {
    for mood in NudgeMood.allCases { #expect(Nudge.sample(mood).mood == mood) }
    #expect(Nudge.sample(.shocked).title == "😱 FAHHH! A whole day?!")
    #expect(Nudge.sample(.gentle).title == "🐾 Hi from Pip")
}
