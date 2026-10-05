// Reading time that counts (spec 09): a page earns seconds only while someone is there (the app active, the reading
// window visible, input in the last 90 s) and the page is on screen. A page is read once it has had at least
// max(6 s, its words at 600 words a minute); the Read step is done when 85% of pages are read and the last was reached.

import Foundation

/// One chapter's reading: credited seconds per page (0-based index, as a string key), how many pages it had, and the
/// furthest page reached while reading.
public struct ReadingRecord: Codable, Equatable, Sendable {
    public var pages: [String: Double] = [:]
    public var count = 0
    public var last: Int?

    public init(pages: [String: Double] = [:], count: Int = 0, last: Int? = nil) {
        (self.pages, self.count, self.last) = (pages, count, last)
    }

    enum CodingKeys: String, CodingKey { case pages, count, last }

    /// Lenient: a bad page entry is skipped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pages = ((try? c.decodeIfPresent([String: Lossy<Double>].self, forKey: .pages)) ?? nil)?
            .compactMapValues(\.value).filter { $0.value.isFinite && $0.value >= 0 } ?? [:]
        count = max(0, ((try? c.decodeIfPresent(Int.self, forKey: .count)) ?? nil) ?? 0)
        last = (try? c.decodeIfPresent(Int.self, forKey: .last)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pages.mapValues { ($0 * 10).rounded() / 10 }, forKey: .pages)
        try c.encode(count, forKey: .count)
        try c.encodeIfPresent(last, forKey: .last)
    }

    /// Two devices' reading: the most seconds for each page, the larger count, the furthest page.
    public func merged(_ other: ReadingRecord) -> ReadingRecord {
        ReadingRecord(pages: pages.merging(other.pages) { max($0, $1) }, count: max(count, other.count),
                      last: [last, other.last].compactMap { $0 }.max())
    }
}

public struct ReadingProgress: Equatable, Sendable {
    public var counted: Int
    public var total: Int
    public var reachedLast: Bool

    public init(counted: Int, total: Int, reachedLast: Bool) { (self.counted, self.total, self.reachedLast) = (counted, total, reachedLast) }

    public var fraction: Double { total > 0 ? Double(counted) / Double(total) : 0 }
    public var done: Bool { total > 0 && reachedLast && fraction >= ReadingCredit.enough - 1e-9 }
}

public enum ReadingCredit {
    /// No input for this long and the reader has probably wandered off.
    public static let idleLimit = 90.0
    public static let minimumSeconds = 6.0
    /// Fast skimming; turning pages faster than this isn't reading.
    public static let fastestWordsPerMinute = 600.0
    public static let enough = 0.85
    /// Text chapters are read in sections of about this many words.
    public static let sectionWords = 300
    /// One tick never credits more than this (a timer that fired late, a Mac that slept).
    public static let longestTick = 2.0

    public static func needed(words: Int) -> Double { max(minimumSeconds, Double(max(0, words)) / fastestWordsPerMinute * 60) }

    /// Whether this moment counts as reading at all. `lastInput` and `now` are in seconds.
    public static func earning(now: Double, lastInput: Double?, appActive: Bool, windowVisible: Bool) -> Bool {
        guard appActive, windowVisible, let lastInput else { return false }
        return now - lastInput <= idleLimit
    }

    /// Credits one tick to the pages on screen, shared between them. Returns whether anything was credited.
    @discardableResult
    public static func credit(_ record: inout ReadingRecord, visible: [Int], seconds: Double, pageCount: Int, earning: Bool) -> Bool {
        let pages = Set(visible.filter { $0 >= 0 && $0 < pageCount })
        guard earning, !pages.isEmpty, seconds.isFinite, seconds > 0 else { return false }
        let share = min(seconds, longestTick) / Double(pages.count)
        for page in pages { record.pages[String(page), default: 0] += share }
        record.count = pageCount
        record.last = max(record.last ?? 0, pages.max() ?? 0)
        return true
    }

    /// How far along the reading is, given what each page needs (`needed(words:)`, one per page).
    public static func progress(_ record: ReadingRecord?, needs: [Double]) -> ReadingProgress {
        let pages = record?.pages ?? [:]
        let counted = needs.indices.filter { (pages[String($0)] ?? 0) >= needs[$0] - 1e-9 }.count
        let reached = !needs.isEmpty && (record?.last ?? -1) >= needs.count - 1
        return ReadingProgress(counted: counted, total: needs.count, reachedLast: reached)
    }

    /// Where a page sits on screen (any vertical unit, as long as the window uses the same).
    public struct Span: Equatable, Sendable {
        public var page: Int
        public var top: Double
        public var bottom: Double
        public init(page: Int, top: Double, bottom: Double) { (self.page, self.top, self.bottom) = (page, top, bottom) }
    }

    /// The pages that really are on screen: at least 40% of the page, or a page filling at least 40% of the window.
    public static func visible(_ spans: [Span], top: Double, bottom: Double) -> [Int] {
        let window = bottom - top
        guard window > 0 else { return [] }
        return spans.filter { span in
            let height = span.bottom - span.top
            let shown = min(span.bottom, bottom) - max(span.top, top)
            return height > 0 && shown > 0 && (shown >= 0.4 * height || shown >= 0.4 * window)
        }
        .map(\.page).sorted()
    }

    /// Groups a text chapter's blocks (paragraphs, headings, figures) into sections of about 300 words: each section
    /// is the block indices it holds.
    public static func sections(_ blocks: [String]) -> [[Int]] {
        var out: [[Int]] = [], current: [Int] = [], words = 0
        for (index, block) in blocks.enumerated() {
            current.append(index)
            words += self.words(block)
            if words >= sectionWords { out.append(current); (current, words) = ([], 0) }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Words in a piece of text: runs with at least one letter or digit (a figure's Markdown counts as none).
    public static func words(_ text: String) -> Int {
        if text.hasPrefix("![") { return 0 }
        return text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }
}
