// FSRS-4.5 spaced-repetition scheduler: the same rules as pipeline/site/src/core/fsrs.js.

import Foundation

public enum Rating: Int, Sendable { case again = 1, hard, good, easy }

/// A card's schedule, as stored in progress.json: `{s, d, reps, last, due}` (times in Unix milliseconds).
public struct CardState: Codable, Equatable, Sendable {
    public var s: Double
    public var d: Double
    public var reps: Int
    public var last: Double
    public var due: Double

    public init(s: Double = 0, d: Double = 0, reps: Int = 0, last: Double = 0, due: Double = 0) {
        (self.s, self.d, self.reps, self.last, self.due) = (s, d, reps, last, due)
    }
}

public enum FSRS {
    static let w: [Double] = [
        0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031, 1.6474, 0.1367, 1.0461, 2.1072, 0.0793, 0.3246,
        1.587, 0.2272, 2.8755,
    ]
    static let decay = -0.5
    static let factor = 19.0 / 81.0
    public static let dayMs = 86_400_000.0
    static let relearnMs = 10.0 * 60_000
    static let maxIntervalDays = 365.0

    public static func retrievability(elapsedDays: Double, stability: Double) -> Double {
        pow(1 + factor * elapsedDays / stability, decay)
    }

    /// Grade a card at time `now` (Unix ms); returns the updated state.
    public static func grade(_ card: CardState?, _ rating: Rating, now: Double) -> CardState {
        let card = card ?? CardState()
        let r = Double(rating.rawValue)
        var next = card
        if card.reps == 0 {
            next.s = w[rating.rawValue - 1]
            next.d = clamp(w[4] - (r - 3) * w[5])
        } else {
            let recall = retrievability(elapsedDays: (now - card.last) / dayMs, stability: card.s)
            let d = card.d
            next.d = clamp(w[7] * (w[4] - w[5]) + (1 - w[7]) * (d - w[6] * (r - 3)))
            if rating == .again {
                next.s = w[11] * pow(d, -w[12]) * (pow(card.s + 1, w[13]) - 1) * exp(w[14] * (1 - recall))
            } else {
                let hard = rating == .hard ? w[15] : 1
                let easy = rating == .easy ? w[16] : 1
                next.s = card.s * (1 + exp(w[8]) * (11 - d) * pow(card.s, -w[9]) * (exp(w[10] * (1 - recall)) - 1) * hard * easy)
            }
        }
        next.s = max(0.1, next.s)
        next.reps = card.reps + 1
        next.last = now
        next.due = rating == .again ? now + relearnMs : now + min(maxIntervalDays, max(1, next.s.rounded())) * dayMs
        return next
    }

    /// "10 min", "3 h", "4 d": how long until `due`.
    public static func formatWait(due: Double, now: Double) -> String {
        let ms = due - now
        if ms < 3_600_000 { return "\(max(1, Int((ms / 60_000).rounded()))) min" }
        if ms < dayMs { return "\(Int((ms / 3_600_000).rounded())) h" }
        return "\(Int((ms / dayMs).rounded())) d"
    }

    private static func clamp(_ d: Double) -> Double { min(10, max(1, d)) }
}
