// swiftlint:disable line_length
import Foundation
import OSLog

/// Errors that can occur during rsync process execution.
public enum RsyncProcessError: Error, LocalizedError {
    /// The rsync executable was not found at the specified path.
    case executableNotFound(String)

    /// The rsync process failed with a non-zero exit code.
    ///
    /// - Parameters:
    ///   - exitCode: The exit code returned by the process
    ///   - errors: Error messages captured from stderr
    case processFailed(exitCode: Int32, errors: [String])

    /// The process was cancelled by calling `cancel()`.
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

/// Thread-safe accumulator for streaming output and error lines.
///
/// This actor manages the accumulation of stdout and stderr data, handling partial lines
/// and providing thread-safe access to accumulated output. It's designed for efficient
/// streaming with minimal memory overhead.
///
/// The accumulator handles line breaking intelligently, preserving partial lines across
/// multiple `consume()` calls until a newline is received.
actor StreamAccumulator {
    private var lines: [String] = []
    private var partialLine: String = ""
    private var errorLines: [String] = []
    private var lineCounter: Int = 0

    /// Consumes text data and returns any complete lines.
    ///
    /// Partial lines (text without a trailing newline) are buffered internally
    /// and combined with the next chunk of data. Empty lines are filtered out.
    ///
    /// - Parameter text: Raw text data from stdout
    /// - Returns: Array of complete, non-empty lines extracted from the text
    func consume(_ text: String) -> [String] {
        let combined = partialLine + text
        let parts = combined.components(separatedBy: .newlines)
        partialLine = parts.last ?? ""
        let newLines = parts.dropLast().filter { !$0.isEmpty }
        lines.append(contentsOf: newLines)
        return Array(newLines)
    }

    /// Flushes any remaining partial line as a complete line.
    ///
    /// Call this at the end of processing to capture output that didn't end with a newline.
    ///
    /// - Returns: The trailing partial line, or nil if there was none
    func flushTrailing() -> String? {
        guard !partialLine.isEmpty else { return nil }
        let trailing = partialLine
        partialLine = ""
        lines.append(trailing)
        return trailing
    }

    /// Returns a snapshot of all accumulated output lines.
    func snapshot() -> [String] { lines }

    /// Records an error message from stderr.
    ///
    /// - Parameter text: Error text from stderr
    func recordError(_ text: String) {
        errorLines.append(text)
    }

    /// Returns a snapshot of all accumulated error lines.
    func errorSnapshot() -> [String] { errorLines }

    /// Increments and returns the line counter.
    ///
    /// - Returns: The new line count after incrementing
    func incrementLineCounter() -> Int {
        lineCounter += 1
        return lineCounter
    }

    /// Returns the current line count without incrementing.
    func getLineCount() -> Int { lineCounter }

    /// Resets all accumulated state to initial values.
    func reset() {
        lines.removeAll()
        partialLine = ""
        errorLines.removeAll()
        lineCounter = 0
    }
}

/// MainActor-isolated process manager for executing rsync with real-time output streaming.
///
/// `RsyncProcess` orchestrates the execution of rsync commands, streaming stdout and stderr
/// in real-time through configured handlers. It provides process lifecycle management,
/// cancellation support, and comprehensive error handling.
///
/// The class is MainActor-isolated to safely integrate with UI code while delegating
/// concurrent output accumulation to an internal actor.
///
/// Example usage:
/// ```swift
/// let handlers = ProcessHandlers(
///     processTermination: { output, _ in
///         print(\"Completed with \\(output?.count ?? 0) lines\")
///     },
///     fileHandler: { count in },
///     rsyncPath: nil,
///     checkLineForError: { _ in },
///     updateProcess: { _ in },
///     propagateError: { error in print(error) },
///     checkForErrorInRsyncOutput: true
/// )
///
/// let process = RsyncProcess(
///     arguments: [\"-av\", \"source/\", \"dest/\"],
///     handlers: handlers
/// )
///
/// try process.executeProcess()
///
/// // Later, to cancel:
/// process.cancel()
/// ```
@MainActor
public final class RsyncProcess {
    private let arguments: [String]
    private let hiddenID: Int?
    private let handlers: ProcessHandlers
    private let useFileHandler: Bool
    private var accumulator = StreamAccumulator()

