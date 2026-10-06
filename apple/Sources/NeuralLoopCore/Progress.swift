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
    /// When each quiz, recall, remake, map position, and "where you left off" last changed, anywhere (Unix ms):
    /// "quiz.3", "recall.3", "remake.2", "mapPos.<id>", "last". Merging keeps the newest of each, so a device saving an
    /// older view never rolls back newer work. Files from before stamps count as 0 (then the newer file wins).
    public var stamps: [String: Double] = [:]
    /// What of each chapter's podcast and video has really played (spec 09): chapter -> played stretches.
    public var watch: [String: WatchProgress] = [:]
    /// Reading time each chapter's pages earned (spec 09): chapter -> pages, page count, furthest page.
    public var reading: [String: ReadingRecord] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case cards, loop, quiz, recall, remake, mapPos, mapSeen, last, log, updatedAt, stamps, watch, reading
    }

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
        stamps = ((try? c.decodeIfPresent([String: Lossy<Double>].self, forKey: .stamps)) ?? nil)?.compactMapValues(\.value) ?? [:]
        watch = ((try? c.decodeIfPresent([String: Lossy<WatchProgress>].self, forKey: .watch)) ?? nil)?
            .compactMapValues(\.value).filter { Int($0.key) != nil } ?? [:]
        reading = ((try? c.decodeIfPresent([String: Lossy<ReadingRecord>].self, forKey: .reading)) ?? nil)?
            .compactMapValues(\.value).filter { Int($0.key) != nil } ?? [:]
    }

    /// Watching and reading are left out while empty, so files from before them stay byte for byte the same.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cards, forKey: .cards)
        try c.encode(loop, forKey: .loop)
        try c.encode(quiz, forKey: .quiz)
        try c.encode(recall, forKey: .recall)
        try c.encode(remake, forKey: .remake)
        try c.encode(mapPos, forKey: .mapPos)
        try c.encode(mapSeen, forKey: .mapSeen)
        try c.encodeIfPresent(last, forKey: .last)
        try c.encode(log, forKey: .log)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(stamps, forKey: .stamps)
        if !watch.isEmpty { try c.encode(watch, forKey: .watch) }
        if !reading.isEmpty { try c.encode(reading, forKey: .reading) }
    }

    // Changes that carry their own time (use these rather than setting the fields, so merging knows what's newest).

    public mutating func setQuiz(_ key: String, _ value: JSONValue, now: Double) { quiz[key] = value; stamp("quiz.\(key)", now) }
    public mutating func setRecall(_ key: String, _ value: JSONValue, now: Double) { recall[key] = value; stamp("recall.\(key)", now) }
    public mutating func setRemake(_ key: String, _ value: JSONValue, now: Double) { remake[key] = value; stamp("remake.\(key)", now) }
    public mutating func setMapPos(_ id: String, _ point: [Double], now: Double) { mapPos[id] = point; stamp("mapPos.\(id)", now) }
    public mutating func setLast(_ resume: Resume, now: Double) { last = resume; stamp("last", now) }

    private mutating func stamp(_ key: String, _ now: Double) {
        stamps[key] = max(stamps[key] ?? 0, now)
        updatedAt = max(updatedAt, now)
    }

    /// Merge every device's progress. Cards: the latest review wins. Loop steps: done anywhere is done (earliest time).
    /// Watching: the union of what played anywhere. Reading: the most seconds for each page, the furthest page.
    /// Study log: seconds add up across devices (each device's own file holds only its own study time). Each quiz,
    /// recall, remake, map position, and where you left off: the newest stamp wins (a tie, as with files from before
    /// stamps, goes to the most recently updated device).
    public static func merged(_ devices: [StudyProgress]) -> StudyProgress {
        var out = StudyProgress()
        func newest<V>(_ field: WritableKeyPath<StudyProgress, [String: V]>, _ prefix: String, from device: StudyProgress) {
            for (key, value) in device[keyPath: field] where device.stamps["\(prefix).\(key)"] ?? 0 >= out.stamps["\(prefix).\(key)"] ?? 0 {
                out[keyPath: field][key] = value
            }
        }
        let ordered = devices.sorted { ($0.updatedAt, $0.stamps.count) < ($1.updatedAt, $1.stamps.count) }
        for device in ordered {
            for (id, card) in device.cards where card.last >= (out.cards[id]?.last ?? -1) { out.cards[id] = card }
            for (chapter, steps) in device.loop {
                out.loop[chapter, default: [:]].merge(steps) { min($0, $1) }
            }
            for (day, seconds) in device.log { out.log[day, default: 0] += seconds }
            out.watch.merge(device.watch) { $0.union($1) }
            out.reading.merge(device.reading) { $0.merged($1) }
            newest(\.quiz, "quiz", from: device)
            newest(\.recall, "recall", from: device)
            newest(\.remake, "remake", from: device)
            newest(\.mapPos, "mapPos", from: device)
            out.mapSeen = Array(Set(out.mapSeen).union(device.mapSeen)).sorted()
            if let last = device.last, device.stamps["last"] ?? 0 >= out.stamps["last"] ?? 0 { out.last = last }
            out.stamps.merge(device.stamps) { max($0, $1) }
            out.updatedAt = max(out.updatedAt, device.updatedAt)
        }
        return out
    }

    /// Two copies of this device's own file (two windows on one book, each saving its own): merged like devices,
    /// except study time, which both copies counted from the same start, so each day keeps the larger count.
    public static func mergedSameDevice(_ a: StudyProgress, _ b: StudyProgress) -> StudyProgress {
        var out = merged([a, b])
        out.log = a.log.merging(b.log) { max($0, $1) }
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
        let others = others(in: folder)
        return (own, others.isEmpty ? own : StudyProgress.merged([own] + others))
    }

    /// Every other device's progress for this book (their files, downloaded by sync, in `devices/<id>.json`).
    public static func others(in folder: URL) -> [StudyProgress] {
        let devices = folder.appendingPathComponent("devices", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(StudyProgress.self, from: $0) } }
    }

    /// A cheap fingerprint of the other devices' progress files (names, sizes, modification times): when it changes,
    /// sync brought something new and an open book should merge again.
    public static func devicesSignature(in folder: URL) -> String {
        let devices = folder.appendingPathComponent("devices", isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        return ((try? FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "json" }
            .map { url -> String in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return "\(url.lastPathComponent):\(values?.fileSize ?? 0):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }
            .sorted().joined(separator: "|")
    }

    /// Saves the merged view as this device's file, but with only this device's own study time.
    public static func save(_ merged: StudyProgress, ownLog: [String: Double], to folder: URL) {
        var mine = merged
        mine.log = ownLog
        save(mine, to: folder)
    }

    public static func save(_ progress: StudyProgress, to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys  // the same progress always makes the same bytes (so sync sends it once)
        guard let data = try? encoder.encode(progress) else { return }
        try? data.write(to: folder.appendingPathComponent("progress.json"), options: .atomic)
    }
}
