// The guided tour: a few short pages, each with a little animated scene, that show how NeuralLoop works before the
// first book. New installs see it instead of a plain welcome; Help → Take the Tour (iPad: Settings) shows it again.
// Back/Next, the arrow keys, or the dots move between pages; Skip is always there. Reduce Motion rests every scene.

import NeuralLoopCore
import SwiftUI

struct GuidedTour: View {
    let done: () -> Void
    @State private var page = Self.startPage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages = TourPage.all

    /// Development: `-NLTourPage 3` opens the tour on its fourth page (for screenshots).
    static var startPage: Int {
        #if DEBUG
        UserDefaults.standard.integer(forKey: "NLTourPage")
        #else
        0
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("A quick tour").font(Theme.body(12)).foregroundStyle(Theme.ink3)
                Spacer()
                Button("Skip") { done() }.buttonStyle(.borderless).foregroundStyle(Theme.ink2)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24).padding(.top, 18)

            ZStack {
                ForEach(pages.indices, id: \.self) { i in
                    if i == page {
                        pageView(pages[i])
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                                              removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack(spacing: 14) {
                Button("Back") { go(page - 1) }.disabled(page == 0).keyboardShortcut(.leftArrow, modifiers: [])
                Spacer()
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { i in
                        Button { go(i) } label: {
                            Capsule().fill(i == page ? Theme.accent : Theme.line).frame(width: i == page ? 22 : 8, height: 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Page \(i + 1) of \(pages.count)")
                    }
                }
                Spacer()
                if page < pages.count - 1 {
                    Button("Next") { go(page + 1) }.buttonStyle(.borderedProminent).keyboardShortcut(.rightArrow, modifiers: [])
                } else {
                    Button("Let's go") { done() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.bottom, 22)
        }
        .frame(width: 680, height: 600)
        .background(Theme.paper)
        .tint(Theme.accent)
    }

    private func go(_ target: Int) {
        let next = min(max(target, 0), pages.count - 1)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85)) { page = next }
    }

    private func pageView(_ p: TourPage) -> some View {
        VStack(spacing: 14) {
            scene(p.scene).frame(height: 290).frame(maxWidth: .infinity)
            Text(p.title).font(Theme.display(26)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text(p.body).font(Theme.body(15)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                .frame(maxWidth: 500).fixedSize(horizontal: false, vertical: true)
            if p.scene == .setUp { TourSetUp() }
        }
        .padding(.horizontal, 30)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func scene(_ scene: TourPage.Scene) -> some View {
        switch scene {
        case .hello: PipView(pose: .hop, size: 230, interactive: true)
        case .addBook: EmptyShelfGuide().scaleEffect(0.9)
        case .prepare: PrepareScene()
        case .loop: LoopScene()
        case .map: MapScene()
        case .company: CompanyScene()
        case .setUp: PipView(pose: .hug, size: 200)
        }
    }
}

/// What each page says. Kept together so the tour reads as one story.
struct TourPage: Identifiable {
    enum Scene { case hello, addBook, prepare, loop, map, company, setUp }
    let scene: Scene
    let title: String
    let body: String
    var id: String { title }

    static var all: [TourPage] {
        [
            TourPage(scene: .hello, title: "Hi, I'm Pip!",
                     body: "I turn a book you own into small learning loops, one chapter at a time, so it actually sticks. Here's how it works."),
            TourPage(scene: .addBook, title: "Bring a book",
                     body: Self.onMac ? "Drag a PDF or EPUB onto the window, or click Add a book. Your book stays on your Mac."
                                      : "Add a PDF or EPUB from Files. Your Mac prepares it and it shows up here."),
            TourPage(scene: .prepare, title: "Pip prepares each chapter",
                     body: "Google NotebookLM makes podcasts, videos, quizzes, and more, or use your own AI. The first chapter is ready first, so you can start in minutes."),
            TourPage(scene: .loop, title: "Five small steps per chapter",
                     body: "Listen & watch, read with a guide, recall it in your own words, remake the map, then remember with flashcards that come back right before you'd forget."),
            TourPage(scene: .map, title: "Chapters unlock as you go",
                     body: "Close a chapter's loop and the next one opens. Your book map grows with every chapter you map, and your year fills in a square for every day you study."),
            TourPage(scene: .company, title: "Pip keeps you company",
                     body: "Find me in the menu bar to pick up where you left off. I nudge gently, at most once a day, and get a bit dramatic if you're away too long (you can turn that off)."),
            TourPage(scene: .setUp, title: "Let's get you set up",
                     body: Self.onMac ? "Sign in with Google for NotebookLM and your library, and let me send notifications. You can do both later in Settings."
                                      : "Sign in with Google to bring your library over from your Mac. You can do it later in Settings."),
        ]
    }

    static var onMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
}

/// The last page's buttons: Google, and notifications on the Mac.
private struct TourSetUp: View {
    #if os(macOS)
    @Environment(AISettings.self) private var settings
    #endif
    @State private var drive = DriveAccount.shared

    var body: some View {
        VStack(spacing: 10) {
            #if os(macOS)
            if settings.account.signedIn {
                Label(settings.account.email.isEmpty ? "Signed in to NotebookLM" : "Signed in as \(settings.account.email)", systemImage: "checkmark.circle.fill")
                    .font(Theme.body(14)).foregroundStyle(Theme.mint)
            } else {
                Button { Task { await GoogleSignIn.everything(settings) } } label: {
                    Label(settings.signingIn ? "Waiting for Google…" : "Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(settings.signingIn)
            }
            NotificationsAllowed(compact: true)
            #else
            if drive.isSignedIn {
                Label("Signed in\(drive.email.map { " as \($0)" } ?? "")", systemImage: "checkmark.circle.fill").font(Theme.body(14)).foregroundStyle(Theme.mint)
            } else {
                Button { Task { await drive.signIn() } } label: {
                    Label(drive.signingIn ? "Waiting for Google…" : "Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(drive.signingIn || !drive.isConfigured)
            }
            #endif
        }
        #if os(macOS)
        .task { await settings.refreshAccount() }
        #endif
    }
}

// MARK: Scenes

/// Pip at the laptop, with what makes each chapter ticking in one by one.
private struct PrepareScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let items = ["🎧 Podcast", "🎬 Video", "📖 Reading guide", "❓ Quiz", "🗺️ Mind map", "🃏 Flashcards"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: reduceMotion)) { timeline in
            let shown = reduceMotion ? items.count : Int(timeline.date.timeIntervalSinceReferenceDate / 0.7) % (items.count + 3)
            HStack(spacing: 26) {
                PipView(pose: .study, size: 200, interactive: false)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            Image(systemName: i < shown ? "checkmark.circle.fill" : "circle.dotted")
                                .foregroundStyle(i < shown ? Theme.mint : Theme.ink3)
                            Text(items[i]).font(Theme.body(15)).foregroundStyle(i < shown ? Theme.ink : Theme.ink3)
                        }
                        .animation(.easeOut(duration: 0.25), value: shown)
                    }
                }
                .padding(18).background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
        }
    }
}

/// The five steps lighting up in turn, with Pip changing to match.
private struct LoopScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let steps: [(String, PipPose)] = [("Listen & watch", .read), ("Read", .study), ("Recall", .hop), ("Map", .play), ("Remember", .proud)]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10, paused: reduceMotion)) { timeline in
            let current = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate / 1.5) % steps.count
            VStack(spacing: 16) {
                PipView(pose: steps[current].1, size: 170, interactive: false)
                HStack(spacing: 4) {
                    ForEach(steps.indices, id: \.self) { i in
                        HStack(spacing: 5) {
                            Text("\(i + 1)").font(Theme.display(12, .bold)).foregroundStyle(i == current ? .white : Theme.accent)
                                .frame(width: 20, height: 20).background(i == current ? Theme.accent : Theme.accentSoft, in: Circle())
                            Text(steps[i].0).font(Theme.display(13, .medium)).foregroundStyle(i == current ? Theme.ink : Theme.ink3)
                                .lineLimit(1).fixedSize()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(i == current ? Theme.surface : .clear, in: Capsule())
                        .scaleEffect(i == current && !reduceMotion ? 1.05 : 1)
                        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: current)
                    }
                }
            }
        }
    }
}

