// NeuralLoop for Mac: drop a book, and Pip turns every chapter into a five-step learning loop.

import SwiftUI

@main
struct NeuralLoopApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup("NeuralLoop") {
            RootView()
                .environment(library)
                .frame(minWidth: 900, minHeight: 620)
                .task {
                    library.reload()
                    library.resumeUnfinished()
                    // Books can be prepared outside this window (a run from the command line, later the iPad's queue):
                    // look at the shelf again every few seconds while the app is open.
                    while !Task.isCancelled {
                        library.reload()
                        try? await Task.sleep(for: .seconds(4))
                    }
                }
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add a Book…") { library.isPicking = true }.keyboardShortcut("o")
            }
        }
    }
}

struct RootView: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        NavigationStack(path: $library.path) {
            LibraryView()
                .navigationDestination(for: String.self) { id in
                    if let entry = library.entry(id) { BookView(entry: entry) }
                }
        }
        .background(Theme.paper)
        .tint(Theme.accent)
    }
}
