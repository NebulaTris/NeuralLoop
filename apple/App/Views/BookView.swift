// A book: chapters in order (each unlocks when the one before it is closed), and a chapter's five-step loop.

import NeuralLoopCore
import SwiftUI

struct BookView: View {
    let entry: BookEntry
    @State private var session: BookSession?

    var body: some View {
        Group {
            if let session { BookContent(session: session) } else { Color.clear }
        }
        // Made once per book (not on every redraw of the shelf behind it).
        .task(id: entry.id) { if session?.entry.id != entry.id { session = BookSession(entry: entry) } }
    }
}

/// The open book left the shelf (removed here or on another device): say so warmly and offer the way back.
struct BookGoneView: View {
    @Environment(Library.self) private var library
    @State private var shown = false  // a moment's grace while the shelf is first read, so this never flashes

    var body: some View {
        VStack(spacing: 14) {
            if shown {
                PipView(pose: .read, size: 140)
                Text("This book is no longer on your shelf").font(Theme.display(22)).foregroundStyle(Theme.ink)
                Text("It was removed, here or on another of your devices. Everything else is right where you left it.")
                    .font(Theme.body(15)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button { library.path = [] } label: { Label("Back to your shelf", systemImage: "books.vertical") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            shown = true
        }
    }
}

struct BookContent: View {
    @Environment(Library.self) private var library
    #if os(macOS)
    @Environment(\.controlActiveState) private var active
    private var isFront: Bool { active == .key }
    #else
    @Environment(\.scenePhase) private var active
    private var isFront: Bool { active == .active }
    #endif
    let session: BookSession
    @State private var selected: Int?
    #if DEBUG
    @State private var showingMap = UserDefaults.standard.bool(forKey: "NLBookMap")  // development: `-NLBookMap YES`
    #else
    @State private var showingMap = false
    #endif

    var body: some View {
        HStack(spacing: 0) {
            chapterList.frame(width: Self.listWidth)
            Divider()
            if showingMap {
                BookMapView(session: session) { n in showingMap = false; selected = n }
            } else if let n = selected, let chapter = session.book.chapters.first(where: { $0.n == n }) {
                if Loop.isUnlocked(session.progress, session.book.chapters, n) {
                    ChapterView(session: session, chapter: chapter).id(n)
                } else {
                    LockedChapter(chapter: chapter, previous: session.book.chapters.last(where: { $0.n < n }))
                }
            } else {
                VStack(spacing: 12) {
                    PipView(pose: .read, size: 160)
                    Text("Pick a chapter to start its loop.").font(Theme.display(20)).foregroundStyle(Theme.ink2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.paper)
        .navigationTitle(session.book.title)
        .toolbar {
            Button { showingMap.toggle() } label: {
                Label(showingMap ? "Chapters" : "Book map", systemImage: showingMap ? "list.bullet" : "point.3.filled.connected.trianglepath.dotted")
            }
            .help("Your map of the book grows with every chapter you map")
            #if os(macOS)
            if library.entry(session.entry.id)?.preparing != true {
                Button("Prepare more") { library.prepareMore(session.entry.id) }
            }
            #endif
        }
        .onAppear {
            selected = session.progress.last?.n ?? session.book.chapters.first?.n
            session.isActive = isFront
            session.startClock()
        }
        .onChange(of: active) { session.isActive = isFront }
        .onDisappear { session.isActive = false; session.stopClock() }
        // New chapters and items appear while Pip is still preparing the book (the library reads book.json off the main thread).
        .onChange(of: library.entry(session.entry.id)?.book) { _, fresh in if let fresh, fresh != session.book { session.book = fresh } }
    }

    private var chapterList: some View {
        List(selection: Binding(get: { selected }, set: { selected = $0; showingMap = false })) {
            Section("Chapters") {
                ForEach(session.book.chapters, id: \.n) { chapter in
                    let unlocked = Loop.isUnlocked(session.progress, session.book.chapters, chapter.n)
                    HStack(spacing: 10) {
                        Text("\(chapter.n)").font(Theme.display(14)).frame(width: 26, height: 26)
                            .background(Theme.accentSoft, in: Circle()).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.title).font(Theme.body(14)).lineLimit(2)
                            Text(caption(chapter, unlocked: unlocked)).font(Theme.body(11)).foregroundStyle(Self.captionStyle)
                        }
                        Spacer()
                        if !unlocked { Image(systemName: "lock.fill").foregroundStyle(Theme.ink3).font(.caption) }
                        else if Loop.isClosed(session.progress, chapter.n) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint) }
                    }
                    .padding(.vertical, 4)
                    .tag(chapter.n)
                    .disabled(!unlocked)
                }
            }
        }
        .listStyle(.sidebar)
    }

    #if os(macOS)
    private static let listWidth: CGFloat = 290
    #else
    private static let listWidth: CGFloat = 260  // leaves the chapter room on an iPad held upright
    #endif

    #if os(macOS)
    private static let captionStyle = AnyShapeStyle(Theme.ink3)
    #else
    private static let captionStyle = AnyShapeStyle(.secondary)  // stays readable on the iPad's filled selection
    #endif

    private func caption(_ chapter: Chapter, unlocked: Bool) -> String {
        if !unlocked { return "Opens when the chapter before is done" }
        if chapter.status["study"] != .done { return chapter.status["study"] == .working ? "Pip is preparing it…" : "Waiting its turn" }
        if let next = Loop.nextStage(session.progress, chapter.n) { return "Next: \(next.label)" }
        return "Loop closed"
    }
}

struct ChapterView: View {
    let session: BookSession
    let chapter: Chapter
    @State private var stage: Stage = .prime
    @State private var celebrate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(chapter.title).font(Theme.display(28)).foregroundStyle(Theme.ink)
                #if os(macOS)
                stepBar
                #else
                ScrollView(.horizontal, showsIndicators: false) { stepBar.padding(1) }  // an upright iPad is narrower
                #endif
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
            Divider()
            ScrollView {
                Group {
                    switch stage {
                    case .prime: ListenStep(session: session, chapter: chapter)
                    case .read: ReadStep(session: session, chapter: chapter)
                    case .recall: RecallStep(session: session, chapter: chapter)
                    case .map: MapStep(session: session, chapter: chapter)
                    case .space: RememberStep(session: session, chapter: chapter)
                    }
                }
                .padding(28)
                .frame(maxWidth: 860, alignment: .leading)
                finishButton.padding(.horizontal, 28).padding(.bottom, 30)
            }
        }
        .overlay { if celebrate { closedOverlay } }
        .onAppear {
            // On an iPad, opening a chapter brings its podcast, video, and pages (and the next chapter's) from the Drive.
            DriveSync.shared.want(book: session.entry.id, chapter: chapter.n)
            #if DEBUG
            if let forced = UserDefaults.standard.string(forKey: "NLStage").flatMap(Stage.init) { stage = forced; return }
            #endif
            if let last = session.progress.last, last.n == chapter.n, let s = Stage(rawValue: last.stage) { stage = s }
            else if let next = Loop.nextStage(session.progress, chapter.n) { stage = next }
        }
        .onChange(of: stage) { session.remember(chapter.n, stage) }
    }

