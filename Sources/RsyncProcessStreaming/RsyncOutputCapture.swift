//
//  RsyncOutputCapture.swift
//  RsyncUI
//
//  Created by Thomas Evensen on 12/11/2025.
//

import Foundation
import OSLog

/// Thread-safe singleton for capturing rsync output across the application
public actor RsyncOutputCapture {
    public static let shared = RsyncOutputCapture()

    private var isEnabled: Bool = false
    private var outputLines: [String] = []

    // Optional: File URL for writing output
    private var fileURL: URL?
    private var fileHandle: FileHandle?

    init() {}

    // MARK: - Configuration

    /// Enable output capture
    public func enable(writeToFile: URL? = nil) {
        Logger.process.debugThreadOnly("RsyncOutputCapture: ENABLE() capture")
        isEnabled = true
        fileURL = writeToFile

        if let fileURL {
            setupFileOutput(at: fileURL)
        }
    }

    /// Disable output capture
    public func disable() {
        Logger.process.debugThreadOnly("RsyncOutputCapture: DISABLE() capture")
        isEnabled = false
        closeFileOutput()
    }

    /// Check if capture is enabled
    public func isCapturing() -> Bool {
        isEnabled
    }

    // MARK: - Output Capture

    /// Capture a line of output
    public func captureLine(_ line: String) {
        guard isEnabled else { return }
        outputLines.append(line)
        // Write to file if configured
        if let fileHandle {
            if let data = (line + "\n").data(using: .utf8) {
                try? fileHandle.write(contentsOf: data)
            }
        }
    }

    /// Get all captured lines
    public func getAllLines() -> [String] {
        outputLines
    }

    /// Get recent lines (last N lines)
    public func getRecentLines(count: Int) -> [String] {
        let startIndex = max(0, outputLines.count - count)
        return Array(outputLines[startIndex...])
    }

    /// Clear captured output
    public func clear() {
        outputLines.removeAll()
    }

    // MARK: - File Output

    private func setupFileOutput(at url: URL) {
        do {
            // Create file if it doesn't exist
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }

            fileHandle = try FileHandle(forWritingTo: url)
            fileHandle?.seekToEndOfFile()

            // Write header
            let header = "\n=== Rsync Output Session: \(Date()) ===\n"
            if let data = header.data(using: .utf8) {
                try? fileHandle?.write(contentsOf: data)
            }
        } catch {
            Logger.process.error("Failed to open file for writing: \(error.localizedDescription)")
        }
    }

    private func closeFileOutput() {
        try? fileHandle?.close()
        fileHandle = nil
    }
}

// MARK: - Convenience Methods

public extension RsyncOutputCapture {
    /// Create a printlines closure for ProcessHandlers
    /// The closure updates the @Observable PrintLines model on the MainActor
    /// and also forwards the line into the actor's captureLine(...) as before.
    nonisolated func makePrintLinesClosure() -> (String) -> Void {
        { line in
            // Update UI-observable model on MainActor (non-blocking)
            Task { @MainActor in
                PrintLines.shared.appendLine(line)
            }

            // Also keep capturing in the actor's internal storage (async)
            Task {
                await self.captureLine(line)
            }
        }
    }
}
