// swiftlint:disable type_body_length file_length line_length
import Foundation
import OSLog
@testable import RsyncProcessStreaming
import Testing

// MARK: - Mock Error for Testing

enum MockRsyncError: Error {
    case testError
}

// MARK: - Thread-Safe State

@MainActor
final class TestState {
    var mockOutput: [String]?
    var mockHiddenID: Int?
    var fileHandlerCount: Int = 0
    var errorPropagated: Error?
    var processUpdateCalled: Bool = false
    var processUpdateNilCalled: Bool = false
    var terminationCalled: Bool = false
    var checkLineForErrorCalled: Bool = false
    var lastCheckedLine: String?

    func reset() {
        mockOutput = nil
        mockHiddenID = nil
        fileHandlerCount = 0
        errorPropagated = nil
        processUpdateCalled = false
        processUpdateNilCalled = false
        terminationCalled = false
        checkLineForErrorCalled = false
        lastCheckedLine = nil
    }
}

// MARK: - Helper Functions

extension RsyncProcessStreamingTests {
    /// Wait for a condition to become true, with timeout
    func waitFor(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let startTime = ContinuousClock.now
        while await !condition() {
            if ContinuousClock.now - startTime > timeout {
                throw TestError.timeout
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    enum TestError: Error {
        case timeout
    }
}

// MARK: - Tests

struct RsyncProcessStreamingTests {
    // MARK: - StreamAccumulator Unit Tests

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

    // MARK: - Process Execution Tests

    @Test("Process termination returns output via confirmation")
    func processTerminationCaptured() async throws {
        let state = TestState()
        let hiddenID = 123

        let handlers = ProcessHandlers(
            processTermination: { output, id in
                Task { @MainActor in
                    state.mockOutput = output
                    state.mockHiddenID = id
                    state.terminationCalled = true
                }
            },
            fileHandler: { _ in },
            rsyncPath: "/usr/bin/rsync",
            checkLineForError: { _ in },
            updateProcess: { _ in },
            propagateError: { _ in },
            logger: { _, _ in },
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: true
        )

        let process = await RsyncProcess(
            arguments: ["--version"],
            hiddenID: hiddenID,
            handlers: handlers,
            useFileHandler: false
        )

        try await process.executeProcess()

        // Wait for termination
        try await waitFor { await state.terminationCalled }

        let output = await state.mockOutput
        #expect(output != nil)
        #expect(await state.mockHiddenID == hiddenID)
    }

    @Test("File handler increments count during execution")
    func fileHandlerIncrements() async throws {
        let state = TestState()

        let handlers = ProcessHandlers(
            processTermination: { _, _ in
                Task { @MainActor in
                    state.terminationCalled = true
                }
            },
            fileHandler: { count in
                Task { @MainActor in
                    state.fileHandlerCount = max(state.fileHandlerCount, count)
                }
            },
            rsyncPath: "/usr/bin/rsync",
            checkLineForError: { _ in },
            updateProcess: { _ in },
            propagateError: { _ in },
            logger: { _, _ in },
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: true
        )

        let process = await RsyncProcess(
            arguments: ["--version"],
            handlers: handlers,
            useFileHandler: true
        )

        try await process.executeProcess()

        // Wait for termination
        try await waitFor { await state.terminationCalled }

        let terminationCalled = await state.terminationCalled
        #expect(terminationCalled == true)
        let count = await state.fileHandlerCount
        #expect(count > 0)
    }

    @Test("Process cancellation propagates correct error")
    func processCancellationPropagates() async throws {
        let state = TestState()

        let handlers = ProcessHandlers(
            processTermination: { _, _ in
                Task { @MainActor in
                    state.terminationCalled = true
                }
            },
            fileHandler: { _ in },
            rsyncPath: "/bin/sleep",
            checkLineForError: { _ in },
            updateProcess: { _ in },
            propagateError: { error in
                Task { @MainActor in
                    state.errorPropagated = error
                }
            },
            logger: { _, _ in },
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: true
        )

        let process = await RsyncProcess(
            arguments: ["5"],
            handlers: handlers
        )

        try await process.executeProcess()

        // Wait for process to actually start running
        var attempts = 0
        while await !process.isRunning, attempts < 50 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }

        // Now cancel it
        await process.cancel()

        // Wait for termination and error propagation
        try await waitFor(timeout: .seconds(3)) {
            let terminated = await state.terminationCalled
            let error = await state.errorPropagated
            return terminated && error != nil
        }

        let error = await state.errorPropagated
        #expect(error != nil, "Expected cancellation error to be propagated")

        // Verify it's a cancellation error
        guard let rsyncError = error as? RsyncProcessError else {
            Issue.record("Expected error to be RsyncProcessError")
            return
        }

        let isCancelledError = if case .processCancelled = rsyncError {
            true
        } else {
            false
        }
        #expect(isCancelledError, "Expected RsyncProcessError.processCancelled")
    }

    @Test("Error in line detection stops process and propagates error")
    func lineErrorDetection() async throws {
        let state = TestState()

        let handlers = ProcessHandlers(
            processTermination: { _, _ in
                Task { @MainActor in
                    state.terminationCalled = true
                }
            },
            fileHandler: { _ in },
            rsyncPath: "/usr/bin/rsync",
            checkLineForError: { line in
                // Simulate an error if any line is processed
                // Using a broad condition to ensure we catch at least one line
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw MockRsyncError.testError
                }
            },
            updateProcess: { _ in },
            propagateError: { error in
                Task { @MainActor in
                    state.errorPropagated = error
                }
            },
            logger: { _, _ in },
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: true
        )

        let process = await RsyncProcess(
            arguments: ["--help"],
            handlers: handlers
        )

        try await process.executeProcess()

        // Wait for error to be propagated (with longer timeout since we know error should occur)
        do {
            try await waitFor(timeout: .seconds(3)) {
                await state.errorPropagated != nil
            }
        } catch {
            // If timeout, check termination status
            let terminated = await state.terminationCalled
            let errorValue = await state.errorPropagated
            print("DEBUG: Timeout waiting for error. Terminated: \(terminated), Error: \(String(describing: errorValue))")
            throw error
        }

        let error = await state.errorPropagated
        let isNil = error == nil
        let isCorrectType = error is MockRsyncError

        #expect(!isNil, "Expected error to be propagated")
        #expect(isCorrectType, "Expected MockRsyncError")
    }

    @Test("Invalid executable path throws error immediately")
    func invalidExecutablePath() async throws {
        let handlers = ProcessHandlers(
            processTermination: { _, _ in },
            fileHandler: { _ in },
            rsyncPath: "/invalid/path/rsync",
            checkLineForError: { _ in },
            updateProcess: { _ in },
            propagateError: { _ in },
            logger: { _, _ in },
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: true
        )

        let process = await RsyncProcess(
            arguments: ["--version"],
            handlers: handlers
        )

        await #expect(throws: RsyncProcessError.self) {
            try await process.executeProcess()
        }
    }

