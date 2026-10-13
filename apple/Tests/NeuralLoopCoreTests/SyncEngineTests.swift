import Foundation
import Testing
@testable import NeuralLoopCore

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nl-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, _ root: URL, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ root: URL, _ path: String) -> String? {
    (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
}

@Test func aBookPreparedOnTheMacAppearsOnThePadAndProgressFlowsBothWays() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot(), pad = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: pad) }
    try write(#"{"title":"MCP"}"#, mac, "books/mcp/book.json")
    try write("# One", mac, "books/mcp/chapters/01.md")
    try write("audio", mac, "books/mcp/media/01-podcast.m4a")
    try write("log", mac, "books/mcp/pipeline.log")           // private: stays on the Mac
    try write(#"{"log":{"2026-09-29":600}}"#, mac, "books/mcp/progress.json")

    let macSync = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive)
    let padSync = SyncEngine(root: pad, device: "ipad1", role: .pad, store: drive)
    let first = try await macSync.sync()
    #expect(first.uploaded == 4 && first.problems.isEmpty)
    let privateLog = await drive.data(at: "books/mcp/pipeline.log")
    #expect(privateLog == nil)

    // The pad gets the book and the Mac's progress, but no media until the chapter is opened.
    _ = try await padSync.sync()
    #expect(read(pad, "books/mcp/book.json") == #"{"title":"MCP"}"# && read(pad, "books/mcp/chapters/01.md") == "# One")
    #expect(read(pad, "books/mcp/media/01-podcast.m4a") == nil)
    #expect(read(pad, "books/mcp/devices/mac1.json") == #"{"log":{"2026-09-29":600}}"#)
    _ = try await padSync.sync(wantedMedia: ["mcp:1"])
    #expect(read(pad, "books/mcp/media/01-podcast.m4a") == "audio")

    // The pad studies; its own progress goes up and comes down on the Mac as another device's file.
    try write(#"{"log":{"2026-09-29":300}}"#, pad, "books/mcp/progress.json")
    _ = try await padSync.sync()
    _ = try await macSync.sync()
    #expect(read(mac, "books/mcp/devices/ipad1.json") == #"{"log":{"2026-09-29":300}}"#)
    #expect(read(mac, "books/mcp/progress.json") == #"{"log":{"2026-09-29":600}}"#)  // never overwritten by another device

    // Nothing changed: nothing moves (hashes are cached, files aren't sent twice).
    let uploads = await drive.uploads
    let quiet = try await macSync.sync()
    let uploadsAfter = await drive.uploads
    #expect(quiet.uploaded == 0 && quiet.downloaded == 0 && uploadsAfter == uploads)
}

@Test func aBookAddedOnThePadIsPreparedByTheMacAndLeavesTheInbox() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot(), pad = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: pad) }
    try write("%PDF", pad, "inbox/u1.pdf")
    try write(#"{"title":"Clean Code"}"#, pad, "inbox/u1.json")
    let padSync = SyncEngine(root: pad, device: "ipad1", role: .pad, store: drive)
    let macSync = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive)

    let sent = try await padSync.sync()
    #expect(sent.uploaded == 2)
    let arrived = try await macSync.sync().arrived
    #expect(arrived.map(\.lastPathComponent) == ["u1.pdf"] && read(mac, "inbox/u1.json") == #"{"title":"Clean Code"}"#)

    await macSync.markTaken(arrived[0])
    let tidied = try await macSync.sync()
    #expect(tidied.deleted == 2)
    let left = try await libraryFiles(drive)
    #expect(left.isEmpty)
    _ = try await padSync.sync()
    #expect(read(pad, "inbox/u1.pdf") == nil)  // the pad tidies up once the Mac has it
}

@Test func remoteFilesNeverLandOutsideTheLibraryFolder() async throws {
    let drive = MemoryDrive()
    let parent = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("library", isDirectory: true)
    try write(#"{"title":"MCP"}"#, root, "books/mcp/book.json")
    try write("mine", root, "books/mcp/progress.json")
    let source = parent.appendingPathComponent("payload")
    try Data("gotcha".utf8).write(to: source)
    // What a compromised device could put in the Drive app folder.
    for path in ["inbox/..", "inbox/../escaped.pdf", "books/mcp/..", "books/mcp/../../../escaped", "books/mcp/progress.json",
                 "books/mcp/progress/../../../escaped.json", "books/../escaped", "../escaped"] {
        try await drive.upload(source, as: path, replacing: nil)
    }
    for role in [SyncRole.pad, .mac] {
        let report = try await SyncEngine(root: root, device: "me1", role: role, store: drive).sync(wantedMedia: ["mcp:1"])
        #expect(report.downloaded == 0 && report.arrived.isEmpty)
    }
    #expect(read(root, "books/mcp/book.json") == #"{"title":"MCP"}"# && read(root, "books/mcp/progress.json") == "mine")
    let outside = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
    #expect(outside == ["library", "payload"])
}


@Test func localPathsStayInsideTheirFolder() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = SyncEngine(root: root, device: "me1", role: .pad, store: MemoryDrive())
    #expect(await engine.localURL("books/mcp/../../x") == nil)
    #expect(await engine.localURL("books/mcp/..") == nil)
    #expect(await engine.localURL("inbox/..") == nil)
    #expect(await engine.localURL("sync-state.json") == nil)
    #expect(await engine.localURL("books/mcp/chapters/01.md")?.path.hasSuffix("/books/mcp/chapters/01.md") == true)
    #expect(await engine.localURL("books/mcp/progress/pad-2.json")?.path.hasSuffix("/books/mcp/devices/pad-2.json") == true)
    #expect(await engine.localURL("books/mcp/progress/me1.json")?.path.hasSuffix("/books/mcp/progress.json") == true)
}

@Test func md5MatchesDrivesChecksums() throws {
    #expect(FileHash.md5(Data("hello".utf8)) == "5d41402abc4b2a76b9719d911017c592")
}

@Test func aBookRemovedOnOneDeviceLeavesEveryDeviceAndNeverComesBack() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot(), pad = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: pad) }
    try write(#"{"title":"Keep"}"#, mac, "books/keep/book.json")
    try write(#"{"title":"Gone"}"#, mac, "books/gone/book.json")
    try write("# One", mac, "books/gone/chapters/01.md")
    let macSync = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive)
    let padSync = SyncEngine(root: pad, device: "ipad1", role: .pad, store: drive)
    _ = try await macSync.sync()
    _ = try await padSync.sync()
    #expect(read(pad, "books/gone/book.json") != nil)

    // Removed on the iPad: the Drive loses it, the Mac is told to let go, and nothing comes back.
    await padSync.remove(book: "gone")
    try FileManager.default.removeItem(at: pad.appendingPathComponent("books/gone"))
    _ = try await padSync.sync()
    let left = try await drive.list().map(\.path)
    #expect(!left.contains { $0.hasPrefix("books/gone/") } && left.contains("removed/gone.json") && left.contains("books/keep/book.json"))
    let macReport = try await macSync.sync()
    #expect(macReport.removedElsewhere == ["gone"] && macReport.uploaded == 0)
    let afterMac = try await drive.list().map(\.path)
    #expect(!afterMac.contains { $0.hasPrefix("books/gone/") })   // the Mac's copy isn't uploaded again
    #expect(await macSync.removedBooks.contains("gone"))
    _ = try await padSync.sync()
    #expect(read(pad, "books/gone/book.json") == nil && read(pad, "books/keep/book.json") != nil)
}

