// "Chapter 1 is ready to study" and "Your book is ready": system notifications while Pip prepares books.

import AppKit
import Foundation
import NeuralLoopCore
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// Set by the app: open the main window on a book when a notification is clicked.
    var openBook: ((String) -> Void)?
    /// Set by the app's views (SwiftUI's `openWindow`): opens a library window when none is left.
    var openMainWindow: (() -> Void)?

    /// Brings NeuralLoop's library window to the front, opening one if it was closed.
    func showLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            if main.isMiniaturized { main.deminiaturize(nil) }
            main.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    enum Permission { case notAsked, allowed, off }

    func permission() async -> Permission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .off
        default: .allowed
        }
    }

    /// Asks macOS (the first time it shows its prompt); once turned off, only System Settings can turn it back on.
    func ask() async -> Permission {
        if await permission() == .off { Self.openSystemSettings(); return .off }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await permission()
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "app.neuralloop.books"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") { NSWorkspace.shared.open(url) }
    }

    /// `sound: nil` arrives silently (the on-screen Pip is playing it). `picture` is only drawn when notifications are
    /// allowed (it would go nowhere otherwise), and its file is removed if the system won't take it.
    func post(title: String, body: String, bookId: String, sound: UNNotificationSound? = .default,
              picture: (@MainActor () -> URL?)? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.userInfo = ["bookId": bookId]
        Task {
            if let picture, await permission() == .allowed, let file = picture() {
                do {
                    content.attachments = [try UNNotificationAttachment(identifier: "pip", url: file)]
                } catch {
                    try? FileManager.default.removeItem(at: file)  // it goes out without the picture
                }
            }
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let bookId = response.notification.request.content.userInfo["bookId"] as? String
        await MainActor.run {
            showLibrary()  // a nudge names no book: the library it is
            if let bookId, !bookId.isEmpty { openBook?(bookId) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
