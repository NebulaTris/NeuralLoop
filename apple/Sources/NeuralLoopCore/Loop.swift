// The five-step learning loop per chapter, and which chapters are unlocked.

public enum Stage: String, CaseIterable, Codable, Sendable {
    case prime, read, recall, map, space

    public var label: String {
        switch self {
        case .prime: "Listen & watch"
        case .read: "Read"
        case .recall: "Recall"
        case .map: "Map"
        case .space: "Remember"
        }
    }
}

public enum Loop {
    public static func isClosed(_ p: StudyProgress, _ n: Int) -> Bool {
        let steps = p.loop[String(n)] ?? [:]
        return Stage.allCases.allSatisfy { steps[$0.rawValue] != nil }
    }

    /// The first unfinished step, or nil when the loop is closed.
    public static func nextStage(_ p: StudyProgress, _ n: Int) -> Stage? {
        let steps = p.loop[String(n)] ?? [:]
        return Stage.allCases.first { steps[$0.rawValue] == nil }
    }

    /// Chapter 1 is always open; every other chapter opens when the one before it is closed.
    public static func isUnlocked(_ p: StudyProgress, _ chapters: [Chapter], _ n: Int) -> Bool {
        guard let index = chapters.firstIndex(where: { $0.n == n }), index > 0 else { return true }
        return isClosed(p, chapters[index - 1].n)
    }

    /// Record a finished step. Returns true if this closed the loop for the first time.
    @discardableResult
    public static func complete(_ p: inout StudyProgress, _ n: Int, _ stage: Stage, now: Double) -> Bool {
        var steps = p.loop[String(n)] ?? [:]
        if steps[stage.rawValue] == nil { steps[stage.rawValue] = now }
        p.loop[String(n)] = steps
        p.updatedAt = max(p.updatedAt, now)
        if isClosed(p, n) && steps["closedShown"] == nil {
            p.loop[String(n)]?["closedShown"] = 1
            return true
        }
        return false
    }

    /// A chapter's ideas join the book map once its Map step is done.
    public static func isMapped(_ p: StudyProgress, _ n: Int) -> Bool { p.loop[String(n)]?["map"] != nil }
}