@Test func removingWorksOfflineAndLeavesTheDriveOnTheNextSync() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot(), pad = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: pad) }
    try write(#"{"title":"Gone"}"#, mac, "books/gone/book.json")
    let macSync = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive)
    _ = try await macSync.sync()
    await macSync.remove(book: "gone")
    try FileManager.default.removeItem(at: mac.appendingPathComponent("books/gone"))
    let report = try await macSync.sync()
    #expect(report.deleted == 1)
    let padReport = try await SyncEngine(root: pad, device: "ipad1", role: .pad, store: drive).sync()
    #expect(padReport.downloaded == 0 && read(pad, "books/gone/book.json") == nil)
}

@Test func duplicatesInTheDriveAreTidiedAndTheNewestComesDown() async throws {
    let drive = MemoryDrive()
    let pad = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: pad) }
    await drive.insert(Data("old".utf8), as: "books/mcp/book.json")
    await drive.insert(Data("new".utf8), as: "books/mcp/book.json")
    let report = try await SyncEngine(root: pad, device: "ipad1", role: .pad, store: drive).sync()
    #expect(read(pad, "books/mcp/book.json") == "new" && report.deleted == 1)
    let left = try await libraryFiles(drive)
    #expect(left.count == 1)
}

/// A Drive whose listing is a snapshot from earlier: what a sync sees when another device changes things mid-sync.
private struct StaleListing: DriveStore {
    let drive: MemoryDrive
    let snapshot: [SyncFile]
    func list() async throws -> [SyncFile] { snapshot }
    func download(_ file: SyncFile, to destination: URL) async throws { try await drive.download(file, to: destination) }
    func upload(_ source: URL, as path: String, replacing id: String?) async throws -> SyncFile {
        try await drive.upload(source, as: path, replacing: id)
    }
    func delete(_ file: SyncFile) async throws { try await drive.delete(file) }
}

@Test func aFileAnotherDeviceDeletedIsCreatedAgainNotLost() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    try write(#"{"title":"MCP"}"#, mac, "books/mcp/book.json")
    _ = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: drive).sync()
    let snapshot = try await drive.list()
    // Gone from the Drive between our list and our replace or delete: Google answers 404, like the stand-in.
    try await drive.delete(snapshot[0])
    await #expect(throws: DriveError.http(404, "File not found")) { try await drive.delete(snapshot[0]) }
    try write(#"{"title":"MCP 2"}"#, mac, "books/mcp/book.json")
    let report = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: StaleListing(drive: drive, snapshot: snapshot)).sync()
    #expect(report.problems.isEmpty && report.uploaded == 1)
    #expect(await drive.data(at: "books/mcp/book.json") == Data(#"{"title":"MCP 2"}"#.utf8))
}

@Test func twoDevicesWithTheSameIDNoticeAndOneStepsAside() async throws {
    let drive = MemoryDrive()
    let a = try temporaryRoot(), b = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    try write(#"{"title":"MCP"}"#, a, "books/mcp/book.json")
    try write(#"{"log":{"d":1}}"#, a, "books/mcp/progress.json")
    _ = try await SyncEngine(root: a, device: "mac1", role: .mac, store: drive).sync()
    // A restored copy of the same Mac: same files, same sync state, same id.
    try FileManager.default.removeItem(at: b)
    try FileManager.default.copyItem(at: a, to: b)
    try write(#"{"log":{"d":2}}"#, a, "books/mcp/progress.json")
    let first = try await SyncEngine(root: a, device: "mac1", role: .mac, store: drive).sync()
    #expect(!first.deviceClash && first.uploaded == 1)
    try write(#"{"log":{"d":3}}"#, b, "books/mcp/progress.json")
    let second = try await SyncEngine(root: b, device: "mac1", role: .mac, store: drive).sync()
    #expect(second.deviceClash && second.uploaded == 0)   // it never overwrites the other device's file
    #expect(await drive.data(at: "books/mcp/progress/mac1.json") == Data(#"{"log":{"d":2}}"#.utf8))
    let fresh = try await SyncEngine(root: b, device: "mac-2", role: .mac, store: drive).sync()
    #expect(!fresh.deviceClash && read(b, "books/mcp/devices/mac1.json") == #"{"log":{"d":2}}"#)
    // Only study time beyond what was already counted under mac1 (d:1, shared by both copies) goes up as mac-2.
    #expect(await drive.data(at: "books/mcp/progress/mac-2.json") == Data(#"{"log":{"d":2}}"#.utf8))
    #expect(studied(b, "mcp") == 4)  // 1 before the copy, then 1 on the original and 2 on the copy
}

@Test func inboxBooksNotYetTakenAreOfferedAgainWithBackoff() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot(), pad = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: pad) }
    try write("%PDF", pad, "inbox/u1.pdf")
    try write(#"{"title":"Clean Code"}"#, pad, "inbox/u1.json")
    _ = try await SyncEngine(root: pad, device: "ipad1", role: .pad, store: drive).sync()
    let macSync = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive)
    let start = Date(timeIntervalSince1970: 1_000_000)
    #expect(try await macSync.sync(now: start).arrived.map(\.lastPathComponent) == ["u1.pdf"])
    // Not prepared (onArrived said no): offered again, but not straight away.
    await macSync.markFailed(mac.appendingPathComponent("inbox/u1.pdf"), now: start)
    #expect(try await macSync.sync(now: start.addingTimeInterval(60)).arrived.isEmpty)
    #expect(try await macSync.sync(now: start.addingTimeInterval(121)).arrived.count == 1)
    for _ in 0..<4 { await macSync.markFailed(mac.appendingPathComponent("inbox/u1.pdf"), now: start) }
    let gaveUp = try await macSync.sync(now: start.addingTimeInterval(1e6))
    #expect(gaveUp.arrived.isEmpty && gaveUp.problems.contains { $0.contains("Clean Code") })
}

@Test func removingEveryBookAlsoEmptiesTheInbox() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot(), pad = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: pad) }
    try write("%PDF", pad, "inbox/u1.pdf")
    try write(#"{"title":"Clean Code"}"#, pad, "inbox/u1.json")
    let padSync = SyncEngine(root: pad, device: "ipad1", role: .pad, store: drive)
    _ = try await padSync.sync()
    await padSync.forgetInbox()
    try FileManager.default.removeItem(at: pad.appendingPathComponent("inbox"))
    let report = try await padSync.sync()
    #expect(report.deleted == 2 && report.uploaded == 0)
    #expect(try await libraryFiles(drive).isEmpty)
    #expect(try await SyncEngine(root: mac, device: "mac1", role: .mac, store: drive).sync().arrived.isEmpty)
}

