// "Your library": how much room it takes, and removing every book (they go to the Trash, and leave every device).

import SwiftUI

struct LibraryDataCard: View {
    @Environment(Library.self) private var library
    @State private var size: Int64?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your library").font(Theme.display(16))
                    Text(summary).font(Theme.body(12)).foregroundStyle(Theme.ink2)
                }
            }
            Button(role: .destructive) { confirming = true } label: {
                Label("Remove all books…", systemImage: "trash")
            }
            .disabled(library.entries.isEmpty)
            Text("To remove just one, right-click it on your shelf (or touch and hold on iPad). Your settings, keys, and sign-ins stay.")
                .font(Theme.body(10)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .task(id: library.entries.count) { size = await Task.detached { Library.librarySize() }.value }
        .confirmationDialog("Remove all \(library.entries.count) books?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Remove all books", role: .destructive) { library.removeAllBooks() }
            Button("Keep them", role: .cancel) {}
        } message: {
            Text("Every book, its podcasts and videos, and your progress go to the Trash, and they leave your other devices too. Your year with Pip starts fresh.")
        }
    }

    private var summary: String {
        let count = library.entries.count
        let books = count == 0 ? "No books yet" : "\(count) book\(count == 1 ? "" : "s")"
        guard let size, count > 0 else { return books }
        return "\(books) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) on this device"
    }
}
