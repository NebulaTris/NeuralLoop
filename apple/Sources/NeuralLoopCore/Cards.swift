// Flashcards across the book, limited to unlocked chapters.

public struct ReviewCard: Equatable, Sendable {
    public let id: String      // "chapter:index", the key in progress.cards
    public let chapter: Int
    public let card: Card
}

public enum Cards {
    public static func unlocked(_ chapters: [Chapter], _ p: StudyProgress) -> [ReviewCard] {
        chapters.filter { Loop.isUnlocked(p, chapters, $0.n) }.flatMap { chapter in
            chapter.cards.enumerated().map { ReviewCard(id: "\(chapter.n):\($0.offset)", chapter: chapter.n, card: $0.element) }
        }
    }

    /// Cards never reviewed, or whose review is due.
    public static func due(_ chapters: [Chapter], _ p: StudyProgress, now: Double) -> [ReviewCard] {
        unlocked(chapters, p).filter { card in (p.cards[card.id]?.due).map { $0 <= now } ?? true }
    }
}
