// The five steps of a chapter's loop: Listen & watch, Read, Recall, Map, Remember.

import AVKit
import ImageIO
import NeuralLoopCore
import PDFKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: Listen & watch

struct ListenStep: View {
    let session: BookSession
    let chapter: Chapter

    private var media: MediaCenter { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if session.progress.loop[String(chapter.n)]?[Stage.prime.rawValue] == nil, chapter.audio != nil || chapter.video != nil {
                listened
            }
            Text("Watch").font(Theme.display(20))
            if let video = chapter.video, let url = session.file(video) {
                WhenDownloaded(url: url, what: "the video") {
                    ChapterVideo(url: url, title: chapter.title, artist: session.book.title,
                                 source: PlaySource(folder: session.entry.folder, n: chapter.n, kind: .video))
                }
            } else {
                NotReady(what: "The video", status: chapter.status["video"], note: chapter.notes["video"], bookId: session.entry.id, n: chapter.n, item: "video")
            }
            Text("Listen").font(Theme.display(20))
            if let audio = chapter.audio, let url = session.file(audio) {
                WhenDownloaded(url: url, what: "the podcast") { 
                    PodcastPlayer(url: url, transcript: chapter.transcript.flatMap(session.file), title: chapter.title, artist: session.book.title,
                                  source: PlaySource(folder: session.entry.folder, n: chapter.n, kind: .audio))
                }
            } else {
                NotReady(what: "The podcast", status: chapter.status["audio"], note: chapter.notes["audio"], bookId: session.entry.id, n: chapter.n, item: "audio")
            }
        }
    }

    /// How much of the podcast and the video has really played (skipping ahead and replays don't add to it).
    private var listened: some View {
        let watch = session.progress.watch[String(chapter.n)]
        let heard = chapter.audio.flatMap(session.file).map { watch?.audio.fraction(media.duration($0)) ?? 0 }
        let seen = chapter.video.flatMap(session.file).map { watch?.video.fraction(media.duration($0)) ?? 0 }
        let parts = [heard.map { "Heard \(Self.percent($0)) of the podcast" }, seen.map { "watched \(Self.percent($0)) of the video" }]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return StepProgressRow(fraction: max(heard ?? 0, seen ?? 0) / Listening.enough,
                               text: text.prefix(1).uppercased() + text.dropFirst(),
                               detail: "This step ticks itself off once you've heard or watched most of one (85%). Skipping ahead doesn't count.")
    }

    static func percent(_ fraction: Double) -> String { "\(Int((min(1, fraction) * 100).rounded(.down)))%" }
}

struct ChapterVideo: View {
    let url: URL
    var corner: CGFloat = 16
    /// What the lock screen and Control Center show: the chapter and the book.
    var title: String? = nil
    var artist: String? = nil
    /// The chapter it belongs to: watching it (while it's on screen) counts toward Listen & watch.
    var source: PlaySource? = nil
    @State private var probe = ViewProbe()

    var body: some View {
        PlayerView(player: MediaCenter.shared.player(for: url))
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .background(VisibilityProbe(probe: probe))
            .onAppear {
                if let title { MediaCenter.shared.setNowPlaying(url, title: title, artist: artist) }
                MediaCenter.shared.track(url, as: source)
                MediaCenter.shared.shown(url, by: probe)
            }
    }
}

