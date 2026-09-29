// NeuralLoop for Mac: drop a book, and Pip turns every chapter into a five-step learning loop.

import SwiftUI

@main
struct NeuralLoopApp: App {
    @State private var library: Library
    @State private var settings = AISettings()

    init() {
        let library = Library()
        _library = State(initialValue: library)
        library.start()  // the shelf loop lives as long as the app, window or not
    }

    var body: some Scene {
        WindowGroup("NeuralLoop", id: "main") {
            RootView()
                .environment(library)
                .environment(settings)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add a Book…") { library.isPicking = true }.keyboardShortcut("o")
            }
        }
        Settings {
            SettingsView().environment(settings).environment(library)
        }
        // Development: `-NLPreviewPanel YES` shows the menu-bar panel in a window, for screenshots.
        Window("Quick panel", id: "panel-preview") {
            QuickPanel().environment(library).environment(settings)
        }
        .windowResizability(.contentSize)
        MenuBarExtra {
            QuickPanel().environment(library).environment(settings)
        } label: {
            MenuBarPip()
        }
        .menuBarExtraStyle(.window)
    }
}

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage("welcomed") private var welcomed = false
    @State private var movingIn = AppMover.shouldAsk

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
        // First things first: move into Applications (when running from Downloads or the disk image), then the welcome.
        .sheet(isPresented: $movingIn) { MoveInView() }
        .sheet(isPresented: Binding(get: { !welcomed && !movingIn }, set: { if !$0 { welcomed = true } })) { WelcomeView() }
        // Development: `open NeuralLoop.app --args -NLOpenSettings YES` opens Settings (for screenshots and checks).
        .task {
            if UserDefaults.standard.bool(forKey: "NLOpenSettings") { openSettings() }
            if UserDefaults.standard.bool(forKey: "NLPreviewPanel") { openWindow(id: "panel-preview") }
            // `-NLOpenBook <id> [-NLStage map] [-NLBookMap YES]` opens a book (for screenshots and checks).
            if let id = UserDefaults.standard.string(forKey: "NLOpenBook") {
                try? await Task.sleep(for: .seconds(1))
                library.path = [id]
            }
        }
    }
}
