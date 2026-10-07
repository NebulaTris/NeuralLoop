// Keeps this device's library and the Google Drive app folder in step (spec 07): every couple of minutes while signed
// in, and right away when asked. The Mac uploads what it prepares and picks up books added on other devices; an iPad
// downloads books (media only for chapters that are opened) and sends books it adds to the Mac.

import Foundation
import NeuralLoopCore
import Observation
import Security
#if os(iOS)
import UIKit
#endif

@MainActor @Observable
final class DriveSync {
    static let shared = DriveSync()

    private(set) var syncing = false
    private(set) var lastSync: Date?
    private(set) var lastReport: SyncReport?
    private(set) var problem: String?
    /// Every device on the library (this one first), from the last sync.
    private(set) var devices: [DeviceInfo] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var again = false
    /// Signing out (or signed out from here): no sync starts until the next sign-in.
    @ObservationIgnored private var signingOutNow = false
    @ObservationIgnored private var soonTask: Task<Void, Never>?
    @ObservationIgnored private var engine: SyncEngine?
    /// Mac: a book waits in the inbox (the file, and the title from its sidecar). Return true once it's being prepared;
    /// false means it's offered again later (a few times, further apart).
    @ObservationIgnored var onArrived: (URL, String?) -> Bool = { _, _ in false }
    /// Something changed on disk: the library should look again.
    @ObservationIgnored var onChanged: () -> Void = {}
    /// Another device removed a book: let go of it here too.
    @ObservationIgnored var onRemovedElsewhere: (String) -> Void = { _ in }
    /// Books removed on any device (a new book never reuses one of their ids). Read from sync-state.json at launch,
    /// signed in or not.
    private(set) var removedBooks: Set<String> = SyncEngine.removedBooks(savedIn: DriveSync.root)

    static let root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app.neuralloop.books", isDirectory: true)

    /// A stable id for this device (its progress file in the Drive is named after it). Kept in a this-device-only
    /// Keychain item, so a backup restored onto another device doesn't bring it along; if two devices still end up
    /// sharing one (sync notices, `SyncReport.deviceClash`), this one takes a new id.
    private(set) var device: String = DeviceIdentity.load(role: DriveSync.role)

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

