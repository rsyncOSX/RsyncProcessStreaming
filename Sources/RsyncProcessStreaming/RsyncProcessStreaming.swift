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
    private let accumulator = StreamAccumulator()

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

        currentProcess = process
        handlers.updateProcess(process)

        // Start strømming av data
        setupPipeHandlers(outputPipe: outputPipe, errorPipe: errorPipe)
        setupTerminationHandler(process: process, outputPipe: outputPipe, errorPipe: errorPipe)

        try process.run()
        logProcessStart(process)
    }

    private func setupPipeHandlers(outputPipe: Pipe, errorPipe: Pipe) {
        // Håndter Standard Output via AsyncStream
        Task { [weak self] in
            let outputStream = self?.createAsyncStream(for: outputPipe.fileHandleForReading)
            if let outputStream {
                for await text in outputStream {
                    await self?.handleOutputData(text)
                }
            }
        }

        // Håndter Standard Error via AsyncStream
        Task { [weak self] in
            let errorStream = self?.createAsyncStream(for: errorPipe.fileHandleForReading)
            if let errorStream {
                for await text in errorStream {
                    await self?.accumulator.recordError(text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    private func createAsyncStream(for handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
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

            // Les siste rest av data manuelt før vi stenger alt
            let finalOutputData = try? outputPipe.fileHandleForReading.readToEnd()
            let finalErrorData = try? errorPipe.fileHandleForReading.readToEnd()

            // Dette trigger continuation.onTermination i AsyncStreams
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            Task { @MainActor [weak self] in
                guard let self else { return }
                await processFinalOutput(
                    finalOutputData: finalOutputData ?? Data(),
                    finalErrorData: finalErrorData ?? Data(),
                    task: task
                )
            }
        }
    }

    private func handleOutputData(_ text: String) async {
        guard !cancelled, !errorOccurred else { return }

        let lines = await accumulator.consume(text)
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

    private func processFinalOutput(finalOutputData: Data, finalErrorData: Data, task: Process) async {
        if let text = String(data: finalOutputData, encoding: .utf8), !text.isEmpty {
            await handleOutputData(text)
        }
        if let trailing = await accumulator.flushTrailing() {
            Logger.process.debugMessageOnly("Flushed trailing: \(trailing)")
        }
        if let errorText = String(data: finalErrorData, encoding: .utf8), !errorText.isEmpty {
            await accumulator.recordError(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        await handleTermination(task: task)
    }

    private func handleTermination(task: Process) async {
        let output = await accumulator.snapshot()
        let errors = await accumulator.errorSnapshot()

        if cancelled {
            handlers.propagateError(RsyncProcessError.processCancelled)
            handlers.processTermination(output, hiddenID)
            handlers.updateProcess(nil)
            return
        }

        if task.terminationStatus != 0, handlers.checkForErrorInRsyncOutput, !errorOccurred {
            handlers.propagateError(RsyncProcessError.processFailed(exitCode: task.terminationStatus, errors: errors))
        }

        handlers.processTermination(output, hiddenID)
        handlers.updateProcess(nil)
        currentProcess = nil
    }

    deinit {
        if let process = currentProcess, process.isRunning {
            process.terminate()
        }
    }
}
