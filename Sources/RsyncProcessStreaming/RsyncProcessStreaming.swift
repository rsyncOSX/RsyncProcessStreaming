// swiftlint:disable line_length
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

    func recordError(_ text: String) {
        errorLines.append(text)
    }

    func errorSnapshot() -> [String] { errorLines }

    func incrementLineCounter() -> Int {
        lineCounter += 1
        return lineCounter
    }

    func getLineCount() -> Int { lineCounter }

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

    // MainActor-isolated state
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
        // Reset state for reuse
        cancelled = false
        errorOccurred = false
        Task {
            await accumulator.reset()
        }

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

        setupPipeHandlers(outputPipe: outputPipe, errorPipe: errorPipe)
        setupTerminationHandler(process: process, outputPipe: outputPipe, errorPipe: errorPipe)

        try process.run()
        logProcessStart(process)
    }

    /// Cancels the running process
    public func cancel() {
        cancelled = true
        currentProcess?.terminate()
        Logger.process.debugMessageOnly("RsyncProcessStreaming: Process cancelled")
    }

    /// Returns whether the process has been cancelled
    public var isCancelledState: Bool {
        cancelled
    }

    /// Returns whether the process is currently running
    public var isRunning: Bool {
        currentProcess?.isRunning ?? false
    }

    // MARK: - Private Setup Methods

    private func setupPipeHandlers(outputPipe: Pipe, errorPipe: Pipe) {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }

            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

            Task {
                await self.handleOutputData(text)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }

            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

            Task {
                await self.accumulator.recordError(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func setupTerminationHandler(process: Process, outputPipe: Pipe, errorPipe: Pipe) {
        process.terminationHandler = { [weak self] task in
            guard let self else { return }

            // Capture remaining output before cleaning up handlers
            let finalOutputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let finalErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            // Remove handlers to prevent further callbacks
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            Task {
                await self.processFinalOutput(
                    finalOutputData: finalOutputData,
                    finalErrorData: finalErrorData,
                    task: task
                )
            }
        }
    }

    private func logProcessStart(_ process: Process) {
        guard let path = process.executableURL, let arguments = process.arguments else { return }
        Logger.process.debugThreadOnly("RsyncProcessStreaming: COMMAND - \(path)")
        Logger.process.debugMessageOnly("RsyncProcessStreaming: ARGUMENTS - \(arguments.joined(separator: "\n"))")
    }

    // MARK: - Private Processing Methods

    private func processFinalOutput(
        finalOutputData: Data,
        finalErrorData: Data,
        task: Process
    ) async {
        // Process any final output data that was still in the pipe
        if let text = String(data: finalOutputData, encoding: .utf8), !text.isEmpty {
            await handleOutputData(text)
        }

        // Flush any remaining partial line
        if let trailing = await accumulator.flushTrailing() {
            Logger.process.debugMessageOnly("RsyncProcessStreaming: Flushed trailing output: \(trailing)")
        }

        // Process any final error data
        if let errorText = String(data: finalErrorData, encoding: .utf8), !errorText.isEmpty {
            await accumulator.recordError(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        await handleTermination(task: task)
    }

    private func handleOutputData(_ text: String) async {
        // Early exit if cancelled or error occurred
        guard !cancelled, !errorOccurred else { return }

        let lines = await accumulator.consume(text)
        guard !lines.isEmpty else { return }

        for line in lines {
            // Recheck state for each line
            if cancelled || errorOccurred { break }

            if useFileHandler {
                let count = await accumulator.incrementLineCounter()
                Task { @MainActor in
                    self.handlers.fileHandler(count)
                }
            }

            do {
                try handlers.checkLineForError(line)
            } catch {
                // Set error flag and terminate the process
                errorOccurred = true
                Logger.process.debugMessageOnly("RsyncProcessStreaming: Error detected in output - \(error.localizedDescription)")

                // Terminate the process when error is detected
                currentProcess?.terminate()

                Task { @MainActor in
                    self.handlers.propagateError(error)
                }
                break
            }
        }
    }

    private func handleTermination(task: Process) async {
        let output = await accumulator.snapshot()
        let errors = await accumulator.errorSnapshot()

        // Priority 1: Handle cancellation
        if cancelled {
            Logger.process.debugMessageOnly("RsyncProcessStreaming: Terminated due to cancellation")
            await MainActor.run {
                self.handlers.propagateError(RsyncProcessError.processCancelled)
                self.handlers.processTermination(output, self.hiddenID)
                self.handlers.updateProcess(nil)
            }
            cleanupProcess()
            return
        }

        // Priority 2: Handle errors detected during output processing
        // (errorOccurred flag was already set and error was propagated)

        // Priority 3: Handle process failure based on exit code
        if task.terminationStatus != 0, handlers.checkForErrorInRsyncOutput, !errorOccurred {
            let error = RsyncProcessError.processFailed(
                exitCode: task.terminationStatus,
                errors: errors
            )
            Logger.process.debugMessageOnly(
                "RsyncProcessStreaming: Process failed with exit code \(task.terminationStatus)"
            )

            await MainActor.run {
                self.handlers.propagateError(error)
            }
        }

        // Always call termination handler
        await MainActor.run {
            self.handlers.processTermination(output, self.hiddenID)
            self.handlers.updateProcess(nil)
        }

        cleanupProcess()
    }

    private func cleanupProcess() {
        currentProcess = nil
    }

    deinit {
        // Ensure process is terminated if RsyncProcess is deallocated
        if let process = currentProcess, process.isRunning {
            process.terminate()
            Logger.process.debugMessageOnly("RsyncProcessStreaming: Process terminated in deinit")
        }

        Logger.process.debugMessageOnly("RsyncProcessStreaming: DEINIT")
    }
}

// swiftlint:enable line_length
