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
    
    func reset() {
        mockOutput = nil
        mockHiddenID = nil
        fileHandlerCount = 0
        errorPropagated = nil
        processUpdateCalled = false
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
        
        try await confirmation("Process should terminate", expectedCount: 1) { (done: Confirmation) in
            let handlers = ProcessHandlers(
                processTermination: { output, id in
                    Task { @MainActor in
                        state.mockOutput = output
                        state.mockHiddenID = id
                        done()
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

            let process = RsyncProcess(
                arguments: ["--version"],
                hiddenID: hiddenID,
                handlers: handlers,
                useFileHandler: false
            )

            try process.executeProcess()
        }

        let output = await state.mockOutput
        #expect(output != nil)
        #expect(await state.mockHiddenID == hiddenID)
    }

    @Test("File handler increments count during execution")
    func fileHandlerIncrements() async throws {
        let state = TestState()
        
        try await confirmation("File handler should be called", expectedCount: 1) { (done: Confirmation) in
            let handlers = ProcessHandlers(
                processTermination: { _, _ in
                    done()
                },
                fileHandler: { count in
                    Task { @MainActor in
                        state.fileHandlerCount = count
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

            let process = RsyncProcess(
                arguments: ["--help"],
                handlers: handlers,
                useFileHandler: true
            )

            try process.executeProcess()
        }

        let count = await state.fileHandlerCount
        #expect(count > 0)
    }

    @Test("Process cancellation propagates correct error")
    func processCancellationPropagates() async throws {
        let state = TestState()
        
        try await confirmation("Should receive cancellation error", expectedCount: 1) { (done: Confirmation) in
            let handlers = ProcessHandlers(
                processTermination: { _, _ in },
                fileHandler: { _ in },
                rsyncPath: "/usr/bin/rsync",
                checkLineForError: { _ in },
                updateProcess: { _ in },
                propagateError: { error in
                    Task { @MainActor in
                        if let err = error as? RsyncProcessError, case .processCancelled = err {
                            state.errorPropagated = err
                            done()
                        }
                    }
                },
                logger: { _, _ in },
                checkForErrorInRsyncOutput: false,
                rsyncVersion3: true
            )

            let process = RsyncProcess(
                arguments: ["--help"],
                handlers: handlers
            )

            try process.executeProcess()
            process.cancel()
        }
        
        let error = await state.errorPropagated
        #expect(error != nil)
    }

    @Test("Error in line detection stops process")
    func lineErrorDetection() async throws {
        let state = TestState()
        
        try await confirmation("Should propagate line error", expectedCount: 1) { (done: Confirmation) in
            let handlers = ProcessHandlers(
                processTermination: { _, _ in },
                fileHandler: { _ in },
                rsyncPath: "/usr/bin/rsync",
                checkLineForError: { line in
                    // Simulate an error if a specific word appears
                    if line.contains("rsync") { throw MockRsyncError.testError }
                },
                updateProcess: { _ in },
                propagateError: { error in
                    Task { @MainActor in
                        state.errorPropagated = error
                        done()
                    }
                },
                logger: { _, _ in },
                checkForErrorInRsyncOutput: false,
                rsyncVersion3: true
            )

            let process = RsyncProcess(
                arguments: ["--version"],
                handlers: handlers
            )

            try process.executeProcess()
        }

        let error = await state.errorPropagated
        #expect(error is MockRsyncError)
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
        
        let process = RsyncProcess(
            arguments: ["--version"],
            handlers: handlers
        )

        #expect(throws: RsyncProcessError.self) {
            try process.executeProcess()
        }
    }
}
