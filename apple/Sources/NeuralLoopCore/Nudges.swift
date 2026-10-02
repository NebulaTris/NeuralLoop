// Pip's nudges: at most one a day, only when something small is worth doing, never in quiet hours, and backing off
// when ignored. Away from the app a while, they turn silly on purpose: a tiny sad violin after 8 hours, a sad meow song
// after 12, a shocked "fahhh" after a day, each once until you open the app again (Settings can turn them down or
// off). `decide` is pure so the whole policy is tested; the app gathers the inputs and plays the sounds.

import Foundation

public struct NudgeSettings: Codable, Equatable, Sendable {
    public var enabled = true
    public var quietStart = 22
    public var quietEnd = 8
    public var pausedUntil: Double = 0  // Unix ms
    /// After a few days away, Pip gets dramatic: sad sounds and a sad (or shocked) Pip.
    public var sillySounds = true
    /// The shocked "fahhh" after a week away (off: the sad meow song instead).
    public var fahhh = true
    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, quietStart, quietEnd, pausedUntil, sillySounds, fahhh }

    /// Settings saved by earlier versions keep what they had; anything new starts at its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NudgeSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        quietStart = try c.decodeIfPresent(Int.self, forKey: .quietStart) ?? d.quietStart
        quietEnd = try c.decodeIfPresent(Int.self, forKey: .quietEnd) ?? d.quietEnd
        pausedUntil = try c.decodeIfPresent(Double.self, forKey: .pausedUntil) ?? d.pausedUntil
        sillySounds = try c.decodeIfPresent(Bool.self, forKey: .sillySounds) ?? d.sillySounds
        fahhh = try c.decodeIfPresent(Bool.self, forKey: .fahhh) ?? d.fahhh
    }
}

public struct NudgeHistory: Codable, Equatable, Sendable {
    public var lastSent: Double = 0
    public var lastSentDay = ""
    public var lastEngaged: Double = 0
    public var ignoredInARow = 0
    /// The last nudge's mood: while it's newer than your last visit, the silly ones already sent aren't sent again.
    public var lastMood: NudgeMood?
    public init() {}

    /// Record a nudge going out; a nudge sent after the last time you opened the app counts as ignored.
    public mutating func sent(now: Double, day: String, mood: NudgeMood = .gentle) {
        let previousWasIgnored = lastSent > 0 && lastEngaged < lastSent
        ignoredInARow = previousWasIgnored ? ignoredInARow + 1 : 0
        (lastSent, lastSentDay, lastMood) = (now, day, mood)
    }

    /// The silliest nudge already sent since you last opened the app.
    var sillySinceVisit: NudgeMood { lastSent > lastEngaged ? lastMood ?? .gentle : .gentle }

    public mutating func engaged(now: Double) { (lastEngaged, ignoredInARow) = (now, 0) }
}

/// How a nudge sounds and which Pip it shows: `gentle` is the usual chime and a happy Pip; the rest are the silly ones.
public enum NudgeMood: String, Codable, CaseIterable, Sendable {
    case gentle, sadViolin, sadMeow, shocked

    /// Hours away before each silly mood (the shocked one also needs `fahhh` on).
    static let violinHours = 8.0, meowHours = 12.0, shockedHours = 24.0

    public static func after(hoursAway: Double, settings: NudgeSettings) -> NudgeMood {
        guard settings.sillySounds else { return .gentle }
        if hoursAway >= shockedHours { return settings.fahhh ? .shocked : .sadMeow }
        if hoursAway >= meowHours { return .sadMeow }
        return hoursAway >= violinHours ? .sadViolin : .gentle
    }

    /// Sillier moods come later on the ladder.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

public struct Nudge: Equatable, Sendable {
    public let title: String
    public let body: String
    public let mood: NudgeMood
    /// What's ready, without the emoji ("4 cards are ready"): a silly nudge leads its body with it.
    let headline: String
    public init(title: String, body: String, mood: NudgeMood = .gentle) {
        (self.title, self.body, self.mood, headline) = (title, body, mood, title)
    }

    init(emoji: String, headline: String, body: String) {
        (title, self.body, mood, self.headline) = ("\(emoji) \(headline)", body, .gentle, headline)
    }

    /// What a nudge of each mood looks and sounds like (Settings → Nudges sends these as tests).
    public static func sample(_ mood: NudgeMood) -> Nudge {
        let test = Nudge(emoji: "🐾", headline: "Hi from Pip", body: "This is how a nudge looks. Pip will only ever send one a day.")
        return test.told(mood)
    }

    /// The same news, told the silly way.
    func told(_ mood: NudgeMood) -> Nudge {
        let title: String = switch mood {
        case .gentle: self.title
        case .sadViolin: "🎻 Pip is playing a tiny sad violin"
        case .sadMeow: "😿 Pip wrote you a sad little song"
        case .shocked: "😱 FAHHH! A whole day?!"
        }
        guard mood != .gentle else { return self }
        return Nudge(title: title, body: headline.isEmpty ? body : "\(headline). \(body)", mood: mood)
    }
}

public enum Nudges {
    static let dayMs = 86_400_000.0
    static let hourMs = 3_600_000.0
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
        let news = dueCardsNudge(books, now: now) ?? halfDoneChapterNudge(books, now: now)
        // The silly ladder: each step once per absence, outside the one-a-day limit and the back-off.
        let hoursAway = history.lastEngaged > 0 ? (now - history.lastEngaged) / hourMs : 0
        let mood = NudgeMood.after(hoursAway: hoursAway, settings: settings)
        if mood.rank > history.sillySinceVisit.rank, !books.isEmpty {
            let missYou = Nudge(emoji: "🐾", headline: "", body: "Your books miss you. Even five minutes counts.")
            return (news ?? missYou).told(mood)
        }
        if history.lastSentDay == today { return nil }  // at most one a day
        if history.ignoredInARow >= 2, now - history.lastSent < 2 * dayMs { return nil }  // ignored twice: every other day
        let awayAWeek = history.lastEngaged > 0 && now - history.lastEngaged > 7 * dayMs
        if awayAWeek, now - history.lastSent < 7 * dayMs { return nil }  // away a week: weekly only
        return news
    }

    static func dueCardsNudge(_ books: [(book: Book, progress: StudyProgress)], now: Double) -> Nudge? {
        let due = books.map { reviewedCardsDue($0.progress, now: now) }.reduce(0, +)
        guard due >= minimumDueCards else { return nil }
        let minutes = (due * secondsPerCard + 59) / 60
        return Nudge(emoji: "🐾", headline: "\(due) cards are ready", body: "About \(minutes) min with Pip, then you're done for today.")
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
        return best.map { Nudge(emoji: "🧶", headline: "Loose yarn in “\($0.title)”", body: "Next: \($0.next). Pip saved your spot.") }
    }

    /// When nudges resume after "pause until tomorrow": tomorrow at the end of quiet hours.
    public static func pauseUntilTomorrow(now: Date, quietEnd: Int, calendar: Calendar = .current) -> Double {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let resume = calendar.date(bySettingHour: min(max(quietEnd, 0), 23), minute: 0, second: 0, of: tomorrow) ?? tomorrow
        return resume.timeIntervalSince1970 * 1000
    }
}
