// How much of a chapter's podcast or video has actually been played (spec 09): the union of the stretches of media
// time that played at a believable speed. Seeking, scrubbing, playing faster than 2x, and replaying add nothing.

import Foundation

public struct PlayCoverage: Equatable, Sendable {
    /// Sorted, non-overlapping [start, end] stretches of media time, in seconds.
    public private(set) var spans: [[Double]] = []

    /// Faster than this is skimming by ear: it doesn't count.
    public static let fastestRate = 2.0
    /// Slack for each reported stretch (timers drift a little); anything further ahead is a seek.
    public static let slack = 0.75

    public init() {}

    /// Spans from a file or another device, tidied: bad ones dropped, the rest sorted and joined.
    public init(_ spans: [[Double]]) {
        for span in spans where span.count == 2 { insert(span[0], span[1]) }
    }

    /// One stretch of playback, reported by a player: media time moved from `from` to `to` while `wallSeconds` passed
    /// at `rate`. Counts only when that's believable: forwards, at most 2x, and no further than the rate allows (a
    /// jump further than that is a seek or a scrub). Returns whether it counted.
    @discardableResult
    public mutating func add(from: Double, to: Double, rate: Double, wallSeconds: Double) -> Bool {
        guard from.isFinite, to.isFinite, rate.isFinite, wallSeconds.isFinite, wallSeconds > 0,
              rate > 0, rate <= Self.fastestRate + 1e-6 else { return false }
        let advance = to - from
        guard advance > 0, advance <= rate * wallSeconds + Self.slack,
              advance <= Self.fastestRate * wallSeconds + Self.slack else { return false }
        insert(max(0, from), to)
        return true
    }

    /// Adds a stretch as a union with what's there.
    public mutating func insert(_ start: Double, _ end: Double) {
        guard start.isFinite, end.isFinite, end > start else { return }
        var (lo, hi) = (start, end)
        var kept: [[Double]] = []
        for span in spans {
            if span[1] < lo || span[0] > hi { kept.append(span) } else { (lo, hi) = (min(lo, span[0]), max(hi, span[1])) }
        }
        kept.append([lo, hi])
        spans = kept.sorted { $0[0] < $1[0] }
    }

    public func union(_ other: PlayCoverage) -> PlayCoverage {
        var out = self
        for span in other.spans { out.insert(span[0], span[1]) }
        return out
    }

    /// Seconds played inside [0, duration].
    public func seconds(within duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return spans.reduce(0) { $0 + max(0, min($1[1], duration) - max($1[0], 0)) }
    }

    /// Share of the media played, 0…1 (0 while the length isn't known).
    public func fraction(_ duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, seconds(within: duration) / duration)
    }
}

extension PlayCoverage: Codable {
    /// Written as [[start, end], …] to a tenth of a second; a bad span is skipped, a bad list is empty.
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode([Lossy<[Double]>].self)) ?? []
        self.init(raw.compactMap(\.value))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(spans.map { $0.map { ($0 * 10).rounded() / 10 } })
    }
}

public enum WatchKind: String, Codable, Sendable { case audio, video }

/// One chapter's played stretches: the podcast and the video, separately.
public struct WatchProgress: Codable, Equatable, Sendable {
    public var audio = PlayCoverage()
    public var video = PlayCoverage()

    public init(audio: PlayCoverage = PlayCoverage(), video: PlayCoverage = PlayCoverage()) { (self.audio, self.video) = (audio, video) }

    enum CodingKeys: String, CodingKey { case audio, video }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audio = ((try? c.decodeIfPresent(PlayCoverage.self, forKey: .audio)) ?? nil) ?? PlayCoverage()
        video = ((try? c.decodeIfPresent(PlayCoverage.self, forKey: .video)) ?? nil) ?? PlayCoverage()
    }

    public subscript(kind: WatchKind) -> PlayCoverage {
        get { kind == .audio ? audio : video }
        set { if kind == .audio { audio = newValue } else { video = newValue } }
    }

    public func union(_ other: WatchProgress) -> WatchProgress {
        WatchProgress(audio: audio.union(other.audio), video: video.union(other.video))
    }
}

/// The Listen & watch step: done once most of the podcast or most of the video has played.
public enum Listening {
    public static let enough = 0.85

    /// The larger of the podcast's and the video's played share (a length that isn't known yet counts as 0).
    public static func share(_ watch: WatchProgress?, audioLength: Double?, videoLength: Double?) -> Double {
        guard let watch else { return 0 }
        return max(watch.audio.fraction(audioLength ?? 0), watch.video.fraction(videoLength ?? 0))
    }

    public static func isDone(_ watch: WatchProgress?, audioLength: Double?, videoLength: Double?) -> Bool {
        share(watch, audioLength: audioLength, videoLength: videoLength) >= enough - 1e-9
    }
}