    private var stepBar: some View {
        HStack(spacing: 8) {
            ForEach(Stage.allCases, id: \.self) { s in
                let done = session.progress.loop[String(chapter.n)]?[s.rawValue] != nil
                Button { stage = s } label: {
                    HStack(spacing: 6) {
                        Image(systemName: done ? "checkmark.circle.fill" : icon(s))
                        Text(s.label).font(Theme.display(14, .medium))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(stage == s ? Theme.accentSoft : Theme.surface, in: Capsule())
                    .overlay(Capsule().stroke(stage == s ? Theme.accent : Theme.line))
                    .foregroundStyle(stage == s ? Theme.accent : (done ? Theme.mint : Theme.ink2))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(_ s: Stage) -> String {
        switch s {
        case .prime: "headphones"
        case .read: "book"
        case .recall: "text.bubble"
        case .map: "point.3.connected.trianglepath.dotted"
        case .space: "rectangle.stack"
        }
    }

    private var finishButton: some View {
        Button {
            if session.complete(chapter.n, stage) {
                withAnimation(reduceMotion ? nil : .spring) { celebrate = true }
            } else if let next = Loop.nextStage(session.progress, chapter.n) {
                stage = next
            }
        } label: { Label("I've done this step", systemImage: "checkmark") }
            .buttonStyle(.borderedProminent)
            .disabled(session.progress.loop[String(chapter.n)]?[stage.rawValue] != nil)
    }

    private var closedOverlay: some View {
        VStack(spacing: 14) {
            PipView(pose: .hug, size: 200)
            Text("Loop closed!").font(Theme.display(32))
            Text("The next chapter is open. Pip is proud of you.").font(Theme.body(16)).foregroundStyle(Theme.ink2)
            Button("Keep going") { celebrate = false }.buttonStyle(.borderedProminent)
        }
        .padding(40)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.12), radius: 30, y: 10)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity))
    }
}

/// A chapter that opens once the one before it is closed. Pip keeps it safe; nothing to feel bad about.
struct LockedChapter: View {
    let chapter: Chapter
    let previous: Chapter?

    var body: some View {
        VStack(spacing: 14) {
            PipView(pose: .nap, size: 150)
            Text("“\(chapter.title)” is waiting for you").font(Theme.display(22))
            Text("It opens when you finish the loop for “\(previous?.title ?? "the chapter before")”. One chapter at a time is how it sticks.")
                .font(Theme.body(15)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
