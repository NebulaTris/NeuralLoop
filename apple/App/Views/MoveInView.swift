// "Psst… I'm still in the moving box!": when NeuralLoop runs from Downloads or the disk image, Pip offers to move into
// Applications (so macOS stops asking, settings stick, and it opens from Launchpad), then reopens from there.

import AppKit
import NeuralLoopCore
import SwiftUI

enum AppMover {
    static var place: InstallPlace { InstallPlace.of(Bundle.main.bundlePath) }

    /// Development builds run from the repo and never ask.
    static var isDevelopmentBuild: Bool {
        !((Bundle.main.object(forInfoDictionaryKey: "NeuralLoopRepo") as? String) ?? "").isEmpty
    }

    static var shouldAsk: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "NLMoveIn") { return true }  // development: `-NLMoveIn YES` shows the sheet
        #endif
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return !isDevelopmentBuild && place.needsMove && UserDefaults.standard.string(forKey: "moveInLater") != version
    }

    static func later() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        UserDefaults.standard.set(version, forKey: "moveInLater")
    }

    /// Copies the app into /Applications (or ~/Applications if that isn't writable), replacing an older copy (which goes
    /// to the Trash, never deleted outright), then opens the new one and quits this one. Returns a reason if it couldn't.
    static func moveIn() -> String? {
        let fm = FileManager.default
        let name = Bundle.main.bundleURL.lastPathComponent
        let personal = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        var lastProblem = ""
        let here = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        for folder in [URL(fileURLWithPath: "/Applications", isDirectory: true), personal] {
            let destination = folder.appendingPathComponent(name)
            // Already there: nothing to move (and never trash the copy that's running).
            if destination.standardizedFileURL.resolvingSymlinksInPath() == here { return nil }
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) {
                    // Only an older NeuralLoop goes to the Trash, never another app that happens to share the name.
                    guard Bundle(url: destination)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                        lastProblem = "There's already a different app called \(name) in \(folder.path). Rename or move it, then try again."
                        continue
                    }
                    try fm.trashItem(at: destination, resultingItemURL: nil)
                }
                try fm.copyItem(at: Bundle.main.bundleURL, to: destination)
                reopen(from: destination)
                return nil
            } catch {
                lastProblem = error.localizedDescription
            }
        }
        return lastProblem
    }

    private static func reopen(from destination: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

struct MoveInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var moving = false
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottom) {
                // Pip peeking out of a moving box.
                // Pip hopping in the box (PipView's own hop; Reduce Motion keeps it still).
                PipView(pose: .hop, size: 150).padding(.bottom, 26)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.color(light: 0xE8C49A, dark: 0xB8906A))
                    .frame(width: 210, height: 62)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Theme.color(light: 0xD4A877, dark: 0x9C7652)).frame(height: 8)
                    }
                    .overlay {
                        Text("FRAGILE · CONTAINS PANDA").font(Theme.display(11, .medium)).fixedSize()
                            .foregroundStyle(Theme.color(light: 0x8A5A33, dark: 0x4A2E18)).tracking(0.8)
                    }
            }
            .frame(height: 180)

            VStack(spacing: 12) {
                Text("Psst… I'm still in the moving box!").font(Theme.display(24)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 2)
                Text("I'm running from \(AppMover.place.words) right now. It's cozy in here, but in Applications I can unpack, remember your settings, and macOS stops asking about me every time you open me.")
                    .font(Theme.body(14)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
            }

            if let problem {
                Text("I couldn't move in by myself (\(problem)). No worries: drag NeuralLoop into Applications in Finder, then open it from there.")
                    .font(Theme.body(12)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                    .padding(10).background(Theme.butterSoft, in: RoundedRectangle(cornerRadius: 10)).frame(maxWidth: 420)
            }

            HStack(spacing: 12) {
                Button("Maybe later") {
                    AppMover.later()
                    dismiss()
                }
                .controlSize(.large)
                Button {
                    moving = true
                    problem = AppMover.moveIn()
                    if problem != nil { moving = false }
                } label: {
                    Label(moving ? "Carrying my yarn…" : "Move me in", systemImage: moving ? "shippingbox.fill" : "house.fill")
                        .font(Theme.display(15, .medium)).padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(moving || AppMover.isDevelopmentBuild)
                .keyboardShortcut(.defaultAction)
            }
            Text(AppMover.place == .diskImage ? "After I reopen, you can eject the NeuralLoop disk image." : "I'll reopen from Applications in a second. The copy here can go in the Trash.")
                .font(Theme.body(11)).foregroundStyle(Theme.ink3)
        }
        .padding(32)
        .frame(width: 520)
        .background(Theme.paper)
    }
}
