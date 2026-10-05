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
                    hour: Int = 18, settings: NudgeSettings = NudgeSettings(), appActive: Bool = false) -> Nudge? {
    Nudges.decide(books: books, settings: settings, history: history, now: nowMs, hour: hour, today: "dayMs-1", appActive: appActive)
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
    away.sent(now: nowMs - 3 * dayMs, day: "a")  // a usual nudge three days ago
    var calm = NudgeSettings()
    calm.sillySounds = false
    #expect(decide(books, away, settings: calm) == nil)  // away a week: weekly only
    var ladderDone = NudgeHistory()
    ladderDone.lastEngaged = nowMs - 8 * dayMs
    ladderDone.sent(now: nowMs - 3 * dayMs, day: "a", mood: .shocked, step: SillyStep.defaults[2])  // the silly ladder ran its course
    #expect(decide(books, ladderDone)?.mood == .gentle)  // silly steps don't use up the weekly nudge
}

@Test func sillyStepsDontCountTowardTheUsualBackOff() throws {
    var history = NudgeHistory()
    history.lastEngaged = nowMs - 30 * hourMs
    history.sent(now: nowMs - 30 * hourMs + 1, day: "a")  // one usual nudge, then the whole ladder
    for (i, step) in SillyStep.defaults.enumerated() {
        history.sent(now: nowMs - Double(3 - i) * hourMs, day: "dayMs-1", mood: step.sound, step: step)
    }
    #expect(history.ignoredInARow == 0 && history.lastSentDay == "a" && history.lastSent == nowMs - 30 * hourMs + 1)
    #expect(history.lastSillySent == nowMs - hourMs && history.lastStepId == SillyStep.defaults[2].id)
    #expect(decide([try withDueCards(reps: 1, count: 4)], history)?.mood == .gentle)  // the usual nudge still comes
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

/// Away `hours`, with the default ladder's step `sentStep` (0 = the first) already sent since the last visit.
private func away(hours: Double, sentStep: Int? = nil) -> NudgeHistory {
    away(hours: hours, sent: sentStep.map { SillyStep.defaults[$0] })
}

private func away(hours: Double, sent: SillyStep?) -> NudgeHistory {
    var history = NudgeHistory()
    history.lastEngaged = nowMs - hours * hourMs
    if let sent { history.sent(now: nowMs - 1, day: "earlier", mood: sent.sound, step: sent) }
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
    back.sent(now: nowMs - 15 * hourMs, day: "yesterday", mood: .shocked, step: SillyStep.defaults[2])
    back.engaged(now: nowMs - 9 * hourMs)  // opened the app since: the ladder starts again
    #expect(decide(books, back)?.mood == .sadViolin)
}

@Test func aGentleNudgeInBetweenDoesntRestartTheLadder() throws {
    var history = away(hours: 9, sentStep: 0)
    history.sent(now: nowMs - 1, day: "dayMs-1")  // a usual nudge after the violin
    #expect(history.lastStepId == SillyStep.defaults[0].id)
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
    let (late, early) = (SillyStep(.sadViolin, after: 4), SillyStep(.sadViolin, after: 1))
    let twoViolins = with([late, early])  // any order
    #expect(decide(books, away(hours: 1.5), settings: twoViolins)?.step == early)
    let second = try #require(decide(books, away(hours: 4.5, sent: early), settings: twoViolins))
    #expect(second.mood == .sadViolin && second.step == late)
    #expect(decide(books, away(hours: 30), settings: with([]))?.mood == .gentle)  // no steps: just the usual nudges
}

@Test func theLastStepCanRepeatEveryFewHours() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    let everySix = with(SillyStep.defaults, repeatEvery: 6)
    var fahhhSent = NudgeHistory()
    fahhhSent.lastEngaged = nowMs - 29 * hourMs
    fahhhSent.sent(now: nowMs - 5 * hourMs, day: "dayMs-1", mood: .shocked, step: SillyStep.defaults[2])
    fahhhSent.lastSentDay = "dayMs-1"  // and today's usual nudge went out
    #expect(decide(books, fahhhSent, settings: everySix) == nil)  // only five hours since
    fahhhSent.lastSillySent = nowMs - 6 * hourMs
    #expect(decide(books, fahhhSent, settings: everySix)?.mood == .shocked)
    #expect(decide(books, fahhhSent) == nil)  // no repeat by default
    #expect(decide(books, fahhhSent, hour: 23, settings: everySix) == nil)  // a repeat that falls in quiet hours waits
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

@Test func withNothingDueSillyModeSaysHiAtMostOnceAWeek() throws {
    let nothingDue = [(try book([1: "Caching"]), StudyProgress())]
    #expect(decide(nothingDue, away(hours: 5)) == nil)
    let nudge = try #require(decide(nothingDue, away(hours: 15)))
    #expect(nudge.mood == .sadMeow && nudge.missesYou && nudge.body == "Pip's ready when you are. Even five minutes counts.")
    var saidHi = away(hours: 15)
    saidHi.sent(nudge, now: nowMs - 3 * dayMs, day: "earlier")
    #expect(saidHi.lastMissedYou == nowMs - 3 * dayMs)
    #expect(decide(nothingDue, saidHi) == nil)  // once this week is enough
    saidHi.lastMissedYou = nowMs - 8 * dayMs
    #expect(decide(nothingDue, saidHi)?.missesYou == true)
    #expect(decide([], away(hours: 15)) == nil)  // no books, nothing to come back to
    let withNews = try #require(decide([try withDueCards(reps: 1, count: 4)], saidHi))
    #expect(!withNews.missesYou)
}

@Test func stepsDueAtTheSameTimePlayOneAfterAnother() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    let (violin, meow) = (SillyStep(.sadViolin, after: 6), SillyStep(.sadMeow, after: 6))
    let same = with([violin, meow])
    #expect(decide(books, away(hours: 7), settings: same)?.step == violin)
    #expect(decide(books, away(hours: 7, sent: violin), settings: same)?.step == meow)
    var both = away(hours: 7, sent: violin)
    both.sent(now: nowMs - 1, day: "x", mood: .sadMeow, step: meow)
    #expect(decide(books, both, settings: same)?.mood == .gentle)
}

