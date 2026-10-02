// A silly nudge on screen: a floating card in the middle of the screen where Pip zooms in big (sad or shocked) with a
// big emoji and the message while the sound plays, then shrinks away when the sound ends. Clicking the card opens
// NeuralLoop's library. Notification banners can't show anything that big, so this is the app's own window; the banner
// still arrives (silently) for Notification Center. Reduce Motion fades instead of zooming.
//
// It only shows when nothing else is going on (`NudgeDelivery.showsBigPip` decides; `moment()` looks): not on a locked
// screen, not over a full-screen app or presentation, and not while the microphone is in use (a call or a meeting is
// likely). Then the notification carries the sound instead, so it keeps to Focus. Focus itself can't be read here:
// INFocusStatusCenter needs the Communication Notifications entitlement, which this app doesn't have.

#if os(macOS)
import AppKit
import CoreAudio
import NeuralLoopCore
import Observation
import SwiftUI

@MainActor
final class NudgeOverlay {
    static let shared = NudgeOverlay()

    private var panel: NSPanel?
    private var state: OverlayState?
    private var sound: NSSound?
    private var soundEnded: SoundEnded?
    private var closing: Task<Void, Never>?
    /// Which overlay is showing: an old sound's (or timer's) end never closes a newer one.
    private var generation = 0
    /// Room around the card for its shadow; the panel is no bigger than that.
    private static let margin: CGFloat = 44

    /// The screen the big Pip would use: the one you're working on.
    static var screen: NSScreen? { NSScreen.main ?? NSScreen.screens.first }

    /// Shows the big Pip; true when it's playing the nudge's sound itself (false: the notification should carry it).
    @discardableResult
    func show(_ nudge: Nudge, volume: Double) -> Bool {
        hide(now: true)
        guard let screen = Self.screen else { return false }
        generation += 1
        let shown = generation
        let state = OverlayState()
        let host = NSHostingView(rootView: NudgeOverlayView(nudge: nudge, pose: NudgeSounds.pose(nudge.mood), state: state,
                                                            margin: Self.margin) {
            NudgeOverlay.shared.hide()
            Notifier.shared.showLibrary()
        })
        let size = host.fittingSize
        let frame = screen.visibleFrame
        let panel = NSPanel(contentRect: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]  // never over a full-screen app's space
        panel.contentView = host
        (self.panel, self.state) = (panel, state)
        panel.orderFrontRegardless()
        state.shown = true
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(nudge.words). \(nudge.body)",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])

        // Gone once the sound ends (or after a few seconds without one).
        let played = NudgeSounds.url(nudge.mood).flatMap { NSSound(contentsOf: $0, byReference: true) }
        let ended = SoundEnded { Task { @MainActor in NudgeOverlay.shared.ended(shown) } }
        played?.delegate = ended
        played?.volume = Float(volume)
        (sound, soundEnded) = (played, ended)
        let playing = played?.play() == true
        let seconds = playing ? (played?.duration ?? 4) : 4
        closing = Task {
            try? await Task.sleep(for: .seconds(max(seconds, 2.5) + 0.6))
            if !Task.isCancelled { NudgeOverlay.shared.ended(shown) }
        }
        return playing
    }

    private func ended(_ shown: Int) {
        if shown == generation { hide() }
    }

    /// Shrink away, then close.
    func hide(now: Bool = false) {
        closing?.cancel()
        sound?.delegate = nil
        sound?.stop()
        (sound, soundEnded) = (nil, nil)
        guard let panel else { return }
        state?.shown = false
        (self.panel, state) = (nil, nil)
        if now { panel.orderOut(nil); return }
        Task {
            try? await Task.sleep(for: .seconds(0.45))
            panel.orderOut(nil)
        }
    }

    // MARK: is now a good time?

    /// What's going on at the Mac right now.
    static func moment() -> NudgeMoment {
        NudgeMoment(screenLocked: screenLocked(), fullScreenInFront: fullScreenInFront(), microphoneInUse: microphoneInUse())
    }

    private static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// The app in front has a window covering the whole screen the big Pip would use (full screen, or presenting).
    /// Window bounds need no Screen Recording permission (only window names do).
    private static func fullScreenInFront() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, let screen,
              let primary = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let bounds = windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == front,
                  let rect = window[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: rect)
        }
        // Window bounds are measured from the top left of the main display; NSScreen frames from its bottom left.
        let f = screen.frame
        let screenRect = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        return NudgeDelivery.fillsScreen(bounds, screen: screenRect)
    }

    /// Some app is recording from the default microphone (a call or a meeting is likely). Asking needs no permission.
    private static func microphoneInUse() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}

/// One overlay's sound ending (each overlay has its own, so an old sound's end is told apart).
private final class SoundEnded: NSObject, NSSoundDelegate {
    let onEnd: () -> Void
    init(_ onEnd: @escaping () -> Void) { self.onEnd = onEnd }
    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) { onEnd() }
}

/// Each panel's own: a panel shrinking away never springs back when the next one shows.
@MainActor @Observable
final class OverlayState {
    var shown = false
}

struct NudgeOverlayView: View {
    let nudge: Nudge
    let pose: PipPose
    let state: OverlayState
    let margin: CGFloat
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var visible: Bool { state.shown && appeared }
    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 34, style: .continuous) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {  // the emoji on the left: Pip's rain cloud and "!" are on the right
                PipView(pose: pose, size: 320, interactive: false)
                if !nudge.emoji.isEmpty {
                    Text(nudge.emoji).font(.system(size: 92)).offset(x: -16, y: -18)
                        .rotationEffect(.degrees(visible && !reduceMotion ? 10 : -10))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
                }
            }
            Text(nudge.words).font(Theme.display(28)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text(nudge.body).font(Theme.body(15)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 30).padding(.vertical, 26)
        .frame(width: 470)
        .background(card.fill(Theme.paper).shadow(color: .black.opacity(0.28), radius: 30, y: 12))
        .overlay(card.stroke(Theme.accent.opacity(0.5), lineWidth: 3))
        .contentShape(card)  // only the card takes clicks
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens NeuralLoop")
        .accessibilityAction(.default, open)
        .scaleEffect(visible || reduceMotion ? 1 : 0.15)
        .opacity(visible ? 1 : 0)
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.55, dampingFraction: 0.6), value: visible)
        .padding(margin)  // room for the shadow
        .onAppear { appeared = true }
    }
}
#endif
