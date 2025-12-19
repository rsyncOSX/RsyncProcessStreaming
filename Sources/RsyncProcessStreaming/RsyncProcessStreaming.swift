// swiftlint:disable cyclomatic_complexity function_body_length

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
}

public final class RsyncProcess: @unchecked Sendable {
    private let arguments: [String]
    private let hiddenID: Int?
    private let handlers: ProcessHandlers
    private let useFileHandler: Bool
    private let accumulator = StreamAccumulator()
    private var currentProcess: Process?
    private let processLock = NSLock()
    private var isCancelled = false
    private var hasErrorOccurred = false

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

        // Store process reference before starting
        processLock.lock()
        currentProcess = process
        processLock.unlock()

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
            
            // This ensures we capture all output even if termination happens quickly
            let finalOutputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let finalErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            
            // Now safe to remove handlers
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            Task {
                // Process any final output data that was still in the pipe
                if let text = String(data: finalOutputData, encoding: .utf8), !text.isEmpty {
                    await self.handleOutputData(text)
                }
                
                // Flush any remaining partial line
                _ = await self.accumulator.flushTrailing()
                
                // Process any final error data
                if let errorText = String(data: finalErrorData, encoding: .utf8), !errorText.isEmpty {
                    await self.accumulator.recordError(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                
                await self.handleTermination(task: task)
            }
        }

        try process.run()

        if let path = process.executableURL, let arguments = process.arguments {
            Logger.process.debugMessageOnly("RsyncProcessStreaming: COMMAND - \(path)")
            Logger.process.debugMessageOnly("RsyncProcessStreaming: ARGUMENTS - \(arguments.joined(separator: "\n"))")
        }
    }
    
    /// Cancels the running process
    public func cancel() {
        processLock.lock()
        isCancelled = true
        let process = currentProcess
        processLock.unlock()
        
        process?.terminate()
        
        Logger.process.debugMessageOnly("RsyncProcessStreaming: Process cancelled")
    }
    
    /// Returns whether the process has been cancelled
    public var isCancelledState: Bool {
        processLock.lock()
        defer { processLock.unlock() }
        return isCancelled
    }
    
    private func handleOutputData(_ text: String) async {
        // Check if we've been cancelled or if an error has occurred
        guard !isCancelled, !hasErrorOccurred else { return }
        
        let lines = await accumulator.consume(text)
        guard !lines.isEmpty else { return }

        for line in lines {
            // Check again in loop in case error occurs during processing
            guard !isCancelled, !hasErrorOccurred else { break }
            
            // Handle file counting - do this atomically with the line processing
            if useFileHandler {
                let count = await accumulator.incrementLineCounter()
                await MainActor.run {
                    self.handlers.fileHandler(count)
                }
            }

            // Check line for errors
            do {
                try handlers.checkLineForError(line)
            } catch {
                // Mark that an error has occurred to prevent further processing
                hasErrorOccurred = true
                
                await MainActor.run {
                    self.handlers.propagateError(error)
                }
                
                break
            }
        }
    }
    
    private func handleTermination(task: Process) async {
        let output = await accumulator.snapshot()
        let errors = await accumulator.errorSnapshot()

        // Check if this was a cancellation
        if isCancelled {
            await MainActor.run {
                self.handlers.propagateError(RsyncProcessError.processCancelled)
                self.handlers.processTermination(output, self.hiddenID)
                self.handlers.updateProcess(nil)
            }
            return
        }

        // Check for process failure
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
        
        // Clean up process reference
        processLock.withLock {
            currentProcess = nil
        }
    }

    deinit {
        // Ensure process is terminated if RsyncProcess is deallocated
        processLock.lock()
        let process = currentProcess
        processLock.unlock()
        
        if let process = process, process.isRunning {
            process.terminate()
            Logger.process.debugMessageOnly("RsyncProcessStreaming: Process terminated in deinit")
        }
        
        Logger.process.debugMessageOnly("RsyncProcessStreaming: DEINIT")
    }
}

// swiftlint:enable cyclomatic_complexity function_body_length