@Test func anyDeviceClearsWhatsLeftOfARemovedBookAndKeepsAskingToLetGo() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot(), pad = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: pad) }
    try write(#"{"title":"Gone"}"#, mac, "books/gone/book.json")
    let macSync = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive)
    _ = try await macSync.sync()
    let padSync = SyncEngine(root: pad, device: "ipad1", role: .pad, store: drive)
    _ = try await padSync.sync()
    await padSync.remove(book: "gone")
    _ = try await padSync.sync()
    // A straggler (say, a device that was offline) left a file behind: whoever sees it next takes it out.
    await drive.insert(Data("late".utf8), as: "books/gone/chapters/02.md")
    let first = try await macSync.sync()
    #expect(first.removedElsewhere == ["gone"] && first.deleted == 1)
    #expect(!(try await drive.list()).contains { $0.path.hasPrefix("books/gone/") })
    // The folder is still here (removing it failed, or it's waiting for a run to stop): ask again.
    #expect(try await macSync.sync().removedElsewhere == ["gone"])
    try FileManager.default.removeItem(at: mac.appendingPathComponent("books/gone"))
    #expect(try await macSync.sync().removedElsewhere.isEmpty)
    #expect(SyncEngine.removedBooks(savedIn: mac) == ["gone"])
}

@Test func theHashCacheForgetsFilesThatAreGone() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write("a", root, "books/mcp/book.json")
    try write("b", root, "books/mcp/chapters/01.md")
    let engine = SyncEngine(root: root, device: "mac1", role: .mac, store: MemoryDrive())
    _ = try await engine.sync()
    try FileManager.default.removeItem(at: root.appendingPathComponent("books/mcp/chapters"))
    _ = try await engine.sync()
    let state = try String(contentsOf: root.appendingPathComponent("sync-state.json"), encoding: .utf8)
    #expect(state.contains("book.json") && !state.contains("01.md"))
}

@Test func everyDeviceSeesTheOthersByName() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot(), pad = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: pad) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let macSync = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive, name: "Sam's MacBook Pro")
    let padSync = SyncEngine(root: pad, device: "ipad1", role: .pad, store: drive, name: "Sam's iPad")
    let first = try await macSync.sync(now: now)
    #expect(first.uploaded == 0)  // the device note isn't a library file
    #expect(first.devices.map(\.name) == ["Sam's MacBook Pro"] && first.devices[0].isThisDevice)
    let padReport = try await padSync.sync(now: now.addingTimeInterval(60))
    #expect(padReport.devices.map(\.name) == ["Sam's iPad", "Sam's MacBook Pro"])
    #expect(padReport.devices[1].kind == .mac && padReport.devices[1].lastSync == now.timeIntervalSince1970 * 1000)
    let macAgain = try await macSync.sync(now: now.addingTimeInterval(120))
    #expect(macAgain.devices.map(\.name) == ["Sam's MacBook Pro", "Sam's iPad"])
    #expect(read(mac, "deviceinfo/ipad1.json") == nil)  // read from the Drive, never written into the library
    // A quick second sync doesn't rewrite the note; a later one does (so "last synced" stays honest).
    let uploads = await drive.uploads
    _ = try await macSync.sync(now: now.addingTimeInterval(180))
    #expect(await drive.uploads == uploads)
    _ = try await macSync.sync(now: now.addingTimeInterval(20 * 60))
    #expect(await drive.uploads == uploads + 1)
}

@Test func aDeviceNoteThatsOddIsShownSafelyOrNotAtAll() {
    let fine = DeviceInfo.read(Data(#"{"name":"  Sam's\niPad  ","kind":"pad","lastSync":5}"#.utf8), id: "ipad1")
    #expect(fine?.name == "Sam's iPad" && fine?.kind == .pad && fine?.lastSync == 5)
    #expect(DeviceInfo.read(Data("nope".utf8), id: "x") == nil)
    #expect(DeviceInfo.read(Data(#"{"name":"","kind":"mac","lastSync":1}"#.utf8), id: "mac9")?.name == "A Mac")
    #expect(DeviceInfo.read(Data(#"{"name":"\#(String(repeating: "a", count: 300))","kind":"tv","lastSync":1}"#.utf8), id: "z")?.name.count == 60)
    #expect(SyncLayout.deviceInfo("deviceinfo/ipad1.json") == "ipad1" && SyncLayout.deviceInfo("deviceinfo/../x.json") == nil)
    #expect(!SyncLayout.isSafeRemote("deviceinfo/ipad1.json"))  // never placed on disk
}

private func note(_ name: String, _ kind: String = "pad", lastSync: Double) -> Data {
    Data(#"{"name":"\#(name)","kind":"\#(kind)","lastSync":\#(lastSync)}"#.utf8)
}

private func notes(_ drive: MemoryDrive, _ id: String) async throws -> [SyncFile] {
    try await drive.list().filter { $0.path == SyncLayout.deviceInfoPath(id) }
}

@Test func duplicateDeviceNotesAreTidiedAndEachDeviceIsListedOnce() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ms = now.timeIntervalSince1970 * 1000
    await drive.insert(note("Old name", lastSync: ms - 1000), as: "deviceinfo/ipad1.json")
    await drive.insert(note("Sam's iPad", lastSync: ms - 500), as: "deviceinfo/ipad1.json")
    await drive.insert(note("Sam's MacBook", "mac", lastSync: ms - 2000), as: "deviceinfo/mac1.json")
    await drive.insert(note("Sam's MacBook", "mac", lastSync: ms - 1500), as: "deviceinfo/mac1.json")
    let report = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: drive, name: "Sam's MacBook").sync(now: now)
    #expect(report.devices.map(\.id) == ["mac1", "ipad1"])
    #expect(report.devices[1].name == "Sam's iPad")  // the newest copy
    #expect(try await notes(drive, "ipad1").count == 1)
    #expect(try await notes(drive, "mac1").count == 1)
    #expect(DeviceInfo.read(await drive.data(at: "deviceinfo/mac1.json") ?? Data(), id: "mac1", now: now)?.lastSync == ms)
}

@Test func afterAnIDClashTheNoteMovesToTheNewID() async throws {
    let drive = MemoryDrive()
    let a = try temporaryRoot(), b = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    _ = try await SyncEngine(root: a, device: "mac1", role: .mac, store: drive, name: "Sam's Mac").sync(now: now)
    try FileManager.default.removeItem(at: b)
    try FileManager.default.copyItem(at: a, to: b)  // a restored copy, sync state and all
    // The copy took a new id: its note goes up under that id at once, and the shared id's note leaves the Drive.
    let fresh = try await SyncEngine(root: b, device: "mac-2", role: .mac, store: drive, name: "Sam's Mac").sync(now: now.addingTimeInterval(60))
    #expect(fresh.devices.map(\.id) == ["mac-2"] && fresh.devices[0].isThisDevice)
    #expect(try await notes(drive, "mac-2").count == 1)
    #expect(try await notes(drive, "mac1").isEmpty)
    // The device still using the old id finds its note gone and writes it again right away.
    let original = try await SyncEngine(root: a, device: "mac1", role: .mac, store: drive, name: "Sam's Mac").sync(now: now.addingTimeInterval(120))
    #expect(try await notes(drive, "mac1").count == 1)
    #expect(original.devices.map(\.id) == ["mac1", "mac-2"])
}

@Test func notesOlderThanNinetyDaysAreHiddenAndTidied() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day = 86_400_000.0, ms = now.timeIntervalSince1970 * 1000
    await drive.setClock(now)  // the Drive's clock agrees with this Mac's here
    await drive.insert(note("Old iPad", lastSync: ms - 91 * day), as: "deviceinfo/ipad-old.json",
                       modified: now.addingTimeInterval(-91 * 86_400))
    await drive.insert(note("Sam's iPad", lastSync: ms - 89 * day), as: "deviceinfo/ipad1.json",
                       modified: now.addingTimeInterval(-89 * 86_400))
    let report = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: drive, name: "Sam's Mac").sync(now: now)
    #expect(report.devices.map(\.id) == ["mac1", "ipad1"])
    #expect(try await notes(drive, "ipad-old").isEmpty)
}

