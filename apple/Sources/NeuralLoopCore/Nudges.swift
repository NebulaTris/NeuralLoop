// Pip's nudges: at most one a day, only when something small is worth doing, never in quiet hours, and backing off
// when ignored. Away from the app a while, they turn silly on purpose, step by step: by default a tiny sad violin after
// 8 hours, a sad meow song after 12, and a shocked "fahhh" after a day, each once until you open the app again, and
// only with real news (cards due or a chapter left halfway; with nothing to do, one "Pip's ready when you are" a week
// at most). The steps are yours to change in Settings (sounds, hours, how many, and an optional repeat of the last
// one). Silly steps keep their own history, so they never push the usual nudge into its back-off.
// `decide` is pure so the whole policy is tested; the app gathers the inputs and plays the sounds.

import Foundation

public struct NudgeSettings: Codable, Equatable, Sendable {
    /// The master switch: off means no notification from Pip at all.
    public var enabled = true
    /// "Chapter 2 is ready": when the chapter you can study next is fully prepared.
    public var chapterReady = true
    /// The usual gentle nudges (cards due, a loop left halfway).
    public var nudges = true
    public var quietStart = 22
    public var quietEnd = 8
    public var pausedUntil: Double = 0  // Unix ms
    /// Away a while, Pip gets dramatic: sad sounds and a sad (or shocked) Pip, step by step.
    public var sillySounds = true
    /// Silly mode's steps, each once per absence (in order of hours, whatever order they're saved in).
    public var steps = SillyStep.defaults
    /// After the last step, play it again every this many hours while you're still away (0: don't).
    public var repeatHours = 0.0
    /// Silly nudges also pop up a big Pip in the middle of the screen while the sound plays (off: a notification only,
    /// with its sound at the Mac's alert volume).
    public var bigPip = true
    /// How loud the big Pip plays its sound, 0…1.
    public var volume = 0.8
    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, chapterReady, nudges, quietStart, quietEnd, pausedUntil, sillySounds, steps, repeatHours, bigPip, volume
        case fahhh  // read only: before steps, a switch for the fahhh step
    }

    /// The steps in the order they come (steps with the same hours in the order they're saved).
    public enum Kind: Sendable { case chapterReady, nudges, silly }

    /// Whether this kind of notification may go out at all: the master switch, then its own.
    public func allows(_ kind: Kind) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .chapterReady: return chapterReady
        case .nudges: return nudges
        case .silly: return sillySounds
        }
    }

    /// Pip keeps quiet now: during quiet hours (`hour` is the local hour) or while paused ("Pause until tomorrow").
    public func isQuiet(now: Double, hour: Int) -> Bool {
        now < pausedUntil || Nudges.inQuietHours(hour: hour, start: quietStart, end: quietEnd)
    }

    public var ladder: [SillyStep] {
        steps.enumerated().sorted { ($0.element.hours, $0.offset) < ($1.element.hours, $1.offset) }.map(\.element)
    }

    /// Settings saved by earlier versions keep what they had; anything new starts at its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NudgeSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        chapterReady = try c.decodeIfPresent(Bool.self, forKey: .chapterReady) ?? d.chapterReady
        nudges = try c.decodeIfPresent(Bool.self, forKey: .nudges) ?? d.nudges
        quietStart = try c.decodeIfPresent(Int.self, forKey: .quietStart) ?? d.quietStart
        quietEnd = try c.decodeIfPresent(Int.self, forKey: .quietEnd) ?? d.quietEnd
        pausedUntil = try c.decodeIfPresent(Double.self, forKey: .pausedUntil) ?? d.pausedUntil
        sillySounds = try c.decodeIfPresent(Bool.self, forKey: .sillySounds) ?? d.sillySounds
        if let saved = try? c.decodeIfPresent([LenientStep].self, forKey: .steps) {
            steps = SillyStep.separated(Array(saved.compactMap(\.step).prefix(SillyStep.most)))
        } else if (try? c.decodeIfPresent(Bool.self, forKey: .fahhh)) == false {
            steps = d.steps.filter { $0.sound != .shocked }
        }
        repeatHours = SillyStep.repeatChoice(try c.decodeIfPresent(Double.self, forKey: .repeatHours) ?? d.repeatHours)
        bigPip = try c.decodeIfPresent(Bool.self, forKey: .bigPip) ?? d.bigPip
        volume = min(max(try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume, 0), 1)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(chapterReady, forKey: .chapterReady)
        try c.encode(nudges, forKey: .nudges)
        try c.encode(quietStart, forKey: .quietStart)
        try c.encode(quietEnd, forKey: .quietEnd)
        try c.encode(pausedUntil, forKey: .pausedUntil)
        try c.encode(sillySounds, forKey: .sillySounds)
        try c.encode(steps, forKey: .steps)
        try c.encode(repeatHours, forKey: .repeatHours)
        try c.encode(bigPip, forKey: .bigPip)
        try c.encode(volume, forKey: .volume)
    }

    /// A saved step that may be odd (not a step at all, an unknown or calm sound, hours out of range): kept if it can
    /// be made sensible, skipped on its own otherwise (one bad step never throws the others away).
    private struct LenientStep: Decodable {
        let step: SillyStep?
        init(from decoder: Decoder) throws {
            guard let c = try? decoder.container(keyedBy: SillyStep.CodingKeys.self) else { step = nil; return }
            let sound = (try? c.decode(String.self, forKey: .sound)).flatMap(NudgeMood.init(rawValue:))
            let hours = (try? c.decode(Double.self, forKey: .hours)) ?? 0
            let id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
            step = sound.flatMap { SillyStep.sounds.contains($0) ? SillyStep($0, after: hours, id: id) : nil }
        }
    }
}

