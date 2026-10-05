// What the app can see of real studying (spec 09): whether a view is on screen in the active app, when the person
// last touched the keyboard, mouse, or trackpad, and which pages of the chapter are showing. The rules that decide
// what counts live in NeuralLoopCore (`ReadingCredit`, `PlayCoverage`); this only measures.

import NeuralLoopCore
import Observation
import PDFKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(macOS)
typealias PlatformView = NSView
#else
typealias PlatformView = UIView
#endif

/// Holds an invisible view placed behind something, to ask whether that something can be seen right now.
@MainActor
final class ViewProbe {
    weak var view: PlatformView?

    var isGone: Bool { view == nil }

    /// Its window is visible (not minimized, not hidden behind other windows), the app is active, and some of it is
    /// on screen. `fullScreenPlayer`: a video's own full-screen window counts too (macOS moves it to its own window).
    func isShown(fullScreenPlayer: Bool = false) -> Bool {
        guard let view else { return false }
        #if os(macOS)
        guard NSApp.isActive else { return false }
        if let window = view.window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible),
           !view.visibleRect.isEmpty { return true }
        if fullScreenPlayer, let key = NSApp.keyWindow, key !== view.window, key.styleMask.contains(.fullScreen) { return true }
        return false
        #else
        guard let window = view.window, window.windowScene?.activationState == .foregroundActive else { return false }
        return view.convert(view.bounds, to: nil).intersects(window.bounds)
        #endif
    }

    /// The reading window is the one taking input (always so on an iPad, where the app is in front).
    var isKey: Bool {
        #if os(macOS)
        view?.window?.isKeyWindow == true
        #else
        view?.window != nil
        #endif
    }
}

#if os(macOS)
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Place behind a view (`.background(VisibilityProbe(probe:))`) to measure it.
struct VisibilityProbe: NSViewRepresentable {
    let probe: ViewProbe
    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        probe.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { probe.view = view }
}
#else
struct VisibilityProbe: UIViewRepresentable {
    let probe: ViewProbe
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        probe.view = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { probe.view = view }
}
#endif

/// Follows what's on screen in the Read step: the chapter's pages (PDF) or ~300-word sections (text), what each
/// needs, and the person's last input.
@MainActor @Observable
final class ReadingTracker {
    /// Seconds each page or section needs to count as read (`ReadingCredit.needed`), once known.
    var needs: [Double] = []
    var isPDF = false
    @ObservationIgnored let probe = ViewProbe()
    @ObservationIgnored weak var pdfView: PDFView?
    /// Text sections' places in the chapter's scroll view, and that view's height.
    @ObservationIgnored private var sections: [Int: (top: Double, bottom: Double)] = [:]
    @ObservationIgnored var viewport: Double = 0
    @ObservationIgnored private var touched: Date?
    #if os(iOS)
    @ObservationIgnored var scrolling: NSKeyValueObservation?
    #endif

    /// A sign someone is there (an iPad scroll or page turn; the Mac asks the system instead).
    func poke() { touched = Date() }

    /// When the person last used the keyboard, mouse, or trackpad (Mac), or scrolled or turned a page (iPad).
    var lastInput: Date? {
        #if os(macOS)
        let anyInput = CGEventType(rawValue: ~0)
        let types: [CGEventType] = anyInput.map { [$0] }
            ?? [.keyDown, .flagsChanged, .mouseMoved, .scrollWheel, .leftMouseDown, .rightMouseDown, .leftMouseDragged]
        let seconds = types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
        return seconds.isFinite ? Date(timeIntervalSinceNow: -seconds) : touched
        #else
        return touched
        #endif
    }

    func sectionMoved(_ index: Int, top: Double, bottom: Double) {
        if let old = sections[index], abs(old.top - top) > 1 { poke() }  // the text scrolled
        sections[index] = (top, bottom)
    }

    /// The pages or sections really on screen now.
    func visible() -> [Int] {
        if isPDF { return visiblePDFPages() }
        let spans = sections.map { ReadingCredit.Span(page: $0.key, top: $0.value.top, bottom: $0.value.bottom) }
        return ReadingCredit.visible(spans, top: 0, bottom: viewport)
    }

    private func visiblePDFPages() -> [Int] {
        guard let view = pdfView, let document = view.document else { return [] }
        #if os(macOS)
        let shown = view.visibleRect  // what's left after the chapter's own scrolling clips it
        #else
        guard let window = view.window else { return [] }
        let shown = view.convert(view.convert(view.bounds, to: nil).intersection(window.bounds), from: nil)
        #endif
        guard !shown.isEmpty else { return [] }
        let spans = view.visiblePages.map { page in
            let frame = view.convert(page.bounds(for: view.displayBox), from: page)
            return ReadingCredit.Span(page: document.index(for: page), top: frame.minY, bottom: frame.maxY)
        }
        return ReadingCredit.visible(spans, top: shown.minY, bottom: shown.maxY)
    }

    /// What each page of a PDF chapter needs, from its words (a picture-only page needs the minimum). Read off the
    /// main thread.
    static func pdfNeeds(_ url: URL) async -> [Double] {
        await Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: url) else { return [] }
            return (0..<document.pageCount).map { ReadingCredit.needed(words: ReadingCredit.words(document.page(at: $0)?.string ?? "")) }
        }.value
    }
}

/// The chapter scroll view's height, for working out which text sections are on screen.
private struct ChapterViewportKey: EnvironmentKey { static let defaultValue: Double = 0 }
extension EnvironmentValues {
    var chapterViewport: Double {
        get { self[ChapterViewportKey.self] }
        set { self[ChapterViewportKey.self] = newValue }
    }
}

/// How far along a step is, shown while it isn't done: a small ring and a few plain words.
struct StepProgressRow: View {
    let fraction: Double
    let text: String
    var detail: String = ""

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 4)
                Circle().trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(Theme.body(14)).foregroundStyle(Theme.ink).monospacedDigit()
                if !detail.isEmpty {
                    Text(detail).font(Theme.body(12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
