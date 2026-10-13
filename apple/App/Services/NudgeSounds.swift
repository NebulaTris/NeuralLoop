// What a silly nudge sounds like and which Pip it shows. A sound is NeuralLoop-<name>.caf, looked for in the app (the
// three in Resources, see NOTICE.md) and then in ~/Library/Sounds (`scripts/install-nudge-sounds.sh`); without one, the
// usual chime plays. A notification's sound keeps to Focus and the Mac's alert volume; the big on-screen Pip plays its
// sound itself (NSSound, at Settings' volume), which Focus doesn't silence, so it only shows when `NudgeDelivery` says
// nothing else is going on, and otherwise the notification carries the sound.

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

    /// A missing sound file falls back to the usual chime: a nudge is never silent by accident.
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

    private static var previewing: NSSound?

    /// Plays a mood's sound right here, at `volume` (Settings → Nudges, and a test nudge the big Pip can't show):
    /// what you asked to hear, whatever the notification settings or Focus say. True when it's playing.
    @discardableResult
    static func play(_ mood: NudgeMood, volume: Double) -> Bool {
        previewing?.stop()
        previewing = url(mood).flatMap { NSSound(contentsOf: $0, byReference: true) }
        previewing?.volume = Float(volume)
        return previewing?.play() == true
    }
}
#endif
