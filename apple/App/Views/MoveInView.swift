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

    /// Copies the app into /Applications (or ~/Applications if that isn't writable), then opens the new copy and quits
    /// this one. The new copy is made under a temporary name and checked first; only then does an older copy go to the
    /// Trash (never deleted outright) and the new one take its place, so a copy that fails never leaves nothing behind.
    /// This copy quits only once the new one has opened. Says how it went.
    /// The copy (over a gigabyte, with the runtime) happens off the main thread, so Pip keeps carrying yarn meanwhile.
    @MainActor static func moveIn() async -> MoveOutcome {
        switch await Task.detached(operation: { copyIn() }).value {
        case .alreadyThere: return .alreadyHome
        case .failed(let problem): return .problem(problem)
        case .copied(let destination):
            let problem = await reopen(from: destination)
            switch MoveInPlan.afterReopen(opened: problem == nil) {
            case .quit:
                NSApp.terminate(nil)
                return .reopening
            case .keepRunning:
                return .movedButNotOpened(folder: destination.deletingLastPathComponent().path, problem ?? "")
            }
        }
    }

    /// `reopening`: this copy is about to quit. `alreadyHome`: it's the one in Applications, so nothing to do.
    /// `movedButNotOpened`: the new copy is in place, but macOS wouldn't open it, so this one keeps running.
    enum MoveOutcome: Equatable { case reopening, alreadyHome, problem(String), movedButNotOpened(folder: String, String) }

    enum CopyOutcome: Sendable { case alreadyThere, copied(URL), failed(String) }

    nonisolated private static func copyIn() -> CopyOutcome {
        let fm = FileManager.default
        let name = Bundle.main.bundleURL.lastPathComponent
        let personal = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        var lastProblem = ""
        let here = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        for folder in [URL(fileURLWithPath: "/Applications", isDirectory: true), personal] {
            let destination = folder.appendingPathComponent(name)
            let found: MoveInPlan.Destination =
                destination.standardizedFileURL.resolvingSymlinksInPath() == here ? .thisCopy
                : !fm.fileExists(atPath: destination.path) ? .empty
                : Bundle(url: destination)?.bundleIdentifier == Bundle.main.bundleIdentifier ? .olderCopy : .otherApp
            switch MoveInPlan.decide(found) {
            case .alreadyThere:
                return .alreadyThere
            case .tryNextFolder:
                lastProblem = "there's already a different app called \(name) in \(folder.path). Rename or move it, then try again"
            case .steps(let steps):
                guard let problem = carryOut(steps, into: folder, destination: destination) else { return .copied(destination) }
                lastProblem = problem
            }
        }
        return .failed(lastProblem)
    }

    /// Does the steps in order; when one fails, undoes what was done and says why.
    nonisolated private static func carryOut(_ steps: [MoveInPlan.Step], into folder: URL, destination: URL) -> String? {
        let fm = FileManager.default
        let staging = folder.appendingPathComponent(".moving-\(UUID().uuidString)-\(destination.lastPathComponent)")
        var trashed: URL?
        for step in steps {
            do {
                switch step {
                case .copyToStaging:
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    try fm.copyItem(at: Bundle.main.bundleURL, to: staging)
                case .checkStaging:
                    guard isGoodCopy(staging) else { throw MoveProblem.incompleteCopy }
                case .trashOld:
                    var result: NSURL?
                    try fm.trashItem(at: destination, resultingItemURL: &result)
                    trashed = result as URL?
                case .putInPlace:
                    try fm.moveItem(at: staging, to: destination)
                }
            } catch {
                for undo in MoveInPlan.undo(failedAt: step, trashedOld: trashed != nil) {
                    switch undo {
                    case .removeStaging: try? fm.removeItem(at: staging)
                    case .restoreOld: if let trashed { try? fm.moveItem(at: trashed, to: destination) }
                    }
                }
                return error.localizedDescription
            }
        }
        return nil
    }

    /// The copy has this app's identifier, version, and executable (read from its Info.plist, never cached).
    nonisolated private static func isGoodCopy(_ copy: URL) -> Bool {
        let info = (try? Data(contentsOf: copy.appendingPathComponent("Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let executable = (info["CFBundleExecutable"] as? String).map { copy.appendingPathComponent("Contents/MacOS/\($0)").path }
        return MoveInPlan.isGoodCopy(bundleID: info["CFBundleIdentifier"] as? String, version: info["CFBundleVersion"] as? String,
                                     hasExecutable: executable.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false,
                                     expectedID: Bundle.main.bundleIdentifier,
                                     expectedVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    enum MoveProblem: LocalizedError {
        case incompleteCopy
        var errorDescription: String? { "the copy in Applications didn't come out complete" }
    }

    /// Opens the new copy. Returns nil when it opened, or why it didn't (macOS can refuse to open a downloaded app).
    private static func reopen(from destination: URL) async -> String? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct MoveInView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var moving = false
    @State private var problem: String?
    /// Where the new copy went, when macOS wouldn't open it.
    @State private var movedTo: URL?

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
                Text(problem)
                    .font(Theme.body(12)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).background(Theme.butterSoft, in: RoundedRectangle(cornerRadius: 10)).frame(maxWidth: 420)
            }

            if let movedTo {
                // Moved, but macOS wouldn't open the new copy: show it, so it's one double-click away.
                HStack(spacing: 12) {
                    Button("Close") {
                        AppMover.later()
                        dismiss()
                    }
                    .controlSize(.large)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([movedTo])
                    } label: {
                        Label("Show it in Finder", systemImage: "folder").font(Theme.display(15, .medium)).padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                moveButtons
            }
            if movedTo == nil {
                Text(AppMover.place == .diskImage ? "After I reopen, you can eject the NeuralLoop disk image." : "I'll reopen from Applications in a second. The copy here can go in the Trash.")
                    .font(Theme.body(11)).foregroundStyle(Theme.ink3)
            }
        }
        .padding(32)
        .frame(width: 520)
        .background(Theme.paper)
    }

    private var moveButtons: some View {
        HStack(spacing: 12) {
            Button("Maybe later") {
                AppMover.later()
                dismiss()
            }
            .controlSize(.large)
            Button {
                moving = true
                problem = nil
                Task {
                    switch await AppMover.moveIn() {
                    case .reopening: break  // this copy quits in a moment
                    case .alreadyHome: dismiss()
                    case .problem(let reason):
                        problem = "I couldn't move in by myself (\(reason)). No worries: drag NeuralLoop into Applications in Finder, then open it from there."
                        moving = false
                    case .movedButNotOpened(let folder, let reason):
                        // The new copy is in place; this one keeps running so you're never left with nothing open.
                        problem = "I'm unpacked in \(folder), but macOS wouldn't open the new copy (\(reason)). Quit me, then open NeuralLoop from \(folder) yourself. If macOS asks, choose Open."
                        moving = false
                        movedTo = URL(fileURLWithPath: folder).appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
                    }
                }
            } label: {
                Label(moving ? "Carrying my yarn…" : "Move me in", systemImage: moving ? "shippingbox.fill" : "house.fill")
                    .font(Theme.display(15, .medium)).padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(moving || AppMover.isDevelopmentBuild)
            .keyboardShortcut(.defaultAction)
        }
    }
}
