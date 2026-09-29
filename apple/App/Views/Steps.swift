// The five steps of a chapter's loop: Listen & watch, Read, Recall, Map, Remember.

import AppKit
import AVKit
import NeuralLoopCore
import PDFKit
import SwiftUI

// MARK: Listen & watch

struct ListenStep: View {
    let session: BookSession
    let chapter: Chapter

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let video = chapter.video {
                Text("Watch").font(Theme.display(20))
                VideoPlayer(player: AVPlayer(url: session.file(video)))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if let audio = chapter.audio {
                Text("Listen").font(Theme.display(20))
                PodcastPlayer(url: session.file(audio), transcript: chapter.transcript.map(session.file))
            }
            if chapter.video == nil && chapter.audio == nil {
                NotReady(what: "The podcast and video", status: chapter.status["audio"], note: chapter.notes["audio"])
            }
        }
    }
}

struct TranscriptLine: Decodable, Identifiable {
    let speaker: String
    let voice: String
    let text: String
    let start: Double
    var id: Double { start }
}

@MainActor @Observable
final class PodcastModel {
    let player: AVPlayer
    var lines: [TranscriptLine] = []
    var time: Double = 0
    var playing = false
    private var observer: Any?

    init(url: URL, transcript: URL?) {
        player = AVPlayer(url: url)
        if let transcript, let data = try? Data(contentsOf: transcript),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = object["lines"], let linesData = try? JSONSerialization.data(withJSONObject: raw) {
            lines = (try? JSONDecoder().decode([TranscriptLine].self, from: linesData)) ?? []
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.time = t.seconds }
        }
    }

    var current: Double? { lines.last(where: { $0.start <= time + 0.05 })?.start }

    func toggle() { playing ? player.pause() : player.play(); playing.toggle() }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        player.play()
        playing = true
    }
}

struct PodcastPlayer: View {
    @State private var model: PodcastModel

    init(url: URL, transcript: URL?) { _model = State(initialValue: PodcastModel(url: url, transcript: transcript)) }

    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                Button { model.toggle() } label: {
                    Label(model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill")
                        .font(Theme.display(15))
                }
                .buttonStyle(.borderedProminent)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(model.lines) { line in
                                Button { model.seek(line.start) } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Text(line.voice).font(Theme.display(13)).frame(width: 50, alignment: .leading)
                                            .foregroundStyle(line.speaker == "A" ? Theme.accent : Theme.sky)
                                        Text(line.text).font(Theme.body(14)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(model.current == line.start ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .id(line.start)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: model.current) { _, now in if let now { withAnimation { proxy.scrollTo(now, anchor: .center) } } }
                }
            }
        }
    }
}

// MARK: Read

struct ReadStep: View {
    let session: BookSession
    let chapter: Chapter

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !chapter.guide.isEmpty {
                CardBox(fill: Theme.sunk) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your reading plan").font(Theme.display(17))
                        ForEach(chapter.guide, id: \.section) { g in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                LevelPill(level: g.level)
                                Text(g.section).font(Theme.body(14)).bold() + Text("  \(g.why)").font(Theme.body(14)).foregroundColor(Theme.ink2)
                            }
                        }
                    }
                }
            }
            switch chapter.read {
            case .pdf(let file):
                PDFReader(url: session.file(file)).frame(minHeight: 640)
            case .text(let text):
                ReaderText(text: text, folder: session.file("chapters"), guide: chapter.guide)
            }
        }
    }
}

struct LevelPill: View {
    let level: String
    var body: some View {
        let (label, fg, bg): (String, Color, Color) = switch level {
        case "deep": ("Deep read", Theme.rose, Theme.roseSoft)
        case "skim": ("Skim", Theme.ink2, Theme.sunk)
        default: ("Read", Theme.mint, Theme.mintSoft)
        }
        Text(label).font(Theme.body(11)).bold().padding(.horizontal, 8).padding(.vertical, 2)
            .background(bg, in: Capsule()).foregroundStyle(fg)
    }
}

/// Chapter Markdown as a textbook page: headings with reading-plan labels, paragraphs, lists, and figures with captions.
struct ReaderText: View {
    let text: String
    let folder: URL
    let guide: [GuideEntry]

    var body: some View {
        let blocks = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: String) -> some View {
        if let m = block.firstMatch(of: /^!\[([^\]]*)\]\((img\/[\w.-]+)\)$/) {
            VStack(spacing: 6) {
                if let image = NSImage(contentsOf: folder.appendingPathComponent(String(m.2))) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel(String(m.1))
                }
            }
            .frame(maxWidth: .infinity)
        } else if let m = block.firstMatch(of: /^(#{1,3})\s+(.*)$/) {
            let title = String(m.2)
            HStack(spacing: 8) {
                Text(title).font(Theme.display(m.1.count == 1 ? 24 : 19))
                if let g = guide.first(where: { title.lowercased().contains($0.section.lowercased()) || $0.section.lowercased().contains(title.lowercased()) }) {
                    LevelPill(level: g.level)
                }
            }
            .padding(.top, 8)
        } else if block.hasPrefix("*"), block.hasSuffix("*"), !block.hasPrefix("**") {
            Text(block.trimmingCharacters(in: CharacterSet(charactersIn: "*"))).font(Theme.body(13)).italic().foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity)
        } else {
            Text((try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block))
                .font(Theme.body(17)).lineSpacing(6).foregroundStyle(Theme.ink)
        }
    }
}