#if os(macOS)
/// AppKit's player with the system controls (SwiftUI's VideoPlayer aborts while loading on this macOS).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.updatesNowPlayingInfoCenter = false  // MediaCenter says what's playing, with the chapter's title
        view.player = player
        return view
    }

    /// AVPlayerView has no useful size of its own; take the width offered and stay 16:9.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        let width = proposal.width ?? 480
        return CGSize(width: width, height: width * 9 / 16)
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#else
/// The system player with its controls, full screen, and picture in picture.
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.updatesNowPlayingInfoCenter = false  // MediaCenter says what's playing, with the chapter's title
        return controller
    }

    /// Take the width offered and stay 16:9.
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: AVPlayerViewController, context: Context) -> CGSize? {
        let width = proposal.width ?? 480
        return CGSize(width: width, height: width * 9 / 16)
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
#endif

struct TranscriptLine: Decodable, Identifiable {
    let speaker: String
    let voice: String
    let text: String
    let start: Double
    var id: Double { start }

    /// Lines from the transcript file next to a podcast our own voices made. NotebookLM's podcasts have none.
    static func load(_ url: URL?) -> [TranscriptLine] {
        guard let url, let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["lines"], let linesData = try? JSONSerialization.data(withJSONObject: raw)
        else { return [] }
        return (try? JSONDecoder().decode([TranscriptLine].self, from: linesData)) ?? []
    }
}

/// Play/pause, where you are, and a bar to jump around. Used on the chapter screen and in the menu-bar panel.
struct PodcastControls: View {
    let url: URL
    var compact = false
    var title: String? = nil
    var artist: String? = nil
    /// The chapter it belongs to: listening counts toward Listen & watch, even with the window in the background.
    var source: PlaySource? = nil
    private var media: MediaCenter { .shared }

    var body: some View {
        let duration = media.duration(url)
        HStack(spacing: compact ? 10 : 14) {
            Button { media.toggle(url) } label: {
                Image(systemName: media.isPlaying(url) ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 14 : 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: compact ? 34 : 46, height: compact ? 34 : 46)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .help(media.isPlaying(url) ? "Pause" : "Play")
            .accessibilityLabel(media.isPlaying(url) ? "Pause the podcast" : "Play the podcast")
            VStack(alignment: .leading, spacing: 2) {
                Slider(value: Binding(get: { min(media.time(url), max(duration, 1)) },
                                      set: { media.seek(url, to: $0, play: media.isPlaying(url)) }),
                       in: 0...max(duration, 1))
                    .controlSize(compact ? .mini : .small)
                    .accessibilityLabel("Podcast position")
                HStack {
                    Text(MediaCenter.clock(media.time(url)))
                    Spacer()
                    Text(duration > 0 ? MediaCenter.clock(duration) : "")
                }
                .font(Theme.body(11)).monospacedDigit().foregroundStyle(Theme.ink3)
            }
        }
        .onAppear {
            _ = media.player(for: url)
            if let title { media.setNowPlaying(url, title: title, artist: artist) }
            media.track(url, as: source)
        }
    }
}

struct PodcastPlayer: View {
    let url: URL
    let lines: [TranscriptLine]
    let title: String?
    let artist: String?
    let source: PlaySource?
    private var media: MediaCenter { .shared }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(url: URL, transcript: URL?, title: String? = nil, artist: String? = nil, source: PlaySource? = nil) {
        self.url = url
        self.lines = TranscriptLine.load(transcript)
        (self.title, self.artist, self.source) = (title, artist, source)
    }

    private var current: Double? {
        let time = media.time(url)
        return lines.last(where: { $0.start <= time + 0.05 })?.start
    }

    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 12) {
                PodcastControls(url: url, title: title, artist: artist, source: source)
                if !lines.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(lines) { line in
                                    Button { media.seek(url, to: line.start) } label: {
                                        HStack(alignment: .top, spacing: 10) {
                                            Text(line.voice).font(Theme.display(13)).frame(width: 50, alignment: .leading)
                                                .foregroundStyle(line.speaker == "A" ? Theme.accent : Theme.sky)
                                            Text(line.text).font(Theme.body(14)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                                        }
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(current == line.start ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                    .id(line.start)
                                }
                            }
                        }
                        .frame(maxHeight: 320)
                        .onChange(of: current) { _, now in if let now { withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(now, anchor: .center) } } }
                    }
                }
            }
        }
    }
}

/// Media on an iPad arrives from the Drive when a chapter opens: until the file is here, say so (and then show it).
struct WhenDownloaded<Content: View>: View {
    let url: URL
    let what: String
    @ViewBuilder var content: () -> Content
    @State private var ready = false

    var body: some View {
        Group {
            if ready || FileManager.default.fileExists(atPath: url.path) {
                content()
            } else {
                CardBox(fill: Theme.sunk) {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Bringing \(what) from your Drive…").font(Theme.body(14)).foregroundStyle(Theme.ink2)
                    }
                }
                .task {
                    while !FileManager.default.fileExists(atPath: url.path) && !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(2))
                    }
                    ready = true
                }
            }
        }
    }
}

// MARK: Read

struct ReadStep: View {
    let session: BookSession
    let chapter: Chapter
    @State private var tracker = ReadingTracker()
    @Environment(\.chapterViewport) private var viewport

