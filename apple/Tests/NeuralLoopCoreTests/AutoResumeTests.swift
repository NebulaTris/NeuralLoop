import Foundation
import Testing
@testable import NeuralLoopCore

private let minute = 60_000.0

@Test func setupProblemsWaitForNewSettingsInsteadOfRetryingForever() {
    let setup = RunRecord.after(nil, code: 3, now: 1000)
    #expect(!AutoResume.mayStart(after: setup, settingsChangedAt: 0, now: 1000 + 600 * minute))
    #expect(AutoResume.mayStart(after: setup, settingsChangedAt: 2000, now: 3000))
    #expect(!AutoResume.mayStart(after: RunRecord.after(nil, code: 2, now: 1000), settingsChangedAt: 0, now: 1_000_000_000))
}

@Test func otherFailuresBackOffAndSuccessResets() {
    let once = RunRecord.after(nil, code: 1, now: 0)
    #expect(!AutoResume.mayStart(after: once, settingsChangedAt: 0, now: 4 * minute))
    #expect(AutoResume.mayStart(after: once, settingsChangedAt: 0, now: 5 * minute))
    let thrice = RunRecord.after(RunRecord.after(once, code: 1, now: 0), code: 1, now: 0)
    #expect(thrice.failuresInARow == 3 && !AutoResume.mayStart(after: thrice, settingsChangedAt: 0, now: 19 * minute))
    #expect(RunRecord.after(thrice, code: 0, now: 0).failuresInARow == 0 && AutoResume.mayStart(after: nil, settingsChangedAt: 0, now: 0))
}

@Test func workLeftOrALiftedLimitMeansThereIsWork() throws {
    func book(_ status: String, engine: String = "auto") throws -> Book {
        try JSONDecoder().decode(Book.self, from: Data(#"{"engine":"\#(engine)","chapters":[{"n":1,"title":"A","status":{"quiz":"done","audio":"\#(status)"}}]}"#.utf8))
    }
    #expect(AutoResume.hasWork(try book("todo"), usage: nil, logModified: 0, now: 0))
    #expect(!AutoResume.hasWork(try book("done"), usage: nil, logModified: 0, now: 0))
    #expect(!AutoResume.hasWork(try book("waiting_quota", engine: "local"), usage: nil, logModified: 0, now: 60 * minute))
    #expect(AutoResume.hasWork(try book("waiting_quota", engine: "local"), usage: nil, logModified: 0, now: 361 * minute))
}

@Test func bookFilesStayInsideTheBookFolder() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("media"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(BookFiles.url("media/01-podcast.m4a", in: folder)?.lastPathComponent == "01-podcast.m4a")
    #expect(BookFiles.url("../../secret.pdf", in: folder) == nil)
    #expect(BookFiles.url("/etc/passwd", in: folder) == nil && BookFiles.url("", in: folder) == nil)
}