    /// What this device is called in the device list.
    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "This Mac"
        #else
        UIDevice.current.name
        #endif
    }

    /// The engine, made on first use (making it touches nothing on the network).
    private func sharedEngine() -> SyncEngine {
        if let engine { return engine }
        let account = DriveAccount.shared
        let store: GoogleDrive = Self.fakeDrive.map { GoogleDrive(base: $0) { "development" } }
            ?? GoogleDrive { force in try await account.accessToken(forceRefresh: force) }
        let made = SyncEngine(root: Self.root, device: device, role: Self.role, store: store, name: Self.deviceName)
        engine = made
        return made
    }

    /// Signed in just now: start syncing right away rather than at the next tick (and this device's note goes up again).
    func signedIn() {
        signingOutNow = false
        let engine = sharedEngine()
        Task {
            await engine.signedIn()
            if started { await syncNow() } else { start() }
        }
    }

    /// Signing out of the library: syncing stops at once (nothing more is asked of the Drive, so nothing puts the note
    /// back), a sync already underway gets a few seconds to finish, then this device's note leaves the Drive (best
    /// effort; a note left behind stops being listed after 90 days), and the device list here empties. The engine
    /// itself never writes the note again until the next sign-in, even if that sync is still going.
    func signingOut() async {
        signingOutNow = true
        again = false
        soonTask?.cancel()
        let deadline = Date().addingTimeInterval(15)
        while syncing, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if DriveAccount.shared.isSignedIn || Self.fakeDrive != nil {
            try? await sharedEngine().removeNote()
        }
        devices = []
    }

    /// "Remove all books": books waiting in the inbox leave the Drive too (the caller empties the local inbox).
    func forgetInbox() {
        let engine = sharedEngine()
        Task {
            await engine.forgetInbox()
            await syncNow()
        }
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

    /// Something changed here (you reviewed a card, finished a step, answered a quiz): sync a few seconds later, once
    /// things settle. The study clock doesn't call this; its minutes go with the next sync.
    func soon() {
        soonTask?.cancel()
        soonTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { await self?.syncNow() }
        }
    }

    func syncNow() async {
        let account = DriveAccount.shared
        guard account.isSignedIn || Self.fakeDrive != nil, !signingOutNow else { return }
        guard !syncing else { again = true; return }  // asked while syncing: go once more right after
        syncing = true
        defer {
            syncing = false
            if again, !signingOutNow { again = false; Task { await syncNow() } }
        }
        var engine = sharedEngine()
        do {
            var report = try await engine.sync(wantedMedia: wantedMedia, account: account.email)
            if report.deviceClash, !signingOutNow {
                // Another device has been using this id: take a new one and sync as that.
                device = DeviceIdentity.replace(role: Self.role)
                self.engine = nil
                engine = sharedEngine()
                report = try await engine.sync(wantedMedia: wantedMedia, account: account.email)
            }
            removedBooks = await engine.removedBooks
            for id in report.removedElsewhere { onRemovedElsewhere(id) }
            for book in report.arrived {
                let sidecar = book.deletingPathExtension().appendingPathExtension("json")
                let details = (try? JSONSerialization.jsonObject(with: Data(contentsOf: sidecar))) as? [String: Any]
                if onArrived(book, details?["title"] as? String) { await engine.markTaken(book) } else { await engine.markFailed(book) }
            }
            lastReport = report
            lastSync = Date()
            if !report.devices.isEmpty, account.isSignedIn || Self.fakeDrive != nil { devices = DeviceInfo.unique(report.devices) }
            problem = report.problems.first
            if report.downloaded > 0 || report.forgotten > 0 {
                NotificationCenter.default.post(name: BookSession.progressArrived, object: nil)  // open books merge again
            }
            if report.downloaded > 0 || report.forgotten > 0 || !report.arrived.isEmpty || !report.removedElsewhere.isEmpty { onChanged() }
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// This device's sync id, in a Keychain item that stays on this device: not synced through iCloud, not restored onto
/// another device from a backup (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly). The Mac uses the data protection
/// keychain when the app's signature allows it, and the login keychain otherwise (which Migration Assistant does copy;
/// sync's clash check covers that). Ids saved in UserDefaults by earlier versions move over once.
enum DeviceIdentity {
    private static let account = "SYNC_DEVICE_ID"
    private static let legacyKey = "deviceID"

    static func load(role: SyncRole) -> String {
        if let saved = read(), BookID.isValid(saved) { return saved }
        let legacy = UserDefaults.standard.string(forKey: legacyKey).flatMap { BookID.isValid($0) ? $0 : nil }
        let id = legacy ?? fresh(role)
        if write(id) { UserDefaults.standard.removeObject(forKey: legacyKey) } else { UserDefaults.standard.set(id, forKey: legacyKey) }
        return id
    }

    /// A new id, for when another device turned out to share this one.
    static func replace(role: SyncRole) -> String {
        let id = fresh(role)
        if !write(id) { UserDefaults.standard.set(id, forKey: legacyKey) }
        return id
    }

    private static func fresh(_ role: SyncRole) -> String { "\(role.rawValue)-\(UUID().uuidString.prefix(8).lowercased())" }

    private static func base(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Keychain.service,
                                    kSecAttrAccount as String: account, kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        #if os(macOS)
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    private static var variants: [Bool] {
        #if os(macOS)
        [true, false]
        #else
        [true]
        #endif
    }

    private static func read() -> String? {
        for dataProtection in variants {
            var query = base(dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    private static func write(_ id: String) -> Bool {
        let fields: [String: Any] = [kSecValueData as String: Data(id.utf8),
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        for dataProtection in variants {
            let query = base(dataProtection: dataProtection)
            var status = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
            if status == errSecItemNotFound { status = SecItemAdd(query.merging(fields) { $1 } as CFDictionary, nil) }
            if status == errSecSuccess { return true }
        }
        return false
    }
}
