// Steps that complete themselves from what the person really did (spec 09). The button stays as a manual override;
// these only ever add a step, never take one away, and never in a chapter that's still locked.

public enum AutoSteps {
    /// Recall: every question of the chapter's quiz answered.
    public static func quizFinished(_ p: StudyProgress, _ chapter: Chapter) -> Bool {
        !chapter.quiz.isEmpty && QuizProgress(p.quiz[String(chapter.n)]).i >= chapter.quiz.count
    }

    /// Recall: a checked answer counts when it's a real try (at least five words, not the same one over and over).
    public static func isRealAnswer(_ answer: String) -> Bool {
        let words = answer.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.count >= 5 && Set(words).count >= 3
    }

    /// Remember: every card of the chapter reviewed at least once (here or on another device).
    public static func cardsAllSeen(_ p: StudyProgress, _ chapter: Chapter) -> Bool {
        !chapter.cards.isEmpty && cardsSeen(p, chapter) == chapter.cards.count
    }

    /// How many of the chapter's cards have been reviewed at least once.
    public static func cardsSeen(_ p: StudyProgress, _ chapter: Chapter) -> Int {
        chapter.cards.indices.filter { i in p.cards["\(chapter.n):\(i)"].map { $0.reps >= 1 || $0.last > 0 } ?? false }.count
    }
}

extension Loop {
    /// Completes a step the person earned, but only in an open chapter and only if it isn't done yet. Returns nil when
    /// nothing changed, otherwise whether this closed the loop for the first time.
    public static func completeIfOpen(_ p: inout StudyProgress, _ chapters: [Chapter], _ n: Int, _ stage: Stage, now: Double) -> Bool? {
        guard chapters.contains(where: { $0.n == n }), isUnlocked(p, chapters, n),
              p.loop[String(n)]?[stage.rawValue] == nil else { return nil }
        return complete(&p, n, stage, now: now)
    }
}

extension StudyProgress {
    /// A stretch of the chapter's podcast or video played. Like study time, it leaves `updatedAt` alone: merging
    /// takes the union anyway. Returns whether it counted.
    @discardableResult
    public mutating func recordPlay(_ n: Int, _ kind: WatchKind, from: Double, to: Double, rate: Double, wallSeconds: Double) -> Bool {
        var watching = watch[String(n)] ?? WatchProgress()
        guard watching[kind].add(from: from, to: to, rate: rate, wallSeconds: wallSeconds) else { return false }
        watch[String(n)] = watching
        return true
    }

    /// Adds played stretches that were gathered elsewhere (while the book wasn't open).
    public mutating func addWatching(_ n: Int, _ played: WatchProgress) {
        watch[String(n)] = (watch[String(n)] ?? WatchProgress()).union(played)
    }

    /// One reading tick for the chapter (see `ReadingCredit.credit`); leaves `updatedAt` alone.
    @discardableResult
    public mutating func creditReading(_ n: Int, visible: [Int], seconds: Double, pageCount: Int, earning: Bool) -> Bool {
        var record = reading[String(n)] ?? ReadingRecord()
        guard ReadingCredit.credit(&record, visible: visible, seconds: seconds, pageCount: pageCount, earning: earning) else { return false }
        reading[String(n)] = record
        return true
    }
}