/// One step of Silly mode: which sound, and how many hours after you last opened the app.
public struct SillyStep: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var sound: NudgeMood
    public var hours: Double {
        didSet { hours = Self.clamp(hours) }
    }

    public init(_ sound: NudgeMood, after hours: Double, id: UUID = UUID()) {
        (self.id, self.sound, self.hours) = (id, sound, Self.clamp(hours))
    }

    enum CodingKeys: String, CodingKey { case id, sound, hours }

    public static let defaults = [SillyStep(.sadViolin, after: 8), SillyStep(.sadMeow, after: 12), SillyStep(.shocked, after: 24)]
    /// The sounds a step can play.
    public static let sounds: [NudgeMood] = [.sadViolin, .sadMeow, .shocked]
    public static let hourRange = 1.0...168.0  // an hour to a week
    public static let most = 8
    public static let repeatRange = 1.0...48.0

    static func clamp(_ hours: Double) -> Double { min(max(hours.rounded(), hourRange.lowerBound), hourRange.upperBound) }

    /// Hours for a new step: four after the last one, or the nearest free hour (later first, then earlier), so no two
    /// steps share an hour.
    public static func freeHours(after steps: [SillyStep]) -> Double {
        let taken = Set(steps.map(\.hours))
        return nearestFree(clamp((steps.map(\.hours).max() ?? 4) + 4), taken: taken)
    }

    /// Saved steps sharing an hour move to the nearest free one (later first, then earlier), keeping their order.
    static func separated(_ steps: [SillyStep]) -> [SillyStep] {
        var taken = Set<Double>()
        return steps.map { step in
            var step = step
            step.hours = nearestFree(step.hours, taken: taken)
            taken.insert(step.hours)
            return step
        }
    }

    private static func nearestFree(_ hours: Double, taken: Set<Double>) -> Double {
        let later = stride(from: hours, through: hourRange.upperBound, by: 1).first { !taken.contains($0) }
        return later ?? stride(from: hours, through: hourRange.lowerBound, by: -1).first { !taken.contains($0) } ?? hours
    }

    /// A repeat interval: off (0) or within range.
    public static func repeatChoice(_ hours: Double) -> Double {
        hours <= 0 ? 0 : min(max(hours.rounded(), repeatRange.lowerBound), repeatRange.upperBound)
    }
}

