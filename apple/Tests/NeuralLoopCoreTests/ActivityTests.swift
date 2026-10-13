import Foundation
import Testing
@testable import NeuralLoopCore

func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Double {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h))!.timeIntervalSince1970 * 1000
}

@Test func quittingMidTickKeepsTheSecondsSinceTheLastTick() {
    // 9 s after the last tick, in front the whole time: those 9 s count.
    #expect(Activity.partialTick(lastTick: 100, activeSince: 50, until: 109) == 9)
    // In front only for the last 4 s of it: only those count.
    #expect(Activity.partialTick(lastTick: 100, activeSince: 105, until: 109) == 4)
    // Not in front at all: nothing.
    #expect(Activity.partialTick(lastTick: 100, activeSince: nil, until: 109) == 0)
    // Never more than one tick, never less than nothing (a clock change).
    #expect(Activity.partialTick(lastTick: 100, activeSince: 0, until: 200) == 15)
    #expect(Activity.partialTick(lastTick: 100, activeSince: 0, until: 90) == 0)
}

@Test func studyTimeIsLoggedPerLocalDay() {
    var p = StudyProgress()
    Activity.log(&p, now: local(2026, 9, 28), seconds: 15)
    Activity.log(&p, now: local(2026, 9, 28) + 60_000, seconds: 15)
    #expect(p.log == ["2026-09-28": 30])
}

@Test func theYearGridCovers53WeeksEndingThisWeekSundayFirst() {
    let grid = Activity.yearGrid(["2026-09-28": 1500, "2026-09-27": 300], today: local(2026, 9, 28))
    #expect(grid.weeks.count == 53 && grid.weeks.allSatisfy { $0.count == 7 })
    let last = grid.weeks.last!
    #expect(last[0].date == "2026-09-27" && last[1].date == "2026-09-28")
    #expect(last[1].level == 3 && last[0].level == 1 && last[2].future)
}

@Test func levelsGrowWithMinutes() {
    #expect([0, 60, 540, 900, 1800, 5400].map { Activity.level(Double($0)) } == [0, 1, 1, 2, 3, 4])
}

@Test func yearStatsAreOnlyEncouraging() {
    let log: [String: Double] = ["2026-09-24": 600, "2026-09-25": 1200, "2026-09-26": 3000, "2026-09-28": 60, "2024-01-01": 9999]
    let s = Activity.yearStats(log, today: local(2026, 9, 28))
    #expect(s.total == 4860 && s.days == 4 && s.longestRun == 3)
    #expect(s.best?.date == "2026-09-26" && s.best?.seconds == 3000)
    #expect(Activity.formatDuration(4860) == "1 h 21 min" && Activity.formatDuration(45) == "1 min" && Activity.formatDuration(0) == "0 min")
}
