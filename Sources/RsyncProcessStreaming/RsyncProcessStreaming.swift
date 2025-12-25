import Foundation
import OSLog

public enum RsyncProcessError: Error, LocalizedError {
    case executableNotFound(String)
    case processFailed(exitCode: Int32, errors: [String])
    case processCancelled

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "Rsync executable not found at path: \(path)"
        case let .processFailed(code, errors):
            let message = errors.joined(separator: "\n")
            return "rsync exited with code \(code).\n\(message)"
        case .processCancelled:
            return "Process was cancelled"
        }
    }
}

actor StreamAccumulator {
    private var lines: [String] = []
    private var partialLine: String = ""
    private var errorLines: [String] = []
    private var lineCounter: Int = 0

    func consume(_ text: String) -> [String] {
        let combined = partialLine + text
        let parts = combined.components(separatedBy: .newlines)
        partialLine = parts.last ?? ""
        let newLines = parts.dropLast().filter { !$0.isEmpty }
        lines.append(contentsOf: newLines)
        return Array(newLines)
    }

    func flushTrailing() -> String? {
        guard !partialLine.isEmpty else { return nil }
        let trailing = partialLine
        partialLine = ""
        lines.append(trailing)
        return trailing
    }

    func snapshot() -> [String] { lines }
    func recordError(_ text: String) { errorLines.append(text) }
    func errorSnapshot() -> [String] { errorLines }
    func incrementLineCounter() -> Int {
        lineCounter += 1
        return lineCounter
    }

    func reset() {
        lines.removeAll()
        partialLine = ""
        errorLines.removeAll()
        lineCounter = 0
    }
}

@MainActor
public final class RsyncProcess {
    private let arguments: [String]
    private let hiddenID: Int?
    private let handlers: ProcessHandlers
    private let useFileHandler: Bool
    let accumulator = StreamAccumulator()

    private var completion = CompletionCoordinator()

    private var outputPipe: Pipe?
    private var errorPipe: Pipe?

    private var currentProcess: Process?
    private var cancelled = false
    private var errorOccurred = false

    public init(
        arguments: [String],
        hiddenID: Int? = nil,
        handlers: ProcessHandlers,
        useFileHandler: Bool = false
    ) {
        self.arguments = arguments
        self.hiddenID = hiddenID
        self.handlers = handlers
        self.useFileHandler = useFileHandler
    }

