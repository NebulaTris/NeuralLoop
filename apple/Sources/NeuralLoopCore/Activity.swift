// The daily study log: seconds per local day, a year-long calendar grid, and encouraging totals
// (first written for the study site).

import Foundation

public struct DayCell: Equatable, Sendable {
    public let date: String
    public let seconds: Double
    public let level: Int
    public let future: Bool
}

public struct YearStats: Equatable, Sendable {
    public let total: Double
    public let days: Int
    public let longestRun: Int
    public let best: (date: String, seconds: Double)?

    public static func == (a: YearStats, b: YearStats) -> Bool {
        a.total == b.total && a.days == b.days && a.longestRun == b.longestRun && a.best?.date == b.best?.date
    }
}

public enum Activity {
    static let levelStarts: [Double] = [0, 10 * 60, 20 * 60, 45 * 60]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    public static func dayKey(_ ms: Double, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// The study time since the last 15-second tick, when the app quits before the next one: only the part spent in
    /// front (from `activeSince`, nil when it never was, `until` now or when it left the front), and never more than a
    /// tick. All in seconds.
    public static func partialTick(lastTick: Double, activeSince: Double?, until: Double, every: Double = 15) -> Double {
        guard let activeSince else { return 0 }
        return min(every, max(0, until - max(lastTick, activeSince)))
    }

    public static func log(_ p: inout StudyProgress, now: Double, seconds: Double) {
        p.log[dayKey(now), default: 0] += seconds
        p.updatedAt = max(p.updatedAt, now)
    }

    public static func level(_ seconds: Double) -> Int {
        seconds <= 0 ? 0 : levelStarts.filter { seconds >= $0 }.count
    }

    /// 53 weeks of 7 days (Sunday first), ending with this week, plus month labels by week index.
    public static func yearGrid(_ log: [String: Double], today: Double, calendar: Calendar = .current)
        -> (weeks: [[DayCell]], months: [(week: Int, label: String)])
    {
        let end = calendar.startOfDay(for: Date(timeIntervalSince1970: today / 1000))
        let weekday = calendar.component(.weekday, from: end) - 1  // Sunday = 0
        let start = calendar.date(byAdding: .day, value: -(52 * 7 + weekday), to: end)!
        var weeks: [[DayCell]] = []
        var labels: [(Int, String)] = []
        for w in 0..<53 {
            let week = (0..<7).map { d -> DayCell in
                let date = calendar.date(byAdding: .day, value: w * 7 + d, to: start)!
                let key = dayKey(date.timeIntervalSince1970 * 1000, calendar: calendar)
                let seconds = log[key] ?? 0
                return DayCell(date: key, seconds: seconds, level: level(seconds), future: date > end)
            }
            let first = calendar.date(byAdding: .day, value: w * 7, to: start)!
            let month = calendar.component(.month, from: first)
            if w == 0 || calendar.component(.month, from: calendar.date(byAdding: .day, value: -7, to: first)!) != month {
                labels.append((w, months[month - 1]))
            }
            weeks.append(week)
        }
        return (weeks, labels)
    }

    /// Totals for the last 365 days. Only positive framing: no "streak lost".
    public static func yearStats(_ log: [String: Double], today: Double, calendar: Calendar = .current) -> YearStats {
        let end = calendar.startOfDay(for: Date(timeIntervalSince1970: today / 1000))
        var (total, days, run, longest) = (0.0, 0, 0, 0)
        var best: (date: String, seconds: Double)?
        for back in stride(from: 364, through: 0, by: -1) {
            let key = dayKey(calendar.date(byAdding: .day, value: -back, to: end)!.timeIntervalSince1970 * 1000, calendar: calendar)
            let seconds = log[key] ?? 0
            total += seconds
            if seconds > 0 {
                days += 1
                run += 1
                longest = max(longest, run)
                if seconds > (best?.seconds ?? 0) { best = (key, seconds) }
            } else {
                run = 0
            }
        }
        return YearStats(total: total, days: days, longestRun: longest, best: best)
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let minutes = seconds > 0 ? max(1, Int((seconds / 60).rounded())) : 0
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
