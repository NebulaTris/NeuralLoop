import Foundation
import Testing
@testable import NeuralLoopCore

private func file(_ path: String, _ md5: String = "a", id: String? = nil) -> SyncFile { SyncFile(path: path, md5: md5, size: 10, id: id) }

@Test func theMacUploadsBookFilesThatChangedAndOnlyItsOwnProgress() {
    let local = [file("books/mcp/book.json", "new"), file("books/mcp/media/01-podcast.m4a", "same"),
                 file("books/mcp/progress/mac1.json", "p2"), file("books/mcp/progress/ipad1.json", "stale")]
    let remote = [file("books/mcp/book.json", "old", id: "r1"), file("books/mcp/media/01-podcast.m4a", "same", id: "r2"),
                  file("books/mcp/progress/mac1.json", "p1", id: "r3"), file("books/mcp/progress/ipad1.json", "fresh", id: "r4")]
    let plan = SyncPlan.make(local: local, remote: remote, device: "mac1", role: .mac)
    #expect(plan.uploads.map(\.path) == ["books/mcp/book.json", "books/mcp/progress/mac1.json"])
    #expect(plan.uploads.map(\.id) == ["r1", "r3"])                    // replaces, never duplicates
    #expect(plan.downloads.map(\.path) == ["books/mcp/progress/ipad1.json"])  // other devices' progress comes down
}

@Test func thePadDownloadsBooksButMediaOnlyForOpenedChapters() {
    let remote = [file("books/mcp/book.json"), file("books/mcp/chapters/01.md"), file("books/mcp/chapters/img/01-01.png"),
                  file("books/mcp/media/01-podcast.m4a"), file("books/mcp/media/02-video.mp4"), file("books/mcp/chapters/02.pdf")]
    let plan = SyncPlan.make(local: [], remote: remote, device: "ipad1", role: .pad, wantedMedia: ["mcp:1"])
    #expect(Set(plan.downloads.map(\.path)) == ["books/mcp/book.json", "books/mcp/chapters/01.md", "books/mcp/chapters/img/01-01.png",
                                                 "books/mcp/media/01-podcast.m4a"])
    #expect(plan.uploads.isEmpty)
    // A pad never pushes book files, even ones it has locally.
    #expect(SyncPlan.make(local: [file("books/mcp/book.json", "x")], remote: [], device: "ipad1", role: .pad).uploads.isEmpty)
}

@Test func booksAddedOnThePadTravelThroughTheInbox() {
    let padLocal = [file("inbox/u1.epub"), file("inbox/u1.json")]
    let up = SyncPlan.make(local: padLocal, remote: [], device: "ipad1", role: .pad)
    #expect(up.uploads.map(\.path) == ["inbox/u1.epub", "inbox/u1.json"])
    let remote = [file("inbox/u1.epub", id: "i1"), file("inbox/u1.json", id: "i2"), file("inbox/u0.pdf", id: "i0")]
    let mac = SyncPlan.make(local: [], remote: remote, device: "mac1", role: .mac, takenInbox: ["inbox/u0.pdf"])
    #expect(mac.downloads.map(\.path) == ["inbox/u1.epub", "inbox/u1.json"])
    #expect(mac.deletes.map(\.id) == ["i0"])
}

@Test func layoutPathsReadBack() {
    #expect(SyncLayout.book("books/mcp/media/01-video.mp4") == "mcp" && SyncLayout.book("inbox/x.pdf") == nil)
    #expect(SyncLayout.progressDevice("books/mcp/progress/mac-1.json") == "mac-1" && SyncLayout.progressDevice("books/mcp/book.json") == nil)
    #expect(SyncLayout.mediaChapter("books/mcp/media/03-podcast-lines/001.wav") == 3 && SyncLayout.mediaChapter("books/mcp/chapters/01.md") == nil)
    #expect(SyncLayout.isPrivate("pipeline.log") && SyncLayout.isPrivate(".running") && SyncLayout.isPrivate("media/01-podcast-lines/001.wav"))
    #expect(!SyncLayout.isPrivate("book.json") && !SyncLayout.isPrivate("media/01-podcast.m4a"))
    #expect(SyncLayout.isPrivate("index.html") && SyncLayout.isPrivate("app.js") && !SyncLayout.isPrivate("chapters/img/app.js"))
}