    private var isDone: Bool { session.progress.loop[String(chapter.n)]?[Stage.read.rawValue] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !isDone, !tracker.needs.isEmpty { readSoFar }
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
                if let url = session.file(file) { PDFReader(url: url, tracker: tracker).frame(minHeight: 640) }
            case .text(let text):
                ReaderText(text: text, folder: session.entry.folder.appendingPathComponent("chapters"), guide: chapter.guide, tracker: tracker)
            }
        }
        .background(VisibilityProbe(probe: tracker.probe))
        .onAppear { tracker.viewport = viewport }
        .onChange(of: viewport) { tracker.viewport = viewport }
        .task(id: chapter.n) { await follow() }
    }

    /// "Read 40% · 12 of 30 pages", and what's left to do.
    private var readSoFar: some View {
        let p = ReadingCredit.progress(session.progress.reading[String(chapter.n)], needs: tracker.needs)
        let unit = tracker.isPDF ? (p.total == 1 ? "page" : "pages") : (p.total == 1 ? "section" : "sections")
        let detail = p.fraction >= ReadingCredit.enough && !p.reachedLast
            ? "Nearly there: this step ticks itself off once you reach the end."
            : "Pages count as you read them, at your own pace. This step ticks itself off at 85% and the last page."
        return StepProgressRow(fraction: p.fraction, text: "Read \(ListenStep.percent(p.fraction)) · \(p.counted) of \(p.total) \(unit)", detail: detail)
    }

    /// Works out what each page needs, then credits reading time once a second while someone is really reading.
    private func follow() async {
        switch chapter.read {
        case .pdf(let file):
            tracker.isPDF = true
            if let url = session.file(file) { tracker.needs = await ReadingTracker.pdfNeeds(url) }
        case .text(let text):
            tracker.isPDF = false
            let blocks = ReaderText.blocks(text)
            tracker.needs = ReadingCredit.sections(blocks).map { section in
                ReadingCredit.needed(words: section.reduce(0) { $0 + ReadingCredit.words(blocks[$1]) })
            }
        }
        var last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let now = Date()
            defer { last = now }
            guard !isDone, !tracker.needs.isEmpty else { continue }
            let earning = ReadingCredit.earning(now: now.timeIntervalSince1970, lastInput: tracker.lastInput?.timeIntervalSince1970,
                                                appActive: session.isActive,
                                                windowVisible: tracker.probe.isShown() && tracker.probe.isKey)
            session.creditReading(chapter.n, visible: tracker.visible(), seconds: now.timeIntervalSince(last),
                                  needs: tracker.needs, earning: earning)
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
    /// Follows which ~300-word sections are on screen, for the Read step's reading time.
    var tracker: ReadingTracker? = nil

    static func blocks(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        let blocks = Self.blocks(text)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(ReadingCredit.sections(blocks).enumerated()), id: \.offset) { index, section in
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(section, id: \.self) { blockView(blocks[$0]) }
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(ChapterView.scrollSpace)) }) { frame in
                    tracker?.sectionMoved(index, top: frame.minY, bottom: frame.maxY)
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .textSelection(.enabled)
        // Links in a chapter open in the browser; anything else (file:, other apps' schemes) is ignored.
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }

    @ViewBuilder
    private func blockView(_ block: String) -> some View {
        if let m = block.firstMatch(of: /^!\[([^\]]*)\]\((img\/[\w.-]+)\)$/) {
            VStack(spacing: 6) {
                if let image = Self.picture(folder.appendingPathComponent(String(m.2))) {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 420)
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

extension ReaderText {
    /// A figure from the chapter's img/ folder (PNG, JPEG, GIF…), on every platform.
    static func picture(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

#if os(macOS)
struct PDFReader: NSViewRepresentable {
    let url: URL
    var tracker: ReadingTracker? = nil
    func makeNSView(context: Context) -> PDFView {
        let view = PDFReader.view(url)
        tracker?.pdfView = view
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) { tracker?.pdfView = view }
}
#else
struct PDFReader: UIViewRepresentable {
    let url: URL
    var tracker: ReadingTracker? = nil
    func makeUIView(context: Context) -> PDFView {
        let view = PDFReader.view(url)
        tracker?.pdfView = view
        // The iPad can't ask the system about input: scrolling the pages is the sign someone is reading.
        DispatchQueue.main.async { [weak tracker, weak view] in
            guard let view, let scroll = PDFReader.scrollView(in: view) else { return }
            tracker?.scrolling = scroll.observe(\.contentOffset) { [weak tracker] _, _ in
                DispatchQueue.main.async { tracker?.poke() }
            }
        }
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) { tracker?.pdfView = view }

    static func scrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let scroll = sub as? UIScrollView { return scroll }
            if let found = scrollView(in: sub) { return found }
        }
        return nil
    }
}
#endif

extension PDFReader {
    static func view(_ url: URL) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }
}

// MARK: Recall

struct RecallStep: View {
    let session: BookSession
    let chapter: Chapter
    @State private var index = 0
    @State private var answer = ""
    @State private var covered: [Bool]?
    @State private var feedback = ""
    @State private var checkedBy = ""
    @State private var checking = false
    #if DEBUG
    @State private var showQuiz = UserDefaults.standard.bool(forKey: "NLQuiz")  // development: `-NLQuiz YES`
    #else
    @State private var showQuiz = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if session.progress.loop[String(chapter.n)]?[Stage.recall.rawValue] == nil, !chapter.recall.isEmpty || !chapter.quiz.isEmpty {
                recallSoFar
            }
            if !chapter.quiz.isEmpty {
                Picker("Recall", selection: $showQuiz) {
                    Text("In your own words").tag(false)
                    Text("Quiz").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            }
            if showQuiz {
                QuizView(session: session, chapter: chapter)
            } else {
                ownWords
            }
        }
    }

    /// What finishes the step: one checked answer in your own words, or the whole quiz.
    private var recallSoFar: some View {
        let total = chapter.quiz.count
        let answered = min(session.quiz(chapter.n).i, total)
        let text = total > 0 ? "Quiz: \(answered) of \(total) answered" : "Answer one question in your own words"
        let detail = chapter.recall.isEmpty
            ? "This step ticks itself off when you finish the quiz."
            : total > 0 ? "This step ticks itself off when Pip checks an answer in your own words, or when you finish the quiz."
            : "This step ticks itself off when Pip checks your answer."
        return StepProgressRow(fraction: total > 0 ? Double(answered) / Double(total) : 0, text: text, detail: detail)
    }

    @ViewBuilder private var ownWords: some View {
        if chapter.recall.isEmpty {
            NotReady(what: "Recall questions", status: chapter.status["study"], note: chapter.notes["study"], bookId: session.entry.id, n: chapter.n, item: "study")
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
                    Button(checking ? "Pip is checking…" : "Check my answer") { Task { await check(prompt) } }
                        .buttonStyle(.borderedProminent).disabled(checking || answer.trimmingCharacters(in: .whitespaces).isEmpty)
                    if checking { ProgressView().controlSize(.small) }
                    if index + 1 < chapter.recall.count {
                        Button("Next question") { index += 1; answer = ""; covered = nil; feedback = ""; checkedBy = "" }
                            .disabled(checking)
                    } else if !chapter.quiz.isEmpty, covered != nil {
                        Button("On to the quiz") { showQuiz = true }.disabled(checking)
                    }
                }
                if let covered {
                    CardBox(fill: Theme.sunk) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(zip(prompt.keyPoints, covered).enumerated()), id: \.offset) { _, pair in
                                Label(pair.0, systemImage: pair.1 ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(pair.1 ? Theme.mint : Theme.ink3).font(Theme.body(14))
                            }
                            Text(feedback).font(Theme.body(14))
                            if !checkedBy.isEmpty { Text("Checked by \(checkedBy)").font(Theme.body(11)).foregroundStyle(Theme.ink3) }
                        }
                    }
                }
            }
        }
    }
}