public struct NudgeHistory: Codable, Equatable, Sendable {
    /// The last usual (gentle) nudge: these three drive the one-a-day limit and the back-off.
    public var lastSent: Double = 0
    public var lastSentDay = ""
    public var ignoredInARow = 0
    public var lastEngaged: Double = 0
    public var lastMood: NudgeMood?
    /// The last Silly mode step sent, and when. Silly steps keep to their own history: they never count as an ignored
    /// nudge or use up the day's one.
    public var lastSillySent: Double = 0
    public var lastStepId: UUID?
    /// The last "Pip's ready when you are" (a silly step with nothing to do): at most one a week.
    public var lastMissedYou: Double = 0
    public init() {}

    enum CodingKeys: String, CodingKey {
        case lastSent, lastSentDay, ignoredInARow, lastEngaged, lastMood, lastSillySent, lastStepId, lastMissedYou
        case lastStep  // read only: before step ids, the sent step's place in the ladder
    }

    /// Lenient: an odd field starts at its default. History saved before silly steps had their own fields keeps the
    /// last silly nudge's time, so the ladder doesn't start again.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastSent = (try? c.decodeIfPresent(Double.self, forKey: .lastSent)) ?? 0
        lastSentDay = (try? c.decodeIfPresent(String.self, forKey: .lastSentDay)) ?? ""
        ignoredInARow = (try? c.decodeIfPresent(Int.self, forKey: .ignoredInARow)) ?? 0
        lastEngaged = (try? c.decodeIfPresent(Double.self, forKey: .lastEngaged)) ?? 0
        lastMood = ((try? c.decodeIfPresent(String.self, forKey: .lastMood)) ?? nil).flatMap(NudgeMood.init(rawValue:))
        lastSillySent = (try? c.decodeIfPresent(Double.self, forKey: .lastSillySent)) ?? 0
        lastStepId = (try? c.decodeIfPresent(UUID.self, forKey: .lastStepId)) ?? nil
        lastMissedYou = (try? c.decodeIfPresent(Double.self, forKey: .lastMissedYou)) ?? 0
        let oldStep = (try? c.decodeIfPresent(Int.self, forKey: .lastStep)) ?? nil
        if oldStep != nil, lastSillySent == 0, let lastMood, lastMood != .gentle { lastSillySent = lastSent }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lastSent, forKey: .lastSent)
        try c.encode(lastSentDay, forKey: .lastSentDay)
        try c.encode(ignoredInARow, forKey: .ignoredInARow)
        try c.encode(lastEngaged, forKey: .lastEngaged)
        try c.encodeIfPresent(lastMood, forKey: .lastMood)
        try c.encode(lastSillySent, forKey: .lastSillySent)
        try c.encodeIfPresent(lastStepId, forKey: .lastStepId)
        try c.encode(lastMissedYou, forKey: .lastMissedYou)
    }

    /// Record a nudge going out. A usual nudge sent after the last time you opened the app counts as ignored; a silly
    /// step only moves the ladder along.
    public mutating func sent(now: Double, day: String, mood: NudgeMood = .gentle, step: SillyStep? = nil, missedYou: Bool = false) {
        lastMood = mood
        if mood == .gentle {
            let previousWasIgnored = lastSent > 0 && lastEngaged < lastSent
            ignoredInARow = previousWasIgnored ? ignoredInARow + 1 : 0
            (lastSent, lastSentDay) = (now, day)
        } else {
            lastSillySent = now
            if let step { lastStepId = step.id }
            if missedYou { lastMissedYou = now }
        }
    }

    public mutating func sent(_ nudge: Nudge, now: Double, day: String) {
        sent(now: now, day: day, mood: nudge.mood, step: nudge.step, missedYou: nudge.missesYou)
    }

    /// How far along `ladder` this absence's silly steps went (the last sent step's place), or nil if none went out
    /// since your last visit. A step since removed counts as far as what was due when it went out.
    func sentPlace(in ladder: [SillyStep]) -> Int? {
        guard lastSillySent > lastEngaged else { return nil }
        if let lastStepId, let place = ladder.firstIndex(where: { $0.id == lastStepId }) { return place }
        let hoursThen = (lastSillySent - lastEngaged) / Nudges.hourMs
        return ladder.lastIndex { $0.hours <= hoursThen }
    }

    public mutating func engaged(now: Double) { (lastEngaged, ignoredInARow) = (now, 0) }
}

