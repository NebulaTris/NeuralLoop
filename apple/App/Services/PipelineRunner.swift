// Runs the book pipeline and streams its output lines.
// Where the pipeline lives, in order: the downloaded runtime (Application Support/app.neuralloop.books/runtime),
// NEURALLOOP_PIPELINE (a folder with nl_book.py) with NEURALLOOP_PYTHON, then (development) the repo this app was built from.

import Foundation

final class PipelineRunner: @unchecked Sendable {
    enum Failure: LocalizedError {
        case notFound
        var errorDescription: String? { "NeuralLoop's engine isn't installed yet. Open NeuralLoop once while online to finish setup." }
    }

    private var process: Process?

    static func command() -> (executable: URL, prefix: [String])? {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("app.neuralloop.books")
        let runtime = support.appendingPathComponent("runtime/bin/neuralloop")
        if fm.isExecutableFile(atPath: runtime.path) { return (runtime, []) }
        let env = ProcessInfo.processInfo.environment
        if let folder = env["NEURALLOOP_PIPELINE"], let python = env["NEURALLOOP_PYTHON"] {
            return (URL(fileURLWithPath: python), [folder + "/nl_book.py"])
        }
        if let repo = Bundle.main.object(forInfoDictionaryKey: "NeuralLoopRepo") as? String {
            let root = URL(fileURLWithPath: repo).standardizedFileURL
            let python = root.appendingPathComponent(".venv/bin/python")
            let script = root.appendingPathComponent("pipeline/nl_book.py")
            if fm.isExecutableFile(atPath: python.path), fm.fileExists(atPath: script.path) { return (python, [script.path]) }
        }
        return nil
    }

    func start(arguments: [String], onLine: @escaping @Sendable (String) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        guard let (executable, prefix) = Self.command() else { throw Failure.notFound }
        let process = Process()
        process.executableURL = executable
        process.arguments = prefix + arguments
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        let config = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.neuralloop.books/ai.json")
        if FileManager.default.fileExists(atPath: config.path) { env["NEURALLOOP_AI_CONFIG"] = config.path }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let buffer = LineBuffer(onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { buffer.append(data) }
        }
        process.terminationHandler = { finished in
            buffer.flush()
            onExit(finished.terminationStatus)
        }
        try process.run()
        self.process = process
    }

    func stop() { process?.terminate() }
}

/// Splits streamed bytes into lines.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            onLine(line)
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
    }
}
