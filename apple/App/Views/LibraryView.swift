// The shelf: Pip's greeting, a drop zone, and one card per book with live progress.

import NeuralLoopCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(Library.self) private var library
    @State private var dropping = false

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 18)]

    var body: some View {
        @Bindable var library = library
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if library.entries.isEmpty { emptyShelf } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(library.entries) { entry in
                            Button { library.path.append(entry.id) } label: { BookCard(entry: entry) }
                                .buttonStyle(.plain)
                        }
                        addCard
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.paper)
        .overlay { if dropping { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in library.add(url) } }
                }
            }
            return true
        }
        .fileImporter(isPresented: $library.isPicking, allowedContentTypes: [.pdf, UTType(filenameExtension: "epub") ?? .data]) { result in
            if case .success(let url) = result { library.add(url) }
        }
        .alert(library.message ?? "", isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .navigationTitle("Library")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            PipView(pose: library.entries.contains(where: \.preparing) ? .study : .read, size: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text(greeting).font(Theme.display(30)).foregroundStyle(Theme.ink)
                Text("Drop a PDF or EPUB anywhere on this window. Pip makes a podcast, a reading guide, a quiz, flashcards, and a map for every chapter.")
                    .font(Theme.body(15)).foregroundStyle(Theme.ink2).frame(maxWidth: 560, alignment: .leading)
            }
            Spacer()
            Button { library.isPicking = true } label: { Label("Add a book", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning!" : hour < 18 ? "Good afternoon!" : "Good evening!"
    }

    private var emptyShelf: some View {
        CardBox(fill: Theme.sunk) {
            VStack(spacing: 12) {
                Text("Your shelf is empty, and that's a fine place to start.").font(Theme.display(20))
                Text("Drop a book here, or try the sample book to see how a loop feels.").font(Theme.body()).foregroundStyle(Theme.ink2)
                HStack {
                    Button("Add a book") { library.isPicking = true }.buttonStyle(.borderedProminent)
                    Button("Try the sample book") { addSample() }
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 30)
        }
    }

    private var addCard: some View {
        Button { library.isPicking = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.accent)
                Text("Add a book").font(Theme.display(16, .medium)).foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(Theme.sunk.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [6])))
        }
        .buttonStyle(.plain)
    }

    private var dropOverlay: some View {
        VStack(spacing: 14) {
            PipView(pose: .hug, size: 170)
            Text("Drop your book here").font(Theme.display(26)).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper.opacity(0.94))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10])).padding(18))
    }

    private func addSample() {
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "NeuralLoopRepo") as? String else { return }
        library.add(URL(fileURLWithPath: repo).appendingPathComponent("pipeline/sample/sample-book.epub").standardizedFileURL, practice: true)
    }
}

struct BookCard: View {
    let entry: BookEntry

    var body: some View {
        CardBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "book.closed.fill").foregroundStyle(Theme.accent)
                    Spacer()
                    if entry.preparing { ProgressView().controlSize(.small) }
                }
                Text(entry.title).font(Theme.display(19)).foregroundStyle(Theme.ink).lineLimit(2)
                if let book = entry.book {
                    Text("\(entry.readyChapters) of \(book.chapters.count) chapters ready")
                        .font(Theme.body(13)).foregroundStyle(Theme.ink2)
                    ProgressView(value: Double(entry.readyChapters), total: Double(max(book.chapters.count, 1))).tint(Theme.mint)
                }
                Text(entry.preparing ? (entry.lastLine.isEmpty ? "Pip is getting started…" : entry.lastLine) : madeWith)
                    .font(Theme.body(12)).foregroundStyle(Theme.ink3).lineLimit(2)
            }
            .frame(minHeight: 134, alignment: .topLeading)
        }
    }

    private var madeWith: String {
        guard let book = entry.book else { return "" }
        if book.dryRun { return "A practice run" }
        switch book.engine {
        case "local": return "Made with \(book.model.isEmpty ? "your AI" : book.model)"
        case "auto": return book.model.isEmpty ? "Made with NotebookLM" : "Made with NotebookLM and \(book.model)"
        default: return "Made with NotebookLM"
        }
    }
}
