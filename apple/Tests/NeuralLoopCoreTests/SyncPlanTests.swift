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
    #expect(up.uploads.map(\.path) == ["inbox/u1.json", "inbox/u1.epub"])  // the title goes first
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
    #expect(SyncLayout.isPrivate("activity.json"))  // the live progress feed: rewritten every half second, Mac only
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

private func dated(_ path: String, _ md5: String, id: String, at seconds: Double?) -> SyncFile {
    SyncFile(path: path, md5: md5, size: 10, id: id, modified: seconds.map { Date(timeIntervalSince1970: $0) })
}

// Two creates of the same name (a retried upload, two syncs racing) leave duplicates in the Drive: keep the newest,
// delete the rest, and only ever read or replace the one that's kept.
@Test func duplicateDriveFilesKeepTheNewestAndTheRestAreDeleted() {
    let remote = [dated("books/mcp/book.json", "old", id: "r1", at: 100), dated("books/mcp/book.json", "new", id: "r2", at: 200),
                  dated("books/mcp/book.json", "older", id: "r0", at: nil), dated("books/mcp/progress/mac1.json", "p", id: "r3", at: 50)]
    let pad = SyncPlan.make(local: [], remote: remote.shuffled(), device: "ipad1", role: .pad)
    #expect(pad.downloads.compactMap(\.id).sorted() == ["r2", "r3"])
    #expect(pad.deletes.compactMap(\.id).sorted() == ["r0", "r1"])
    let mac = SyncPlan.make(local: [file("books/mcp/book.json", "mine")], remote: remote.shuffled(), device: "mac1", role: .mac)
    #expect(mac.uploads.map(\.id) == ["r2"] && mac.deletes.compactMap(\.id).sorted() == ["r0", "r1"])
    // Without times (an older stand-in), the choice is still the same on every device.
    let undated = [file("books/mcp/book.json", "a", id: "x1"), file("books/mcp/book.json", "b", id: "x2")]
    #expect(SyncPlan.make(local: [], remote: undated, device: "ipad1", role: .pad).downloads.map(\.id)
        == SyncPlan.make(local: [], remote: undated.reversed(), device: "ipad1", role: .pad).downloads.map(\.id))
}

// Migration Assistant or a backup restore can give two devices the same id. The one whose progress file in the Drive
// isn't what it last uploaded knows someone else writes it.
@Test func aProgressFileSomeoneElseWroteMeansTheDeviceIDIsShared() {
    let remote = [file("books/mcp/progress/mac1.json", "theirs", id: "r1"), file("books/other/progress/mac1.json", "same", id: "r2")]
    #expect(DeviceClash.found(remote: remote, device: "mac1", lastUploaded: ["books/mcp/progress/mac1.json": "mine"]))
    #expect(!DeviceClash.found(remote: remote, device: "mac1", lastUploaded: ["books/mcp/progress/mac1.json": "theirs"]))
    #expect(!DeviceClash.found(remote: remote, device: "mac1", lastUploaded: [:]))  // never uploaded here: nothing to compare
    // Our upload landed but its answer was lost: the Drive holds exactly what's here, so it's still ours.
    #expect(!DeviceClash.found(remote: remote, device: "mac1", lastUploaded: ["books/mcp/progress/mac1.json": "mine"],
                               local: ["books/mcp/progress/mac1.json": "theirs"]))
    #expect(!DeviceClash.found(remote: remote, device: "ipad1", lastUploaded: ["books/mcp/progress/mac1.json": "mine"]))
}

// An upload whose answer never came back (wifi dropped, the Mac slept) may still have landed: any of the last few
// md5s sent there count as ours, so it isn't mistaken for another device writing our file.
@Test func aProgressFileWeSentButNeverHeardBackAboutIsStillOurs() {
    let path = "books/mcp/progress/mac1.json"
    let remote = [file(path, "sent", id: "r1")]
    #expect(!DeviceClash.found(remote: remote, device: "mac1", lastUploaded: [path: "older"], attempted: [path: ["x", "sent"]],
                               local: [path: "newer"]))
    #expect(DeviceClash.found(remote: remote, device: "mac1", lastUploaded: [path: "older"], attempted: [path: ["x"]],
                              local: [path: "newer"]))
    #expect(SentProgress.remembered(["a", "b", "c", "d", "e"], adding: "f") == ["b", "c", "d", "e", "f"])
    #expect(SentProgress.remembered(["a", "b"], adding: "a") == ["b", "a"])
}

// After a new device id, the old id's progress files are ours: they leave the Drive (never counted as another
// device), unless someone else wrote them since (a real second device on that id), which is kept.
@Test func theOldIDsProgressIsOursUnlessSomeoneElseWroteIt() {
    let remote = [file("books/a/progress/mac1.json", "ours", id: "r1"), file("books/b/progress/mac1.json", "theirs", id: "r2"),
                  file("books/c/progress/mac1.json", "ours-c", id: "r3")]
    let retired = ["books/a/progress/mac1.json": ["ours"], "books/b/progress/mac1.json": ["ours-b"], "books/d/progress/mac1.json": ["x"]]
    let found = SentProgress.retiredOnDrive(remote: remote, retired: retired)
    #expect(found.ours.compactMap(\.id) == ["r1"])
    #expect(found.foreign == ["books/b/progress/mac1.json"])
}

@Test func inboxRetriesBackOffAndStopAfterFive() {
    #expect(InboxRetry.isDue(attempts: 0, last: 0, now: 0))
    #expect(!InboxRetry.isDue(attempts: 1, last: 0, now: 60_000) && InboxRetry.isDue(attempts: 1, last: 0, now: 120_000))
    #expect(!InboxRetry.isDue(attempts: 3, last: 0, now: 7 * 60_000) && InboxRetry.isDue(attempts: 3, last: 0, now: 8 * 60_000))
    #expect(!InboxRetry.isDue(attempts: 5, last: 0, now: 1e12) && InboxRetry.gaveUp(attempts: 5) && !InboxRetry.gaveUp(attempts: 4))
}