@Test func signingOutTakesThisDevicesNoteOffTheDrive() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let engine = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive, name: "Sam's Mac")
    _ = try await engine.sync(now: now)
    await drive.insert(note("Sam's Mac", "mac", lastSync: 1), as: "deviceinfo/mac1.json")  // and a stray copy
    await drive.insert(note("Sam's iPad", lastSync: now.timeIntervalSince1970 * 1000), as: "deviceinfo/ipad1.json")
    try await engine.removeNote()
    #expect(try await notes(drive, "mac1").isEmpty)
    #expect(try await notes(drive, "ipad1").count == 1)  // only our own note goes
    // Signed in again soon after: the note goes straight back up.
    _ = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: drive, name: "Sam's Mac").sync(now: now.addingTimeInterval(60))
    #expect(try await notes(drive, "mac1").count == 1)
}

@Test func thisDeviceShowsTheSyncThatJustHappened() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let engine = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive, name: "Sam's Mac")
    _ = try await engine.sync(now: now)
    let later = try await engine.sync(now: now.addingTimeInterval(5 * 60))  // the note isn't rewritten yet
    #expect(later.devices[0].lastSync == now.addingTimeInterval(5 * 60).timeIntervalSince1970 * 1000)
}

@Test func hiddenAndControlCharactersNeverReachADevicesName() {
    let tricky = "Sam\u{202E}daPi\u{200B}\u{0007}\u{2028}x\u{FEFF}"
    let info = DeviceInfo(id: "ipad1", name: tricky, kind: .pad, lastSync: 1)
    #expect(info.name == "SamdaPi x")
    #expect(info.name.unicodeScalars.allSatisfy { ![.control, .format].contains($0.properties.generalCategory) })
    #expect(DeviceInfo(id: "x", name: "\u{202E}\u{200B}", kind: .mac, lastSync: 1).name == "A Mac")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let future = DeviceInfo.read(note("Sam's iPad", lastSync: 9e15), id: "ipad1", now: now)
    #expect(future?.lastSync == now.timeIntervalSince1970 * 1000 + 86_400_000)
    #expect(DeviceInfo.read(note("Sam's iPad", lastSync: -5), id: "ipad1", now: now)?.lastSync == 0)
}

@Test func aDeviceIsNeverListedTwice() {
    let me = DeviceInfo(id: "mac1", name: "Mac", kind: .mac, lastSync: 2, isThisDevice: true)
    let other = DeviceInfo(id: "ipad1", name: "iPad", kind: .pad, lastSync: 1)
    #expect(DeviceInfo.unique([me, other, other, DeviceInfo(id: "mac1", name: "Old", kind: .mac, lastSync: 1)]) == [me, other])
}

/// What's in the Drive besides the devices' notes about themselves.
private func libraryFiles(_ drive: MemoryDrive) async throws -> [SyncFile] {
    try await drive.list().filter { SyncLayout.deviceInfo($0.path) == nil }
}

// MARK: device notes: signing out, clocks, names

/// A Drive that holds one call (a `list` or a device note's `upload`) until released, to replay a sync and a sign-out
/// running at the same time.
private actor HeldDrive: DriveStore {
    let inner: MemoryDrive
    private var armed: String?
    private var held: CheckedContinuation<Void, Never>?
    var holding: Bool { held != nil }

    init(_ inner: MemoryDrive) { self.inner = inner }
    func hold(_ call: String) { armed = call }
    func release() { held?.resume(); held = nil }

    private func wait(_ call: String) async {
        guard armed == call else { return }
        armed = nil
        await withCheckedContinuation { held = $0 }
    }

    func list() async throws -> [SyncFile] {
        let files = try await inner.list()
        await wait("list")  // the snapshot is taken, then the sync stalls
        return files
    }
    func download(_ file: SyncFile, to destination: URL) async throws { try await inner.download(file, to: destination) }
    func upload(_ source: URL, as path: String, replacing id: String?) async throws -> SyncFile {
        if SyncLayout.deviceInfo(path) != nil { await wait("upload") }
        return try await inner.upload(source, as: path, replacing: id)
    }
    func delete(_ file: SyncFile) async throws { try await inner.delete(file) }
}

private func whileHeld(_ drive: HeldDrive) async {
    while !(await drive.holding) { await Task.yield() }
}

@Test func aSyncAlreadyUnderwayWhenSigningOutNeverBringsTheNoteBack() async throws {
    let memory = MemoryDrive()
    let drive = HeldDrive(memory)
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let engine = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive, name: "Sam's Mac")
    _ = try await engine.sync(now: now)
    // A sync has looked at the Drive (its snapshot still has the note) when sign-out takes the note away.
    await drive.hold("list")
    let underway = Task { try await engine.sync(now: now.addingTimeInterval(60)) }
    await whileHeld(drive)
    try await engine.removeNote()
    await drive.release()
    _ = try await underway.value
    #expect(try await notes(memory, "mac1").isEmpty)
}

@Test func aNoteOnItsWayUpWhenSigningOutIsTakenBackDown() async throws {
    let memory = MemoryDrive()
    let drive = HeldDrive(memory)
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let engine = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive, name: "Sam's Mac")
    _ = try await engine.sync(now: now)
    await drive.hold("upload")  // the 15-minute rewrite is in flight
    let underway = Task { try await engine.sync(now: now.addingTimeInterval(20 * 60)) }
    await whileHeld(drive)
    try await engine.removeNote()
    await drive.release()
    _ = try await underway.value
    #expect(try await notes(memory, "mac1").isEmpty)
}

