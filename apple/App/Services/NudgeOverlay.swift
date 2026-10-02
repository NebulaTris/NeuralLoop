// A silly nudge on screen: a floating card in the middle of the screen where Pip zooms in big (sad or shocked) with a
// big emoji and the message while the sound plays, then shrinks away when the sound ends. Clicking it opens NeuralLoop.
// Notification banners can't show anything that big, so this is the app's own window; the banner still arrives
// (silently) for Notification Center. Reduce Motion fades instead of zooming.

#if os(macOS)
import AppKit
import NeuralLoopCore
import Observation
import SwiftUI

@MainActor
final class NudgeOverlay: NSObject, NSSoundDelegate {
    static let shared = NudgeOverlay()

    private var panel: NSPanel?
    private var sound: NSSound?
    private var closing: Task<Void, Never>?
    private let state = OverlayState()

    func show(_ nudge: Nudge, volume: Double) {
        hide(now: true)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = CGSize(width: 560, height: 640)
        let frame = screen.visibleFrame
        let panel = NSPanel(contentRect: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: NudgeOverlayView(nudge: nudge, pose: NudgeSounds.pose(nudge.mood), state: state) { [weak self] in
            self?.hide()
            NSApp.activate(ignoringOtherApps: true)
            Notifier.shared.openBook?("")
        })
        self.panel = panel
        panel.orderFrontRegardless()
        state.shown = true

        // Gone once the sound ends (or after a few seconds without one).
        let played = NudgeSounds.url(nudge.mood).flatMap { NSSound(contentsOf: $0, byReference: true) }
        played?.delegate = self
        played?.volume = Float(volume)
        sound = played
        let seconds = (played?.play() == true ? played?.duration : nil) ?? 4
        closing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(seconds, 2.5) + 0.6))
            if !Task.isCancelled { self?.hide() }
        }
    }

    nonisolated func sound(_ sound: NSSound, didFinishPlaying finished: Bool) {
        Task { @MainActor in self.hide() }
    }

    /// Shrink away, then close.
    func hide(now: Bool = false) {
        closing?.cancel()
        sound?.delegate = nil
        sound?.stop()
        sound = nil
        guard let panel else { return }
        self.panel = nil
        state.shown = false
        if now { panel.orderOut(nil); return }
        Task {
            try? await Task.sleep(for: .seconds(0.45))
            panel.orderOut(nil)
        }
    }
}

@MainActor @Observable
final class OverlayState {
    var shown = false
}

struct NudgeOverlayView: View {
    let nudge: Nudge
    let pose: PipPose
    let state: OverlayState
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var visible: Bool { state.shown && appeared }

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
        .background(RoundedRectangle(cornerRadius: 34, style: .continuous).fill(Theme.paper).shadow(color: .black.opacity(0.28), radius: 30, y: 12))
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).stroke(Theme.accent.opacity(0.5), lineWidth: 3))
        .scaleEffect(visible || reduceMotion ? 1 : 0.15)
        .opacity(visible ? 1 : 0)
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(response: 0.55, dampingFraction: 0.6), value: visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onAppear { appeared = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens NeuralLoop")
    }
}
#endif
