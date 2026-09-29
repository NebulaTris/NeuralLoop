// What the library shows about each book: a dot per chapter, one study log for every book, and a cover colour.

import Foundation

public enum ChapterDot: Equatable, Sendable {
    case closed     // all five steps done
    case open       // ready and unlocked: the one to study
    case ready      // ready, opens when the chapter before it closes
    case preparing  // Pip is still making it
}

public enum Shelf {
    public static func dots(_ chapters: [Chapter], _ progress: StudyProgress) -> [ChapterDot] {
        chapters.map { chapter in
            if Loop.isClosed(progress, chapter.n) { return .closed }
            guard chapter.status["study"] == .done else { return .preparing }
            return Loop.isUnlocked(progress, chapters, chapter.n) ? .open : .ready
        }
    }

    public static func combinedLog(_ logs: [[String: Double]]) -> [String: Double] {
        logs.reduce(into: [:]) { total, log in total.merge(log, uniquingKeysWith: +) }
    }

    /// Stable across launches (Swift's own hashes are not), so a book keeps its colour.
    public static func coverIndex(_ title: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let sum = title.unicodeScalars.enumerated().reduce(0) { $0 &+ Int($1.element.value) &* ($1.offset + 1) }
        return abs(sum) % count
    }
}
