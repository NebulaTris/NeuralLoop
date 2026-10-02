// What a silly nudge sounds like and which Pip it shows. A sound is NeuralLoop-<name>.caf, looked for in the app (none
// ship yet: sounds need a licence that allows it) and then in ~/Library/Sounds, where `scripts/install-nudge-sounds.sh`
// puts your own; without one, the usual chime plays. Notification sounds keep to Focus and the system's alert volume.

#if os(macOS)
import AppKit
import NeuralLoopCore
import SwiftUI
import UserNotifications

@MainActor
enum NudgeSounds {
    static func fileName(_ mood: NudgeMood) -> String? {
        switch mood {
        case .gentle: nil
        case .sadViolin: "NeuralLoop-sad-violin.caf"
        case .sadMeow: "NeuralLoop-sad-meow.caf"
        case .shocked: "NeuralLoop-fahhh.caf"
        }
    }

    static func url(_ mood: NudgeMood) -> URL? {
        guard let name = fileName(mood) else { return nil }
        if let bundled = Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: "caf") { return bundled }
        let mine = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds/\(name)")
        return FileManager.default.fileExists(atPath: mine.path) ? mine : nil
    }

    static func sound(_ mood: NudgeMood) -> UNNotificationSound {
        guard url(mood) != nil, let name = fileName(mood) else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(name))
    }

    static func pose(_ mood: NudgeMood) -> PipPose {
        switch mood {
        case .gentle: .hop
        case .sadViolin, .sadMeow: .sad
        case .shocked: .shocked
        }
    }

    /// Pip as a picture for the notification (silly nudges only), in a fresh temporary file: the system takes it over.
    static func picture(_ mood: NudgeMood) -> URL? {
        guard mood != .gentle else { return nil }
        let renderer = ImageRenderer(content: PipView(pose: pose(mood), size: 240, interactive: false))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pip-\(UUID().uuidString).png")
        return (try? png.write(to: file)) != nil ? file : nil
    }
}
#endif
