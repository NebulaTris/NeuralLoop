// NeuralLoop for Mac: drop a book, and Pip turns every chapter into a five-step learning loop.

import NeuralLoopCore
import SwiftUI

@main
struct NeuralLoopApp: App {
    @State private var library: Library
    @State private var settings = AISettings()

    init() {
        let library = Library()
        _library = State(initialValue: library)
        library.start()  // the shelf loop lives as long as the app, window or not
        // Your library on every device: upload what the Mac prepares, prepare books added on the iPad.
        DriveSync.shared.onArrived = { file, title in library.addFromInbox(file, title: title) }
        DriveSync.shared.onChanged = { library.reload() }
        DriveSync.shared.onRemovedElsewhere = { library.removedElsewhere($0) }
        DriveSync.shared.start()
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
            CommandGroup(replacing: .help) {
                TourCommand(library: library)
            }
        }
        Settings {
            SettingsView().environment(settings).environment(library)
        }
        #if DEBUG
        // Development only (never in a Release build): `-NLPipSheet YES` shows every pose, animated, for checking Pip's artwork and motion.
        Window("Pip", id: "pip-sheet") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(200), spacing: 16), count: 4), spacing: 16) {
                ForEach(PipPose.allCases, id: \.self) { pose in
                    VStack(spacing: 4) {
                        PipView(pose: pose, size: 190)
                        Text(pose.rawValue).font(Theme.body(12)).foregroundStyle(Theme.ink3)
                    }
                }
            }
            .padding(24)
            .background(Theme.paper)
        }
        .windowResizability(.contentSize)
        // Development: `-NLPreviewPanel YES` shows the menu-bar panel in a window, for screenshots.
        Window("Quick panel", id: "panel-preview") {
            QuickPanel().environment(library).environment(settings)
        }
        .windowResizability(.contentSize)
        #endif
        MenuBarExtra {
            QuickPanel().environment(library).environment(settings)
        } label: {
            MenuBarPip()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Help → Take the Tour: the tour shows on the main window, so that window opens first if it's closed.
struct TourCommand: View {
    let library: Library
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Take the Tour") {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
            NSApp.activate(ignoringOtherApps: true)
            library.requestTour()
        }
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
                    if let entry = library.entry(id) { BookView(entry: entry) } else { BookGoneView() }
                }
        }
        .background(Theme.paper)
        .tint(Theme.accent)
        // First things first: move into Applications (when running from Downloads or the disk image), then the welcome.
        .sheet(isPresented: $movingIn) { MoveInView() }
        // Never on top of the move-in sheet; once that closes, the tour follows if it's wanted.
        .sheet(isPresented: Binding(get: { (!welcomed || library.showingTour) && !movingIn },
                                    set: { if !$0 { welcomed = true; library.showingTour = false } })) {
            GuidedTour { welcomed = true; library.showingTour = false }
        }
        // Development builds only: `open NeuralLoop.app --args -NLOpenSettings YES` opens Settings (for screenshots and checks).
        .task {
            if Notifier.shared.openMainWindow == nil { Notifier.shared.openMainWindow = { openWindow(id: "main") } }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "NLOpenSettings") { openSettings() }
            if UserDefaults.standard.bool(forKey: "NLPreviewPanel") { openWindow(id: "panel-preview") }
            if UserDefaults.standard.bool(forKey: "NLPipSheet") { openWindow(id: "pip-sheet") }
            if UserDefaults.standard.bool(forKey: "NLTour") { library.showingTour = true }  // `-NLTour YES [-NLTourPage n]`
            // `-NLTestNudge sadViolin|sadMeow|shocked|gentle` sends that test nudge (sound, picture, on-screen Pip).
            if let mood = UserDefaults.standard.string(forKey: "NLTestNudge").flatMap(NudgeMood.init(rawValue:)) {
                try? await Task.sleep(for: .seconds(1.5))
                Nudger.send(Nudge.sample(mood), test: true)
            }
            // `-NLNudgePictures <folder>` writes each silly nudge's Pip picture there (checking what notifications show).
            if let folder = UserDefaults.standard.string(forKey: "NLNudgePictures") {
                for mood in NudgeMood.allCases {
                    guard let picture = NudgeSounds.picture(mood) else { continue }
                    let target = URL(fileURLWithPath: folder).appendingPathComponent("\(mood.rawValue).png")
                    try? FileManager.default.removeItem(at: target)
                    try? FileManager.default.moveItem(at: picture, to: target)
                }
            }
            // `-NLOpenBook <id> [-NLStage map] [-NLBookMap YES]` opens a book (for screenshots and checks).
            if let id = UserDefaults.standard.string(forKey: "NLOpenBook") {
                try? await Task.sleep(for: .seconds(1))
                library.path = [id]
            }
            #endif
        }
    }
}
