import Foundation
import Testing
@testable import NeuralLoopCore

/// Plays from `start` to `end` in one-second ticks at `rate`, the way the shared players report it.
func play(_ c: inout PlayCoverage, _ start: Double, _ end: Double, rate: Double = 1) {
    var t = start
    while t < end {
        let next = min(end, t + rate)
        c.add(from: t, to: next, rate: rate, wallSeconds: 1)
        t = next
    }
}

@Test func playingStraightThroughCoversTheWholeThing() {
    var c = PlayCoverage()
    play(&c, 0, 100)
    #expect(c.spans == [[0, 100]] && c.fraction(100) == 1)
}

@Test func aSeekDoesNotCountTheSkippedPart() {
    var c = PlayCoverage()
    play(&c, 0, 10)
    do { let result = c.add(from: 10, to: 80, rate: 1, wallSeconds: 1); #expect(!result) }  // dragged the bar to 80
    play(&c, 80, 100)
    #expect(c.spans == [[0, 10], [80, 100]] && abs(c.fraction(100) - 0.3) < 1e-9)
}

@Test func scrubbingInSmallJumpsCountsNothing() {
    var c = PlayCoverage()
    for start in stride(from: 0.0, to: 100, by: 15) { c.add(from: start, to: start + 15, rate: 1, wallSeconds: 0.2) }
    #expect(c.fraction(100) == 0)
}

@Test func faster_than_double_speed_does_not_count_but_double_speed_does() {
    var c = PlayCoverage()
    do { let result = c.add(from: 0, to: 3, rate: 3, wallSeconds: 1); #expect(!result) }
    do { let result = c.add(from: 0, to: 2, rate: 2, wallSeconds: 1); #expect(result) }
    #expect(c.spans == [[0, 2]])
    // A player that claims 1x but moves 5 seconds a second is seeking, whatever it says.
    do { let result = c.add(from: 2, to: 7, rate: 1, wallSeconds: 1); #expect(!result) }
}

@Test func replayingTheSamePartDoesNotCountTwice() {
    var c = PlayCoverage()
    play(&c, 0, 40)
    play(&c, 0, 40)
    play(&c, 30, 50)
    #expect(c.spans == [[0, 50]] && c.fraction(100) == 0.5)
}

@Test func goingBackwardsOrStandingStillAddsNothing() {
    var c = PlayCoverage()
    do { let result = c.add(from: 20, to: 10, rate: 1, wallSeconds: 1); #expect(!result) }
    do { let result = c.add(from: 5, to: 5, rate: 1, wallSeconds: 1); #expect(!result) }
    do { let result = c.add(from: 0, to: 1, rate: 0, wallSeconds: 1); #expect(!result) }
    do { let result = c.add(from: 0, to: .nan, rate: 1, wallSeconds: 1); #expect(!result) }
    #expect(c.spans.isEmpty && c.fraction(0) == 0)
}

@Test func coveragePastTheEndIsClippedToTheLength() {
    let c = PlayCoverage([[90, 130]])
    #expect(c.fraction(100) == 0.1)
}

@Test func spansFromAFileAreTidied() {
    let c = PlayCoverage([[30, 40], [0, 10], [5, 20], [50, 45], [60, 60]])
    #expect(c.spans == [[0, 20], [30, 40]])
    #expect(c.union(PlayCoverage([[15, 35]])).spans == [[0, 40]])
}

@Test func listeningIsDoneAtEightyFivePercentOfThePodcastOrTheVideo() {
    var w = WatchProgress()
    w.audio = PlayCoverage([[0, 84]])
    #expect(!Listening.isDone(w, audioLength: 100, videoLength: 50))
    w.audio = PlayCoverage([[0, 85]])
    #expect(Listening.isDone(w, audioLength: 100, videoLength: nil))
    w = WatchProgress(audio: PlayCoverage(), video: PlayCoverage([[0, 43]]))
    #expect(Listening.isDone(w, audioLength: 100, videoLength: 50))
    #expect(!Listening.isDone(w, audioLength: 100, videoLength: nil))  // length not known yet: not yet
    #expect(!Listening.isDone(nil, audioLength: 100, videoLength: 50))
    #expect(Listening.share(w, audioLength: 100, videoLength: 50) == 0.86)
}

@Test func watchProgressRoundTripsCompactlyAndSkipsBadSpans() throws {
    let p = try progress(#"{"watch":{"2":{"audio":[[0,12.34],[20,"x"],[5]],"video":"nope"},"x":7}}"#)
    #expect(p.watch["2"]?.audio.spans == [[0, 12.34]] && p.watch["2"]?.video.spans == [] && p.watch["x"] == nil)
    let again = try JSONDecoder().decode(StudyProgress.self, from: JSONEncoder().encode(p))
    #expect(again.watch["2"]?.audio.spans == [[0, 12.3]])  // a tenth of a second is plenty
}

@Test func watchingOnTwoDevicesAddsUpAsAUnion() throws {
    let mac = try progress(#"{"watch":{"1":{"audio":[[0,50]],"video":[]}}}"#)
    let ipad = try progress(#"{"watch":{"1":{"audio":[[40,90]],"video":[[0,10]]},"2":{"audio":[[0,5]],"video":[]}}}"#)
    let merged = StudyProgress.merged([mac, ipad])
    #expect(merged.watch["1"]?.audio.spans == [[0, 90]] && merged.watch["1"]?.video.spans == [[0, 10]])
    #expect(merged.watch["2"]?.audio.spans == [[0, 5]])
    #expect(StudyProgress.merged([merged, ipad]) == merged)
}

@Test func filesWithoutWatchingOrReadingStayByteForByteTheSame() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let text = String(decoding: try encoder.encode(StudyProgress()), as: UTF8.self)
    #expect(!text.contains("watch") && !text.contains("reading"))
}