/// Chapters sprouting on a golden-angle spiral around the book, like the book map.
private struct MapScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let colors: [Color] = [Theme.accent, Theme.mint, Theme.sky, Theme.rose, .purple]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { timeline in
            let count = reduceMotion ? 12 : Int(timeline.date.timeIntervalSinceReferenceDate / 0.45) % 18
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let points = (0..<min(count, 14)).map { k -> CGPoint in
                    let angle = Double(k) * 2.39996 - 0.6
                    let radius = 78 + 16 * Double(k).squareRoot()  // around Pip, not behind
                    return CGPoint(x: center.x + radius * cos(angle) * 1.7, y: center.y + radius * sin(angle) * 0.95)
                }
                for (k, point) in points.enumerated() {
                    var line = Path()
                    line.move(to: k == 0 ? center : points[max(0, k - 2)])
                    line.addLine(to: point)
                    context.stroke(line, with: .color(Theme.line), lineWidth: 2)
                }
                for (k, point) in points.enumerated() {
                    let r = 9.0 + Double(k % 3) * 2
                    context.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)), with: .color(colors[k % colors.count]))
                }
            }
            .overlay { PipView(pose: .proud, size: 110, interactive: false) }
        }
    }
}

/// A little menu bar with Pip in it, and a nudge sliding in.
private struct CompanyScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion)) { timeline in
            let t = reduceMotion ? 0.5 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 5) / 5
            let showing = t > 0.25 && t < 0.85
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "wifi").foregroundStyle(Theme.ink3)
                    Image(systemName: "battery.75").foregroundStyle(Theme.ink3)
                    PipView(pose: .hop, size: 34, interactive: false)
                        .padding(4).background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                    Text("Fri 9:41").font(Theme.body(12)).foregroundStyle(Theme.ink2)
                }
                .padding(.horizontal, 14).frame(height: 40)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                HStack(alignment: .top, spacing: 12) {
                    Spacer()
                    HStack(spacing: 10) {
                        PipView(pose: .play, size: 52, interactive: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("🐾 4 cards are ready").font(Theme.display(14)).foregroundStyle(Theme.ink)
                            Text("About 1 min with Pip, then you're done for today.").font(Theme.body(12)).foregroundStyle(Theme.ink2)
                        }
                    }
                    .padding(12).frame(width: 330, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                    .offset(x: showing || reduceMotion ? 0 : 380)
                    .opacity(showing || reduceMotion ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.75), value: showing)
                }
                HStack(spacing: 10) {
                    PipView(pose: .sad, size: 90, interactive: false)
                    Text("…and a tiny sad violin if you vanish 🎻").font(Theme.body(13)).foregroundStyle(Theme.ink2)
                }
            }
            .padding(.horizontal, 40)
        }
    }
}

