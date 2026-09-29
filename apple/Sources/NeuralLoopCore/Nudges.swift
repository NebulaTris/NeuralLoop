// Pip's gentle nudges: at most one a day, only when something small is worth doing, never in quiet hours, and
// backing off when ignored. `decide` is pure so the whole policy is tested; the app gathers the inputs.

import Foundation

public struct NudgeSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var quietStart = 22
    public var quietEnd = 8
    public var pausedUntil: Double = 0  // Unix ms
    public init() {}
}

public struct NudgeHistory: Codable, Equatable, Sendable {
    public var lastSent: Double = 0
    public var lastSentDay = ""
    public var lastEngaged: Double = 0
    public var ignoredInARow = 0
    public init() {}

    /// Record a nudge going out; a nudge sent after the last time you opened the app counts as ignored.
    public mutating func sent(now: Double, day: String) {
        let previousWasIgnored = lastSent > 0 && lastEngaged < lastSent
        ignoredInARow = previousWasIgnored ? ignoredInARow + 1 : 0
        (lastSent, lastSentDay) = (now, day)
    }

    public mutating func engaged(now: Double) { (lastEngaged, ignoredInARow) = (now, 0) }
}

public struct Nudge: Equatable, Sendable {
    public let title: String
    public let body: String
    public init(title: String, body: String) { (self.title, self.body) = (title, body) }
}

public enum Nudges {
    static let dayMs = 86_400_000.0
    static let minimumDueCards = 3
    static let secondsPerCard = 15
    static let nextStep: [Stage: String] = [
        .prime: "watch or listen", .read: "read with your guide", .recall: "recall it in your own words",
        .map: "remake the map from memory", .space: "review your flashcards",
    ]

    public static func inQuietHours(hour: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }
        return start > end ? (hour >= start || hour < end) : (hour >= start && hour < end)
    }

    /// Cards reviewed at least once whose next review is due. Never-seen cards don't count.
    public static func reviewedCardsDue(_ progress: StudyProgress, now: Double) -> Int {
        progress.cards.values.filter { $0.reps > 0 && $0.due <= now }.count
    }

    /// Should Pip nudge now, and with what? `books` pairs each book with this device's progress.
    public static func decide(books: [(book: Book, progress: StudyProgress)], settings: NudgeSettings, history: NudgeHistory,
                              now: Double, hour: Int, today: String) -> Nudge? {
        guard settings.enabled, now >= settings.pausedUntil,
              !inQuietHours(hour: hour, start: settings.quietStart, end: settings.quietEnd) else { return nil }
        if history.lastSentDay == today { return nil }  // at most one a day
        if history.ignoredInARow >= 2, now - history.lastSent < 2 * dayMs { return nil }  // ignored twice: every other day
        let awayAWeek = history.lastEngaged > 0 && now - history.lastEngaged > 7 * dayMs
        if awayAWeek, now - history.lastSent < 7 * dayMs { return nil }  // away a week: weekly only
        return dueCardsNudge(books, now: now) ?? halfDoneChapterNudge(books, now: now)
    }

    static func dueCardsNudge(_ books: [(book: Book, progress: StudyProgress)], now: Double) -> Nudge? {
        let due = books.map { reviewedCardsDue($0.progress, now: now) }.reduce(0, +)
        guard due >= minimumDueCards else { return nil }
        let minutes = (due * secondsPerCard + 59) / 60
        return Nudge(title: "🐾 \(due) cards are ready", body: "About \(minutes) min with Pip, then you're done for today.")
    }

    /// The most recently touched chapter left partway through its loop for at least half a day.
    static func halfDoneChapterNudge(_ books: [(book: Book, progress: StudyProgress)], now: Double) -> Nudge? {
        var best: (touched: Double, title: String, next: String)?
        for (book, progress) in books {
            for (chapter, steps) in progress.loop {
                let done = Stage.allCases.compactMap { steps[$0.rawValue] }
                guard !done.isEmpty, done.count < Stage.allCases.count, let touched = done.max(),
                      now - touched >= dayMs / 2, touched > (best?.touched ?? -1) else { continue }
                let next = Stage.allCases.first { steps[$0.rawValue] == nil }.flatMap { nextStep[$0] } ?? "keep going"
                let title = book.chapters.first { String($0.n) == chapter }?.title ?? "your chapter"
                best = (touched, title, next)
            }
        }
        return best.map { Nudge(title: "🧶 Loose yarn in “\($0.title)”", body: "Next: \($0.next). Pip saved your spot.") }
    }

    /// When nudges resume after "pause until tomorrow": tomorrow at the end of quiet hours.
    public static func pauseUntilTomorrow(now: Date, quietEnd: Int, calendar: Calendar = .current) -> Double {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let resume = calendar.date(bySettingHour: min(max(quietEnd, 0), 23), minute: 0, second: 0, of: tomorrow) ?? tomorrow
        return resume.timeIntervalSince1970 * 1000
    }
}