    @Test("Process state checks work correctly")
    func processStateChecks() async throws {
        let state = TestState()

        let handlers = ProcessHandlers(
            processTermination: { _, _ in
                Task { @MainActor in
                    state.terminationCalled = true
                }
            },
            fileHandler: { _ in },
            rsyncPath: "/usr/bin/rsync",
            checkLineForError: { _ in },
            updateProcess: { _ in },
            propagateError: { _ in },
            logger: { _, _ in },
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: true
        )

        let process = await RsyncProcess(
            arguments: ["--version"],
            handlers: handlers
        )

        // Before execution
        let initialCancelled = await process.isCancelledState
        let initialRunning = await process.isRunning
        #expect(initialCancelled == false)
        #expect(initialRunning == false)

        try await process.executeProcess()

        // During execution - check quickly while it might still be running
        try await Task.sleep(for: .milliseconds(10))
        // Note: Process might complete quickly, so we don't assert this

        // Wait for termination
        try await waitFor { await state.terminationCalled }

        // After execution
        let afterRunning = await process.isRunning
        #expect(afterRunning == false)
    }

    @Test("Cancellation sets cancelled state")
    func cancellationSetsState() async throws {
        let state = TestState()

        let handlers = ProcessHandlers(
            processTermination: { _, _ in
                Task { @MainActor in
                    state.terminationCalled = true
                }
            },
            fileHandler: { _ in },
            rsyncPath: "/usr/bin/rsync",
            checkLineForError: { _ in },
            updateProcess: { _ in },
            propagateError: { _ in },
            logger: { _, _ in },
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: true
        )

        let process = await RsyncProcess(
            arguments: ["--help"],
            handlers: handlers
        )

        try await process.executeProcess()

        // Verify not cancelled initially
        let beforeCancel = await process.isCancelledState
        #expect(beforeCancel == false)

        await process.cancel()

        // Verify cancelled state is set
        let afterCancel = await process.isCancelledState
        #expect(afterCancel == true)

        // Wait for termination
        try await waitFor { await state.terminationCalled }
    }

