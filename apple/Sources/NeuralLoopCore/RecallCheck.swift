// A free-recall answer when the pipeline can't grade it (`--grade-recall` does, with a model): word matching (same
// rule as pipeline/neuralloop_books/recall.py's `word_match`), and warm feedback naming the next thing to add.

import Foundation

public enum RecallCheck {
    static let stop: Set<String> = ["that", "this", "with", "from", "have", "they", "their", "what", "when", "your", "into", "than", "then"]

    static func stems(_ text: String) -> Set<String> {
        let words = text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
        return Set(words.filter { $0.count > 3 && !stop.contains($0) }.map { String($0.prefix(5)) })
    }

    /// A key point counts as covered when most of its meaningful words (by stem) appear in the answer.
    public static func wordMatch(_ keyPoints: [String], answer: String) -> [Bool] {
        let said = stems(answer)
        return keyPoints.map { point in
            let words = stems(point)
            return !words.isEmpty && Double(words.intersection(said).count) / Double(words.count) >= 0.6
        }
    }

    public static func feedback(_ keyPoints: [String], covered: [Bool]) -> String {
        let missing = zip(keyPoints, covered).filter { !$0.1 }.map(\.0)
        let remembered = zip(keyPoints, covered).filter { $0.1 }.map(\.0)
        guard let next = missing.first else { return "You covered every key point. Lovely recall!" }
        if let first = remembered.first { return "Nice: you remembered that \(first). Next time, also add that \(next)." }
        return "Good start. Next time, try to include that \(next)."
    }
}
