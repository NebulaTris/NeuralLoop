// Keeps this device's library and the Google Drive app folder in step (spec 07): every couple of minutes while signed
// in, and right away when asked. The Mac uploads what it prepares and picks up books added on other devices; an iPad
// downloads books (media only for chapters that are opened) and sends books it adds to the Mac.

import Foundation
import NeuralLoopCore
import Observation

@MainActor @Observable
final class DriveSync {
    static let shared = DriveSync()

    private(set) var syncing = false
    private(set) var lastSync: Date?
    private(set) var lastReport: SyncReport?
    private(set) var problem: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var soonTask: Task<Void, Never>?
    @ObservationIgnored private var engine: SyncEngine?
    /// Mac: a book arrived in the inbox (the file, and the title from its sidecar). Return true once it's being prepared.
    @ObservationIgnored var onArrived: (URL, String?) -> Bool = { _, _ in false }
    /// Something changed on disk: the library should look again.
    @ObservationIgnored var onChanged: () -> Void = {}
    /// Another device removed a book: let go of it here too.
    @ObservationIgnored var onRemovedElsewhere: (String) -> Void = { _ in }
    /// Books removed on any device (a new book never reuses one of their ids).
    private(set) var removedBooks: Set<String> = []

    static let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app.neuralloop.books", isDirectory: true)

    /// A stable id for this device (its progress file in the Drive is named after it).
    static let device: String = {
        if let saved = UserDefaults.standard.string(forKey: "deviceID") { return saved }
        let made = "\(role.rawValue)-\(UUID().uuidString.prefix(8).lowercased())"
        UserDefaults.standard.set(made, forKey: "deviceID")
        return made
    }()

    #if os(macOS)
    static let role = SyncRole.mac
    #else
    static let role = SyncRole.pad
    #endif

    /// "book:chapter" keys whose media this device keeps (an iPad downloads media when a chapter is opened).
    private(set) var wantedMedia: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "wantedMedia") ?? [])

    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                await syncNow()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    /// Opening a chapter asks for its media and the next chapter's (so studying works offline once a chapter is open).
    func want(book: String, chapter: Int) {
        let keys: Set<String> = ["\(book):\(chapter)", "\(book):\(chapter + 1)"]
        guard !keys.isSubset(of: wantedMedia) else { return }
        wantedMedia.formUnion(keys)
        UserDefaults.standard.set(Array(wantedMedia), forKey: "wantedMedia")
        Task { await syncNow() }
    }

    /// Development builds only: `-NLFakeDrive http://127.0.0.1:8765` syncs through scripts/fake_drive.py instead of
    /// Google, to test the Mac and iPad together without a Google account. Release builds ignore it.
    static var fakeDrive: String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "NLFakeDrive")
        #else
        return nil
        #endif
    }

    /// The engine, made on first use (making it touches nothing on the network).
    private func sharedEngine() -> SyncEngine {
        if let engine { return engine }
        let account = DriveAccount.shared
        let store: GoogleDrive = Self.fakeDrive.map { GoogleDrive(base: $0) { "development" } }
            ?? GoogleDrive { try await account.accessToken() }
        let made = SyncEngine(root: Self.root, device: Self.device, role: Self.role, store: store)
        engine = made
        Task { removedBooks = await made.removedBooks }
        return made
    }

    /// A book was removed here: it leaves the Drive (and every other device) on the next sync, even if that's later.
    func removed(book id: String) {
        removedBooks.insert(id)
        let engine = sharedEngine()
        Task {
            await engine.remove(book: id)
            await syncNow()
        }
    }

    /// Something changed here (you studied, reviewed a card): sync a few seconds later, once things settle.
    func soon() {
        soonTask?.cancel()
        soonTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { await self?.syncNow() }
        }
    }

    func syncNow() async {
        let account = DriveAccount.shared
        guard account.isSignedIn || Self.fakeDrive != nil else { return }
        guard !syncing else { again = true; return }  // asked while syncing: go once more right after
        syncing = true
        defer {
            syncing = false
            if again { again = false; Task { await syncNow() } }
        }
        let engine = sharedEngine()
        do {
            let report = try await engine.sync(wantedMedia: wantedMedia)
            removedBooks = await engine.removedBooks
            for id in report.removedElsewhere { onRemovedElsewhere(id) }
            for book in report.arrived {
                let sidecar = book.deletingPathExtension().appendingPathExtension("json")
                let details = (try? JSONSerialization.jsonObject(with: Data(contentsOf: sidecar))) as? [String: Any]
                if onArrived(book, details?["title"] as? String) { await engine.markTaken(book) }
            }
            lastReport = report
            lastSync = Date()
            problem = report.problems.first
            if report.downloaded > 0 || !report.arrived.isEmpty || !report.removedElsewhere.isEmpty { onChanged() }
        } catch {
            problem = error.localizedDescription
        }
    }
}