    @Test("Process update handler is called")
    func processUpdateHandlerCalled() async throws {
        let state = TestState()

        let handlers = ProcessHandlers(
            processTermination: { _, _ in
                Task { @MainActor in
                    state.terminationCalled = true
                }
            },
            fileHandler: { _ in },
            rsyncPath: "/usr/bin/rsync",
            checkLineForError: { _ in },
            updateProcess: { process in
                Task { @MainActor in
                    if process != nil {
                        state.processUpdateCalled = true
                    } else {
                        state.processUpdateNilCalled = true
                    }
                }
            },
            propagateError: { _ in },
            logger: { _, _ in },
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: true
        )

        let process = await RsyncProcess(
            arguments: ["--version"],
            handlers: handlers
        )

        try await process.executeProcess()

        // Wait for termination
        try await waitFor { await state.terminationCalled }

        // Verify both calls happened
        let updateCalled = await state.processUpdateCalled
        let nilCalled = await state.processUpdateNilCalled
        #expect(updateCalled == true)
        #expect(nilCalled == true)
    }

    @Test("Error priority: cancellation takes precedence")
    func errorPriorityCancellation() async throws {
        let state = TestState()

        let handlers = ProcessHandlers(
            processTermination: { _, _ in
                Task { @MainActor in
                    state.terminationCalled = true
                }
            },
            fileHandler: { _ in },
            rsyncPath: "/usr/bin/rsync",
            checkLineForError: { line in
                // This error should be ignored if cancellation happens
                if line.contains("rsync") { throw MockRsyncError.testError }
            },
            updateProcess: { _ in },
            propagateError: { error in
                Task { @MainActor in
                    // Should only receive cancellation error
                    state.errorPropagated = error
                }
            },
            logger: { _, _ in },
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: true
        )

        let process = await RsyncProcess(
            arguments: ["--help"],
            handlers: handlers
        )

        try await process.executeProcess()

        // Cancel immediately to test priority
        await process.cancel()

        // Wait for error to be propagated
        try await waitFor { await state.errorPropagated != nil }

        let error = await state.errorPropagated
        #expect(error != nil)

        // Verify it's a cancellation error, not the mock error
        if let rsyncError = await state.errorPropagated as? RsyncProcessError {
            if case .processCancelled = rsyncError {
                // Success - cancellation error takes precedence
            } else {
                Issue.record("Expected processCancelled error")
            }
        }
    }

    @Test("Repeated executeProcess does not accumulate output")
    func repeatedExecuteDoesNotAccumulateOutput() async throws {
        let state = TestState()

        let handlers = ProcessHandlers(
            processTermination: { output, _ in
                Task { @MainActor in
                    state.mockOutput = output
                    state.terminationCalled = true
                }
            },
            fileHandler: { _ in },
            rsyncPath: "/bin/echo",
            checkLineForError: { _ in },
            updateProcess: { _ in },
            propagateError: { _ in },
            logger: { _, _ in },
            checkForErrorInRsyncOutput: false,
            rsyncVersion3: true
        )

        let process = await RsyncProcess(
            arguments: ["one"],
            handlers: handlers,
            useFileHandler: false
        )

        try await process.executeProcess()
        try await waitFor { await state.terminationCalled }
        let firstOutput = await state.mockOutput
        #expect(firstOutput == ["one"])

        await state.reset()

        try await process.executeProcess()
        try await waitFor { await state.terminationCalled }
        let secondOutput = await state.mockOutput
        #expect(secondOutput == ["one"])
    }

    @Test("Non-zero exit propagates processFailed when enabled")
    func nonZeroExitPropagatesProcessFailed() async throws {
        let state = TestState()

        let handlers = ProcessHandlers(
            processTermination: { _, _ in
                Task { @MainActor in
                    state.terminationCalled = true
                }
            },
            fileHandler: { _ in },
            rsyncPath: "/usr/bin/false",
            checkLineForError: { _ in },
            updateProcess: { _ in },
            propagateError: { error in
                Task { @MainActor in
                    state.errorPropagated = error
                }
            },
            logger: { _, _ in },
            checkForErrorInRsyncOutput: true,
            rsyncVersion3: true
        )

        let process = await RsyncProcess(
            arguments: [],
            handlers: handlers,
            useFileHandler: false
        )

        try await process.executeProcess()

        try await waitFor(timeout: .seconds(3)) {
            let terminated = await state.terminationCalled
            let error = await state.errorPropagated
            return terminated && error != nil
        }

        guard let error = await state.errorPropagated as? RsyncProcessError else {
            Issue.record("Expected RsyncProcessError")
            return
        }

        guard case let .processFailed(exitCode, _) = error else {
            Issue.record("Expected processFailed")
            return
        }

        #expect(exitCode != 0)
    }
}

// swiftlint:enable type_body_length file_length line_length
