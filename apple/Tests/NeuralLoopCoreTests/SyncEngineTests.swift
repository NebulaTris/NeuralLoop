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
    let left = try await drive.list()
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