extension RecallStep {
    /// The recall model from Settings checks each key point (gemma2:2b on this Mac by default); word matching if it can't.
    /// The iPad has no pipeline, so it uses word matching until an on-device model arrives (spec 07).
    func check(_ prompt: RecallPrompt) async {
        checking = true
        defer { checking = false }
        let asked = index
        let answer = answer  // the answer as it was sent, even if it's edited while Pip checks
        #if os(macOS)
        let request: [String: Any] = ["question": prompt.prompt, "keyPoints": prompt.keyPoints, "answer": answer]
        let input = String(decoding: (try? JSONSerialization.data(withJSONObject: request)) ?? Data(), as: UTF8.self)
        let (_, lines) = await PipelineRunner.once(["--grade-recall"], input: input, timeout: .seconds(240))
        #else
        let lines: [String] = []
        #endif
        guard asked == index else { return }  // the question changed meanwhile: this result belongs to another one
        if let line = lines.last, let result = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
           let marks = result["covered"] as? [Bool], marks.count == prompt.keyPoints.count {
            covered = marks
            feedback = result["feedback"] as? String ?? RecallCheck.feedback(prompt.keyPoints, covered: marks)
            checkedBy = result["by"] as? String ?? ""
        } else {
            let marks = RecallCheck.wordMatch(prompt.keyPoints, answer: answer)
            covered = marks
            feedback = RecallCheck.feedback(prompt.keyPoints, covered: marks)
            checkedBy = "word match"
        }
        session.recallChecked(chapter.n, answer: answer)  // a real, checked try counts as the Recall step
    }
}

