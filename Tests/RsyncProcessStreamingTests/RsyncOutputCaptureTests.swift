import Foundation
@testable import RsyncProcessStreaming
import Testing

@MainActor
@Suite("RsyncOutputCapture Tests", .serialized)
struct RsyncOutputCaptureTests {
    @Test("Output capture can be enabled and disabled")
    func enableDisable() async {
            let capture = RsyncOutputCapture.shared

            // Start disabled
            await capture.disable()
            #expect(await capture.isCapturing() == false)

            // Enable
            await capture.enable()
            #expect(await capture.isCapturing() == true)

            // Disable again
            await capture.disable()
            #expect(await capture.isCapturing() == false)
    }

    @Test("Captures lines when enabled")
    func captureLines() async {
            let capture = RsyncOutputCapture.shared

            // Disable first to ensure clean state
            await capture.disable()
            await capture.clear()

            // Now enable
            await capture.enable()

            // Capture some lines
            await capture.captureLine("Line 1")
            await capture.captureLine("Line 2")
            await capture.captureLine("Line 3")

            let lines = await capture.getAllLines()
            #expect(lines.count == 3)
            #expect(lines[0] == "Line 1")
            #expect(lines[1] == "Line 2")
            #expect(lines[2] == "Line 3")

            // Cleanup
            await capture.clear()
            await capture.disable()
    }

    @Test("Does not capture lines when disabled")
    func doesNotCaptureWhenDisabled() async {
            let capture = RsyncOutputCapture.shared

            // Disable and clear
            await capture.disable()
            await capture.clear()

            // Try to capture
            await capture.captureLine("Should not be captured")

            let lines = await capture.getAllLines()
            #expect(lines.isEmpty)
    }

    @Test("Clear removes all captured lines")
    func testClear() async {
            let capture = RsyncOutputCapture.shared

            await capture.enable()
            await capture.captureLine("Line 1")
            await capture.captureLine("Line 2")

            var lines = await capture.getAllLines()
            #expect(lines.count == 2)

            // Clear
            await capture.clear()

            lines = await capture.getAllLines()
            #expect(lines.isEmpty)

            await capture.disable()
    }

    @Test("Get recent lines returns correct subset")
    func testGetRecentLines() async {
            let capture = RsyncOutputCapture.shared

            // Clean start
            await capture.disable()
            await capture.clear()
            await capture.enable()

            // Add 10 lines
            for idx in 1 ... 10 {
                await capture.captureLine("Line \(idx)")
            }

            // Get last 3 lines
            let recent = await capture.getRecentLines(count: 3)
            #expect(recent.count == 3)
            #expect(recent[0] == "Line 8")
            #expect(recent[1] == "Line 9")
            #expect(recent[2] == "Line 10")

            // Get more lines than available
            let all = await capture.getRecentLines(count: 100)
            #expect(all.count == 10)

            // Cleanup
            await capture.disable()
            await capture.clear()
    }

    @Test("makePrintLinesClosure works correctly")
    func printLinesClosure() async {
            let capture = RsyncOutputCapture.shared

            // Clean start
            await capture.disable()
            await capture.clear()
            await capture.enable()

            // Get the closure (no await needed - it's nonisolated)
            let printLines = capture.makePrintLinesClosure()

            // Use it synchronously (as it would be used in ProcessHandlers)
            printLines("Closure line 1")
            printLines("Closure line 2")

            // Wait longer for async tasks to complete
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            let lines = await capture.getAllLines()
            #expect(lines.count >= 2)
            if lines.count >= 2 {
                let tail = Array(lines.suffix(2))
                #expect(tail.contains("Closure line 1"))
                #expect(tail.contains("Closure line 2"))
            }

            // Cleanup
            await capture.disable()
            await capture.clear()
    }

    @Test("File output creates and writes to file")
    func fileOutput() async throws {
            let capture = RsyncOutputCapture.shared

            // Create temporary file URL
            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent("rsync-test-\(UUID().uuidString).log")

            // Ensure file doesn't exist
            try? FileManager.default.removeItem(at: fileURL)

            // Enable with file output
            await capture.clear()
            await capture.enable(writeToFile: fileURL)

            // Capture some lines
            await capture.captureLine("File test line 1")
            await capture.captureLine("File test line 2")

            // Disable to flush and close file
            await capture.disable()

            // Verify file was created and contains content
            #expect(FileManager.default.fileExists(atPath: fileURL.path))

            let fileContent = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(fileContent.contains("File test line 1"))
            #expect(fileContent.contains("File test line 2"))
            #expect(fileContent.contains("Rsync Output Session"))

            // Cleanup
            try? FileManager.default.removeItem(at: fileURL)
            await capture.clear()
    }

    @Test("Integration with ProcessHandlers")
    func processHandlersIntegration() async {
            let capture = RsyncOutputCapture.shared

            // Clean start
            await capture.disable()
            await capture.clear()
            await capture.enable()

            let handlers = ProcessHandlers(
                processTermination: { _, _ in },
                fileHandler: { _ in },
                rsyncPath: "/usr/bin/rsync",
                checkLineForError: { _ in },
                updateProcess: { _ in },
                propagateError: { _ in },
                logger: { _, _ in },
                checkForErrorInRsyncOutput: false,
                rsyncVersion3: true,
                environment: nil,
                printLine: capture.makePrintLinesClosure()
            )

            // Simulate calling print line closure
            if let printLine = handlers.printLine {
                printLine("Test output 1")
                printLine("Test output 2")
            }

            // Give async tasks time to complete
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            let capturedLines = await capture.getAllLines()
            #expect(capturedLines.count >= 2)
            if capturedLines.count >= 2 {
                let tail = Array(capturedLines.suffix(2))
                #expect(tail[0] == "Test output 1")
                #expect(tail[1] == "Test output 2")
            }

            // Cleanup
            await capture.disable()
            await capture.clear()
    }
}