struct PDFReader: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {}
}

// MARK: Recall

struct RecallStep: View {
    let session: BookSession
    let chapter: Chapter
    @State private var index = 0
    @State private var answer = ""
    @State private var covered: [Bool]?

    var body: some View {
        if chapter.recall.isEmpty {
            NotReady(what: "Recall questions", status: chapter.status["study"], note: chapter.notes["study"])
        } else {
            let prompt = chapter.recall[min(index, chapter.recall.count - 1)]
            VStack(alignment: .leading, spacing: 14) {
                Text("Question \(index + 1) of \(chapter.recall.count)").font(Theme.body(12)).foregroundStyle(Theme.ink3)
                Text(prompt.prompt).font(Theme.display(21))
                Text("No peeking. Pulling it out of your head is the whole trick.").font(Theme.body(13)).foregroundStyle(Theme.ink2)
                TextEditor(text: $answer)
                    .font(Theme.body(15)).frame(minHeight: 150).padding(8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                HStack {
                    Button("Check my answer") { covered = RecallCheck.wordMatch(prompt.keyPoints, answer: answer) }
                        .buttonStyle(.borderedProminent).disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                    if index + 1 < chapter.recall.count {
                        Button("Next question") { index += 1; answer = ""; covered = nil }
                    }
                }
                if let covered {
                    CardBox(fill: Theme.sunk) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(zip(prompt.keyPoints, covered).enumerated()), id: \.offset) { _, pair in
                                Label(pair.0, systemImage: pair.1 ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(pair.1 ? Theme.mint : Theme.ink3).font(Theme.body(14))
                            }
                            Text(RecallCheck.feedback(prompt.keyPoints, covered: covered)).font(Theme.body(14))
                        }
                    }
                }
            }
        }
    }
}

// MARK: Map

struct MapStep: View {
    let chapter: Chapter

    var body: some View {
        if let tree = chapter.mindmap {
            CardBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tree.name).font(Theme.display(20)).foregroundStyle(Theme.accent)
                    ForEach(tree.children, id: \.name) { branch in MindBranch(node: branch, depth: 0) }
                }
            }
        } else {
            NotReady(what: "The mind map", status: chapter.status["mindmap"], note: chapter.notes["mindmap"])
        }
    }
}

struct MindBranch: View {
    let node: MindNode
    let depth: Int
    @State private var open = true

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(node.children, id: \.name) { child in MindBranch(node: child, depth: depth + 1).padding(.leading, 14) }
        } label: {
            Text(node.name).font(depth == 0 ? Theme.display(16, .medium) : Theme.body(14))
        }
    }
}

// MARK: Remember

struct RememberStep: View {
    let session: BookSession
    let chapter: Chapter
    @State private var flipped = false
    @State private var reviewed = 0

    var body: some View {
        let due = Cards.due([chapter], session.progress, now: session.now)
        if chapter.cards.isEmpty {
            NotReady(what: "Flashcards", status: chapter.status["cards"], note: chapter.notes["cards"])
        } else if let card = due.first {
            VStack(spacing: 18) {
                Text("\(due.count) card\(due.count == 1 ? "" : "s") to go").font(Theme.body(13)).foregroundStyle(Theme.ink3)
                Button { withAnimation(.spring(duration: 0.4)) { flipped.toggle() } } label: {
                    Text(flipped ? card.card.back : card.card.front)
                        .font(Theme.display(22, .medium)).multilineTextAlignment(.center).padding(30)
                        .frame(maxWidth: 560, minHeight: 220)
                        .background(flipped ? Theme.mintSoft : Theme.butterSoft, in: RoundedRectangle(cornerRadius: 22))
                        .rotation3DEffect(.degrees(flipped ? 360 : 0), axis: (x: 0, y: 1, z: 0))
                }
                .buttonStyle(.plain)
                if flipped {
                    HStack {
                        ForEach([(Rating.again, "Again"), (.hard, "Hard"), (.good, "Good"), (.easy, "Easy")], id: \.1) { rating, label in
                            Button(label) { session.review(card.id, rating); flipped = false; reviewed += 1 }
                                .buttonStyle(.bordered).controlSize(.large)
                        }
                    }
                } else {
                    Text("Say the answer in your head, then tap the card.").font(Theme.body(13)).foregroundStyle(Theme.ink2)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 10) {
                PipView(pose: .proud, size: 150)
                Text("All caught up for this chapter.").font(Theme.display(20))
                Text("Pip will bring cards back right before you'd forget them.").font(Theme.body(14)).foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Shared

struct NotReady: View {
    let what: String
    let status: ItemStatus?
    let note: String?

    var body: some View {
        CardBox(fill: Theme.sunk) {
            HStack(spacing: 16) {
                PipView(pose: status == .working ? .study : .nap, size: 90)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.display(18))
                    if let note, !note.isEmpty { Text(note).font(Theme.body(13)).foregroundStyle(Theme.ink2) }
                }
            }
        }
    }

    private var title: String {
        switch status {
        case .working: "\(what): Pip is making it right now."
        case .skipped: "\(what) wasn't chosen for this chapter. Use Prepare more to add it."
        case .failed: "\(what) needs another try. Use Prepare more."
        case .waiting: "\(what) will be made after the AI's limit resets."
        default: "\(what) is on Pip's list."
        }
    }
}
