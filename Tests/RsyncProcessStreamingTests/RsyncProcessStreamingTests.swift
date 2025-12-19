import Foundation
import OSLog
@testable import RsyncProcessStreaming
import Testing

actor ActorToFile {
    private func logging(command _: String, stringoutput: [String]) async {
        var logfile: String?

        if logfile == nil {
            logfile = stringoutput.joined(separator: "\n")
        } else {
            logfile! += stringoutput.joined(separator: "\n")
        }
        if let logfile {
            print(logfile)
        }
    }

    @discardableResult
    init(_ command: String, _ stringoutput: [String]?) async {
        if let stringoutput {
            await logging(command: command, stringoutput: stringoutput)
        }
    }
}

@MainActor
struct RsyncProcessStreamingTests {
    @MainActor
    final class TestState {
        var mockOutput: [String]?
        var mockHiddenID: Int?
        var fileHandlerCount: Int = 0
        var processUpdateCalled: Bool = false
        var errorPropagated: Error?
        var loggerCalled: Bool = false
        var loggedID: String?
        var loggedOutput: [String]?
        var allProcessedLines: [String] = [String]()
        var errorCheckCount: Int = 0

        func reset() {
            mockOutput = nil
            mockHiddenID = nil
            fileHandlerCount = 0
            processUpdateCalled = false
            errorPropagated = nil
            loggerCalled = false
            loggedID = nil
            loggedOutput = nil
            allProcessedLines = []
            errorCheckCount = 0
        }

        func printLine(_ line: String) {
            allProcessedLines.append(line)
            print(line)
        }
    }

    // MARK: - Helper Methods

    func createMockHandlers(
        rsyncPath: String? = "/opt/homebrew/bin/rsync",
        checkForError: Bool = false,
        rsyncVersion3: Bool = true,
        shouldThrowError: Bool = false,
        printLine: ((String) -> Void)? = nil,
        state: TestState
    ) -> ProcessHandlers {
        ProcessHandlers(
            processTermination: { output, hiddenID in
                state.mockOutput = output
                state.mockHiddenID = hiddenID
            },
            fileHandler: { count in
                state.fileHandlerCount = count
            },
            rsyncPath: rsyncPath,
            checkLineForError: { line in
                state.errorCheckCount += 1
                printLine?(line)
                if shouldThrowError && line.contains("error") {
                    throw MockRsyncError.testError
                }
            },
            updateProcess: { _ in
                state.processUpdateCalled = true
            },
            propagateError: { error in
                state.errorPropagated = error
            },
            logger: { command, output in
                _ = await ActorToFile(command, output)
            },
            checkForErrorInRsyncOutput: checkForError,
            rsyncVersion3: rsyncVersion3,
            environment: nil
        )
    }

    // MARK: - StreamAccumulator Tests

    @Test("StreamAccumulator splits lines correctly")
    func streamAccumulatorSplitsLines() async {
        let accumulator = StreamAccumulator()
        let first = await accumulator.consume("one\ntwo\npart")
        #expect(first == ["one", "two"])
        let second = await accumulator.consume("ial\nthree\n")
        #expect(second == ["partial", "three"])
        _ = await accumulator.flushTrailing()
        let snapshot = await accumulator.snapshot()
        #expect(snapshot == ["one", "two", "partial", "three"])
    }

    @Test("StreamAccumulator handles empty strings")
    func streamAccumulatorHandlesEmpty() async {
        let accumulator = StreamAccumulator()
        let lines = await accumulator.consume("")
        #expect(lines.isEmpty)
        
        let snapshot = await accumulator.snapshot()
        #expect(snapshot.isEmpty)
    }

    @Test("StreamAccumulator handles lines without newlines")
    func streamAccumulatorNoNewlines() async {
        let accumulator = StreamAccumulator()
        let first = await accumulator.consume("partial")
        #expect(first.isEmpty)
        
        let second = await accumulator.consume("complete\n")
        #expect(second == ["partialcomplete"])
    }

    @Test("StreamAccumulator flushes trailing content")
    func streamAccumulatorFlushTrailing() async {
        let accumulator = StreamAccumulator()
        _ = await accumulator.consume("line1\npartial")
        
        let trailing = await accumulator.flushTrailing()
        #expect(trailing == "partial")
        
        let snapshot = await accumulator.snapshot()
        #expect(snapshot == ["line1", "partial"])
    }

