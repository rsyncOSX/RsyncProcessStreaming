// swiftlint:disable cyclomatic_complexity function_body_length

import Foundation
import OSLog

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
}

public final class RsyncProcess: @unchecked Sendable {
    private let arguments: [String]
    private let hiddenID: Int?
    private let handlers: ProcessHandlers
    private let useFileHandler: Bool
    private let accumulator = StreamAccumulator()

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
        
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            
            let data = handle.availableData
            guard data.count > 0 else { return }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

            Task {
                await self.handleOutputData(text)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            
            let data = handle.availableData
            guard data.count > 0 else { return }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }

            Task {
                await self.accumulator.recordError(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        process.terminationHandler = { [weak self] task in
            guard let self = self else { return }
            
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            Task {
                await self.handleTermination(task: task)
            }
        }

        try process.run()

        if let path = process.executableURL, let arguments = process.arguments {
            Logger.process.debugMessageOnly("RsyncProcessStreaming: COMMAND - \(path)")
            Logger.process.debugMessageOnly("RsyncProcessStreaming: ARGUMENTS - \(arguments.joined(separator: "\n"))")
        }
    }
    
    private func handleOutputData(_ text: String) async {
        let lines = await accumulator.consume(text)
        guard !lines.isEmpty else { return }

        for line in lines {
            if useFileHandler {
                let count = await accumulator.incrementLineCounter()
                await MainActor.run {
                    self.handlers.fileHandler(count)
                }
            }

            do {
                try handlers.checkLineForError(line)
            } catch {
                await MainActor.run {
                    self.handlers.propagateError(error)
                }
            }
        }
    }
    
    private func handleTermination(task: Process) async {
        let output = await accumulator.snapshot()
        let errors = await accumulator.errorSnapshot()

        // Log the command and output if logger is available
        // await handlers.logger?(commandString, output)

        if task.terminationStatus != 0, handlers.checkForErrorInRsyncOutput == true {
            let error = RsyncProcessError.processFailed(
                exitCode: task.terminationStatus,
                errors: errors
            )
            await MainActor.run {
                self.handlers.propagateError(error)
            }
        }

        await MainActor.run {
            self.handlers.processTermination(output, self.hiddenID)
            self.handlers.updateProcess(nil)
        }
    }

    deinit {
        Logger.process.debugMessageOnly("RsyncProcessStreaming: DEINIT")
    }
}

// swiftlint:enable cyclomatic_complexity function_body_length
