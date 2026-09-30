// NeuralLoop for iPad: the library your Mac prepares (sync fills the same book folders), every chapter's five-step loop,
// the maps, and your year with Pip. The iPad never runs the pipeline; books added here wait in inbox/ for the Mac.

import AVFoundation
import SwiftUI

@main
struct NeuralLoopPadApp: App {
    @State private var library: Library

    init() {
        let library = Library()
        _library = State(initialValue: library)
        library.start()
        // Books and progress come from the Drive; books added here go to the Mac through the inbox.
        DriveSync.shared.onChanged = { library.reload() }
        DriveSync.shared.onRemovedElsewhere = { library.removedElsewhere($0) }
        DriveSync.shared.start()
        // Podcasts keep playing with the silent switch on and the screen locked.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    }

    var body: some Scene {
        WindowGroup {
            PadRootView().environment(library)
        }
    }
}

struct PadRootView: View {
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
        .task {
            // Development, as on the Mac: `-NLOpenBook <id> [-NLStage map] [-NLBookMap YES]` opens a book
            // (`xcrun simctl launch booted app.neuralloop.books -NLOpenBook sample-book`).
            if let id = UserDefaults.standard.string(forKey: "NLOpenBook") {
                try? await Task.sleep(for: .seconds(1))
                library.path = [id]
            }
        }
    }
}