/// The very first launch: Google sign-in first (the login opens by itself), then the tour. Help → Take the Tour
/// shows only the tour.
struct FirstLaunch: View {
    let done: () -> Void
    @State private var signingIn = true

    var body: some View {
        if signingIn {
            SignInFirst { withAnimation(.easeInOut(duration: 0.3)) { signingIn = false } }
        } else {
            GuidedTour(done: done)
        }
    }
}

/// "Sign in with Google to get started": opens Google's login right away and moves on once it's done.
private struct SignInFirst: View {
    let next: () -> Void
    #if os(macOS)
    @Environment(AISettings.self) private var settings
    #endif
    @State private var drive = DriveAccount.shared
    @State private var started = false
    /// Checking whether someone's already signed in (a few seconds): the button waits, so it can't start a second sign-in.
    /// On the Mac it starts out checking, so there's no moment before the check when a click could slip through.
    #if os(macOS)
    @State private var checking = true
    #else
    @State private var checking = false
    #endif
    /// "Not now": nothing opens afterwards, even if the check was still going.
    @State private var declined = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 10)
            PipView(pose: .hop, size: 200)
            Text("Hi, I'm Pip! Let's sign you in").font(Theme.display(28)).foregroundStyle(Theme.ink)
            Text(Self.why).font(Theme.body(15)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                .frame(maxWidth: 480).fixedSize(horizontal: false, vertical: true)
            if busy {
                Label("Waiting for Google… finish signing in in the window that opened.", systemImage: "hourglass")
                    .font(Theme.body(14)).foregroundStyle(Theme.accent)
            } else {
                Button { Task { await signIn() } } label: { Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(checking)
                if checking {
                    Text("Checking whether you're already signed in…").font(Theme.body(12)).foregroundStyle(Theme.ink2)
                }
            }
            if !note.isEmpty { Text(note).font(Theme.body(12)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 480) }
            Spacer(minLength: 10)
            Button("Not now") { declined = true; next() }.buttonStyle(.borderless).foregroundStyle(Theme.ink2).keyboardShortcut(.cancelAction)
        }
        .padding(30)
        .frame(width: 680, height: 600)
        .background(Theme.paper)
        .tint(Theme.accent)
        .task {
            guard !started else { return }
            started = true
            #if os(macOS)
            checking = true
            await settings.refreshAccount()  // already signed in to NotebookLM: no browser window for nothing
            checking = false
            #endif
            // The refresh ignores cancellation, so "Not now" during it is only seen here.
            switch FirstSignIn.next(signedIn: signedIn, canSignIn: canSignIn, declined: declined,
                                    cancelled: Task.isCancelled, signingIn: busy) {
            case .moveOn: next()
            case .signIn: await signIn()
            case .stay: break
            }
        }
    }

    private static var why: String {
        #if os(macOS)
        "With Google, NotebookLM makes your podcasts, videos, and quizzes, and your library follows you to your iPad. Google's sign-in opens in your browser; Pip never sees your password."
        #else
        "Sign in with the Google account your Mac uses, and your books, progress, and cards come over from it."
        #endif
    }

    private func signIn() async {
        #if os(macOS)
        await GoogleSignIn.everything(settings, refreshed: true)  // the check on arrival just asked who's signed in
        #else
        await drive.signIn()
        #endif
        if signedIn, !declined { next() }
    }

    private var signedIn: Bool {
        #if os(macOS)
        settings.account.signedIn
        #else
        drive.isSignedIn
        #endif
    }

    private var busy: Bool {
        #if os(macOS)
        settings.signingIn || drive.signingIn
        #else
        drive.signingIn
        #endif
    }

    private var canSignIn: Bool {
        #if os(macOS)
        true
        #else
        drive.isConfigured
        #endif
    }

    private var note: String {
        #if os(macOS)
        settings.accountNote
        #else
        drive.note
        #endif
    }
}
