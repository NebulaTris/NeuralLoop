// Checking a free-recall answer (same rules as pipeline/neuralloop_books/recall.py): one small model check per key
// point; a "covered" verdict counts only when its quoted evidence is in the answer and about the idea; word matching
// when no model is available. The model call itself lives in the app (MLX Swift on device).

import Foundation

public struct Verdict: Equatable, Sendable {
    public let covered: Bool
    public let evidence: String
}

public enum RecallCheck {
    static let stop: Set<String> = ["that", "this", "with", "from", "have", "they", "their", "what", "when", "your", "into", "than", "then"]
    static let meta: Set<String> = Set(["answer", "learner", "clearly", "expresses", "mentions", "states", "says", "explains", "idea", "point"]
        .map { String($0.prefix(5)) })

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

    /// Evidence must mostly come from the answer (0.4 allows light paraphrase) and touch the idea itself.
    public static func grounded(_ quote: String, answer: String, idea: String) -> Bool {
        let words = stems(quote).subtracting(meta)
        guard !words.isEmpty else { return false }
        let inAnswer = Double(words.intersection(stems(answer)).count) / Double(words.count) >= 0.4
        return inAnswer && !words.intersection(stems(idea)).isEmpty
    }

    public static func feedback(_ keyPoints: [String], covered: [Bool]) -> String {
        let missing = zip(keyPoints, covered).filter { !$0.1 }.map(\.0)
        let remembered = zip(keyPoints, covered).filter { $0.1 }.map(\.0)
        guard let next = missing.first else { return "You covered every key point. Lovely recall!" }
        if let first = remembered.first { return "Nice: you remembered that \(first). Next time, also add that \(next)." }
        return "Good start. Next time, try to include that \(next)."
    }

    /// A model's answer for one key point, or nil when it isn't a verdict.
    public static func verdict(from reply: String) -> Verdict? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any],
              let covered = object["covered"] as? Bool
        else { return nil }
        return Verdict(covered: covered, evidence: (object["evidence"] as? String) ?? "")
    }

    /// The prompt for one key point (same wording as the pipeline's RECALL_POINT).
    public static func prompt(question: String, point: String, answer: String) -> String {
        """
        Question the learner answered: \(question)
        Idea: "\(point)"
        Learner's answer: <<<\(answer.trimmingCharacters(in: .whitespacesAndNewlines))>>>
        JSON: {"covered": true or false, "evidence": "a short phrase copied from the answer that expresses the idea, or empty"}
        """
    }
}