@Test func editingStepsMidAbsenceKeepsTheLadderWhereItWas() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    var settings = NudgeSettings()
    let history = away(hours: 13, sent: settings.ladder[1])  // the song went out
    #expect(decide(books, history, settings: settings)?.mood == .gentle)
    settings.steps.insert(SillyStep(.shocked, after: 2), at: 0)  // a new early step: the song still counts as sent
    #expect(decide(books, history, settings: settings)?.mood == .gentle)
    settings.steps.removeAll { $0.sound == .sadMeow }  // the sent step removed: what was due when it went out counts as sent
    #expect(decide(books, history, settings: settings)?.mood == .gentle)
}

@Test func theClockGoingBackwardsSendsNothingSilly() throws {
    var history = NudgeHistory()
    history.lastEngaged = nowMs + 30 * hourMs
    #expect(Nudges.sillyStep(settings: NudgeSettings(), history: history, now: nowMs) == nil)
    #expect(decide([try withDueCards(reps: 1, count: 4)], history)?.mood == .gentle)
}

@Test func noSillyNudgeWhileNeuralLoopIsInFront() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    #expect(decide(books, away(hours: 25), appActive: true)?.mood == .gentle)
}

@Test func addingAStepPicksAFreeHour() {
    #expect(SillyStep.freeHours(after: SillyStep.defaults) == 28)
    #expect(SillyStep.freeHours(after: []) == 8)
    #expect(SillyStep.freeHours(after: [SillyStep(.sadViolin, after: 4), SillyStep(.sadMeow, after: 8)]) == 12)
    #expect(SillyStep.freeHours(after: [SillyStep(.shocked, after: 168)]) == 167)
    let top = [SillyStep(.shocked, after: 166), SillyStep(.shocked, after: 167), SillyStep(.shocked, after: 168)]
    #expect(SillyStep.freeHours(after: top) == 165)
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
    let oneBad = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"steps":[5,{"sound":"sadViolin","hours":3}]}"#.utf8))
    #expect(oneBad.steps.map(\.sound) == [.sadViolin] && oneBad.steps[0].hours == 3)  // a removed fahhh stays removed
    let twins = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"steps":[{"sound":"sadViolin","hours":5},{"sound":"sadMeow","hours":5},{"sound":"shocked","hours":168},{"sound":"sadMeow","hours":168}]}"#.utf8))
    #expect(twins.steps.map(\.hours) == [5, 6, 168, 167])
    let broken = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"steps":"nope","quietStart":20}"#.utf8))
    #expect(broken.quietStart == 20 && broken.steps == NudgeSettings().steps)
    let roundTrip = try JSONDecoder().decode(NudgeSettings.self, from: JSONEncoder().encode(with([SillyStep(.shocked, after: 2)], repeatEvery: 3)))
    #expect(roundTrip.steps.map(\.hours) == [2] && roundTrip.repeatHours == 3)
    let history = try JSONDecoder().decode(NudgeHistory.self, from: Data(#"{"lastSent":1,"lastSentDay":"d","lastEngaged":2,"ignoredInARow":0}"#.utf8))
    #expect(history.lastStepId == nil && history.lastSillySent == 0 && history.lastSentDay == "d")
    // Saved while silly steps still shared the usual nudge's history (and the step was a place in the ladder).
    let older = try JSONDecoder().decode(NudgeHistory.self, from: Data(#"{"lastSent":50,"lastSentDay":"d","lastEngaged":2,"ignoredInARow":3,"lastMood":"shocked","lastStep":2}"#.utf8))
    #expect(older.lastSillySent == 50 && older.lastStepId == nil && older.ignoredInARow == 3)
    let weird = try JSONDecoder().decode(NudgeHistory.self, from: Data(#"{"lastSent":"x","lastMood":"loud","lastEngaged":7}"#.utf8))
    #expect(weird.lastEngaged == 7 && weird.lastSent == 0 && weird.lastMood == nil)
    var historyTrip = NudgeHistory()
    historyTrip.sent(now: 9, day: "d", mood: .sadMeow, step: SillyStep.defaults[1])
    #expect(try JSONDecoder().decode(NudgeHistory.self, from: JSONEncoder().encode(historyTrip)) == historyTrip)
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

// MARK: the big on-screen Pip

@Test func theBigPipOnlyShowsWhenNothingElseIsGoingOn() {
    let settings = NudgeSettings()
    let calm = NudgeMoment()
    #expect(NudgeDelivery.showsBigPip(.sadViolin, settings: settings, moment: calm))
    #expect(!NudgeDelivery.showsBigPip(.gentle, settings: settings, moment: calm))  // the usual nudge is a notification
    var noBigPip = settings
    noBigPip.bigPip = false
    #expect(!NudgeDelivery.showsBigPip(.shocked, settings: noBigPip, moment: calm))
    for busy in [NudgeMoment(screenLocked: true), NudgeMoment(fullScreenInFront: true), NudgeMoment(microphoneInUse: true)] {
        #expect(!NudgeDelivery.showsBigPip(.shocked, settings: settings, moment: busy))
    }
}

@Test func aWindowCoveringTheWholeScreenCountsAsFullScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    #expect(NudgeDelivery.fillsScreen([CGRect(x: 0, y: 0, width: 1512, height: 982)], screen: screen))
    let small = CGRect(x: 10, y: 40, width: 600, height: 400)
    #expect(NudgeDelivery.fillsScreen([small, CGRect(x: -1, y: -1, width: 1514, height: 984)], screen: screen))
    #expect(!NudgeDelivery.fillsScreen([CGRect(x: 0, y: 33, width: 1512, height: 949)], screen: screen))  // a big window below the menu bar
    #expect(!NudgeDelivery.fillsScreen([], screen: screen))
    let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    #expect(!NudgeDelivery.fillsScreen([screen], screen: second))  // full screen on the other display
}

@Test func turningNotificationsOffMeansNothingAtAll() throws {
    let books = [try withDueCards(reps: 1, count: 4)]
    var off = NudgeSettings()
    off.enabled = false
    #expect(decide(books, away(hours: 25), settings: off) == nil)  // not even Silly mode
    #expect(!off.allows(.chapterReady) && !off.allows(.nudges) && !off.allows(.silly))
    var noNudges = NudgeSettings()
    noNudges.nudges = false
    #expect(decide(books, away(hours: 5), settings: noNudges) == nil)
    #expect(noNudges.allows(.chapterReady) && !noNudges.allows(.nudges))
    var noChapters = NudgeSettings()
    noChapters.chapterReady = false
    #expect(!noChapters.allows(.chapterReady) && noChapters.allows(.nudges))
}

@Test func aLooseYarnNudgeOnlyPointsAtAChapterThatsFullyPrepared() throws {
    var p = StudyProgress()
    p.loop["1"] = ["prime": nowMs - dayMs, "read": nowMs - dayMs]
    let coming = try JSONDecoder().decode(Book.self, from: Data(#"{"title":"B","chapters":[{"n":1,"title":"Caching","status":{"study":"done","audio":"working","video":"todo"}}]}"#.utf8))
    #expect(decide([(coming, p)]) == nil)
    let ready = try JSONDecoder().decode(Book.self, from: Data(#"{"title":"B","chapters":[{"n":1,"title":"Caching","status":{"study":"done","audio":"done","video":"done"}}]}"#.utf8))
    #expect(decide([(ready, p)])?.title == "🧶 Loose yarn in “Caching”")
}

@Test func settingsSavedBeforeTheSplitKeepTheirMasterSwitch() throws {
    let old = try JSONDecoder().decode(NudgeSettings.self, from: Data(#"{"enabled":false}"#.utf8))
    #expect(!old.enabled && old.chapterReady && old.nudges)
}

@Test func itsQuietDuringQuietHoursAndWhilePaused() {
    var s = NudgeSettings()
    #expect(s.isQuiet(now: nowMs, hour: 23) && s.isQuiet(now: nowMs, hour: 7))
    #expect(!s.isQuiet(now: nowMs, hour: 12))
    s.pausedUntil = nowMs + 1
    #expect(s.isQuiet(now: nowMs, hour: 12))
    #expect(!s.isQuiet(now: nowMs + 1, hour: 12))
}

@Test func aFullScreenWindowOnAnyDisplayCounts() {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    let video = CGRect(x: 1512, y: 0, width: 1920, height: 1080)  // a full-screen video on the other display
    #expect(NudgeDelivery.fillsAnyScreen([video], screens: [laptop, external]))
    #expect(NudgeDelivery.fillsAnyScreen([laptop], screens: [laptop, external]))
    #expect(!NudgeDelivery.fillsAnyScreen([CGRect(x: 1600, y: 40, width: 800, height: 600)], screens: [laptop, external]))
    #expect(!NudgeDelivery.fillsAnyScreen([video], screens: []))
}

@Test func theMacIsOnlyAskedWhatsGoingOnForABigPip() {
    let settings = NudgeSettings()
    #expect(!NudgeDelivery.needsMoment(.gentle, settings: settings))
    #expect(NudgeDelivery.needsMoment(.sadMeow, settings: settings))
    var noBigPip = settings
    noBigPip.bigPip = false
    #expect(!NudgeDelivery.needsMoment(.shocked, settings: noBigPip))
}

@Test func aLooseYarnNudgeStillComesWhenAVideoFailed() throws {
    var p = StudyProgress()
    p.loop["1"] = ["prime": nowMs - dayMs, "read": nowMs - dayMs]
    let failed = try JSONDecoder().decode(Book.self, from: Data(#"{"title":"B","chapters":[{"n":1,"title":"Caching","status":{"study":"done","audio":"done","video":"failed"}}]}"#.utf8))
    #expect(decide([(failed, p)])?.title == "🧶 Loose yarn in “Caching”")
}