/// How a nudge sounds and which Pip it shows: `gentle` is the usual chime and a happy Pip; the rest are the silly ones.
public enum NudgeMood: String, Codable, CaseIterable, Sendable {
    case gentle, sadViolin, sadMeow, shocked

    /// How Settings names it.
    public var name: String {
        switch self {
        case .gentle: "The usual chime"
        case .sadViolin: "🎻 Sad violin"
        case .sadMeow: "😿 Sad meow song"
        case .shocked: "😱 Fahhh"
        }
    }
}

public struct Nudge: Equatable, Sendable {
    public let title: String
    public let body: String
    public let mood: NudgeMood
    /// Which Silly mode step this is (recorded so it isn't sent twice), or nil.
    public let step: SillyStep?
    /// A silly step with nothing to do but say hi (at most one a week).
    public let missesYou: Bool
    /// What's ready, without the emoji ("4 cards are ready"): a silly nudge leads its body with it.
    let headline: String
    public init(title: String, body: String, mood: NudgeMood = .gentle, step: SillyStep? = nil, missesYou: Bool = false) {
        (self.title, self.body, self.mood, self.step, self.missesYou, headline) = (title, body, mood, step, missesYou, title)
    }

    init(emoji: String, headline: String, body: String) {
        (title, self.body, mood, step, missesYou, self.headline) = ("\(emoji) \(headline)", body, .gentle, nil, false, headline)
    }

    /// The title's leading emoji, shown big on screen, and the words after it.
    public var emoji: String {
        guard let first = title.first, first.unicodeScalars.first?.properties.isEmojiPresentation == true else { return "" }
        return String(first)
    }

    public var words: String { emoji.isEmpty ? title : String(title.dropFirst()).trimmingCharacters(in: .whitespaces) }

    /// What a nudge of each mood looks and sounds like (Settings → Nudges sends these as tests).
    public static func sample(_ mood: NudgeMood) -> Nudge {
        let test = Nudge(emoji: "🐾", headline: "Hi from Pip", body: "This is how a nudge looks and sounds.")
        return test.told(mood, hoursAway: 24)
    }

    /// The same news, told the silly way.
    func told(_ mood: NudgeMood, hoursAway: Double, step: SillyStep? = nil, missesYou: Bool = false) -> Nudge {
        let title: String = switch mood {
        case .gentle: self.title
        case .sadViolin: "🎻 Pip is playing a tiny sad violin"
        case .sadMeow: "😿 Pip wrote you a sad little song"
        case .shocked: "😱 FAHHH! \(Self.howLong(hoursAway))?!"
        }
        guard mood != .gentle else { return self }
        return Nudge(title: title, body: headline.isEmpty ? body : "\(headline). \(body)", mood: mood, step: step, missesYou: missesYou)
    }