// MARK: Map

struct MapStep: View {
    let session: BookSession
    let chapter: Chapter
    #if DEBUG
    // Development: `-NLMapMode concepts|mind|remake` opens that view.
    @State private var mode: MapMode? = ["concepts": MapMode.concepts, "mind": .mind, "remake": .remake][UserDefaults.standard.string(forKey: "NLMapMode") ?? ""]
    #else
    @State private var mode: MapMode?
    #endif

    enum MapMode: String, CaseIterable { case remake = "Remake from memory", mind = "Mind map", concepts = "Concept graph" }

    private var modes: [MapMode] {
        (chapter.mindmap != nil ? [.remake, .mind] : []) + (chapter.graph != nil || !chapterGraph.nodes.isEmpty ? [.concepts] : [])
    }

    private var chapterGraph: KnowledgeGraph { session.book.graph.chapter(chapter.n, tour: chapter.graph?.tour ?? []) }

    var body: some View {
        let current = mode ?? (chapter.mindmap != nil ? (Loop.isMapped(session.progress, chapter.n) ? .mind : .remake) : .concepts)
        if modes.isEmpty {
            NotReady(what: "The mind map", status: chapter.status["mindmap"], note: chapter.notes["mindmap"], bookId: session.entry.id, n: chapter.n, item: "mindmap")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Map view", selection: Binding(get: { current }, set: { mode = $0 })) {
                    ForEach(modes, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 480)
                switch current {
                case .remake:
                    if let map = chapter.mindmap {
                        RemakeView(session: session, chapter: chapter, map: map) {
                            session.earn(chapter.n, .map)  // remaking it counts as mapping the chapter
                            mode = .mind
                        }
                    }
                case .mind:
                    if let map = chapter.mindmap { MindMapTree(map: map) }
                case .concepts:
                    GraphExplorer(graph: chapterGraph)
                }
            }
        }
    }
}

// MARK: Remember

