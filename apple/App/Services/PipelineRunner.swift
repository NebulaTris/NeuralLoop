// Runs the book pipeline and streams its output lines.
// Where the pipeline lives, in order: the runtime packaged inside the app (Contents/Resources/runtime, `make package`;
// it's covered by the app's signature, so nothing outside the app can swap it), NEURALLOOP_PIPELINE (a folder with
// nl_book.py) with NEURALLOOP_PYTHON, then (development builds) the repo this app was built from.

import Foundation
import NeuralLoopCore

final class PipelineRunner: @unchecked Sendable {
    enum Failure: LocalizedError {
        case notFound
        var errorDescription: String? { "NeuralLoop's engine is missing from the app. Download NeuralLoop again to repair it." }
    }

    private var process: Process?

    static func command() -> (executable: URL, prefix: [String])? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime/bin/neuralloop"),
           fm.isExecutableFile(atPath: bundled.path) { return (bundled, []) }
        let env = ProcessInfo.processInfo.environment
        if let folder = env["NEURALLOOP_PIPELINE"], let python = env["NEURALLOOP_PYTHON"] {
            return (URL(fileURLWithPath: python), [folder + "/nl_book.py"])
        }
        if let repo = Bundle.main.object(forInfoDictionaryKey: "NeuralLoopRepo") as? String, !repo.isEmpty {
            let root = URL(fileURLWithPath: repo).standardizedFileURL
            let python = root.appendingPathComponent(".venv/bin/python")
            let script = root.appendingPathComponent("pipeline/nl_book.py")
            if fm.isExecutableFile(atPath: python.path), fm.fileExists(atPath: script.path) { return (python, [script.path]) }
        }
        return nil
    }

    /// Runs the pipeline with its output going straight to the book's pipeline.log, so preparation keeps going if the
    /// app quits (a pipe would break and stop it). While the app is open it follows the log: every new line goes to
    /// `onLine`, and `onExit` gets the exit code plus the last lines, to say what happened.
    func start(arguments: [String], log: URL, onLine: @escaping @Sendable (String) -> Void,
               onExit: @escaping @Sendable (Int32, [String]) -> Void) throws {
        guard let (executable, prefix) = Self.command() else { throw Failure.notFound }
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let output = try FileHandle(forWritingTo: log)
        output.seekToEndOfFile()
        output.write(Data("\n— \(Date().formatted()) —\n".utf8))
        let startOffset = output.offsetInFile
        let process = Process()
        process.executableURL = executable
        process.arguments = prefix + arguments
        process.environment = Self.environment()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let follower = LogFollower(url: log, from: startOffset, onLine: onLine)
        process.terminationHandler = { finished in
            follower.stop()
            onExit(finished.terminationStatus, follower.tail)
        }
        try process.run()
        follower.start()
        self.process = process
    }

    func stop() { process?.terminate() }

    static let aiConfigURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("app.neuralloop.books/ai.json")

    /// The pipeline's environment: the person's ai.json and their keys from the Keychain (never on the command line).
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        if FileManager.default.fileExists(atPath: aiConfigURL.path) { env["NEURALLOOP_AI_CONFIG"] = aiConfigURL.path }
        for name in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "NEURALLOOP_API_KEY"] {
            if let key = Keychain.read(name), !key.isEmpty { env[name] = key }
        }
        return env
    }

    /// Run a quick pipeline command (sign in, account, usage, check AI, grade recall) and collect its output.
    /// Output is read while it runs (so a chatty command never blocks), and a command that runs past `timeout` is stopped.
    static func once(_ arguments: [String], input: String? = nil, timeout: Duration = .seconds(120)) async -> (code: Int32, lines: [String]) {
        guard let (executable, prefix) = command() else { return (3, [Failure.notFound.errorDescription ?? ""]) }
        let process = Process()
        process.executableURL = executable
        process.arguments = prefix + arguments
        process.environment = environment()
        let out = Pipe()
        let stdin = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        let collected = OutputBuffer()
        out.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        let code: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
                return
            }
            if let input { try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
            try? stdin.fileHandleForWriting.close()
            let running = UncheckedProcess(process)
            Task.detached {
                try? await Task.sleep(for: timeout)
                if running.process.isRunning { running.process.terminate() }
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        collected.append((try? out.fileHandleForReading.readToEnd()) ?? Data())
        if code == -1 { return (3, [Failure.notFound.errorDescription ?? ""]) }
        return (code, collected.text.split(separator: "\n").map(String.init))
    }
}

/// A process handed to the timeout task (Process isn't Sendable; only isRunning and terminate are used).
private struct UncheckedProcess: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// Bytes collected from a pipe on a background thread.
private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Follows a growing log file: reads new bytes every half second, hands out whole lines, keeps the last few.
final class LogFollower: @unchecked Sendable {
    private let url: URL
    private var offset: UInt64
    private let lock = NSLock()
    private var lines: [String] = []
    private var timer: DispatchSourceTimer?
    private let buffer = LineBuffer()
    /// Reading and stopping happen on this one queue, so the same bytes are never read twice.
    private let queue = DispatchQueue(label: "app.neuralloop.log-follower")

    init(url: URL, from offset: UInt64, onLine: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.offset = offset
        buffer.onLine = { [weak self] line in self?.remember(line); onLine(line) }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.read() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        queue.sync {
            read()
            timer?.cancel()
            buffer.flush()
        }
    }

    private func read() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        offset += UInt64(data.count)
        buffer.append(data)
    }

    private func remember(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("Fetching"), !trimmed.contains("HF_TOKEN") else { return }
        lock.lock(); defer { lock.unlock() }
        lines.append(trimmed)
        if lines.count > 30 { lines.removeFirst() }
    }

    var tail: [String] { lock.lock(); defer { lock.unlock() }; return lines }

    /// The last progress line in a log, for books being prepared by a run this app didn't start (or before a relaunch).
    static func lastProgress(in url: URL) -> PipelineLine? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Only the end matters, and logs grow with every run.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for raw in text.split(separator: "\n").suffix(200).reversed() {
            let line = PipelineLine.parse(String(raw))
            switch line {
            case .made, .added, .fellBack, .waiting, .failed, .setup: return line
            default: continue
            }
        }
        return nil
    }
}

/// Splits streamed bytes into lines.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    var onLine: (@Sendable (String) -> Void)?

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            onLine?(line)
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { onLine?(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
    }
}