    // MainActor-isolated state
    private var currentProcess: Process?
    private var cancelled = false
    private var errorOccurred = false

    /// Creates a new RsyncProcess instance.
    ///
    /// - Parameters:
    ///   - arguments: Command-line arguments to pass to rsync
    ///   - hiddenID: Optional identifier passed through to termination handler
    ///   - handlers: Configuration for all process callbacks and behaviors
    ///   - useFileHandler: Whether to invoke fileHandler callback for each line (default: false)
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

    /// Executes the rsync process with configured arguments and streams output.
    ///
    /// Validates the rsync executable exists, spawns the process, and sets up
    /// real-time streaming handlers for stdout and stderr. The process runs
    /// asynchronously with callbacks fired via the configured `ProcessHandlers`.
    ///
    /// The method resets internal state, allowing the same instance to be reused
    /// for multiple executions.
    ///
    /// - Throws: `RsyncProcessError.executableNotFound` if rsync is not found at the configured path
    /// - Note: This method is MainActor-isolated for safe UI integration
    /// - Important: Call `cancel()` to terminate a running process before deallocation
    public func executeProcess() throws {
        // Reset state for reuse
        cancelled = false
        errorOccurred = false
        accumulator = StreamAccumulator()

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

    /// Cancels the running process.
    ///
    /// Terminates the process immediately and triggers the termination handler
    /// with a `RsyncProcessError.processCancelled` error. Safe to call multiple
    /// times or when no process is running.
    public func cancel() {
        cancelled = true
        currentProcess?.terminate()
        Logger.process.debugMessageOnly("RsyncProcessStreaming: Process cancelled")
    }

    /// Returns whether the process has been cancelled.
    ///
    /// This flag is set when `cancel()` is called and remains true until
    /// the next call to `executeProcess()`.
    public var isCancelledState: Bool {
        cancelled
    }

    /// Returns whether the process is currently running.
    ///
    /// Returns false if no process has been started or if the process has terminated.
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

            Task { @MainActor [weak self] in
                guard let self else { return }
                await handleOutputData(text)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }

            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                await
                    accumulator.recordError(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func setupTerminationHandler(process: Process, outputPipe: Pipe, errorPipe: Pipe) {
        process.terminationHandler = { [weak self] task in
            guard let self else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }

                // Give a brief moment for any in-flight readability handler callbacks to complete
                // This ensures we don't race with pending data processing
                try? await Task.sleep(for: .milliseconds(50))

                // Now capture any remaining output that wasn't processed by readability handlers
                let finalOutputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let finalErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                // Remove handlers to prevent further callbacks
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                await processFinalOutput(
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
            await processOutputLine(trailing)
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

            await processOutputLine(line)
        }
    }

    private func processOutputLine(_ line: String) async {
        guard !cancelled, !errorOccurred else { return }

        if useFileHandler {
            let count = await accumulator.incrementLineCounter()
            handlers.fileHandler(count)
        }

        do {
            try handlers.checkLineForError(line)
        } catch {
            errorOccurred = true
            Logger.process.debugMessageOnly("RsyncProcessStreaming: Error detected in output - \(error.localizedDescription)")

            currentProcess?.terminate()
            handlers.propagateError(error)
        }
    }

    private func handleTermination(task: Process) async {
        let output = await accumulator.snapshot()
        let errors = await accumulator.errorSnapshot()

        // Priority 1: Handle cancellation
        if cancelled {
            Logger.process.debugMessageOnly("RsyncProcessStreaming: Terminated due to cancellation")
            handlers.propagateError(RsyncProcessError.processCancelled)
            handlers.processTermination(output, hiddenID)
            handlers.updateProcess(nil)
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

            handlers.propagateError(error)
        }

        // Always call termination handler
        handlers.processTermination(output, hiddenID)
        handlers.updateProcess(nil)

        cleanupProcess()
    }

    private func cleanupProcess() {
        currentProcess = nil
    }

    deinit {
        if let process = currentProcess, process.isRunning {
            process.terminate()
            Logger.process.debugMessageOnly("RsyncProcessStreaming: Process terminated in deinit")
        }

        Logger.process.debugMessageOnly("RsyncProcessStreaming: DEINIT")
    }
}

// swiftlint:enable line_length
