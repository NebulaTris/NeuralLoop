// How a silly nudge arrives: the big on-screen Pip (with its own sound) only when nothing else is going on. While the
// screen is locked, a full-screen app or presentation is in front, or the microphone is in use (a call or a meeting is
// likely), Pip stays a notification, whose sound keeps to Focus and the Mac's alert volume. The app looks; this decides.

import CoreGraphics
import Foundation

/// What's going on at the Mac right now, as far as the app can tell.
public struct NudgeMoment: Equatable, Sendable {
    public var screenLocked = false
    /// The app in front has a window covering a whole display (any of them).
    public var fullScreenInFront = false
    /// Some app is recording from the default microphone.
    public var microphoneInUse = false

    public init(screenLocked: Bool = false, fullScreenInFront: Bool = false, microphoneInUse: Bool = false) {
        (self.screenLocked, self.fullScreenInFront, self.microphoneInUse) = (screenLocked, fullScreenInFront, microphoneInUse)
    }
}

public enum NudgeDelivery {
    /// The big Pip on screen (true), or a notification only, carrying the sound itself (false).
    public static func showsBigPip(_ mood: NudgeMood, settings: NudgeSettings, moment: NudgeMoment) -> Bool {
        mood != .gentle && settings.bigPip && !moment.screenLocked && !moment.fullScreenInFront && !moment.microphoneInUse
    }

    /// Whether it's worth asking the Mac what's going on (windows, the microphone): only for a silly nudge that may
    /// show the big Pip. A gentle nudge is always just a notification.
    public static func needsMoment(_ mood: NudgeMood, settings: NudgeSettings) -> Bool {
        mood != .gentle && settings.bigPip
    }

    /// Whether any of these windows covers all of `screen` (same coordinates; a point or two of slack).
    public static func fillsScreen(_ windows: [CGRect], screen: CGRect, slack: CGFloat = 2) -> Bool {
        let inner = screen.insetBy(dx: slack, dy: slack)
        return windows.contains { $0.contains(inner) }
    }

    /// Whether any of these windows covers a whole display, whichever it is (a full-screen video on a second display
    /// counts too: the big Pip's sound would play over it).
    public static func fillsAnyScreen(_ windows: [CGRect], screens: [CGRect], slack: CGFloat = 2) -> Bool {
        screens.contains { fillsScreen(windows, screen: $0, slack: slack) }
    }
}