    /// "3 hours", "A whole day", "3 days".
    static func howLong(_ hours: Double) -> String {
        if hours < 24 { return "\(max(Int(hours), 1)) hour\(Int(hours) == 1 ? "" : "s")" }
        let days = Int(hours / 24)
        return days == 1 ? "A whole day" : "\(days) days"
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

    /// Should Pip nudge now, and with what? `books` pairs each book with this device's progress; `appActive`: NeuralLoop
    /// is the app in front (you're here, so nothing silly).
    public static func decide(books: [(book: Book, progress: StudyProgress)], settings: NudgeSettings, history: NudgeHistory,
                              now: Double, hour: Int, today: String, appActive: Bool = false) -> Nudge? {
        guard settings.enabled, !settings.isQuiet(now: now, hour: hour) else { return nil }
        let news = dueCardsNudge(books, now: now) ?? halfDoneChapterNudge(books, now: now)
        // Silly mode: each step once per absence (the last may repeat), outside the one-a-day limit and the back-off,
        // and only with something to come back to; with nothing to do, a hi at most once a week.
        if !appActive, !books.isEmpty, let place = sillyStep(settings: settings, history: history, now: now) {
            let step = settings.ladder[place]
            let hoursAway = (now - history.lastEngaged) / hourMs
            if let news { return news.told(step.sound, hoursAway: hoursAway, step: step) }
            if now - history.lastMissedYou >= 7 * dayMs {
                let hi = Nudge(emoji: "🐾", headline: "", body: "Pip's ready when you are. Even five minutes counts.")
                return hi.told(step.sound, hoursAway: hoursAway, step: step, missesYou: true)
            }
        }
        guard settings.allows(.nudges) else { return nil }
        if history.lastSentDay == today { return nil }  // at most one a day
        if history.ignoredInARow >= 2, now - history.lastSent < 2 * dayMs { return nil }  // ignored twice: every other day
        let awayAWeek = history.lastEngaged > 0 && now - history.lastEngaged > 7 * dayMs
        if awayAWeek, now - history.lastSent < 7 * dayMs { return nil }  // away a week: weekly only
        return news
    }

    /// The ladder step to send now, if any (its place in `settings.ladder`): the latest one whose hours have passed,
    /// unless it (or a later one) went out already since your last visit; steps sharing those hours go one at a time,
    /// in order; quiet hours that swallowed a step skip it.
    static func sillyStep(settings: NudgeSettings, history: NudgeHistory, now: Double) -> Int? {
        guard settings.sillySounds, history.lastEngaged > 0, now >= history.lastEngaged else { return nil }
        let ladder = settings.ladder
        let hoursAway = (now - history.lastEngaged) / hourMs
        guard let due = ladder.lastIndex(where: { $0.hours <= hoursAway }),
              let dueGroup = ladder.firstIndex(where: { $0.hours == ladder[due].hours }) else { return nil }
        guard let sent = history.sentPlace(in: ladder) else { return dueGroup }
        let next = max(sent + 1, dueGroup)
        if next <= due { return next }
        let repeatsLast = settings.repeatHours > 0 && sent == ladder.count - 1 && due == sent
        return repeatsLast && now - history.lastSillySent >= settings.repeatHours * hourMs ? due : nil
    }

    static func dueCardsNudge(_ books: [(book: Book, progress: StudyProgress)], now: Double) -> Nudge? {
        let due = books.map { reviewedCardsDue($0.progress, now: now) }.reduce(0, +)
        guard due >= minimumDueCards else { return nil }
        let minutes = (due * secondsPerCard + 59) / 60
        return Nudge(emoji: "🐾", headline: "\(due) cards are ready", body: "About \(minutes) min with Pip, then you're done for today.")
    }

    /// The most recently touched chapter left partway through its loop for at least half a day, and fully prepared
    /// (never a nudge towards a podcast or video that isn't there yet).
    static func halfDoneChapterNudge(_ books: [(book: Book, progress: StudyProgress)], now: Double) -> Nudge? {
        var best: (touched: Double, title: String, next: String)?
        for (book, progress) in books {
            for (chapter, steps) in progress.loop {
                let done = Stage.allCases.compactMap { steps[$0.rawValue] }
                guard !done.isEmpty, done.count < Stage.allCases.count, let touched = done.max(),
                      now - touched >= dayMs / 2, touched > (best?.touched ?? -1) else { continue }
                let next = Stage.allCases.first { steps[$0.rawValue] == nil }.flatMap { nextStep[$0] } ?? "keep going"
                let match = book.chapters.first { String($0.n) == chapter }
                if let match, !ChapterReady.isComplete(match) { continue }
                best = (touched, match?.title ?? "your chapter", next)
            }
        }
        return best.map { Nudge(emoji: "🧶", headline: "Loose yarn in “\($0.title)”", body: "Next: \($0.next). Pip saved your spot.") }
    }

    /// When nudges resume after "pause until tomorrow": the next end of quiet hours after `now` (pressed after
    /// midnight, that's this morning, not the morning after).
    public static func pauseUntilTomorrow(now: Date, quietEnd: Int, calendar: Calendar = .current) -> Double {
        let hour = min(max(quietEnd, 0), 23)
        let today = calendar.startOfDay(for: now)
        let thisMorning = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today) ?? today
        if thisMorning > now { return thisMorning.timeIntervalSince1970 * 1000 }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let resume = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        return resume.timeIntervalSince1970 * 1000
    }
}