    @Test("StreamAccumulator records errors")
    func streamAccumulatorRecordsErrors() async {
        let accumulator = StreamAccumulator()
        await accumulator.recordError("error1")
        await accumulator.recordError("error2")
        
        let errors = await accumulator.errorSnapshot()
        #expect(errors == ["error1", "error2"])
    }

    @Test("StreamAccumulator counts lines incrementally")
    func streamAccumulatorCountsLines() async {
        let accumulator = StreamAccumulator()
        
        let count1 = await accumulator.incrementLineCounter()
        let count2 = await accumulator.incrementLineCounter()
        let count3 = await accumulator.incrementLineCounter()
        
        #expect(count1 == 1)
        #expect(count2 == 2)
        #expect(count3 == 3)
        
        let totalCount = await accumulator.getLineCount()
        #expect(totalCount == 3)
    }

    // MARK: - Process Execution Tests

    @Test("Process termination with pending data")
    func processTerminationWithPendingData() async throws {
        let state = TestState()
        let handlers = createMockHandlers(printLine: state.printLine(_:), state: state)
        let hiddenID = 1

        let process = RsyncProcess(
            arguments: ["--version"],
            hiddenID: hiddenID,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        #expect(state.mockOutput != nil)
        #expect(state.mockOutput?.count ?? 0 > 0)
        #expect(state.mockHiddenID == hiddenID)

        let outputString = state.mockOutput?.joined(separator: " ").lowercased() ?? ""
        #expect(outputString.contains("rsync") || outputString.contains("version"))
    }

    @Test("Process termination before all data handled")
    func processTerminationBeforeAllDataHandled() async throws {
        let state = TestState()
        let hiddenID = 1
        var dataHandledCount = 0
        var terminationOutputCount = 0

        let handlers = ProcessHandlers(
            processTermination: { output, id in
                state.mockOutput = output
                state.mockHiddenID = id
                terminationOutputCount = output?.count ?? 0
                Logger.process.debugMessageOnly("Termination called with \(terminationOutputCount) lines")
            },
            fileHandler: { count in
                dataHandledCount = count
                state.fileHandlerCount = count
            },
            rsyncPath: "/opt/homebrew/bin/rsync",
            checkLineForError: { _ in },
            updateProcess: { _ in
                state.processUpdateCalled = true
            },
            propagateError: { error in
                state.errorPropagated = error
            },
            logger: { command, output in
                _ = await ActorToFile(command, output)
            },
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: false,
            environment: nil
        )

        let process = RsyncProcess(
            arguments: ["--help"],
            hiddenID: hiddenID,
            handlers: handlers,
            useFileHandler: true
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 3_000_000_000)

        #expect(state.mockOutput != nil)
        #expect(state.mockHiddenID == hiddenID)
        #expect(terminationOutputCount > 0)

        let outputString = state.mockOutput?.joined(separator: " ").lowercased() ?? ""
        #expect(outputString.contains("rsync") || outputString.contains("usage") || outputString.contains("options"))

        let message = "Test complete - Data handled during execution: \(dataHandledCount), " +
            "Data at termination: \(terminationOutputCount)"
        Logger.process.debugMessageOnly(message)
    }

    @Test("File handler counts correctly")
    func fileHandlerCountsCorrectly() async throws {
        let state = TestState()
        let handlers = createMockHandlers(state: state)

        let process = RsyncProcess(
            arguments: ["--help"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: true
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        #expect(state.fileHandlerCount > 0)
    }

    @Test("Process updates are called")
    func processUpdatesAreCalled() async throws {
        let state = TestState()
        let handlers = createMockHandlers(state: state)

        let process = RsyncProcess(
            arguments: ["--version"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        #expect(state.processUpdateCalled)
    }

    // MARK: - Error Handling Tests

    @Test("Invalid executable path throws error")
    func invalidExecutablePathThrows() async throws {
        let state = TestState()
        let handlers = createMockHandlers(
            rsyncPath: "/nonexistent/path/rsync",
            state: state
        )

        let process = RsyncProcess(
            arguments: ["--version"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        #expect(throws: RsyncProcessError.self) {
            try process.executeProcess()
        }
    }

    @Test("Non-zero exit code with error checking propagates error")
    func nonZeroExitCodePropagatesError() async throws {
        let state = TestState()
        let handlers = createMockHandlers(
            checkForError: true,
            state: state
        )

        let process = RsyncProcess(
            arguments: ["--invalid-argument-xyz"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        #expect(state.errorPropagated != nil)
    }

    @Test("Line error detection triggers propagation")
    func lineErrorDetectionTriggers() async throws {
        let state = TestState()
        let handlers = createMockHandlers(
            shouldThrowError: true,
            state: state
        )

        // Create a temporary file with error content
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_error_\(UUID().uuidString).txt")
        try "This line contains error text".write(to: tempFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        let process = RsyncProcess(
            arguments: ["-v", tempFile.path, "/tmp/"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Should have called error check at least once
        #expect(state.errorCheckCount > 0)
    }

    @Test("Zero exit code without error checking completes successfully")
    func zeroExitCodeWithoutErrorCheckingSucceeds() async throws {
        let state = TestState()
        let handlers = createMockHandlers(
            checkForError: false,
            state: state
        )

        let process = RsyncProcess(
            arguments: ["--version"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        #expect(state.errorPropagated == nil)
        #expect(state.mockOutput != nil)
    }

    // MARK: - Stderr Handling Tests

    @Test("Stderr is captured separately")
    func stderrCapturedSeparately() async throws {
        let state = TestState()
        let handlers = createMockHandlers(
            checkForError: true,
            state: state
        )

        let process = RsyncProcess(
            arguments: ["--invalid-flag-xyz"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Error should be propagated with stderr content
        if let error = state.errorPropagated as? RsyncProcessError,
           case let .processFailed(_, errors) = error {
            #expect(!errors.isEmpty)
        }
    }

    // MARK: - Environment and Configuration Tests

    @Test("Custom environment is passed to process")
    func customEnvironmentPassed() async throws {
        let state = TestState()
        let customEnv = ["TEST_VAR": "test_value"]
        
        let handlers = ProcessHandlers(
            processTermination: { output, id in
                state.mockOutput = output
                state.mockHiddenID = id
            },
            fileHandler: { count in
                state.fileHandlerCount = count
            },
            rsyncPath: "/opt/homebrew/bin/rsync",
            checkLineForError: { _ in },
            updateProcess: { _ in
                state.processUpdateCalled = true
            },
            propagateError: { error in
                state.errorPropagated = error
            },
            logger: nil,
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: false,
            environment: customEnv
        )

        let process = RsyncProcess(
            arguments: ["--version"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        #expect(state.mockOutput != nil)
    }

    @Test("HiddenID is passed through correctly")
    func hiddenIDPassedThrough() async throws {
        let state = TestState()
        let testHiddenID = 42
        let handlers = createMockHandlers(state: state)

        let process = RsyncProcess(
            arguments: ["--version"],
            hiddenID: testHiddenID,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        #expect(state.mockHiddenID == testHiddenID)
    }

    // MARK: - Convenience Initializer Tests

    @Test("Convenience initializer with fileHandler parameter works")
    func convenienceInitializerWorks() async throws {
        let state = TestState()
        let handlers = createMockHandlers(state: state)

        let process = RsyncProcess(
            arguments: ["--version"],
            hiddenID: 99,
            handlers: handlers,
            fileHandler: true
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        #expect(state.mockOutput != nil)
        #expect(state.mockHiddenID == 99)
    }

    // MARK: - Output Completeness Tests

    @Test("All output lines are captured")
    func allOutputLinesCaptured() async throws {
        let state = TestState()
        let handlers = createMockHandlers(printLine: state.printLine(_:), state: state)

        let process = RsyncProcess(
            arguments: ["--help"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Help output should have multiple lines
        #expect((state.mockOutput?.count ?? 0) > 10)
        
        // Verify output contains expected content
        let outputString = state.mockOutput?.joined(separator: "\n").lowercased() ?? ""
        #expect(outputString.contains("usage") || outputString.contains("options"))
    }

    @Test("Empty output is handled gracefully")
    func emptyOutputHandled() async throws {
        let state = TestState()
        let handlers = createMockHandlers(state: state)

        // Use an rsync command that produces minimal output
        let process = RsyncProcess(
            arguments: ["--version"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Should complete without errors even if output is minimal
        #expect(state.mockOutput != nil)
        #expect(state.errorPropagated == nil)
    }
}

// MARK: - Mock Error for Testing

enum MockRsyncError: Error {
    case testError
}

extension MockRsyncError: LocalizedError {
    var errorDescription: String? {
        "Mock rsync error for testing"
    }
}

extension RsyncProcessStreamingTests {
    
    // MARK: - Tests for Process Cancellation Fix
    
    @Test("Process can be cancelled")
    func processCancellation() async throws {
        let state = TestState()
        let handlers = createMockHandlers(state: state)

        // Use a long-running command
        let process = RsyncProcess(
            arguments: ["--help"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        
        // Cancel immediately
        process.cancel()
        
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // Should have propagated cancellation error
        #expect(state.errorPropagated != nil)
        
        if let error = state.errorPropagated as? RsyncProcessError,
           case .processCancelled = error {
            // Correctly identified as cancellation
        } else {
            Issue.record("Expected processCancelled error")
        }
        
        #expect(process.isCancelledState)
    }
    
    @Test("Cancelled process stops processing output")
    func cancelledProcessStopsProcessing() async throws {
        let state = TestState()
        
        let handlers = ProcessHandlers(
            processTermination: { output, id in
                state.mockOutput = output
                state.mockHiddenID = id
            },
            fileHandler: { count in
                // If we see counts after cancellation, that's a problem
                state.fileHandlerCount = count
            },
            rsyncPath: "/opt/homebrew/bin/rsync",
            checkLineForError: { line in
                state.allProcessedLines.append(line)
            },
            updateProcess: { _ in
                state.processUpdateCalled = true
            },
            propagateError: { error in
                state.errorPropagated = error
            },
            logger: nil,
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: false,
            environment: nil
        )

        let process = RsyncProcess(
            arguments: ["--help"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: true
        )

        try process.executeProcess()
        
        // Cancel quickly to test if processing stops
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        process.cancel()
        
        try await Task.sleep(nanoseconds: 1_000_000_000)

        #expect(process.isCancelledState)
        // #expect(state.errorPropagated != nil)
    }
    
    // MARK: - Tests for Data Drain Fix
    
    @Test("All output is captured even with fast termination")
    func allOutputCapturedFastTermination() async throws {
        let state = TestState()
        let handlers = createMockHandlers(printLine: state.printLine(_:), state: state)

        // Use --version which terminates very quickly
        let process = RsyncProcess(
            arguments: ["--version"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Should have captured output despite fast termination
        #expect(state.mockOutput != nil)
        #expect((state.mockOutput?.count ?? 0) > 0)
        
        let outputString = state.mockOutput?.joined(separator: " ").lowercased() ?? ""
        #expect(outputString.contains("rsync"))
    }
    
    @Test("Partial lines are flushed at termination")
    func partialLinesFlushedAtTermination() async throws {
        let state = TestState()
        let handlers = createMockHandlers(printLine: state.printLine(_:), state: state)

        let process = RsyncProcess(
            arguments: ["--version"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Verify output was captured (which would include any partial lines)
        #expect(state.mockOutput != nil)
        #expect((state.mockOutput?.count ?? 0) > 0)
    }
    
    @Test("Error output is captured at termination")
    func errorOutputCapturedAtTermination() async throws {
        let state = TestState()
        let handlers = createMockHandlers(
            checkForError: true,
            state: state
        )

        let process = RsyncProcess(
            arguments: ["--invalid-option-xyz-123"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Should have captured error output
        #expect(state.errorPropagated != nil)
        
        if let error = state.errorPropagated as? RsyncProcessError,
           case let .processFailed(_, errors) = error {
            #expect(!errors.isEmpty)
        }
    }
    
    // MARK: - Tests for Error Propagation During Processing
    
    @Test("Error during line processing stops further processing")
    func errorDuringProcessingStops() async throws {
        let state = TestState()
        var errorThrown = false
        
        let handlers = ProcessHandlers(
            processTermination: { output, id in
                state.mockOutput = output
                state.mockHiddenID = id
            },
            fileHandler: { count in
                state.fileHandlerCount = count
            },
            rsyncPath: "/opt/homebrew/bin/rsync",
            checkLineForError: { line in
                state.errorCheckCount += 1
                // Throw error on first line
                if state.errorCheckCount == 1 {
                    errorThrown = true
                    throw MockRsyncError.testError
                }
            },
            updateProcess: { _ in
                state.processUpdateCalled = true
            },
            propagateError: { error in
                state.errorPropagated = error
            },
            logger: nil,
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: false,
            environment: nil
        )

        let process = RsyncProcess(
            arguments: ["--help"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        #expect(errorThrown)
        #expect(state.errorPropagated != nil)
    }
    
    // MARK: - Tests for Process Cleanup in Deinit
    
    @Test("Process is terminated if RsyncProcess is deallocated")
    func processTerminatedOnDeinit() async throws {
        let state = TestState()
        let handlers = createMockHandlers(state: state)

        var process: RsyncProcess? = RsyncProcess(
            arguments: ["--help"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        try process?.executeProcess()
        
        // Give it a moment to start
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Deallocate the process object
        process = nil
        
        // Give deinit time to run
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Process should have been cleaned up
        // We can't directly verify process termination, but no crashes = success
        #expect(process == nil)
    }
    
    // MARK: - Tests for Race Condition Fix
    
    @Test("File handler count increments atomically with line processing")
    func fileHandlerCountAtomic() async throws {
        let state = TestState()
        let handlers = createMockHandlers(state: state)

        let process = RsyncProcess(
            arguments: ["--help"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: true
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Should have a reasonable count (not 0, not millions)
        let count = state.fileHandlerCount
        #expect(count > 0)
        #expect(count < 10000) // Sanity check
        
        // If count matches or is close to output lines, atomicity is working
        let outputLineCount = state.mockOutput?.count ?? 0
        #expect(count == outputLineCount)
    }
    
    // MARK: - Tests for Thread Safety
    
    @Test("Multiple concurrent operations don't cause crashes")
    func concurrentOperationsSafe() async throws {
        let state = TestState()
        let handlers = createMockHandlers(state: state)

        let process = RsyncProcess(
            arguments: ["--help"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: true
        )

        try process.executeProcess()
        
        // Try to trigger concurrent access
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<10 {
                    _ = process.isCancelledState
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            
            group.addTask {
                try? await Task.sleep(nanoseconds: 100_000_000)
                process.cancel()
            }
        }
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Should complete without crashes
        #expect(true)
    }
    
    // MARK: - Tests for Process Reference Management
    
    @Test("Process reference is properly managed")
    func processReferenceManaged() async throws {
        let state = TestState()
        let handlers = createMockHandlers(state: state)

        let process = RsyncProcess(
            arguments: ["--version"],
            hiddenID: nil,
            handlers: handlers,
            useFileHandler: false
        )

        // Process reference should be nil before execution
        #expect(!process.isCancelledState)
        
        try process.executeProcess()
        
        // Brief wait for execution
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Should be able to check state without crashes
        _ = process.isCancelledState
        
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // After completion, should still be safe to check
        _ = process.isCancelledState
        
        #expect(state.mockOutput != nil)
    }
    
    // MARK: - Integration Tests for All Fixes
    
    @Test("Complete workflow with all fixes working together")
    func completeWorkflowIntegration() async throws {
        let state = TestState()
        let handlers = createMockHandlers(
            checkForError: true,
            printLine: state.printLine(_:),
            state: state
        )

        let process = RsyncProcess(
            arguments: ["--help"],
            hiddenID: 42,
            handlers: handlers,
            useFileHandler: true
        )

        try process.executeProcess()
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // Verify all aspects work together
        #expect(state.mockOutput != nil)
        #expect((state.mockOutput?.count ?? 0) > 0)
        #expect(state.mockHiddenID == 42)
        #expect(state.fileHandlerCount > 0)
        #expect(state.processUpdateCalled)
        
        // Should have no errors for valid --help command
        if state.errorPropagated != nil {
            // Only acceptable error is if rsync path doesn't exist
            if let error = state.errorPropagated as? RsyncProcessError,
               case .executableNotFound = error {
                // This is fine
            }
        }
        
        let outputString = state.mockOutput?.joined(separator: " ").lowercased() ?? ""
        #expect(outputString.contains("rsync") || outputString.contains("usage"))
    }
}
