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

// The Drive app folder is only as trustworthy as every device signed in to it: names that would land outside the
// library folder, or on a device's private files, are never downloaded.
@Test func remoteNamesThatClimbOutOfTheLibraryAreIgnored() {
    let evil = ["books/../../x", "books/a/../../../Library/Preferences/x.plist", "books/a/..", "books/a/.", "books/a//b",
                "inbox/..", "inbox/../../x", "inbox/", "inbox/.hidden.pdf", "inbox/a b.pdf", "inbox/u1.sh", "/etc/passwd",
                "books/a/b\\..\\..\\x", "books/a/x\0.json", "books/a/progress/../../x.json", "books/a/progress/me/../x.json",
                "books/a/progress.json", "books/a/meta.json", "books/a/state.json", "books/a/devices/mac1.json",
                "books/a/source.pdf", "books/A B/book.json", "other/x", "sync-state.json"]
    for path in evil { #expect(!SyncLayout.isSafeRemote(path), "\(path)") }
    for path in ["books/mcp/book.json", "books/mcp/chapters/img/01-02.png", "books/mcp/progress/pad-1a2b.json", "inbox/0f1e-9a.epub",
                 "inbox/0f1e-9a.json"] {
        #expect(SyncLayout.isSafeRemote(path), "\(path)")
    }
    let remote = evil.enumerated().map { SyncFile(path: $1, md5: "m", size: 1, id: "r\($0)") }
    #expect(SyncPlan.make(local: [], remote: remote, device: "ipad1", role: .pad, wantedMedia: ["a:1"]).downloads.isEmpty)
    #expect(SyncPlan.make(local: [], remote: remote, device: "mac1", role: .mac).isEmpty)
}

@Test func progressFromADeviceWithAStrangeNameIsIgnored() {
    #expect(SyncLayout.progressDevice("books/mcp/progress/..json") == nil)
    #expect(SyncLayout.progressDevice("books/mcp/progress/.json") == nil)
    #expect(SyncLayout.progressDevice("books/mcp/progress/a b.json") == nil)
    #expect(SyncLayout.progressDevice("books/mcp/progress//x.json") == nil)
}

@Test func filesBiggerThanTwoGigabytesStayInTheDrive() {
    let remote = [SyncFile(path: "books/mcp/media/01-video.mp4", md5: "m", size: SyncLayout.maxDownloadBytes + 1, id: "r1"),
                  SyncFile(path: "books/mcp/media/01-podcast.m4a", md5: "m", size: 40_000_000, id: "r2")]
    let plan = SyncPlan.make(local: [], remote: remote, device: "ipad1", role: .pad, wantedMedia: ["mcp:1"])
    #expect(plan.downloads.map(\.path) == ["books/mcp/media/01-podcast.m4a"])
}
