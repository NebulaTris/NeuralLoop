import Foundation
import Testing
@testable import NeuralLoopCore

func progress(_ json: String) throws -> StudyProgress {
    try JSONDecoder().decode(StudyProgress.self, from: Data(json.utf8))
}

@Test func readsWhatTheStudySiteWrites() throws {
    let p = try progress("""
    {"cards":{"1:0":{"s":3.7,"d":5.2,"reps":1,"last":100,"due":400}},"quiz":{"1":{"score":2}},
     "loop":{"1":{"prime":10,"read":20,"closedShown":true}},"mapPos":{"k1":[1,2]},"mapSeen":[1],
     "last":{"n":1,"stage":"recall"},"log":{"2026-09-28":900}}
    """)
    #expect(p.cards["1:0"]?.reps == 1 && p.loop["1"]?["closedShown"] == 1 && p.log["2026-09-28"] == 900)
    #expect(p.last == Resume(n: 1, stage: "recall"))
}

@Test func twoDevicesReviewingTheSameCardKeepTheLatestReview() throws {
    let mac = try progress(#"{"cards":{"1:0":{"s":3,"d":5,"reps":1,"last":100,"due":500}},"updatedAt":900}"#)
    let ipad = try progress(#"{"cards":{"1:0":{"s":9,"d":4,"reps":2,"last":700,"due":9000}},"updatedAt":800}"#)
    let merged = StudyProgress.merged([mac, ipad])
    #expect(merged.cards["1:0"]?.reps == 2 && merged.cards["1:0"]?.last == 700)
}

@Test func aStepDoneAnywhereIsDone() throws {
    let mac = try progress(#"{"loop":{"1":{"prime":30,"read":40}}}"#)
    let ipad = try progress(#"{"loop":{"1":{"prime":10,"recall":50}},"updatedAt":5}"#)
    #expect(StudyProgress.merged([mac, ipad]).loop["1"] == ["prime": 10, "read": 40, "recall": 50])
}

@Test func studyTimeAddsUpAcrossDevices() throws {
    let mac = try progress(#"{"log":{"2026-09-28":600,"2026-09-27":60}}"#)
    let ipad = try progress(#"{"log":{"2026-09-28":300}}"#)
    #expect(StudyProgress.merged([mac, ipad]).log == ["2026-09-28": 900, "2026-09-27": 60])
}

@Test func aDeviceSavesTheMergedViewButOnlyItsOwnStudyTime() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("devices"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data(#"{"log":{"2026-09-28":600},"loop":{"1":{"prime":5}}}"#.utf8).write(to: folder.appendingPathComponent("progress.json"))
    try Data(#"{"log":{"2026-09-28":300},"loop":{"1":{"read":9}}}"#.utf8).write(to: folder.appendingPathComponent("devices/ipad1.json"))
    let (own, merged) = ProgressFile.loadMerged(from: folder)
    #expect(merged.log == ["2026-09-28": 900] && merged.loop["1"] == ["prime": 5, "read": 9])
    ProgressFile.save(merged, ownLog: own.log, to: folder)
    let again = ProgressFile.loadMerged(from: folder)
    #expect(again.own.log == ["2026-09-28": 600] && again.merged.log == ["2026-09-28": 900])  // syncing again never inflates it
}

@Test func oneOddEntryDoesNotLoseTheRest() throws {
    let p = try progress("""
    {"cards":{"1:0":{"s":3,"d":5,"reps":1,"last":100,"due":400},"1:1":{"s":"oops"}},"log":{"2026-09-28":900,"x":"y"},
     "loop":{"1":{"prime":10,"read":"soon"}},"mapPos":{"a":[1,2],"b":[1]},"quiz":7,"updatedAt":"later"}
    """)
    #expect(p.cards.keys.sorted() == ["1:0"] && p.log == ["2026-09-28": 900] && p.loop["1"] == ["prime": 10])
    #expect(p.mapPos == ["a": [1, 2]] && p.quiz.isEmpty && p.updatedAt == 0)
}

@Test func anUnreadableProgressFileIsKeptAsideNotOverwritten() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(ProgressFile.load(from: folder) == StudyProgress())
    try Data("{not json".utf8).write(to: folder.appendingPathComponent("progress.json"))
    #expect(ProgressFile.load(from: folder, now: Date(timeIntervalSince1970: 42)) == StudyProgress())
    let kept = folder.appendingPathComponent("progress.json.unreadable-42")
    #expect(try String(contentsOf: kept, encoding: .utf8) == "{not json")
}

@Test func whereYouLeftOffComesFromTheLatestDevice() throws {
    let mac = try progress(#"{"last":{"n":1,"stage":"read"},"mapSeen":[1],"updatedAt":100}"#)
    let ipad = try progress(#"{"last":{"n":2,"stage":"prime"},"mapSeen":[2],"updatedAt":200}"#)
    let merged = StudyProgress.merged([ipad, mac])  // order of files doesn't matter
    #expect(merged.last == Resume(n: 2, stage: "prime") && merged.mapSeen == [1, 2] && merged.updatedAt == 200)
}
