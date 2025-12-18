//
//  PrintLinesTest.swift
//  RsyncProcessStreaming
//
//  Created by Thomas Evensen on 12/18/2025.
//

import Foundation
@testable import RsyncProcessStreaming
import Testing

@MainActor
@Suite("PrintLines Tests", .serialized)
struct PrintLinesTests {
    @Test("PrintLines receives lines via closure")
    func printLinesObservable() async {
        let capture = RsyncOutputCapture.shared

        // Ensure a clean state
        await capture.disable()
        await capture.clear()
        PrintLines.shared.clear()

        // Enable capture
        await capture.enable()

        // Get the nonisolated closure and call it synchronously as ProcessHandlers would
        let printLines = capture.makePrintLinesClosure()
        printLines("Test line A")
        printLines("Test line B")

        // Give async tasks time to complete
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds

        // Read observable output on MainActor
        let lines = PrintLines.shared.output

        #expect(lines.contains("Test line A"))
        #expect(lines.contains("Test line B"))

        // Cleanup
        await capture.disable()
        await capture.clear()
        PrintLines.shared.clear()
    }
}
