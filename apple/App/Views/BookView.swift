// A book: chapters in order (each unlocks when the one before it is closed), and a chapter's five-step loop.

import NeuralLoopCore
import SwiftUI

struct BookView: View {
    @Environment(Library.self) private var library
    @Environment(\.controlActiveState) private var active
    @State private var session: BookSession
    @State private var selected: Int?

    init(entry: BookEntry) { _session = State(initialValue: BookSession(entry: entry)) }

    var body: some View {
        HStack(spacing: 0) {
            chapterList.frame(width: 290)
            Divider()
            if let n = selected, let chapter = session.book.chapters.first(where: { $0.n == n }) {
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
            if library.entry(session.entry.id)?.preparing != true {
                Button("Prepare more") { library.prepareMore(session.entry.id) }
            }
        }
        .onAppear {
            selected = session.progress.last?.n ?? session.book.chapters.first?.n
            session.startClock { [active] in active == .key }
        }
        .onDisappear { session.stopClock() }
        .onChange(of: library.entry(session.entry.id)?.lastLine) { session.reloadBook() }
        .task {
            // New chapters and items appear while Pip is still preparing the book.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                session.reloadBook()
            }
        }
    }

    private var chapterList: some View {
        List(selection: $selected) {
            Section("Chapters") {
                ForEach(session.book.chapters, id: \.n) { chapter in
                    let unlocked = Loop.isUnlocked(session.progress, session.book.chapters, chapter.n)
                    HStack(spacing: 10) {
                        Text("\(chapter.n)").font(Theme.display(14)).frame(width: 26, height: 26)
                            .background(Theme.accentSoft, in: Circle()).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.title).font(Theme.body(14)).lineLimit(2)
                            Text(caption(chapter, unlocked: unlocked)).font(Theme.body(11)).foregroundStyle(Theme.ink3)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(chapter.title).font(Theme.display(28)).foregroundStyle(Theme.ink)
                stepBar
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
            Divider()
            ScrollView {
                Group {
                    switch stage {
                    case .prime: ListenStep(session: session, chapter: chapter)
                    case .read: ReadStep(session: session, chapter: chapter)
                    case .recall: RecallStep(session: session, chapter: chapter)
                    case .map: MapStep(chapter: chapter)
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
                withAnimation(.spring) { celebrate = true }
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
        .transition(.scale(scale: 0.85).combined(with: .opacity))
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
