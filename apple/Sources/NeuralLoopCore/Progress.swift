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

    /// Lenient: one odd card, day, or field (from an older or newer app, or a half-finished edit) is skipped rather
    /// than losing everything else.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cards = ((try? c.decodeIfPresent([String: Lossy<CardState>].self, forKey: .cards)) ?? nil)?.compactMapValues(\.value) ?? [:]
        loop = ((try? c.decodeIfPresent([String: [String: Lossy<FlexibleNumber>]].self, forKey: .loop)) ?? nil)?
            .mapValues { $0.compactMapValues { $0.value?.value } } ?? [:]
        quiz = ((try? c.decodeIfPresent([String: JSONValue].self, forKey: .quiz)) ?? nil) ?? [:]
        recall = ((try? c.decodeIfPresent([String: JSONValue].self, forKey: .recall)) ?? nil) ?? [:]
        remake = ((try? c.decodeIfPresent([String: JSONValue].self, forKey: .remake)) ?? nil) ?? [:]
        mapPos = ((try? c.decodeIfPresent([String: Lossy<[Double]>].self, forKey: .mapPos)) ?? nil)?
            .compactMapValues(\.value).filter { $0.value.count == 2 } ?? [:]
        mapSeen = ((try? c.decodeIfPresent([Lossy<Int>].self, forKey: .mapSeen)) ?? nil)?.compactMap(\.value) ?? []
        last = (try? c.decodeIfPresent(Resume.self, forKey: .last)) ?? nil
        log = ((try? c.decodeIfPresent([String: Lossy<Double>].self, forKey: .log)) ?? nil)?.compactMapValues(\.value) ?? [:]
        updatedAt = ((try? c.decodeIfPresent(Double.self, forKey: .updatedAt)) ?? nil) ?? 0
    }

    /// Merge every device's progress. Cards: the latest review wins. Loop steps: done anywhere is done (earliest time).
    /// Study log: seconds add up across devices (each device's own file holds only its own study time). Quiz, recall, remake, map positions, and where you left off: the most
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

/// Decodes to nil instead of failing, so one bad entry doesn't take its neighbours down with it.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// progress.json on disk: a missing file is a fresh start; a file that isn't readable JSON is kept aside
/// (progress.json.unreadable-<time>) before starting fresh, so nothing is ever overwritten silently.
public enum ProgressFile {
    public static func load(from folder: URL, now: Date = Date()) -> StudyProgress {
        let file = folder.appendingPathComponent("progress.json")
        guard let data = try? Data(contentsOf: file) else { return StudyProgress() }
        if let progress = try? JSONDecoder().decode(StudyProgress.self, from: data) { return progress }
        let aside = folder.appendingPathComponent("progress.json.unreadable-\(Int(now.timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: file, to: aside)
        return StudyProgress()
    }

    /// This device's own progress and the view with every other device's merged in (their files, downloaded by sync,
    /// sit in `devices/<id>.json`). Show `merged`; save changes with `save(merged, ownLog:)` so another device's study
    /// time never ends up in this device's file.
    public static func loadMerged(from folder: URL) -> (own: StudyProgress, merged: StudyProgress) {
        let own = load(from: folder)
        let devices = folder.appendingPathComponent("devices", isDirectory: true)
        let others = ((try? FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(StudyProgress.self, from: $0) } }
        return (own, others.isEmpty ? own : StudyProgress.merged([own] + others))
    }

    /// Saves the merged view as this device's file, but with only this device's own study time.
    public static func save(_ merged: StudyProgress, ownLog: [String: Double], to folder: URL) {
        var mine = merged
        mine.log = ownLog
        save(mine, to: folder)
    }

    public static func save(_ progress: StudyProgress, to folder: URL) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        try? data.write(to: folder.appendingPathComponent("progress.json"), options: .atomic)
    }
}
