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

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, bookId: String, sound: UNNotificationSound = .default, picture: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.userInfo = ["bookId": bookId]
        if let picture, let attachment = try? UNNotificationAttachment(identifier: "pip", url: picture) {
            content.attachments = [attachment]
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func news(before: Book?, after: Book?) -> (chapters: [Chapter], finished: Bool) {
        guard let before, let after else { return ([], false) }
        let news = BookNews.between(before, after)
        return (news.readyChapters, news.finished)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let bookId = response.notification.request.content.userInfo["bookId"] as? String
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if let bookId { openBook?(bookId) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
