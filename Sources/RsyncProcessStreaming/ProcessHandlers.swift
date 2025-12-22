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

public struct ProcessHandlers {
    public let processTermination: ([String]?, Int?) -> Void
    public let fileHandler:  (Int) -> Void
    public let rsyncPath: String?
    public let checkLineForError:  (String) throws -> Void
    public let updateProcess: (Process?) -> Void
    public let propagateError:  (Error) -> Void
    public let logger: (String, [String]) async -> Void?
    public let checkForErrorInRsyncOutput: Bool
    public let rsyncVersion3: Bool
    public let environment: [String: String]?

    public init(
        processTermination: @escaping  ([String]?, Int?) -> Void,
        fileHandler: @escaping (Int) -> Void,
        rsyncPath: String?,
        checkLineForError: @escaping (String) throws -> Void,
        updateProcess: @escaping (Process?) -> Void,
        propagateError: @escaping (Error) -> Void,
        logger: @escaping (String, [String]) async -> Void?,
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
        processTermination: @escaping ([String]?, Int?) -> Void,
        fileHandler: @escaping (Int) -> Void,
        rsyncPath: String?,
        checkLineForError: @escaping (String) throws -> Void,
        updateProcess: @escaping (Process?) -> Void,
        propagateError: @escaping (Error) -> Void,
        logger: @escaping (String, [String]) async -> Void? ,
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
