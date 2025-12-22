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

public struct ProcessHandlers: @unchecked Sendable {
    public let processTermination: @Sendable ([String]?, Int?) -> Void
    public let fileHandler: @Sendable (Int) -> Void
    public let rsyncPath: String?
    public let checkLineForError: @Sendable (String) throws -> Void
    public let updateProcess: @Sendable (Process?) -> Void
    public let propagateError: @Sendable (Error) -> Void
    public let logger: (@Sendable (String, [String]) async -> Void)?
    public let checkForErrorInRsyncOutput: Bool
    public let rsyncVersion3: Bool
    public let environment: [String: String]?

    public init(
        processTermination: @escaping @Sendable ([String]?, Int?) -> Void,
        fileHandler: @escaping @Sendable (Int) -> Void,
        rsyncPath: String?,
        checkLineForError: @escaping @Sendable (String) throws -> Void,
        updateProcess: @escaping @Sendable (Process?) -> Void,
        propagateError: @escaping @Sendable (Error) -> Void,
        logger: (@Sendable (String, [String]) async -> Void)? = nil,
        checkForErrorInRsyncOutput: Bool,
        rsyncVersion3: Bool,
        environment: [String: String]? = nil
    ) {
        self.processTermination = processTermination
        self.fileHandler = fileHandler
        self.rsyncPath = rsyncPath
        self.checkLineForError = checkLineForError
        self.updateProcess = updateProcess
        self.propagateError = propagateError
        self.logger = logger
        self.checkForErrorInRsyncOutput = checkForErrorInRsyncOutput
        self.rsyncVersion3 = rsyncVersion3
        self.environment = environment
    }
}

public extension ProcessHandlers {
    /// Create ProcessHandlers with automatic output capture enabled
    static func withOutputCapture(
        processTermination: @escaping @Sendable ([String]?, Int?) -> Void,
        fileHandler: @escaping @Sendable (Int) -> Void,
        rsyncPath: String?,
        checkLineForError: @escaping @Sendable (String) throws -> Void,
        updateProcess: @escaping @Sendable (Process?) -> Void,
        propagateError: @escaping @Sendable (Error) -> Void,
        logger: (@Sendable (String, [String]) async -> Void)? = nil,
        checkForErrorInRsyncOutput: Bool,
        rsyncVersion3: Bool,
        environment: [String: String]? = nil
    ) -> ProcessHandlers {
        ProcessHandlers(
            processTermination: processTermination,
            fileHandler: fileHandler,
            rsyncPath: rsyncPath,
            checkLineForError: checkLineForError,
            updateProcess: updateProcess,
            propagateError: propagateError,
            logger: logger,
            checkForErrorInRsyncOutput: checkForErrorInRsyncOutput,
            rsyncVersion3: rsyncVersion3,
            environment: environment
        )
    }
}

// swiftlint:enable function_parameter_count
