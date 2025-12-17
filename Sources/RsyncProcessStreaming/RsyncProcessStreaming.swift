import Foundation

public struct ProcessHandlers {
    public let processTermination: ([String]?, Int?) -> Void
    public let fileHandler: (Int) -> Void
    public let rsyncPath: String?
    public let checkLineForError: (String) throws -> Void
    public let updateProcess: (Process?) -> Void
    public let propagateError: (Error) -> Void
    public let logger: (@Sendable (String, [String]) async -> Void)?
    public let checkForErrorInRsyncOutput: Bool
    public let rsyncVersion3: Bool
    public let environment: [String: String]?
    public let printLine: ((String) -> Void)?

    public init(
        processTermination: @escaping ([String]?, Int?) -> Void,
        fileHandler: @escaping (Int) -> Void,
        rsyncPath: String?,
        checkLineForError: @escaping (String) throws -> Void,
        updateProcess: @escaping (Process?) -> Void,
        propagateError: @escaping (Error) -> Void,
        logger: (@Sendable (String, [String]) async -> Void)? = nil,
        checkForErrorInRsyncOutput: Bool,
        rsyncVersion3: Bool,
        environment: [String: String]? = nil,
        printLine: ((String) -> Void)? = nil
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
        self.printLine = printLine
    }
}

public enum RsyncProcessError: Error, LocalizedError {
    case executableNotFound(String)
    case processFailed(exitCode: Int32, errors: [String])

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "Rsync executable not found at path: \(path)"
        case let .processFailed(code, errors):
            let message = errors.joined(separator: "\n")
            return "rsync exited with code \(code).\n\(message)"
        }
    }
}

actor StreamAccumulator {
    private var lines: [String] = []
    private var partialLine: String = ""
    private var errorLines: [String] = []

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
}

public final class RsyncProcess {
    private let arguments: [String]
    private let hiddenID: Int?
    private let handlers: ProcessHandlers
    private let useFileHandler: Bool
    private var lineCounter: Int = 0

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

    public convenience init(
        arguments: [String],
        hiddenID: Int? = nil,
        handlers: ProcessHandlers,
        fileHandler: Bool
    ) {
        self.init(arguments: arguments, hiddenID: hiddenID, handlers: handlers, useFileHandler: fileHandler)
    }

    public func executeProcess() throws {
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

        handlers.updateProcess(process)

        let accumulator = StreamAccumulator()
        let commandString = ([executablePath] + arguments).joined(separator: " ")

        let deliverLine: (String) -> Void = { line in
            Task { @MainActor in
                self.handlers.printLine?(line)
            }
        }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.count > 0 else { return }
            guard let text = String(data: data, encoding: .utf8), text.isEmpty == false else { return }

            Task.detached { [useFileHandler = self.useFileHandler] in
                let lines = await accumulator.consume(text)
                guard lines.isEmpty == false else { return }

                for line in lines {
                    if useFileHandler {
                        self.lineCounter += 1
                        Task { @MainActor in
                            self.handlers.fileHandler(self.lineCounter)
                        }
                    }

                    do {
                        try self.handlers.checkLineForError(line)
                    } catch {
                        Task { @MainActor in
                            self.handlers.propagateError(error)
                        }
                    }

                    deliverLine(line)
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.count > 0 else { return }
            guard let text = String(data: data, encoding: .utf8), text.isEmpty == false else { return }

            Task.detached {
                await accumulator.recordError(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        process.terminationHandler = { [weak self] task in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            Task.detached {
                if let trailing = await accumulator.flushTrailing() {
                    deliverLine(trailing)
                }

                let output = await accumulator.snapshot()
                let errors = await accumulator.errorSnapshot()

                await self?.handlers.logger?(commandString, output)

                if task.terminationStatus != 0, self?.handlers.checkForErrorInRsyncOutput == true {
                    self?.handlers.propagateError(RsyncProcessError.processFailed(exitCode: task.terminationStatus, errors: errors))
                }

                Task { @MainActor in
                    self?.handlers.processTermination(output, self?.hiddenID)
                    self?.handlers.updateProcess(nil)
                }
            }
        }

        try process.run()
    }
}