@Test func afterSigningOutNoSyncWritesTheNoteUntilSignedInAgain() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let engine = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive, name: "Sam's Mac")
    _ = try await engine.sync(now: now)
    try await engine.removeNote()
    _ = try await engine.sync(now: now.addingTimeInterval(60))  // a sync that slipped in while the sign-out finished
    #expect(try await notes(drive, "mac1").isEmpty)
    await engine.signedIn()
    _ = try await engine.sync(now: now.addingTimeInterval(120))
    #expect(try await notes(drive, "mac1").count == 1)
}

@Test func whetherANoteIsOldGoesByTheDrivesClockNotADevicesOwn() async throws {
    let day: TimeInterval = 86_400
    // The Drive's clock: Google's time, whatever the devices think.
    let server = Date(timeIntervalSince1970: 1_800_000_000)
    func library() async -> MemoryDrive {
        let drive = MemoryDrive()
        await drive.setClock(server)
        return drive
    }
    // This Mac's clock runs 100 days fast: the iPad's honest note, written an hour ago, must not look 100 days old.
    let fast = await library()
    await fast.insert(note("Sam's iPad", lastSync: (server.timeIntervalSince1970 - 3600) * 1000), as: "deviceinfo/ipad1.json",
                      modified: server.addingTimeInterval(-3600))
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    let ahead = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: fast, name: "Sam's Mac")
        .sync(now: server.addingTimeInterval(100 * day))
    #expect(ahead.devices.map(\.id) == ["mac1", "ipad1"])
    #expect(try await notes(fast, "ipad1").count == 1)

    // The iPad's clock runs 100 days slow: its note says it's old, but the Drive saw it written a minute ago.
    let slow = await library()
    await slow.insert(note("Sam's iPad", lastSync: (server.timeIntervalSince1970 - 100 * day) * 1000), as: "deviceinfo/ipad1.json",
                      modified: server.addingTimeInterval(-60))
    let mac2 = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac2) }
    let behind = try await SyncEngine(root: mac2, device: "mac1", role: .mac, store: slow, name: "Sam's Mac").sync(now: server)
    #expect(behind.devices.map(\.id) == ["mac1", "ipad1"])
    #expect(try await notes(slow, "ipad1").count == 1)

    // A note the Drive hasn't seen rewritten for 91 days is a device long gone, whatever its note claims (and even
    // when this Mac's clock runs slow).
    let old = await library()
    await old.insert(note("Old iPad", lastSync: server.timeIntervalSince1970 * 1000), as: "deviceinfo/ipad-old.json",
                     modified: server.addingTimeInterval(-91 * day))
    let mac3 = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac3) }
    let tidied = try await SyncEngine(root: mac3, device: "mac1", role: .mac, store: old, name: "Sam's Mac")
        .sync(now: server.addingTimeInterval(-100 * day))
    #expect(tidied.devices.map(\.id) == ["mac1"])
    #expect(try await notes(old, "ipad-old").isEmpty)
}

@Test func namesKeepTheirJoinersEmojiAndFlags() {
    let coder = "Sam's \u{1F469}\u{200D}\u{1F4BB} Mac"  // woman technologist: a joined emoji
    #expect(DeviceInfo(id: "a", name: coder, kind: .mac, lastSync: 1).name == coder)
    let england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F} iPad"  // a flag made of tag characters
    #expect(DeviceInfo(id: "b", name: england, kind: .pad, lastSync: 1).name == england)
    let persian = "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"  // ZWNJ belongs in the word
    #expect(DeviceInfo(id: "c", name: persian, kind: .pad, lastSync: 1).name == persian)
    // Direction marks and invisible spaces still go.
    let sneaky = "\u{202A}A\u{202B}B\u{202C}C\u{202D}D\u{2066}E\u{2067}F\u{2068}G\u{2069}H\u{200E}I\u{200F}J\u{061C}K\u{200B}L\u{2060}M\u{FEFF}N\u{00AD}O"
    #expect(DeviceInfo(id: "d", name: sneaky, kind: .mac, lastSync: 1).name == "ABCDEFGHIJKLMNO")
}

// MARK: device ids: lost answers, other accounts, retired ids

/// Seconds studied in a book here, every device's file merged (what the year log shows).
private func studied(_ root: URL, _ book: String) -> Double {
    ProgressFile.loadMerged(from: root.appendingPathComponent("books/\(book)")).merged.log.values.reduce(0, +)
}

/// A Drive that stores the next progress upload and then loses the answer (wifi dropped, the Mac slept).
private actor LossyDrive: DriveStore {
    let inner: MemoryDrive
    private var loseNext = false
    init(_ inner: MemoryDrive) { self.inner = inner }
    func loseNextAnswer() { loseNext = true }
    func list() async throws -> [SyncFile] { try await inner.list() }
    func download(_ file: SyncFile, to destination: URL) async throws { try await inner.download(file, to: destination) }
    func upload(_ source: URL, as path: String, replacing id: String?) async throws -> SyncFile {
        let stored = try await inner.upload(source, as: path, replacing: id)
        if loseNext, SyncLayout.progressDevice(path) != nil { loseNext = false; throw URLError(.networkConnectionLost) }
        return stored
    }
    func delete(_ file: SyncFile) async throws { try await inner.delete(file) }
}

