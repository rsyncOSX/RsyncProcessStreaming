//
//  ProcessHandlers.swift
//  RsyncProcessStreaming
//
//
//  ProcessHandlers.swift
//  RsyncProcessStreaming
//
//  Created by Thomas Evensen on 17/12/2025.
//
// swiftlint:disable function_parameter_count
import Foundation

/// Configuration for process lifecycle callbacks and external behaviors.
///
/// `ProcessHandlers` uses dependency injection to provide all external behaviors needed
/// by `RsyncProcess`. This design enables testability by allowing all callbacks to be mocked,
/// and maintains separation of concerns by keeping business logic out of the streaming layer.
///
/// All handlers are injected as closures, making this struct `@unchecked Sendable` safe because
/// the closures capture only Sendable values or are explicitly isolated to appropriate actors.
///
/// Example usage:
/// ```swift
/// let handlers = ProcessHandlers(
///     processTermination: { output, id in
///         print("Process completed with \(output?.count ?? 0) lines")
///     },
///     fileHandler: { lineCount in
///         print("Processed \(lineCount) lines")
///     },
///     rsyncPath: "/usr/bin/rsync",
///     checkLineForError: { line in
///         if line.contains("error") {
///             throw CustomError.rsyncError
///         }
///     },
///     updateProcess: { process in
///         // Store or monitor process
///     },
///     propagateError: { error in
///         print("Error occurred: \(error)")
///     },
///     checkForErrorInRsyncOutput: true,
///     environment: ["LANG": "C"]
/// )
/// ```
public struct ProcessHandlers: @unchecked Sendable {
    /// Callback invoked when the process terminates.
    ///
    /// - Parameters:
    ///   - output: Array of output lines captured from stdout, or nil if no output
    ///   - hiddenID: Optional identifier passed through from `RsyncProcess` initialization
    public let processTermination: ([String]?, Int?) -> Void

    /// Callback invoked for each completed output line when file handler mode is enabled.
    ///
    /// - Parameter lineCount: The cumulative count of lines processed
    public let fileHandler: (Int) -> Void

    /// Path to the rsync executable. Defaults to "/usr/bin/rsync" if nil.
    public let rsyncPath: String?

    /// Callback to check each output line for application-specific errors.
    ///
    /// This handler is called for every complete line of stdout. Throwing an error
    /// will terminate the process and propagate the error via `propagateError`.
    ///
    /// - Parameter line: A single line of output from stdout
    /// - Throws: Any error to signal detection of an error condition
    public let checkLineForError: (String) throws -> Void

    /// Callback to receive updates about the current Process instance.
    ///
    /// Called with the Process when execution starts, and with nil when the process terminates.
    ///
    /// - Parameter process: The running Process, or nil when terminated
    public let updateProcess: (Process?) -> Void

    /// Callback to propagate errors to the application layer.
    ///
    /// Invoked when errors occur during execution, including:
    /// - Errors thrown by `checkLineForError`
    /// - Process failures (non-zero exit codes)
    /// - Cancellation
    ///
    /// - Parameter error: The error that occurred
    public let propagateError: (Error) -> Void

    /// Whether to check for non-zero exit codes and treat them as errors.
    ///
    /// When true, a non-zero exit code will cause `RsyncProcessError.processFailed`
    /// to be propagated via `propagateError`.
    public let checkForErrorInRsyncOutput: Bool

    /// Environment variables to set for the rsync process.
    ///
    /// If nil, the process inherits the parent environment.
    public let environment: [String: String]?

    /// Creates a new ProcessHandlers configuration.
    ///
    /// - Parameters:
    ///   - processTermination: Handler for process completion. Receives output lines and optional ID.
    ///   - fileHandler: Handler called for each line when file handler mode is enabled.
    ///   - rsyncPath: Path to rsync executable. Defaults to "/usr/bin/rsync" if nil.
    ///   - checkLineForError: Handler to validate each output line. Throw to signal errors.
    ///   - updateProcess: Handler to receive the Process instance or nil on termination.
    ///   - propagateError: Handler to receive all errors during execution.
    ///   - checkForErrorInRsyncOutput: Whether to treat non-zero exit codes as errors.
    ///   - environment: Environment variables for the process. Inherits parent environment if nil.
    public init(
        processTermination: @escaping ([String]?, Int?) -> Void,
        fileHandler: @escaping (Int) -> Void,
        rsyncPath: String?,
        checkLineForError: @escaping (String) throws -> Void,
        updateProcess: @escaping (Process?) -> Void,
        propagateError: @escaping (Error) -> Void,
        checkForErrorInRsyncOutput: Bool,
        environment: [String: String]? = nil
    ) {
        self.processTermination = processTermination
        self.fileHandler = fileHandler
        self.rsyncPath = rsyncPath
        self.checkLineForError = checkLineForError
        self.updateProcess = updateProcess
        self.propagateError = propagateError
        self.checkForErrorInRsyncOutput = checkForErrorInRsyncOutput
        self.environment = environment
    }
}

// swiftlint:enable function_parameter_count
