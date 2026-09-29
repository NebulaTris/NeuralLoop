// NotebookLM's live usage (`nl_book.py --usage`): how much of its five-hour and weekly windows is left, when each
// resets, and whether it can make a podcast or video right now. A podcast costs about 44% of the five-hour window.

import Foundation

public struct NotebookLMUsage: Decodable, Equatable, Sendable {
    public struct Window: Decodable, Equatable, Sendable {
        public let remaining: Double
        public let resetsAt: String

        public var resetDate: Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: resetsAt) { return d }
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: resetsAt)
        }
    }

    public let known: Bool
    public let available: Bool
    public let fiveHour: Window?
    public let weekly: Window?
    public let podcast: Bool
    public let video: Bool

    enum CodingKeys: String, CodingKey { case known, available, fiveHour, weekly, podcast, video }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        known = try c.decodeIfPresent(Bool.self, forKey: .known) ?? false
        available = try c.decodeIfPresent(Bool.self, forKey: .available) ?? false
        fiveHour = try c.decodeIfPresent(Window.self, forKey: .fiveHour)
        weekly = try c.decodeIfPresent(Window.self, forKey: .weekly)
        podcast = try c.decodeIfPresent(Bool.self, forKey: .podcast) ?? false
        video = try c.decodeIfPresent(Bool.self, forKey: .video) ?? false
    }

    public static func parse(_ line: String) -> NotebookLMUsage? {
        guard line.hasPrefix("NotebookLM usage: ") else { return nil }
        return try? JSONDecoder().decode(NotebookLMUsage.self, from: Data(line.dropFirst("NotebookLM usage: ".count).utf8))
    }

    /// Whether NotebookLM can make this item now (podcasts and videos have their own, bigger costs).
    public func canMake(_ item: String) -> Bool {
        guard known && available else { return false }
        switch item {
        case "audio": return podcast
        case "video": return video
        default: return true
        }
    }
}
