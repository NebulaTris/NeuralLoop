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

@Test func md5MatchesDrivesChecksums() throws {
    #expect(FileHash.md5(Data("hello".utf8)) == "5d41402abc4b2a76b9719d911017c592")
}