    public func executeProcess() throws {
        cancelled = false
        errorOccurred = false
        Task { await accumulator.reset() }
        completion = CompletionCoordinator()

        let executablePath = handlers.rsyncPath ?? "/usr/bin/rsync"
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw RsyncProcessError.executableNotFound(executablePath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = handlers.environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.outputPipe = outputPipe
        self.errorPipe = errorPipe

        currentProcess = process
        handlers.updateProcess(process)

        // Start strømming av data
        setupPipeHandlers(outputPipe: outputPipe, errorPipe: errorPipe)
        setupTerminationHandler(process: process, outputPipe: outputPipe, errorPipe: errorPipe)

        try process.run()

        // Important: close the parent's copy of the write-ends so EOF is observed
        // when the child exits (otherwise the read side may never see EOF).
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        logProcessStart(process)
    }

    private func setupPipeHandlers(outputPipe: Pipe, errorPipe: Pipe) {
        // Håndter Standard Output via AsyncStream
        Task { [weak self] in
            let outputStream = self?.createAsyncStream(
                for: outputPipe.fileHandleForReading,
                onEOF: { [weak self] in
                    Task { await self?.markStdoutEOF() }
                }
            )
            if let outputStream {
                for await text in outputStream {
                    await self?.handleOutputData(text)
                }
            }
        }

        // Håndter Standard Error via AsyncStream
        Task { [weak self] in
            let errorStream = self?.createAsyncStream(
                for: errorPipe.fileHandleForReading,
                onEOF: { [weak self] in
                    Task { await self?.markStderrEOF() }
                }
            )
            if let errorStream {
                for await text in errorStream {
                    await self?.accumulator.recordError(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    private func createAsyncStream(for handle: FileHandle, onEOF: @escaping @Sendable () -> Void) -> AsyncStream<String> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    // EOF
                    handle.readabilityHandler = nil
                    continuation.finish()
                    onEOF()
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    continuation.yield(text)
                }
            }

            continuation.onTermination = { @Sendable _ in
                handle.readabilityHandler = nil
            }
        }
    }

    private func setupTerminationHandler(process: Process, outputPipe: Pipe, errorPipe: Pipe) {
        process.terminationHandler = { [weak self] task in
            guard let self else { return }

            Task {
                await self.markProcessTerminated(task)
            }
        }
    }

    private func handleOutputData(_ text: String) async {
        let lines = await accumulator.consume(text)
        // Keep draining stdout to avoid pipe backpressure even if cancelled/error.
        guard !cancelled, !errorOccurred else { return }

        for line in lines {
            if cancelled || errorOccurred { break }

            if useFileHandler {
                let count = await accumulator.incrementLineCounter()
                handlers.fileHandler(count)
            }

            do {
                try handlers.checkLineForError(line)
            } catch {
                errorOccurred = true
                Logger.process.debugMessageOnly("Error detected: \(error.localizedDescription)")
                currentProcess?.terminate()
                handlers.propagateError(error)
                break
            }
        }
    }

    // ... Resten av metodene (processFinalOutput, handleTermination, osv) forblir i stor grad like ...

    public func cancel() {
        cancelled = true
        currentProcess?.terminate()
    }

    public var isRunning: Bool { currentProcess?.isRunning ?? false }
    public var isCancelled: Bool { cancelled }

    private func logProcessStart(_ process: Process) {
        guard let path = process.executableURL, let arguments = process.arguments else { return }
        Logger.process.debugThreadOnly("RsyncProcessStreaming: COMMAND - \(path)")
        Logger.process.debugMessageOnly("RsyncProcessStreaming: ARGUMENTS - \(arguments.joined(separator: "\n"))")
    }

    private func handleTermination(task: Process) async {
        let output = await accumulator.snapshot()
        let errors = await accumulator.errorSnapshot()

        if cancelled {
            handlers.propagateError(RsyncProcessError.processCancelled)
            handlers.processTermination(output, hiddenID)
            handlers.updateProcess(nil)
            cleanupPipes()
            return
        }

        if task.terminationStatus != 0, handlers.checkForErrorInRsyncOutput, !errorOccurred {
            handlers.propagateError(RsyncProcessError.processFailed(exitCode: task.terminationStatus, errors: errors))
        }

        handlers.processTermination(output, hiddenID)
        handlers.updateProcess(nil)
        currentProcess = nil

        cleanupPipes()
    }

    private func cleanupPipes() {
        // Cleanup: close read handles if they are still open.
        if let outputPipe {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? outputPipe.fileHandleForReading.close()
        }
        if let errorPipe {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? errorPipe.fileHandleForReading.close()
        }
        self.outputPipe = nil
        self.errorPipe = nil
    }

    deinit {
        Logger.process.debugMessageOnly("RsyncProcessStreaming: DEINIT")
        if let process = currentProcess, process.isRunning {
            process.terminate()
        }
    }
}

private actor CompletionCoordinator {
    private var stdoutEOF = false
    private var stderrEOF = false
    private var processTerminated = false
    private var finalized = false

    func markStdoutEOF() -> Bool {
        stdoutEOF = true
        return takeFinalizeIfReady()
    }

    func markStderrEOF() -> Bool {
        stderrEOF = true
        return takeFinalizeIfReady()
    }

    func markProcessTerminated() -> Bool {
        processTerminated = true
        return takeFinalizeIfReady()
    }

    private func takeFinalizeIfReady() -> Bool {
        guard !finalized, stdoutEOF, stderrEOF, processTerminated else { return false }
        finalized = true
        return true
    }
}

private extension RsyncProcess {
    func markStdoutEOF() async {
        if await completion.markStdoutEOF() {
            await finalizeAfterDrain()
        }
    }

    func markStderrEOF() async {
        if await completion.markStderrEOF() {
            await finalizeAfterDrain()
        }
    }

    func markProcessTerminated(_ task: Process) async {
        if await completion.markProcessTerminated() {
            await finalizeAfterDrain(process: task)
        }
    }

    func finalizeAfterDrain(process: Process? = nil) async {
        let task = process ?? currentProcess
        guard let task else { return }

        if let trailing = await accumulator.flushTrailing() {
            Logger.process.debugMessageOnly("Flushed trailing: \(trailing)")
        }
        await handleTermination(task: task)
    }
}