struct RememberStep: View {
    let session: BookSession
    let chapter: Chapter
    @State private var flipped = false
    @State private var reviewed = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let due = Cards.due([chapter], session.progress, now: session.now)
        if chapter.cards.isEmpty {
            NotReady(what: "Flashcards", status: chapter.status["cards"], note: chapter.notes["cards"], bookId: session.entry.id, n: chapter.n, item: "cards")
        } else if let card = due.first {
            VStack(spacing: 18) {
                if session.progress.loop[String(chapter.n)]?[Stage.space.rawValue] == nil { seenSoFar }
                Text("\(due.count) card\(due.count == 1 ? "" : "s") to go").font(Theme.body(13)).foregroundStyle(Theme.ink3)
                Button { withAnimation(reduceMotion ? nil : .spring(duration: 0.4)) { flipped.toggle() } } label: {
                    Text(PlainMath.clean(flipped ? card.card.back : card.card.front))
                        .font(Theme.display(22, .medium)).multilineTextAlignment(.center).padding(30)
                        .frame(maxWidth: 560, minHeight: 220)
                        .background(flipped ? Theme.mintSoft : Theme.butterSoft, in: RoundedRectangle(cornerRadius: 22))
                        .rotation3DEffect(.degrees(flipped && !reduceMotion ? 360 : 0), axis: (x: 0, y: 1, z: 0))
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

    /// "Reviewed 4 of 10 cards": every card seen once finishes the step.
    private var seenSoFar: some View {
        let seen = AutoSteps.cardsSeen(session.progress, chapter)
        return StepProgressRow(fraction: Double(seen) / Double(max(1, chapter.cards.count)),
                               text: "Reviewed \(seen) of \(chapter.cards.count) card\(chapter.cards.count == 1 ? "" : "s")",
                               detail: "This step ticks itself off once you've seen every card once.")
            .frame(maxWidth: 560, alignment: .leading)
    }
}

// MARK: Shared

/// An item that isn't here yet. While it's being made, a real loader: what's happening now ("NotebookLM is recording
/// the podcast", "Voicing the podcast"), who's making it, a bar (exact when the work can be counted, timed against
/// how long it usually takes otherwise), and the time left; while it waits, its place in line.
struct NotReady: View {
    @Environment(Library.self) private var library
    let what: String
    let status: ItemStatus?
    let note: String?
    var bookId: String? = nil
    var n: Int = 0
    var item: String = ""

    private var feed: PrepActivity? {
        bookId.flatMap { library.entry($0)?.activity }.flatMap { $0.isLive ? $0 : nil }
    }

    var body: some View {
        CardBox(fill: Theme.sunk) {
            HStack(alignment: .top, spacing: 16) {
                PipView(pose: status == .working ? .study : .nap, size: 90)
                VStack(alignment: .leading, spacing: 6) {
                    if status == .working, let now = feed?.item(n, item) {
                        Loader(what: what, item: now)
                    } else {
                        Text(title).font(Theme.display(18))
                        if status == .todo || status == nil, let place = feed?.place(n, item) {
                            Label(PrepProgress.placeText(place), systemImage: "list.number").font(Theme.body(13)).foregroundStyle(Theme.accent)
                        }
                    }
                    Text(detail).font(Theme.body(13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    #if os(macOS)
                    if status == .waiting || status == .failed, let bookId {
                        Button { library.makeWithMyAI(bookId) } label: { Label("Make it with my AI now", systemImage: "bolt.fill") }
                            .buttonStyle(.borderedProminent).padding(.top, 4)
                    }
                    #endif
                }
            }
        }
    }

    private var title: String {
        switch status {
        case .working: "\(what): Pip is making it right now."
        case .skipped: "\(what) wasn't chosen for this chapter. Use Prepare more\(Self.onMac) to add it."
        case .failed: "\(what) needs another try."
        case .waiting: "\(what) is waiting for NotebookLM."
        default: "\(what) is on Pip's list."
        }
    }

    #if os(macOS)
    private static let onMac = ""
    #else
    private static let onMac = " on your Mac"
    #endif

    private var detail: String {
        guard status == .waiting else { return note ?? "" }
        #if os(iOS)
        return "NotebookLM is at its limit for now. Your Mac will try again when it resets, and it'll show up here."
        #else
        guard let usage = library.usage, usage.known, let window = usage.fiveHour else {
            return "NotebookLM is at its limit for now. Pip will try again when it resets."
        }
        let reset = window.resetDate.map { $0.formatted(date: .omitted, time: .shortened) } ?? "soon"
        return "NotebookLM has \(Int(window.remaining))% of its five-hour allowance left; a podcast or video uses about 44%. "
            + "It resets at \(reset), and Pip will try again then. Or make it with your own AI right now."
        #endif
    }
}


/// The progress loader for one item being made: refreshed every second so the time keeps moving.
private struct Loader: View {
    let what: String
    let item: PrepActivity.Item

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let p = PrepProgress.of(item, now: context.date.timeIntervalSince1970 * 1000)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(what).font(Theme.display(18))
                    Spacer(minLength: 12)
                    if let percent = p.percentText {
                        Text(percent).font(Theme.display(p.estimated ? 16 : 20)).foregroundStyle(Theme.accent).monospacedDigit()
                            .help(p.estimated ? "NotebookLM doesn't share its progress, so this is an estimate from how long it usually takes." : "")
                    }
                }
                .frame(maxWidth: 420)
                Text(p.step.isEmpty ? "Pip is making it right now" : p.step).font(Theme.body(14)).foregroundStyle(Theme.ink2)
                Group {
                    if let fraction = p.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .tint(p.slow ? Theme.butter : Theme.accent)
                .frame(maxWidth: 420)
                .accessibilityLabel("\(what) progress")
                .accessibilityValue(p.percent.map { "\(p.estimated ? "about " : "")\($0) percent, \(p.detail)" } ?? p.detail)
                HStack(spacing: 10) {
                    Text(p.detail).font(Theme.body(13)).foregroundStyle(p.slow ? Theme.ink2 : Theme.ink)
                    if !p.by.isEmpty {
                        Text(p.by == "NotebookLM" ? "NotebookLM" : "On your Mac · \(p.by)")
                            .font(Theme.body(11)).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8).padding(.vertical, 2).background(Theme.accentSoft, in: Capsule())
                    }
                }
            }
        }
    }
}
