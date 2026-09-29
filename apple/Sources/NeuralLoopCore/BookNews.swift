// What changed between two looks at a book while it's being prepared, for "Chapter 1 is ready" notifications.

public enum BookNews {
    /// Chapters whose reading guide just arrived (so they can be studied), and whether the book just finished.
    public static func between(_ before: Book, _ after: Book) -> (readyChapters: [Chapter], finished: Bool) {
        let wasReady = Set(before.chapters.filter { $0.status["study"] == .done }.map(\.n))
        let ready = after.chapters.filter { $0.status["study"] == .done && !wasReady.contains($0.n) }
        return (ready, busy(before) && !busy(after))
    }

    static func busy(_ book: Book) -> Bool {
        book.chapters.contains { $0.status.values.contains { $0 == .todo || $0 == .working } }
    }
}
