// Scoring free recall and remaking the mind map from memory (the study site's core/recall.js, ported).

import Foundation

public struct RemakeRow: Equatable, Sendable {
    public let name: String
    public let remembered: Bool
    public let children: [RemakeRow]
}

public struct RemakeResult: Equatable, Sendable {
    public let rows: [RemakeRow]
    public let lines: [String]
    public let percent: Int
}

public enum Remake {
    static let stopWords: Set<String> = ["with", "that", "this", "from", "into", "your", "about", "when", "what", "they", "their"]
    /// A guess shorter than this only matches a branch word for word, so "e" can't match "Failure modes".
    static let minimumSubstring = 4

    static func significantWords(_ text: String) -> [String] {
        let cleaned = String(text.lowercased().map { (c: Character) -> Character in c.isLetter || c.isNumber ? c : " " })
        return cleaned.split(separator: " ").map(String.init).filter { $0.count > 3 && !stopWords.contains($0) }
    }

    /// Does a remembered branch name match the real one? Tolerates word forms and extra words.
    public static func namesMatch(_ guess: String, _ truth: String) -> Bool {
        let g = guess.lowercased().trimmingCharacters(in: .whitespaces)
        let t = truth.lowercased().trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty, !t.isEmpty else { return false }
        if g == t { return true }
        if min(g.count, t.count) >= minimumSubstring, g.contains(t) || t.contains(g) { return true }
        let guessWords = significantWords(guess)
        let truthWords = significantWords(truth)
        guard !guessWords.isEmpty, !truthWords.isEmpty else { return false }
        func sameStem(_ a: String, _ b: String) -> Bool { a == b || (a.count > 4 && b.count > 4 && a.prefix(5) == b.prefix(5)) }
        let hits = truthWords.filter { tw in guessWords.contains { sameStem($0, tw) } }.count
        return Double(hits) / Double(truthWords.count) >= 0.5
    }

    /// Compare what someone typed ("Branch" lines, "- sub-idea" lines) with the real mind map.
    public static func compare(_ typed: String, with map: MindNode) -> RemakeResult {
        let lines = typed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let everything = lines.map { $0.hasPrefix("-") ? String($0.drop { $0 == "-" }).trimmingCharacters(in: .whitespaces) : $0 }
        var found = 0
        var total = 0
        let rows = map.children.map { branch -> RemakeRow in
            let children = branch.children.map { child -> RemakeRow in
                let hit = everything.contains { namesMatch($0, child.name) }
                found += hit ? 1 : 0
                total += 1
                return RemakeRow(name: child.name, remembered: hit, children: [])
            }
            let remembered = everything.contains { namesMatch($0, branch.name) }
            found += remembered ? 1 : 0
            total += 1
            return RemakeRow(name: branch.name, remembered: remembered, children: children)
        }
        return RemakeResult(rows: rows, lines: lines, percent: total > 0 ? Int((100 * Double(found) / Double(total)).rounded()) : 0)
    }
}

/// Where someone is in a chapter's quiz, stored in progress.quiz["n"] as {i, results} (the study site's shape).
public struct QuizProgress: Codable, Equatable, Sendable {
    public var i: Int = 0
    public var results: [Bool] = []
    public init() {}
    public init(i: Int, results: [Bool]) { (self.i, self.results) = (i, results) }

    public init(_ value: JSONValue?) {
        guard case .object(let object)? = value else { return }
        if case .number(let n)? = object["i"] { i = max(0, Int(n)) }
        if case .array(let items)? = object["results"] {
            results = items.map { if case .bool(let b) = $0 { b } else { false } }
        }
    }

    public var json: JSONValue { .object(["i": .number(Double(i)), "results": .array(results.map(JSONValue.bool))]) }
    public var right: Int { results.filter { $0 }.count }
    /// 80% or better is worth confetti.
    public func isGreat(outOf total: Int) -> Bool { total > 0 && right >= Int((Double(total) * 0.8).rounded(.up)) }
}

/// Models sometimes write math as LaTeX ("$M \times N$"); show it as plain text ("M × N").
public enum PlainMath {
    static let symbols: [(String, String)] = [
        ("\\times", "×"), ("\\cdot", "·"), ("\\rightarrow", "→"), ("\\to", "→"), ("\\leftarrow", "←"), ("\\leq", "≤"),
        ("\\le", "≤"), ("\\geq", "≥"), ("\\ge", "≥"), ("\\neq", "≠"), ("\\approx", "≈"), ("\\infty", "∞"), ("\\pm", "±"),
        ("\\{", "{"), ("\\}", "}"), ("\\%", "%"), ("\\,", " "),
    ]

    public static func clean(_ text: String) -> String {
        guard text.contains("$") || text.contains("\\") else { return text }
        var out = text
        for (latex, symbol) in symbols { out = out.replacingOccurrences(of: latex, with: symbol) }
        // Math is $…$ hugging its content; "$5 and $6" (prices) has spaces inside and stays as written.
        out = out.replacing(/\$\$?([^\s$](?:[^$]*[^\s$])?)\$\$?/) { String($0.output.1) }
        return out.replacing(/\\(?:text|mathrm|mathbf)\{([^}]*)\}/) { String($0.output.1) }
    }
}
