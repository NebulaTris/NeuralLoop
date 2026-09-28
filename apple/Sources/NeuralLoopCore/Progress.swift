// Study progress (progress.json), and merging every device's copy without losing anything (spec 07).

import Foundation

/// Any JSON value, for the parts of progress the core passes through untouched (quiz answers, recall notes, …).
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

public struct Resume: Codable, Equatable, Sendable {
    public var n: Int
    public var stage: String
    public init(n: Int, stage: String) { (self.n, self.stage) = (n, stage) }
}

/// One device's progress for one book. Field names match progress.json and the study site's store.
public struct StudyProgress: Codable, Equatable, Sendable {
    public var cards: [String: CardState] = [:]
    public var loop: [String: [String: Double]] = [:]      // chapter -> step -> time done (closedShown as 1)
    public var quiz: [String: JSONValue] = [:]
    public var recall: [String: JSONValue] = [:]
    public var remake: [String: JSONValue] = [:]
    public var mapPos: [String: [Double]] = [:]
    public var mapSeen: [Int] = []
    public var last: Resume?
    public var log: [String: Double] = [:]                 // local day -> seconds studied
    public var updatedAt: Double = 0                        // when this device last changed anything (Unix ms)

    public init() {}

    enum CodingKeys: String, CodingKey { case cards, loop, quiz, recall, remake, mapPos, mapSeen, last, log, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cards = try c.decodeIfPresent([String: CardState].self, forKey: .cards) ?? [:]
        loop = try c.decodeIfPresent([String: [String: FlexibleNumber]].self, forKey: .loop)?
            .mapValues { $0.mapValues(\.value) } ?? [:]
        quiz = try c.decodeIfPresent([String: JSONValue].self, forKey: .quiz) ?? [:]
        recall = try c.decodeIfPresent([String: JSONValue].self, forKey: .recall) ?? [:]
        remake = try c.decodeIfPresent([String: JSONValue].self, forKey: .remake) ?? [:]
        mapPos = try c.decodeIfPresent([String: [Double]].self, forKey: .mapPos) ?? [:]
        mapSeen = try c.decodeIfPresent([Int].self, forKey: .mapSeen) ?? []
        last = try c.decodeIfPresent(Resume.self, forKey: .last)
        log = try c.decodeIfPresent([String: Double].self, forKey: .log) ?? [:]
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
    }

    /// Merge every device's progress. Cards: the latest review wins. Loop steps: done anywhere is done (earliest time).
    /// Study log: seconds add up across devices. Quiz, recall, remake, map positions, and where you left off: the most
    /// recently updated device wins.
    public static func merged(_ devices: [StudyProgress]) -> StudyProgress {
        var out = StudyProgress()
        for device in devices.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            for (id, card) in device.cards where card.last >= (out.cards[id]?.last ?? -1) { out.cards[id] = card }
            for (chapter, steps) in device.loop {
                out.loop[chapter, default: [:]].merge(steps) { min($0, $1) }
            }
            for (day, seconds) in device.log { out.log[day, default: 0] += seconds }
            out.quiz.merge(device.quiz) { $1 }
            out.recall.merge(device.recall) { $1 }
            out.remake.merge(device.remake) { $1 }
            out.mapPos.merge(device.mapPos) { $1 }
            out.mapSeen = Array(Set(out.mapSeen).union(device.mapSeen)).sorted()
            out.last = device.last ?? out.last
            out.updatedAt = max(out.updatedAt, device.updatedAt)
        }
        return out
    }
}

/// The study site writes `true` for closedShown and timestamps for steps; accept both as numbers.
struct FlexibleNumber: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = b ? 1 : 0 } else { value = try c.decode(Double.self) }
    }
}
