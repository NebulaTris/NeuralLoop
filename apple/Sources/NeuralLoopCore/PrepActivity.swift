// What the pipeline is making right now (its activity.json), and how to say how far along it is: a bar value and
// plain words. Counted work (lines voiced, frames drawn) shows exact progress; NotebookLM's work is timed against
// how long the same maker took recently; with neither, the bar just moves and says when it started.

import Foundation

public struct PrepActivity: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var n: Int
        public var item: String
        public var by: String
        public var step: String
        public var started: Double  // Unix ms
        public var done: Int?
        public var total: Int?
        /// The item's overall progress across its stages (0…1), when the pipeline can count it (local podcasts, videos).
        public var fraction: Double?
        public var expected: Double?  // seconds
    }

    public var updated: Double
    public var ended: Bool
    public var items: [Item]
    public var queue: [(n: Int, item: String)]

    public static func == (a: PrepActivity, b: PrepActivity) -> Bool {
        a.updated == b.updated && a.ended == b.ended && a.items == b.items
            && a.queue.map { "\($0.n):\($0.item)" } == b.queue.map { "\($0.n):\($0.item)" }
    }

    /// Lenient: a bad entry is skipped; a file that isn't a JSON object reads as nil.
    public static func read(_ data: Data) -> PrepActivity? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func number(_ v: Any?) -> Double? { (v as? NSNumber).map(\.doubleValue) }
        let items: [Item] = (root["items"] as? [[String: Any]] ?? []).compactMap { e in
            guard let n = number(e["n"]), let item = e["item"] as? String else { return nil }
            return Item(n: Int(n), item: item, by: e["by"] as? String ?? "", step: e["step"] as? String ?? "",
                        started: number(e["started"]) ?? 0, done: number(e["done"]).map(Int.init),
                        total: number(e["total"]).map(Int.init), fraction: number(e["fraction"]), expected: number(e["expected"]))
        }
        let queue: [(n: Int, item: String)] = (root["queue"] as? [[String: Any]] ?? []).compactMap { e in
            guard let n = number(e["n"]), let item = e["item"] as? String else { return nil }
            return (Int(n), item)
        }
        return PrepActivity(updated: number(root["updated"]) ?? 0, ended: root["ended"] as? Bool ?? false, items: items, queue: queue)
    }

    public var isLive: Bool { !ended }

    public func item(_ n: Int, _ item: String) -> Item? { items.first { $0.n == n && $0.item == item } }

    /// Where an item waits in line (0 = next), if it's queued.
    public func place(_ n: Int, _ item: String) -> Int? { queue.firstIndex { $0.n == n && $0.item == item } }
}

public struct ItemProgress: Equatable, Sendable {
    /// 0…1, or nil when there's nothing to measure (the bar then just moves).
    public var fraction: Double?
    public var step: String
    public var by: String
    public var detail: String
    /// Past the usual time: say so, kindly.
    public var slow: Bool
    /// Timed against how long it usually takes rather than counted (NotebookLM says nothing about its progress).
    public var estimated = false

    public var percent: Int? { fraction.map { Int(($0 * 100).rounded()) } }

    /// "69%", or "About 34%" when it's an estimate; nil when there's nothing to measure.
    public var percentText: String? { percent.map { estimated ? "About \($0)%" : "\($0)%" } }
}

public enum PrepProgress {
    public static func of(_ item: PrepActivity.Item, now: Double) -> ItemProgress {
        let elapsed = max(0, (now - item.started) / 1000)
        if let overall = item.fraction, overall > 0 {
            // The pipeline's own measure across every stage: exact, and the best guess at the time left.
            let fraction = min(0.99, max(0.02, overall))
            var parts: [String] = []
            if let total = item.total, total > 0 { parts.append("\(min(item.done ?? 0, total)) of \(total)") }
            if overall < 1, elapsed > 0 { parts.append(left(elapsed / overall * (1 - overall)).lowercased()) }
            let detail = parts.isEmpty ? "Almost there" : parts.joined(separator: " · ")
            return ItemProgress(fraction: fraction, step: item.step, by: item.by,
                                detail: detail.prefix(1).uppercased() + detail.dropFirst(), slow: false)
        }
        if let total = item.total, total > 0 {
            let done = min(item.done ?? 0, total)
            let fraction = min(0.99, max(0.02, Double(done) / Double(total)))
            var detail = "\(done) of \(total)"
            if done > 0, done < total {
                let remaining = elapsed / Double(done) * Double(total - done)
                detail += " · " + left(remaining).lowercased()
            }
            return ItemProgress(fraction: fraction, step: item.step, by: item.by, detail: detail, slow: false)
        }
        if let expected = item.expected, expected > 0 {
            let ratio = elapsed / expected
            // Reaches 90 % at the usual time, then creeps towards 99 % without ever claiming done.
            let fraction = ratio < 1 ? 0.9 * ratio : 0.9 + 0.09 * (1 - exp(-(ratio - 1)))
            let slow = ratio > 1.3
            let detail = slow
                ? "Taking longer than usual. It's still going: NotebookLM can be slow when it's busy."
                : left(expected - elapsed)
            return ItemProgress(fraction: max(0.02, fraction), step: item.step, by: item.by, detail: detail, slow: slow, estimated: true)
        }
        return ItemProgress(fraction: nil, step: item.step, by: item.by, detail: "Started \(minutes(elapsed)) ago", slow: false)
    }

    public static func placeText(_ place: Int) -> String {
        if place == 0 { return "Next up" }
        let n = place + 1
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix) in line"
    }

    static func left(_ seconds: Double) -> String {
        if seconds < 45 { return "Almost there" }
        return "About \(minutes(seconds)) left"
    }

    static func minutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m <= 1 ? "1 min" : "\(m) min"
    }
}
