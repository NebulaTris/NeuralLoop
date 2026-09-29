// The quiz, the mind map, remaking the map from memory, and the growing book map.

import NeuralLoopCore
import SwiftUI

// MARK: Quiz

/// Multiple choice, one question at a time, with hints, explanations, and a score. Progress is saved per chapter.
struct QuizView: View {
    let session: BookSession
    let chapter: Chapter
    var onDone: (label: String, action: () -> Void)? = nil
    @State private var picked: Int?
    @State private var showHint = false

    private static let letters = Array("ABCDEF")

    var body: some View {
        let quiz = session.quiz(chapter.n)
        let questions = chapter.quiz
        if quiz.i >= questions.count {
            scoreScreen(quiz, total: questions.count)
        } else {
            question(questions[quiz.i], quiz: quiz, total: questions.count)
        }
    }

    private func question(_ q: QuizQuestion, quiz: QuizProgress, total: Int) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    ForEach(0..<total, id: \.self) { i in
                        Capsule().fill(barColor(i, quiz: quiz)).frame(height: 6)
                    }
                }
                Text("Question \(quiz.i + 1) of \(total)").font(Theme.body(12)).foregroundStyle(Theme.ink3)
                Text(PlainMath.clean(q.q)).font(Theme.display(20)).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, option in
                    optionButton(i, option, q: q, quiz: quiz)
                }
                HStack {
                    if !q.hint.isEmpty, !showHint, picked == nil {
                        Button("Show a hint") { showHint = true }.buttonStyle(.bordered)
                    }
                    Spacer()
                    if picked != nil {
                        Button(quiz.i + 1 >= total ? "See my score" : "Next question") { next(quiz) }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }
                }
                if showHint { Text("💡 \(PlainMath.clean(q.hint))").font(Theme.body(13)).padding(10).background(Theme.butterSoft, in: RoundedRectangle(cornerRadius: 10)) }
            }
            VStack(spacing: 6) {
                Text(bubble(q)).font(Theme.body(12)).multilineTextAlignment(.center).padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                PipView(pose: picked == nil ? .read : (picked == q.a ? .hop : .read), size: 110)
            }
            .frame(width: 150)
        }
    }

    private func optionButton(_ i: Int, _ option: String, q: QuizQuestion, quiz: QuizProgress) -> some View {
        let answered = picked != nil
        let isRight = i == q.a
        let isPicked = i == picked
        let fill: Color = !answered ? Theme.surface : isRight ? Theme.mintSoft : isPicked ? Theme.roseSoft : Theme.surface
        return Button {
            guard picked == nil else { return }
            picked = i
            var updated = quiz
            if updated.results.count <= quiz.i { updated.results += Array(repeating: false, count: quiz.i - updated.results.count + 1) }
            updated.results[quiz.i] = isRight
            session.setQuiz(chapter.n, updated)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(String(Self.letters[min(i, 5)])).font(Theme.display(14)).frame(width: 26, height: 26)
                    .background(Theme.accentSoft, in: Circle()).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(PlainMath.clean(option)).font(Theme.body(14)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                    if answered, isRight || isPicked, i < q.why.count, !q.why[i].isEmpty {
                        Text(PlainMath.clean(q.why[i])).font(Theme.body(12)).foregroundStyle(Theme.ink2).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(answered)
    }

    private func barColor(_ i: Int, quiz: QuizProgress) -> Color {
        if i < quiz.i { return (i < quiz.results.count && quiz.results[i]) ? Theme.mint : Theme.rose }
        return i == quiz.i ? Theme.accent : Theme.line
    }

    private func bubble(_ q: QuizQuestion) -> String {
        guard let picked else { return "Take your time. Guessing and checking is how memory grows." }
        return picked == q.a ? "Yes! Exactly right." : "Close! The right one is highlighted."
    }

    private func next(_ quiz: QuizProgress) {
        var updated = quiz
        updated.i += 1
        session.setQuiz(chapter.n, updated)
        picked = nil
        showHint = false
    }

    private func scoreScreen(_ quiz: QuizProgress, total: Int) -> some View {
        let great = quiz.isGreat(outOf: total)
        return VStack(spacing: 12) {
            PipView(pose: great ? .proud : .hug, size: 140)
            Text("\(quiz.right) of \(total) right").font(Theme.display(24))
            Text(great ? "Wonderful! That chapter's really sinking in." : "Nice work. The ones you missed are great flashcard material.")
                .font(Theme.body(14)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
            HStack {
                if let onDone { Button(onDone.label, action: onDone.action).buttonStyle(.borderedProminent) }
                Button("Try again") { session.setQuiz(chapter.n, QuizProgress()); picked = nil }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: Mind map

/// The chapter's mind map as a tree that grows to the right; tap a branch to fold or unfold it.
struct MindMapTree: View {
    let map: MindNode

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            MindTreeNode(node: map, depth: 0, color: Theme.accent)
                .padding(20)
        }
        .frame(minHeight: 360, maxHeight: 620)
        .background(Theme.sunk, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text("Tap a branch to fold or unfold it").font(Theme.body(11)).foregroundStyle(Theme.ink3).padding(10)
        }
    }
}

private struct MindTreeNode: View {
    let node: MindNode
    let depth: Int
    let color: Color
    @State private var open: Bool

    init(node: MindNode, depth: Int, color: Color) {
        (self.node, self.depth, self.color) = (node, depth, color)
        _open = State(initialValue: depth < 1)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.3)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(node.name).font(depth == 0 ? Theme.display(16) : Theme.body(13)).foregroundStyle(Theme.ink)
                        .lineLimit(2).frame(maxWidth: 230, alignment: .leading)
                    if !node.children.isEmpty {
                        Image(systemName: open ? "minus.circle" : "plus.circle").font(.system(size: 11)).foregroundStyle(color)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(depth == 0 ? Theme.accentSoft : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(node.children.isEmpty)
            if open, !node.children.isEmpty {
                Rectangle().fill(color.opacity(0.6)).frame(width: 18, height: 1.5)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { i, child in
                        HStack(spacing: 0) {
                            Rectangle().fill(childColor(i).opacity(0.6)).frame(width: 14, height: 1.5)
                            MindTreeNode(node: child, depth: depth + 1, color: childColor(i))
                        }
                    }
                }
                .padding(.vertical, 2)
                .overlay(alignment: .leading) { Rectangle().fill(color.opacity(0.35)).frame(width: 1.5).padding(.vertical, 14) }
            }
        }
    }

    private func childColor(_ i: Int) -> Color { depth == 0 ? GraphPalette.color(i) : color }
}

// MARK: Remake from memory

struct RemakeView: View {
    let session: BookSession
    let chapter: Chapter
    let map: MindNode
    let onSeeFullMap: () -> Void
    @State private var guess = ""
    @State private var result: RemakeResult?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remake the map from memory").font(Theme.display(20))
            Text("Before you look: write the main branches of “\(map.name)” as you remember them, one per line. Add sub-ideas under a branch by starting the line with a dash.")
                .font(Theme.body(13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                if guess.isEmpty {
                    Text("Foundations\n- key terms\nIn practice\n- failure modes").font(Theme.body(14)).foregroundStyle(Theme.ink3).padding(14)
                }
                TextEditor(text: $guess).font(Theme.body(14)).scrollContentBackground(.hidden).padding(8)
            }
            .frame(minHeight: 150)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            HStack {
                Button("Compare with the real map") { compare() }.buttonStyle(.borderedProminent)
                if !note.isEmpty { Text(note).font(Theme.body(12)).foregroundStyle(Theme.ink2) }
            }
            if let result { comparison(result) }
        }
        .onAppear { guess = session.remakeGuess(chapter.n) }
        .onChange(of: guess) { session.setRemakeDraft(chapter.n, guess: guess) }
    }

    private func compare() {
        let compared = Remake.compare(guess, with: map)
        guard !compared.lines.isEmpty else { note = "Write at least one branch first"; return }
        note = ""
        session.setRemake(chapter.n, guess: guess, best: max(session.remakeBest(chapter.n), compared.percent))
        withAnimation(.spring) { result = compared }
    }

    private func comparison(_ result: RemakeResult) -> some View {
        let good = result.percent >= 70
        let best = session.remakeBest(chapter.n)
        return HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("The real map").font(Theme.body(12)).bold()
                Text("Green means you remembered it").font(Theme.body(11)).foregroundStyle(Theme.ink3)
                ForEach(Array(result.rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.remembered ? "✓ " : "")\(row.name)").font(Theme.body(13))
                        ForEach(Array(row.children.enumerated()), id: \.offset) { _, child in
                            Text("\(child.remembered ? "✓" : "·") \(child.name)").font(Theme.body(11)).foregroundStyle(Theme.ink2)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(row.remembered ? Theme.mintSoft : Theme.sunk, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Your version").font(Theme.body(12)).bold()
                ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(Theme.body(12)).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.sunk, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(result.percent)%").font(Theme.display(28))
                    Text("remembered\(best > result.percent ? " · best \(best)%" : "")").font(Theme.body(12)).foregroundStyle(Theme.ink2)
                }
                Text(good ? "Brilliant. You can sketch this chapter from memory." : "Look at the grey branches, then try again tomorrow. It gets easier every time.")
                    .font(Theme.body(12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("See the full map", action: onSeeFullMap).buttonStyle(.borderedProminent)
                    Button("Try again") { guess = ""; self.result = nil }
                }
                PipView(pose: good ? .proud : .hug, size: 90)
            }
        }
    }
}

// MARK: Book map

/// Your map of the book: it grows with every chapter whose Map step is done.
struct BookMapView: View {
    let session: BookSession
    let openChapter: (Int) -> Void
    @State private var replay = 0

    var body: some View {
        let chapters = session.book.chapters
        let ideas = Dictionary(grouping: session.book.graph.nodes.compactMap(\.chapter), by: { $0 }).mapValues(\.count)
        let earned = chapters.filter { Loop.isMapped(session.progress, $0.n) && (ideas[$0.n] ?? 0) > 0 }.map(\.n)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Book map").font(Theme.display(28))
                Text("Your map of the book grows with every chapter you map. Dashed lines join the same idea across chapters; pink dotted lines show disagreements.")
                    .font(Theme.body(14)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                growthStrip(chapters: chapters, earned: earned, ideas: ideas)
                if earned.isEmpty {
                    seed(chapters)
                } else {
                    let seen = Set(session.progress.mapSeen)
                    let fresh = Set(earned.filter { !seen.contains($0) })
                    GraphExplorer(
                        graph: session.book.graph.only(chapters: Set(earned)),
                        style: GraphStyle(colorBy: .chapter, chapterOrder: earned,
                                          chapterTitles: Dictionary(uniqueKeysWithValues: chapters.map { ($0.n, $0.title) }),
                                          saved: session.progress.mapPos.compactMapValues { $0.count == 2 ? Point($0[0], $0[1]) : nil },
                                          fresh: fresh),
                        onPlaced: { placed in session.placeOnMap(placed, seen: earned) },
                        onOpenChapter: openChapter,
                        replay: replay
                    )
                    .onAppear { if !fresh.isEmpty { session.placeOnMap([:], seen: earned) } }
                }
            }
            .padding(28)
        }
    }

    private func growthStrip(chapters: [Chapter], earned: [Int], ideas: [Int: Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chapters, id: \.n) { chapter in
                    if let k = earned.firstIndex(of: chapter.n) {
                        HStack(spacing: 6) {
                            Circle().fill(GraphPalette.color(k)).frame(width: 9, height: 9)
                            Text("🌱 Chapter \(chapter.n) · \(ideas[chapter.n] ?? 0) ideas").font(Theme.body(12))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().stroke(Theme.line))
                    } else {
                        let open = Loop.isUnlocked(session.progress, chapters, chapter.n)
                        Text("\(open ? "🌰" : "🔒") Chapter \(chapter.n)").font(Theme.body(12)).foregroundStyle(Theme.ink3)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .overlay(Capsule().strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    }
                }
                if earned.count > 1 {
                    Button { replay += 1 } label: { Label("Replay growth", systemImage: "play.fill") }.controlSize(.small)
                }
            }
        }
    }

    private func seed(_ chapters: [Chapter]) -> some View {
        let first = chapters.first { !Loop.isMapped(session.progress, $0.n) } ?? chapters.first
        return CardBox(fill: Theme.sunk) {
            VStack(spacing: 10) {
                PipView(pose: .play, size: 130)
                Text("Your map is a tiny seed").font(Theme.display(20))
                if let first {
                    Text("Finish chapter \(first.n)'s Map step and its ideas will sprout here. Every chapter after that makes the map bigger.")
                        .font(Theme.body(14)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 460)
                    Button("Go to chapter \(first.n)") { openChapter(first.n) }.buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }
}