@Test func anUploadThatLandedButWhoseAnswerWasLostIsNotAClash() async throws {
    let drive = MemoryDrive()
    let lossy = LossyDrive(drive)
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    try write(#"{"title":"MCP"}"#, mac, "books/mcp/book.json")
    try write(#"{"log":{"2026-09-29":200}}"#, mac, "books/mcp/progress.json")
    _ = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: lossy).sync()
    try write(#"{"log":{"2026-09-29":215}}"#, mac, "books/mcp/progress.json")
    await lossy.loseNextAnswer()
    let lost = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: lossy).sync()
    #expect(!lost.problems.isEmpty)
    try write(#"{"log":{"2026-09-29":2300}}"#, mac, "books/mcp/progress.json")  // a study tick since
    let next = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: lossy).sync()
    #expect(!next.deviceClash && next.uploaded == 1)
    #expect(await drive.data(at: "books/mcp/progress/mac1.json") == Data(#"{"log":{"2026-09-29":2300}}"#.utf8))
}

/// One Drive per Google account; the person signs in to one, then the other.
private actor TwoAccounts: DriveStore {
    let a = MemoryDrive(), b = MemoryDrive()
    private var onB = false
    func use(b: Bool) { onB = b }
    private var drive: MemoryDrive { onB ? b : a }
    func list() async throws -> [SyncFile] { try await drive.list() }
    func download(_ file: SyncFile, to destination: URL) async throws { try await drive.download(file, to: destination) }
    func upload(_ source: URL, as path: String, replacing id: String?) async throws -> SyncFile {
        try await drive.upload(source, as: path, replacing: id)
    }
    func delete(_ file: SyncFile) async throws { try await drive.delete(file) }
}

@Test func signingInToAnotherGoogleAccountAndBackIsNotAClash() async throws {
    let accounts = TwoAccounts()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    try write(#"{"title":"MCP"}"#, mac, "books/mcp/book.json")
    try write(#"{"log":{"d":1}}"#, mac, "books/mcp/progress.json")
    let engine = SyncEngine(root: mac, device: "mac1", role: .mac, store: accounts)
    _ = try await engine.sync(account: "sam@example.com")
    await accounts.use(b: true)
    try write(#"{"log":{"d":22}}"#, mac, "books/mcp/progress.json")
    #expect(try await !engine.sync(account: "work@example.com").deviceClash)
    await accounts.use(b: false)
    try write(#"{"log":{"d":333}}"#, mac, "books/mcp/progress.json")
    let back = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: accounts).sync(account: "Sam@example.com")
    #expect(!back.deviceClash && back.uploaded == 1)
    #expect(await accounts.a.data(at: "books/mcp/progress/mac1.json") == Data(#"{"log":{"d":333}}"#.utf8))
}

@Test func afterANewIDThisDevicesStudyTimeIsCountedOnce() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    try write(#"{"title":"MCP"}"#, mac, "books/mcp/book.json")
    try write(#"{"log":{"2026-09-29":215}}"#, mac, "books/mcp/progress.json")
    _ = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: drive).sync()
    // A copy an older version already brought down as "another device".
    try write(#"{"log":{"2026-09-29":215}}"#, mac, "books/mcp/devices/mac1.json")
    // What the app does after a clash: the same library, a new id.
    let fresh = SyncEngine(root: mac, device: "mac-2", role: .mac, store: drive)
    let report = try await fresh.sync()
    #expect(!report.deviceClash && report.problems.isEmpty)
    #expect(studied(mac, "mcp") == 215)
    #expect(read(mac, "books/mcp/devices/mac1.json") == nil)
    #expect(await drive.data(at: "books/mcp/progress/mac1.json") == nil)
    #expect(await drive.data(at: "books/mcp/progress/mac-2.json") == Data(#"{"log":{"2026-09-29":215}}"#.utf8))
    _ = try await fresh.sync()
    #expect(studied(mac, "mcp") == 215)
}

@Test func aRealSecondDeviceOnTheOldIDIsStillCountedAfterTheClash() async throws {
    let drive = MemoryDrive()
    let a = try temporaryRoot(), b = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    try write(#"{"title":"MCP"}"#, a, "books/mcp/book.json")
    try write(#"{"title":"Other"}"#, a, "books/other/book.json")
    try write(#"{"log":{"d":1}}"#, a, "books/mcp/progress.json")
    try write(#"{"log":{"o":1}}"#, a, "books/other/progress.json")
    _ = try await SyncEngine(root: a, device: "mac1", role: .mac, store: drive).sync()
    try FileManager.default.removeItem(at: b)
    try FileManager.default.copyItem(at: a, to: b)  // a restored copy, same id
    try write(#"{"log":{"d":2}}"#, a, "books/mcp/progress.json")
    _ = try await SyncEngine(root: a, device: "mac1", role: .mac, store: drive).sync()
    try write(#"{"log":{"d":3}}"#, b, "books/mcp/progress.json")
    #expect(try await SyncEngine(root: b, device: "mac1", role: .mac, store: drive).sync().deviceClash)
    let copy = SyncEngine(root: b, device: "mac-2", role: .mac, store: drive)
    _ = try await copy.sync()
    // The old id's files stay and are counted (they carry the history both copies share, plus the other Mac's own
    // time); this copy counts only what it studies beyond that. (Changed on purpose: before, the file only we had
    // written left the Drive, and once the other Mac sent it again the shared history was counted under both ids.)
    #expect(await drive.data(at: "books/mcp/progress/mac1.json") == Data(#"{"log":{"d":2}}"#.utf8))
    #expect(read(b, "books/mcp/devices/mac1.json") == #"{"log":{"d":2}}"#)
    #expect(await drive.data(at: "books/other/progress/mac1.json") == Data(#"{"log":{"o":1}}"#.utf8))
    #expect(read(b, "books/other/devices/mac1.json") == #"{"log":{"o":1}}"#)
    let original = try await SyncEngine(root: a, device: "mac1", role: .mac, store: drive).sync()
    #expect(!original.deviceClash)
    _ = try await copy.sync()
    _ = try await copy.sync()
    #expect(await drive.data(at: "books/other/progress/mac1.json") == Data(#"{"log":{"o":1}}"#.utf8))
    #expect(read(b, "books/other/devices/mac1.json") == #"{"log":{"o":1}}"#)
    // 1 before the copy, then 1 more on the original and 2 more on the copy: the shared part is never counted twice.
    #expect(studied(b, "other") == 1 && studied(a, "other") == 1)
    #expect(studied(b, "mcp") == 4 && studied(a, "mcp") == 4)
}

@Test func anInboxBookWaitsOneSyncForItsTitleThenGoesAhead() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    await drive.insert(Data("%PDF".utf8), as: "inbox/u1.pdf")
    await drive.insert(Data("%PDF".utf8), as: "inbox/u2.pdf")
    let macSync = SyncEngine(root: mac, device: "mac1", role: .mac, store: drive)
    #expect(try await macSync.sync().arrived.isEmpty)  // the title may be on its way
    await drive.insert(Data(#"{"title":"Clean Code"}"#.utf8), as: "inbox/u2.json")
    let second = try await macSync.sync()
    #expect(second.arrived.map(\.lastPathComponent) == ["u1.pdf", "u2.pdf"])
    #expect(read(mac, "inbox/u2.json") == #"{"title":"Clean Code"}"#)
}

// MARK: review fixes: forgotten devices, copied devices, lagging lists, accounts, titles

@Test func aThirdDeviceForgetsAProgressFileThatLeftTheDrive() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot(), pad = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac); try? FileManager.default.removeItem(at: pad) }
    try write(#"{"title":"MCP"}"#, mac, "books/mcp/book.json")
    try write(#"{"log":{"2026-09-29":215}}"#, mac, "books/mcp/progress.json")
    _ = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: drive).sync()
    let padSync = SyncEngine(root: pad, device: "ipad1", role: .pad, store: drive)
    _ = try await padSync.sync()
    #expect(read(pad, "books/mcp/devices/mac1.json") != nil)
    // The Mac moves to a new id (its old id's file leaves the Drive): the iPad lets go of its copy too.
    _ = try await SyncEngine(root: mac, device: "mac-2", role: .mac, store: drive).sync()
    let report = try await padSync.sync()
    #expect(read(pad, "books/mcp/devices/mac1.json") == nil && report.forgotten == 1)
    #expect(read(pad, "books/mcp/devices/mac-2.json") != nil)
    #expect(studied(pad, "mcp") == 215)
}

/// A Mac copied onto another (Migration Assistant, a restored backup): both carry the same history and the same id.
/// Whichever syncs second after the copy finds the clash and takes a new id. Every device must count the shared
/// history once, each copy's own time after the copy once, and a book neither touched since just as before.
private func copiedMacScenario(copySyncsFirst: Bool) async throws {
    let drive = MemoryDrive()
    let a = try temporaryRoot(), b = try temporaryRoot(), pad = try temporaryRoot()
    defer { for url in [a, b, pad] { try? FileManager.default.removeItem(at: url) } }
    try write(#"{"title":"MCP"}"#, a, "books/mcp/book.json")
    try write(#"{"title":"Other"}"#, a, "books/other/book.json")
    try write(#"{"log":{"d1":100}}"#, a, "books/mcp/progress.json")
    try write(#"{"log":{"d1":30}}"#, a, "books/other/progress.json")
    _ = try await SyncEngine(root: a, device: "mac1", role: .mac, store: drive).sync()
    let padSync = SyncEngine(root: pad, device: "ipad1", role: .pad, store: drive)
    _ = try await padSync.sync()
    try FileManager.default.removeItem(at: b)
    try FileManager.default.copyItem(at: a, to: b)  // the copy: same files, same sync state, same id
    // After the copy each studies MCP; neither touches the other book.
    try write(#"{"log":{"d1":100,"d2":10}}"#, a, "books/mcp/progress.json")
    try write(#"{"log":{"d1":100,"d2":20}}"#, b, "books/mcp/progress.json")
    let (first, second) = copySyncsFirst ? (b, a) : (a, b)
    #expect(try await !SyncEngine(root: first, device: "mac1", role: .mac, store: drive).sync().deviceClash)
    #expect(try await SyncEngine(root: second, device: "mac1", role: .mac, store: drive).sync().deviceClash)
    // The app quit before taking its new id: the clash is found again, and nothing is counted twice for it.
    #expect(try await SyncEngine(root: second, device: "mac1", role: .mac, store: drive).sync().deviceClash)
    let renamed = SyncEngine(root: second, device: "mac-2", role: .mac, store: drive)
    #expect(try await !renamed.sync().deviceClash)
    _ = try await SyncEngine(root: first, device: "mac1", role: .mac, store: drive).sync()
    _ = try await renamed.sync()
    _ = try await padSync.sync()
    for root in [a, b, pad] {
        #expect(studied(root, "mcp") == 130)
        #expect(studied(root, "other") == 30)
    }
    // The renamed copy keeps studying: its new time counts everywhere, once.
    let before = copySyncsFirst ? 10 : 20  // what the renamed one had studied on d2
    try write(#"{"log":{"d1":100,"d2":\#(before),"d3":5}}"#, second, "books/mcp/progress.json")
    _ = try await renamed.sync()
    _ = try await SyncEngine(root: first, device: "mac1", role: .mac, store: drive).sync()
    _ = try await padSync.sync()
    for root in [a, b, pad] { #expect(studied(root, "mcp") == 135) }
}

@Test func aCopiedMacCountsTheSharedHistoryOnceWhenTheCopyClashes() async throws {
    try await copiedMacScenario(copySyncsFirst: false)
}

@Test func aCopiedMacCountsTheSharedHistoryOnceWhenTheOriginalClashes() async throws {
    try await copiedMacScenario(copySyncsFirst: true)
}

@Test func aLaggingListingsDuplicateOfOurOwnProgressIsNotAClash() async throws {
    let drive = MemoryDrive()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    try write(#"{"title":"MCP"}"#, mac, "books/mcp/book.json")
    try write(#"{"log":{"d":1}}"#, mac, "books/mcp/progress.json")
    _ = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: drive).sync()
    // The next listing lags and doesn't show that upload yet, so the progress is created a second time.
    try write(#"{"log":{"d":2}}"#, mac, "books/mcp/progress.json")
    _ = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: StaleListing(drive: drive, snapshot: [])).sync()
    #expect(try await drive.list().filter { $0.path == "books/mcp/progress/mac1.json" }.count == 2)
    // Both copies are ours: the older one is a duplicate to tidy, not another device writing our file.
    let report = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: drive).sync()
    #expect(!report.deviceClash)
    #expect(try await drive.list().filter { $0.path == "books/mcp/progress/mac1.json" }.count == 1)
    #expect(await drive.data(at: "books/mcp/progress/mac1.json") == Data(#"{"log":{"d":2}}"#.utf8))
}

@Test func aBookRemovedUnderOneAccountIsNeverDeletedFromAnother() async throws {
    let accounts = TwoAccounts()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    try write(#"{"title":"Gone"}"#, mac, "books/gone/book.json")
    let engine = SyncEngine(root: mac, device: "mac1", role: .mac, store: accounts)
    _ = try await engine.sync(account: "sam@example.com")
    await engine.remove(book: "gone")
    try FileManager.default.removeItem(at: mac.appendingPathComponent("books/gone"))
    _ = try await engine.sync(account: "sam@example.com")
    #expect(await accounts.a.data(at: "removed/gone.json") != nil)
    // The work account has its own book with that id (from another Mac).
    await accounts.use(b: true)
    await accounts.b.insert(Data(#"{"title":"Theirs"}"#.utf8), as: "books/gone/book.json")
    _ = try await engine.sync(account: "work@example.com")
    _ = try await engine.sync(account: "work@example.com")
    #expect(await accounts.b.data(at: "books/gone/book.json") != nil)
    #expect(await accounts.b.data(at: "removed/gone.json") == nil)
    // Ids are still never reused here, whatever the account.
    #expect(await engine.removedBooks.contains("gone"))
    #expect(SyncEngine.removedBooks(savedIn: mac).contains("gone"))
}

@Test func aRemovalNotYetSyncedGoesToTheAccountItWasMadeUnder() async throws {
    let accounts = TwoAccounts()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    try write(#"{"title":"Gone"}"#, mac, "books/gone/book.json")
    let engine = SyncEngine(root: mac, device: "mac1", role: .mac, store: accounts)
    _ = try await engine.sync(account: "sam@example.com")
    await engine.remove(book: "gone")
    try FileManager.default.removeItem(at: mac.appendingPathComponent("books/gone"))
    await accounts.use(b: true)
    _ = try await engine.sync(account: "work@example.com")
    #expect(await accounts.b.data(at: "removed/gone.json") == nil)
    await accounts.use(b: false)
    _ = try await engine.sync(account: "sam@example.com")
    #expect(await accounts.a.data(at: "removed/gone.json") != nil)
    #expect(await accounts.a.data(at: "books/gone/book.json") == nil)
}

@Test func anInboxBookSentToOneAccountStaysOnThePadUnderAnother() async throws {
    let accounts = TwoAccounts()
    let pad = try temporaryRoot(), mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: pad); try? FileManager.default.removeItem(at: mac) }
    try write("%PDF", pad, "inbox/u1.pdf")
    try write(#"{"title":"Clean Code"}"#, pad, "inbox/u1.json")
    let padSync = SyncEngine(root: pad, device: "ipad1", role: .pad, store: accounts)
    _ = try await padSync.sync(account: "sam@example.com")
    await accounts.use(b: true)
    let other = try await padSync.sync(account: "work@example.com")
    #expect(read(pad, "inbox/u1.pdf") == "%PDF")  // the Mac on the first account hasn't taken it yet
    #expect(other.uploaded == 0)                  // and it isn't sent to this account as well
    #expect(await accounts.b.data(at: "inbox/u1.pdf") == nil)
    // Back on the first account, its Mac takes it, and only then does the pad let go.
    await accounts.use(b: false)
    _ = try await padSync.sync(account: "sam@example.com")
    #expect(read(pad, "inbox/u1.pdf") == "%PDF")
    let macSync = SyncEngine(root: mac, device: "mac1", role: .mac, store: accounts.a)
    let arrived = try await macSync.sync().arrived
    await macSync.markTaken(arrived[0])
    _ = try await macSync.sync()
    _ = try await padSync.sync(account: "sam@example.com")
    #expect(read(pad, "inbox/u1.pdf") == nil)
}

@Test func removingEveryBookUnderOneAccountLeavesAnotherAccountsInboxAlone() async throws {
    let accounts = TwoAccounts()
    let pad = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: pad) }
    await accounts.a.insert(Data("%PDF".utf8), as: "inbox/a1.pdf")
    await accounts.b.insert(Data("%PDF".utf8), as: "inbox/b1.pdf")
    let padSync = SyncEngine(root: pad, device: "ipad1", role: .pad, store: accounts)
    _ = try await padSync.sync(account: "sam@example.com")
    await padSync.forgetInbox(now: Date(timeIntervalSince1970: 2_000_000_000))  // then signed in to another account
    await accounts.use(b: true)
    _ = try await padSync.sync(account: "work@example.com")
    #expect(await accounts.b.data(at: "inbox/b1.pdf") != nil)
    await accounts.use(b: false)
    _ = try await padSync.sync(account: "sam@example.com")
    #expect(await accounts.a.data(at: "inbox/a1.pdf") == nil)
}

@Test func removalsSavedBeforeAccountsWereNotedBelongToTheFirstAccountSeen() async throws {
    let accounts = TwoAccounts()
    let mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: mac) }
    try write(#"{"removed":["gone"],"removeFromDrive":["gone"]}"#, mac, "sync-state.json")
    #expect(SyncEngine.removedBooks(savedIn: mac) == ["gone"])
    _ = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: accounts).sync(account: "sam@example.com")
    #expect(await accounts.a.data(at: "removed/gone.json") != nil)
    #expect(SyncEngine.removedBooks(savedIn: mac) == ["gone"])
}

/// A Drive that refuses inbox sidecar uploads (the book's title) a given number of times.
private actor RefusesSidecars: DriveStore {
    let inner: MemoryDrive
    private var refusals: Int
    init(_ inner: MemoryDrive, refusals: Int) { (self.inner, self.refusals) = (inner, refusals) }
    func list() async throws -> [SyncFile] { try await inner.list() }
    func download(_ file: SyncFile, to destination: URL) async throws { try await inner.download(file, to: destination) }
    func upload(_ source: URL, as path: String, replacing id: String?) async throws -> SyncFile {
        if SyncLayout.isInbox(path), path.hasSuffix(".json"), refusals > 0 {
            refusals -= 1
            throw URLError(.networkConnectionLost)
        }
        return try await inner.upload(source, as: path, replacing: id)
    }
    func delete(_ file: SyncFile) async throws { try await inner.delete(file) }
}

@Test func anInboxBookWaitsForItsTitleToGoUpFirst() async throws {
    let drive = MemoryDrive()
    let pad = try temporaryRoot(), mac = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: pad); try? FileManager.default.removeItem(at: mac) }
    try write("%PDF", pad, "inbox/u1.pdf")
    try write(#"{"title":"Clean Code"}"#, pad, "inbox/u1.json")
    let padSync = SyncEngine(root: pad, device: "ipad1", role: .pad, store: RefusesSidecars(drive, refusals: 1))
    let failed = try await padSync.sync()
    #expect(!failed.problems.isEmpty && failed.uploaded == 0)
    #expect(await drive.data(at: "inbox/u1.pdf") == nil)  // never there without its title
    _ = try await padSync.sync()
    #expect(await drive.data(at: "inbox/u1.pdf") != nil)
    #expect(await drive.data(at: "inbox/u1.json") != nil)
    let arrived = try await SyncEngine(root: mac, device: "mac1", role: .mac, store: drive).sync().arrived
    #expect(arrived.map(\.lastPathComponent) == ["u1.pdf"] && read(mac, "inbox/u1.json") == #"{"title":"Clean Code"}"#)
}

/// After a clash, the time counted under the old id is only taken off while that id's file is really there: in
/// another Google account's library (where the old id never wrote) this device's whole history counts and goes up.
@Test func timeCountedUnderAnOldIDIsOnlyLeftOutWhereThatIDsFileIs() async throws {
    let accounts = TwoAccounts()
    let a = try temporaryRoot(), b = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
    try write(#"{"title":"MCP"}"#, a, "books/mcp/book.json")
    try write(#"{"log":{"d1":100}}"#, a, "books/mcp/progress.json")
    _ = try await SyncEngine(root: a, device: "mac1", role: .mac, store: accounts).sync(account: "sam@example.com")
    try FileManager.default.removeItem(at: b)
    try FileManager.default.copyItem(at: a, to: b)  // a restored copy, same id
    try write(#"{"log":{"d1":100,"d2":10}}"#, a, "books/mcp/progress.json")
    _ = try await SyncEngine(root: a, device: "mac1", role: .mac, store: accounts).sync(account: "sam@example.com")
    try write(#"{"log":{"d1":100,"d2":20}}"#, b, "books/mcp/progress.json")
    #expect(try await SyncEngine(root: b, device: "mac1", role: .mac, store: accounts).sync(account: "sam@example.com").deviceClash)
    // Right after the clash, before the old id's file has come down: nothing is taken off yet.
    #expect(studied(b, "mcp") == 120)
    let copy = SyncEngine(root: b, device: "mac-2", role: .mac, store: accounts)
    _ = try await copy.sync(account: "sam@example.com")
    #expect(studied(b, "mcp") == 130)  // the shared history once (in mac1's file), each copy's own time once
    #expect(await accounts.a.data(at: "books/mcp/progress/mac-2.json") == Data(#"{"log":{"d2":20}}"#.utf8))
    // Another Google account: mac1 never wrote there, so none of this device's time is counted elsewhere.
    await accounts.use(b: true)
    _ = try await copy.sync(account: "work@example.com")
    #expect(read(b, "books/mcp/devices/mac1.json") == nil)
    #expect(studied(b, "mcp") == 120)
    #expect(await accounts.b.data(at: "books/mcp/progress/mac-2.json") == Data(#"{"log":{"d1":100,"d2":20}}"#.utf8))
    // And back: the shared history is counted once again.
    await accounts.use(b: false)
    _ = try await copy.sync(account: "sam@example.com")
    #expect(studied(b, "mcp") == 130)
    #expect(await accounts.a.data(at: "books/mcp/progress/mac-2.json") == Data(#"{"log":{"d2":20}}"#.utf8))
}
