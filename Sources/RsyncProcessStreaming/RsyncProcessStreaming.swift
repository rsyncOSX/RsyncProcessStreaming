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

    /// The process timed out.
    case timeout(TimeInterval)

    /// The process is in an invalid state for the requested operation.
    case invalidState(ProcessState)

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "Rsync executable not found at path: \(path)"
        case let .processFailed(code, errors):
            let message = errors.joined(separator: "\n")
            return "rsync exited with code \(code).\n\(message)"
        case .processCancelled:
            return "Process was cancelled"
        case let .timeout(interval):
            return "Process timed out after \(interval) seconds"
        case let .invalidState(state):
            return "Process is in invalid state: \(state)"
        }
    }
}

/// Process state for lifecycle management.
public enum ProcessState: CustomStringConvertible, Sendable {
    case idle
    case running
    case cancelling
    case terminating
    case terminated(exitCode: Int32)
    case failed(Error)

    public var description: String {
        switch self {
        case .idle: "idle"
        case .running: "running"
        case .cancelling: "cancelling"
        case .terminating: "terminating"
        case let .terminated(code): "terminated(\(code))"
        case let .failed(error): "failed(\(error.localizedDescription))"
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
    private let lineSeparator = "\n"
    private let carriageReturn = "\r"

    /// Consumes text data and returns any complete lines.
    ///
    /// Partial lines (text without a trailing newline) are buffered internally
    /// and combined with the next chunk of data. Empty lines are filtered out.
    ///
    /// - Parameter text: Raw text data from stdout
    /// - Returns: Array of complete, non-empty lines extracted from the text
    func consume(_ text: String) -> [String] {
        var lines: [String] = []
        var buffer = partialLine

        for char in text {
            if char == "\n" {
                // Handle \r\n or just \n
                if buffer.hasSuffix("\r") {
                    buffer.removeLast()
                }
                if !buffer.isEmpty {
                    lines.append(buffer)
                }
                buffer = ""
            } else {
                buffer.append(char)
            }
        }

        partialLine = buffer
        self.lines.append(contentsOf: lines)
        return lines
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
        errorLines.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
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
/// cancellation support, timeout handling, and comprehensive error handling.
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
///     handlers: handlers,
///     timeout: 60 // Optional timeout in seconds
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
    private let timeoutInterval: TimeInterval?
    private var accumulator = StreamAccumulator()

    // MainActor-isolated state
    private var currentProcess: Process?
    private var timeoutTimer: Timer?
    private var state: ProcessState = .idle
    private var cancelled = false
    private var errorOccurred = false

    /// Creates a new RsyncProcess instance.
    ///
    /// - Parameters:
    ///   - arguments: Command-line arguments to pass to rsync
    ///   - hiddenID: Optional identifier passed through to termination handler
    ///   - handlers: Configuration for all process callbacks and behaviors
    ///   - useFileHandler: Whether to invoke fileHandler callback for each line (default: false)
    ///   - timeout: Optional timeout interval in seconds after which the process will be terminated
    public init(
        arguments: [String],
        hiddenID: Int? = nil,
        handlers: ProcessHandlers,
        useFileHandler: Bool = false,
        timeout: TimeInterval? = nil
    ) {
        // Validate arguments
        precondition(!arguments.isEmpty, "Arguments cannot be empty")
        if let rsyncPath = handlers.rsyncPath {
            precondition(!rsyncPath.isEmpty, "Rsync path cannot be empty if provided")
        }

        self.arguments = arguments
        self.hiddenID = hiddenID
        self.handlers = handlers
        self.useFileHandler = useFileHandler
        timeoutInterval = timeout

        Logger.process.debugMessageOnly("RsyncProcess initialized with \(arguments.count) arguments")
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
    ///           `RsyncProcessError.invalidState` if process is not idle
    /// - Note: This method is MainActor-isolated for safe UI integration
    /// - Important: Call `cancel()` to terminate a running process before deallocation
    public func executeProcess() throws {
        guard case .idle = state else {
            throw RsyncProcessError.invalidState(state)
        }

        // Reset state for reuse
        cancelled = false
        errorOccurred = false
        state = .running
        accumulator = StreamAccumulator()

        let executablePath = handlers.rsyncPath ?? "/usr/bin/rsync"
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            state = .failed(RsyncProcessError.executableNotFound(executablePath))
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

        // Start timeout timer if configured
        startTimeoutTimer()

        try process.run()
        logProcessStart(process)
    }

    /// Cancels the running process.
    ///
    /// Terminates the process immediately and triggers the termination handler
    /// with a `RsyncProcessError.processCancelled` error. Safe to call multiple
    /// times or when no process is running.
    public func cancel() {
        guard !cancelled else { return }

        cancelled = true
        state = .cancelling

        // Invalidate timeout timer on MainActor
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        // Terminate process - don't modify handlers/pipes as process is already running
        if let process = currentProcess {
            process.terminate()
        }

        Logger.process.debugMessageOnly("RsyncProcess: Process cancelled")

        // Immediately propagate cancellation error
        handlers.propagateError(RsyncProcessError.processCancelled)
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

    /// Returns the current process state.
    public var currentState: ProcessState {
        state
    }

    /// Returns the process identifier if the process is running.
    public var processIdentifier: Int32? {
        currentProcess?.processIdentifier
    }

    /// Returns the termination status if the process has terminated.
    public var terminationStatus: Int32? {
        currentProcess?.terminationStatus
    }

    /// Returns a description of the command being executed.
    public var commandDescription: String {
        let executable = handlers.rsyncPath ?? "/usr/bin/rsync"
        let args = arguments.joined(separator: " ")
        return "\(executable) \(args)"
    }

    // MARK: - Private Setup Methods

    private func setupPipeHandlers(outputPipe: Pipe, errorPipe: Pipe) {
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Capture self strongly for the async task to prevent premature deallocation
            Task { @MainActor in
                guard let self, !self.cancelled, !self.errorOccurred else { return }

                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    await self.handleOutputData(text)
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            Task { @MainActor in
                guard let self else { return }

                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    await self.accumulator.recordError(text)
                }
            }
        }
    }

    private func setupTerminationHandler(process: Process, outputPipe: Pipe, errorPipe: Pipe) {
        // Use a serial queue to ensure proper ordering of termination events
        let terminationQueue = DispatchQueue(label: "com.rsync.process.termination", qos: .userInitiated)

        process.terminationHandler = { [weak self] task in
            terminationQueue.async {
                // Ensure readability handlers are stopped first
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                // Read remaining data synchronously
                let finalOutputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let finalErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                Task { @MainActor in
                    guard let self else { return }
                    await self.processFinalOutput(
                        finalOutputData: finalOutputData,
                        finalErrorData: finalErrorData,
                        task: task
                    )
                }
            }
        }
    }

    private func startTimeoutTimer() {
        guard let timeout = timeoutInterval, timeout > 0 else { return }

        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleTimeout()
            }
        }
    }

    private func handleTimeout() {
        guard !cancelled, !errorOccurred, case .running = state else { return }

        Logger.process.debugMessageOnly("RsyncProcess: Process timed out after \(timeoutInterval ?? 0) seconds")

        let timeoutError = RsyncProcessError.timeout(timeoutInterval ?? 0)
        state = .failed(timeoutError)

        // Cancel the process
        cancelled = true
        currentProcess?.terminate()

        // Propagate timeout error
        handlers.propagateError(timeoutError)
    }

    private func logProcessStart(_ process: Process) {
        guard let path = process.executableURL, let arguments = process.arguments else { return }
        Logger.process.debugThreadOnly("RsyncProcess: COMMAND - \(path)")
        Logger.process.debugMessageOnly("RsyncProcess: ARGUMENTS - \(arguments.joined(separator: "\n"))")

        if let timeout = timeoutInterval {
            Logger.process.debugMessageOnly("RsyncProcess: Timeout set to \(timeout) seconds")
        }
    }

    // MARK: - Private Processing Methods

    private func processFinalOutput(
        finalOutputData: Data,
        finalErrorData: Data,
        task: Process
    ) async {
        // Invalidate timeout timer on MainActor
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        // Process any final output data that was still in the pipe
        if let text = String(data: finalOutputData, encoding: .utf8), !text.isEmpty {
            await handleOutputData(text)
        }

        // Flush any remaining partial line
        if let trailing = await accumulator.flushTrailing() {
            Logger.process.debugMessageOnly("RsyncProcess: Flushed trailing output: \(trailing)")
            await processOutputLine(trailing)
        }

        // Process any final error data
        if let errorText = String(data: finalErrorData, encoding: .utf8), !errorText.isEmpty {
            await accumulator.recordError(errorText)
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
            state = .failed(error)
            Logger.process.debugMessageOnly("RsyncProcess: Error detected in output - \(error.localizedDescription)")

            currentProcess?.terminate()
            handlers.propagateError(error)
        }
    }

    private func handleTermination(task: Process) async {
        let output = await accumulator.snapshot()
        let errors = await accumulator.errorSnapshot()

        defer {
            cleanupProcess()
        }

        // Priority 1: Handle cancellation
        if cancelled {
            Logger.process.debugMessageOnly("RsyncProcess: Terminated due to cancellation")
            state = .terminated(exitCode: task.terminationStatus)
            handlers.processTermination(output, hiddenID)
            handlers.updateProcess(nil)
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
            state = .failed(error)
            Logger.process.debugMessageOnly(
                "RsyncProcess: Process failed with exit code \(task.terminationStatus)"
            )

            handlers.propagateError(error)
        } else {
            state = .terminated(exitCode: task.terminationStatus)
        }

        // Always call termination handler
        handlers.processTermination(output, hiddenID)
        handlers.updateProcess(nil)
    }

    private func cleanupProcess() {
        // Invalidate timer on MainActor
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        currentProcess = nil

        // Reset state to idle to allow re-execution
        state = .idle
    }

    nonisolated deinit {
        // Note: Best practice is to not start async work in deinit
        // Process cleanup should be handled via explicit cancel() or completion
        Logger.process.debugMessageOnly("RsyncProcess: DEINIT")
    }
}
