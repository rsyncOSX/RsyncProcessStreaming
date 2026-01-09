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

/// MainActor-isolated process manager for executing rsync with real-time output streaming.
///
/// Example usage:
/// ```swift
/// let handlers = ProcessHandlers(processTermination: { output, _ in
///     print("Completed with \(output?.count ?? 0) lines")
/// }, fileHandler: { _ in }, rsyncPath: nil, checkLineForError: { _ in },
/// updateProcess: { _ in }, propagateError: { print($0) }, checkForErrorInRsyncOutput: true)
///
/// let process = RsyncProcess(arguments: ["-av", "source/", "dest/"], handlers: handlers)
/// try process.executeProcess()
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

        Logger.process.debugMessage("RsyncProcessStreaming initialized with \(arguments.count) arguments")
    }

    /// Executes the rsync process with configured arguments and streams output.
    ///
    /// - Throws: `RsyncProcessError.executableNotFound` or `RsyncProcessError.invalidState`
    public func executeProcess() throws {
        guard case .idle = state else {
            throw RsyncProcessError.invalidState(state)
        }

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
        startTimeoutTimer()

        try process.run()
        logProcessStart(process)
    }

    /// Cancels the running process.
    public func cancel() {
        guard !cancelled else { return }

        cancelled = true
        state = .cancelling

        timeoutTimer?.invalidate()
        timeoutTimer = nil

        if let process = currentProcess {
            process.terminate()
        }

        Logger.process.debugMessage("RsyncProcessStreaming:  Process cancelled")
        handlers.propagateError(RsyncProcessError.processCancelled)
    }

    /// Whether the process has been cancelled.
    public var isCancelledState: Bool { cancelled }

    /// Whether the process is currently running.
    public var isRunning: Bool { currentProcess?.isRunning ?? false }

    /// The current process state.
    public var currentState: ProcessState { state }

    /// The process identifier if running.
    public var processIdentifier: Int32? { currentProcess?.processIdentifier }

    /// The termination status if terminated.
    public var terminationStatus: Int32? { currentProcess?.terminationStatus }

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
        let queue = DispatchQueue(label: "com.rsync.process.termination", qos: .userInitiated)

        process.terminationHandler = { [weak self] task in
            queue.async {
                Thread.sleep(forTimeInterval: 0.05)

                let outputData = Self.drainPipe(outputPipe.fileHandleForReading)
                let errorData = Self.drainPipe(errorPipe.fileHandleForReading)

                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil

                Task { @MainActor in
                    guard let self else { return }
                    await self.processFinalOutput(
                        finalOutputData: outputData,
                        finalErrorData: errorData,
                        task: task
                    )
                }
            }
        }
    }

    private nonisolated static func drainPipe(_ fileHandle: FileHandle) -> Data {
        var allData = Data()
        while true {
            let data = fileHandle.availableData
            if data.isEmpty { break }
            allData.append(data)
        }
        return allData
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

        let timeout = timeoutInterval ?? 0
        Logger.process.debugMessage("RsyncProcessStreaming:  Timeout after \(timeout)s")

        let timeoutError = RsyncProcessError.timeout(timeout)
        state = .failed(timeoutError)
        cancelled = true
        currentProcess?.terminate()
        handlers.propagateError(timeoutError)
    }

    private func logProcessStart(_ process: Process) {
        guard let path = process.executableURL, let arguments = process.arguments else { return }
        Logger.process.debugWithThreadInfo("RsyncProcessStreaming:  COMMAND - \(path)")
        Logger.process.debugMessage("RsyncProcessStreaming:  ARGUMENTS - \(arguments.joined(separator: "\n"))")

        if let timeout = timeoutInterval {
            Logger.process.debugMessage("RsyncProcessStreaming:  Timeout set to \(timeout) seconds")
        }
    }

    // MARK: - Private Processing Methods

    private func processFinalOutput(
        finalOutputData: Data,
        finalErrorData: Data,
        task: Process
    ) async {
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        if let text = String(data: finalOutputData, encoding: .utf8), !text.isEmpty {
            await handleOutputData(text)
        }

        if let trailing = await accumulator.flushTrailing() {
            Logger.process.debugMessage("RsyncProcessStreaming:  Flushed trailing: \(trailing)")
            await processOutputLine(trailing)
        }

        if let errorText = String(data: finalErrorData, encoding: .utf8), !errorText.isEmpty {
            await accumulator.recordError(errorText)
        }

        await handleTermination(task: task)
    }

    private func handleOutputData(_ text: String) async {
        guard !cancelled, !errorOccurred else { return }

        let lines = await accumulator.consume(text)
        guard !lines.isEmpty else { return }

        for line in lines {
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
            let msg = error.localizedDescription
            Logger.process.debugMessage("RsyncProcessStreaming:  Output error - \(msg)")
            currentProcess?.terminate()
            handlers.propagateError(error)
        }
    }

    private func handleTermination(task: Process) async {
        let output = await accumulator.snapshot()
        let errors = await accumulator.errorSnapshot()

        defer { cleanupProcess() }

        if cancelled {
            Logger.process.debugMessage("RsyncProcessStreaming:  Terminated due to cancellation")
            state = .terminated(exitCode: task.terminationStatus)
            handlers.processTermination(output, hiddenID)
            handlers.updateProcess(nil)
            return
        }

        // Priority 3: Handle process failure based on exit code
        if task.terminationStatus != 0, handlers.checkForErrorInRsyncOutput, !errorOccurred {
            let error = RsyncProcessError.processFailed(
                exitCode: task.terminationStatus,
                errors: errors
            )
            state = .failed(error)
            Logger.process.debugMessage(
                "RsyncProcessStreaming:  Process failed with exit code \(task.terminationStatus)"
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
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        currentProcess = nil
        state = .idle
    }

    nonisolated deinit {
        Logger.process.debugMessage("RsyncProcessStreaming:  DEINIT")
    }
}
