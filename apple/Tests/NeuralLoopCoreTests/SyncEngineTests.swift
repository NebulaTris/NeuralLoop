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
    #expect(await drive.data(at: "books/mcp/progress/mac-2.json") == Data(#"{"log":{"d":3}}"#.utf8))
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

/// What's in the Drive besides the devices' notes about themselves.
private func libraryFiles(_ drive: MemoryDrive) async throws -> [SyncFile] {
    try await drive.list().filter { SyncLayout.deviceInfo($0.path) == nil }
}
