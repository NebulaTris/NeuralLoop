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

@Test func twoCopiesOfThisDevicesFileMergeWithoutCountingStudyTimeTwice() throws {
    // Two windows on one book: each kept its own copy; the file on disk has the other window's reviews and steps.
    let mine = try progress(#"{"cards":{"1:0":{"s":3,"d":5,"reps":1,"last":100,"due":500}},"loop":{"1":{"prime":10}},"log":{"2026-09-28":600},"updatedAt":100}"#)
    let disk = try progress(#"{"cards":{"1:1":{"s":3,"d":5,"reps":1,"last":200,"due":600}},"loop":{"1":{"read":20}},"log":{"2026-09-28":615,"2026-09-27":30},"updatedAt":200}"#)
    let merged = StudyProgress.mergedSameDevice(mine, disk)
    #expect(Set(merged.cards.keys) == ["1:0", "1:1"])
    #expect(merged.loop["1"] == ["prime": 10, "read": 20])
    #expect(merged.log == ["2026-09-28": 615, "2026-09-27": 30])
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

// Every quiz, recall, remake, map position, and "where you left off" carries its own time (stamps), so a device that
// saves an older merged view never rolls back what another device did later.
@Test func aStaleSessionsSaveDoesNotRollBackAnotherDevicesNewerWork() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("devices"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    // The Mac opened the book at t=1000 and keeps that view in memory.
    var mac = StudyProgress()
    mac.setQuiz("3", .object(["i": .number(1)]), now: 500)
    mac.setRemake("2", .object(["guess": .string("old")]), now: 500)
    mac.setLast(Resume(n: 1, stage: "read"), now: 500)
    mac.log = ["2026-09-29": 60]
    ProgressFile.save(mac, ownLog: mac.log, to: folder)
    let session = ProgressFile.loadMerged(from: folder)
    // Meanwhile the iPad did more (its file arrives through sync).
    var ipad = session.merged
    ipad.log = ["2026-09-29": 30]
    ipad.setQuiz("3", .object(["i": .number(4)]), now: 2000)
    ipad.setRemake("2", .object(["guess": .string("new")]), now: 2000)
    ipad.setLast(Resume(n: 2, stage: "recall"), now: 2000)
    ipad.setMapPos("k1", [5, 6], now: 2000)
    try JSONEncoder().encode(ipad).write(to: folder.appendingPathComponent("devices/ipad1.json"))
    // The stale Mac session changes something else later and saves its whole (old) view.
    var stale = session.merged
    stale.setQuiz("5", .object(["i": .number(2)]), now: 3000)
    stale.setMapPos("k1", [1, 1], now: 100)
    ProgressFile.save(stale, ownLog: session.own.log, to: folder)

    for merged in [ProgressFile.loadMerged(from: folder).merged,
                   StudyProgress.merged([ipad, ProgressFile.load(from: folder)])] {  // as the iPad sees it
        #expect(merged.quiz["3"] == .object(["i": .number(4)]) && merged.quiz["5"] == .object(["i": .number(2)]))
        #expect(merged.remake["2"] == .object(["guess": .string("new")]))
        #expect(merged.last == Resume(n: 2, stage: "recall") && merged.mapPos["k1"] == [5, 6])
        #expect(merged.log == ["2026-09-29": 90])
    }
    #expect(ProgressFile.load(from: folder).log == ["2026-09-29": 60])  // own study time only
}

@Test func mergingIsIdempotentAndOrderFree() throws {
    var a = StudyProgress(), b = StudyProgress()
    a.setQuiz("1", .string("a"), now: 10); a.setLast(Resume(n: 1, stage: "read"), now: 40); a.log = ["d": 10]
    b.setQuiz("1", .string("b"), now: 20); b.setRemake("1", .string("b"), now: 5); b.log = ["d": 5]
    b.setLast(Resume(n: 3, stage: "map"), now: 30)
    let once = StudyProgress.merged([a, b])
    var saved = once
    saved.log = a.log  // what device a writes back
    #expect(StudyProgress.merged([saved, b]) == once && StudyProgress.merged([b, saved]) == once)
    #expect(StudyProgress.merged([b, a]) == once)
    #expect(once.quiz["1"] == .string("b") && once.last == Resume(n: 1, stage: "read") && once.log == ["d": 15])
}

@Test func stampsRoundTripAndOldFilesHaveNone() throws {
    let old = try progress(#"{"quiz":{"1":{"i":1}},"updatedAt":5}"#)
    #expect(old.stamps.isEmpty)
    let odd = try progress(#"{"stamps":{"quiz.1":7,"bad":"x"}}"#)
    #expect(odd.stamps == ["quiz.1": 7])
    var p = StudyProgress()
    p.setQuiz("2", .bool(true), now: 9)
    #expect(try JSONDecoder().decode(StudyProgress.self, from: JSONEncoder().encode(p)) == p)
    #expect(p.stamps == ["quiz.2": 9] && p.updatedAt == 9)
}

@Test func theDevicesSignatureChangesWhenAnotherDevicesFileDoes() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("devices"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let empty = ProgressFile.devicesSignature(in: folder)
    try Data("{}".utf8).write(to: folder.appendingPathComponent("devices/ipad1.json"))
    let one = ProgressFile.devicesSignature(in: folder)
    #expect(one != empty && ProgressFile.devicesSignature(in: folder) == one)
    try Data(#"{"log":{}}"#.utf8).write(to: folder.appendingPathComponent("devices/ipad1.json"))
    #expect(ProgressFile.devicesSignature(in: folder) != one)
    try Data("{}".utf8).write(to: folder.appendingPathComponent("progress.json"))  // our own file doesn't count
    #expect(ProgressFile.devicesSignature(in: folder) == ProgressFile.devicesSignature(in: folder))
}

@Test func theDevicesSignatureSeesASameSizeRewriteAndIgnoresOtherFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("devices"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("devices/ipad1.json")
    try Data(#"{"a":1}"#.utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path)
    let before = ProgressFile.devicesSignature(in: folder)
    // Sync rewrites the iPad's file with the same size: only the modification time tells.
    try Data(#"{"a":2}"#.utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: file.path)
    let after = ProgressFile.devicesSignature(in: folder)
    #expect(after != before)
    try Data("x".utf8).write(to: folder.appendingPathComponent("devices/notes.txt"))
    #expect(ProgressFile.devicesSignature(in: folder) == after)
}
