+++
author = "Thomas Evensen"
title = "Streaming Rsync Process"
date = "2025-12-16"
tags = ["version 2.8.4"]
categories = ["technical details"]
+++

**RsyncProcessStreaming** is the superior implementation and should be preferred for new code. It offers a simpler architecture, better resource management, proper handling of streaming data, and cleaner error handling compared to the original RsyncProcess.

---

## Key Differences & Benefits

### 1. Simpler, More Modern Architecture

#### RsyncProcess (Original)
Uses a complex notification-based approach:
- Multiple async tasks monitoring NotificationCenter notifications
- Manual coordination between `sequenceFileHandlerTask` and `sequenceTerminationTask`
- Complex state management with flags like `hasSeenSummaryStart`, `isRealRun`, `isVersionProbe`
- Requires manual notification triggering with `waitForDataInBackgroundAndNotify()`

#### RsyncProcessStreaming (Improved)
Uses direct callbacks:
- Clean `readabilityHandler` closures on file handles
- Single `terminationHandler` for process completion
- Minimal state tracking (just `lineCounter`)
- System handles notification automatically

**Benefit**: Less code, fewer moving parts, easier to understand and debug.

---

### 2. Better Resource Management

#### RsyncProcess Issues
```swift
// Manual draining loop in termination
try? await Task.sleep(nanoseconds: 50_000_000)
var totalDrained = 0
while true {
    let data: Data = pipe.fileHandleForReading.availableData
    if data.isEmpty {
        break
    }
    totalDrained += data.count
    // Process data...
}
```
- Data can be lost between notification delivery and processing
- Arbitrary 50ms sleep before draining
- Complex task cancellation coordination

#### RsyncProcessStreaming Solution
```swift
process.terminationHandler = { [weak self] task in
    // Read any remaining data in pipes before cleanup
    let finalOutputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let finalErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    
    // Now safe to remove handlers
    outputPipe.fileHandleForReading.readabilityHandler = nil
    errorPipe.fileHandleForReading.readabilityHandler = nil
    
    // Process any final output and flush trailing partial line
    if let text = String(data: finalOutputData, encoding: .utf8), !text.isEmpty {
        await self.handleOutputData(text)
    }
    _ = await self.accumulator.flushTrailing()
}
```
- Reads final data from pipes using `readDataToEndOfFile()` before cleanup
- No artificial delays needed
- Proper handling of all remaining data and trailing partial lines

**Benefit**: More reliable, no data loss, cleaner shutdown.

---

### 3. Proper Output Buffering

#### RsyncProcess Problem
```swift
str.enumerateLines { line, _ in
    self.output.append(line)  // What if line is incomplete?
}
```
Appends directly to output array without handling partial lines that may span multiple data chunks.

#### RsyncProcessStreaming Solution
```swift
actor StreamAccumulator {
    private var lines: [String] = []
    private var partialLine: String = ""
    private var errorLines: [String] = []
    private var lineCounter: Int = 0
    
    func consume(_ text: String) -> [String] {
        let combined = partialLine + text  // Handles splits mid-line
        let parts = combined.components(separatedBy: .newlines)
        partialLine = parts.last ?? ""  // Preserves incomplete line
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
    
    func recordError(_ text: String) {
        errorLines.append(text)
    }
    
    func incrementLineCounter() -> Int {
        lineCounter += 1
        return lineCounter
    }
}
```

**Benefit**: Correctly handles streaming data where lines can be split across multiple reads.

---

### 4. Cleaner Error Handling

#### RsyncProcess
- Manually checks errors line-by-line with `errorDiscovered` flag
- stderr goes to same pipe as stdout (mixed output)
- Error logging is conditional and complex
- No structured error information

#### RsyncProcessStreaming
```swift
let outputPipe = Pipe()
let errorPipe = Pipe()  // Separate pipe for errors
process.standardOutput = outputPipe
process.standardError = errorPipe

// Dedicated error accumulation from stderr
errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
    Task {
        await self?.accumulator.recordError(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// Check each line for errors during processing
private func handleOutputData(_ text: String) async {
    let lines = await accumulator.consume(text)
    for line in lines {
        do {
            try handlers.checkLineForError(line)
        } catch {
            hasErrorOccurred = true
            await MainActor.run {
                self.handlers.propagateError(error)
            }
            break
        }
    }
}

// Structured error on process failure
if task.terminationStatus != 0, handlers.checkForErrorInRsyncOutput == true {
    let error = RsyncProcessError.processFailed(
        exitCode: task.terminationStatus,
        errors: errors
    )
    await MainActor.run {
        self.handlers.propagateError(error)
    }
}
```

**Benefit**: Better error diagnostics, separation of stdout/stderr, structured error types. Errors are caught immediately during streaming rather than waiting for process termination.

---

### 5. Removed Unnecessary Complexity

#### RsyncProcess Special Cases
- Version probe detection (`isVersionProbe`)
- Different handlers for rsync3 vs openrsync:
  - `handleRsync3Data()`
  - `handleOpenRsyncData()`
  - `handleVersionData()`
- Summary detection logic (`hasSeenSummaryStart`, `summaryStartMarker`)
- Conditional file handler updates based on dry-run detection
- Complex flag management throughout

#### RsyncProcessStreaming
- Single consistent data handling path
- Version information stored in `ProcessHandlers` (not processed internally)
- Delegates version-specific behavior to handler callbacks
- Simpler, more predictable behavior
- Easy to extend if needed

**Benefit**: Lower maintenance burden, fewer edge cases, easier to reason about. Version-specific logic is externalized to handlers.

---

### 6. Thread Safety & Concurrency

#### RsyncProcess
```swift
@MainActor
public final class RsyncProcess {
    // Entire class runs on main thread
}
```
- Forces all processing onto main thread
- Can cause UI blocking with heavy output
- Less efficient use of system resources

#### RsyncProcessStreaming
```swift
public final class RsyncProcess: @unchecked Sendable {
    private let accumulator = StreamAccumulator()
    private var currentProcess: Process?
    private let processLock = NSLock()
    private var isCancelled = false
    private var hasErrorOccurred = false
    
    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
        Task {  // Process on background thread
            let lines = await self.accumulator.consume(text)
            
            for line in lines {
                if useFileHandler {
                    let count = await self.accumulator.incrementLineCounter()
                    // Only dispatch to main when calling handlers
                    await MainActor.run {
                        self.handlers.fileHandler(count)
                    }
                }
            }
        }
    }
}
```
- Marked `@unchecked Sendable` with internal synchronization via `NSLock`
- Uses `Task` for data processing on background threads
- Only dispatches to `@MainActor` when calling handlers via `MainActor.run`
- Thread-safe with `actor StreamAccumulator`

**Benefit**: Better performance, no UI blocking, proper use of Swift concurrency.

---

### 7. More Predictable Data Flow

#### RsyncProcess Flow
```
Data Available
    ↓
Post Notification
    ↓
NotificationCenter delivers to AsyncSequence
    ↓
Task processes notification
    ↓
Manual call to waitForDataInBackgroundAndNotify()
    ↓
Repeat
```

#### RsyncProcessStreaming Flow
```
Data Available
    ↓
readabilityHandler called automatically
    ↓
Process data
    ↓
Done (system continues monitoring)
```

**Benefit**: Simpler mental model, fewer opportunities for bugs.

---

## Side-by-Side Comparison

| Feature | RsyncProcess | RsyncProcessStreaming |
|---------|--------------|----------------------|
| **Architecture** | Notification-based | Callback-based |
| **Lines of Code** | ~350 | ~260 |
| **State Flags** | 6+ flags | 2 (isCancelled, hasErrorOccurred) |
| **Async Tasks** | 2 coordinated tasks | 0 (uses handlers) |
| **Thread Model** | @MainActor (blocking) | @unchecked Sendable with NSLock |
| **Partial Line Handling** | ❌ No | ✅ Yes (via StreamAccumulator) |
| **Separate stderr** | ❌ No | ✅ Yes |
| **Error Structure** | Generic Error | RsyncProcessError with details |
| **Error Checking** | Post-processing | Per-line during streaming |
| **Manual Draining** | ✅ Yes (with delay) | ❌ No (readDataToEndOfFile) |
| **Maintenance Complexity** | High | Low |

---

## When You Might Still Use RsyncProcess

The only scenarios where the original might be preferred:

1. **Summary Suppression**: If you specifically need the `isRealRun` and `hasSeenSummaryStart` logic to suppress final summary lines during progress reporting
2. **Legacy Code Compatibility**: Existing implementations that depend on specific RsyncProcess behavior

**However**: Any needed features can easily be added to RsyncProcessStreaming if needed, and the architecture is much cleaner for doing so.

---

## Migration Considerations

If migrating from RsyncProcess to RsyncProcessStreaming:

1. **Handler Compatibility**: Both use the same `ProcessHandlers` protocol, so handlers are compatible
2. **Output Array**: Both accumulate output, accessible via `StreamAccumulator.snapshot()`
3. **Error Checking**: Similar pattern, but streaming version has better error details
4. **No Breaking Changes**: API is nearly identical for consumers

---

## Recommendation

### ✅ Use RsyncProcessStreaming

**Reasons:**
- Has fewer bugs and edge cases
- Is easier to maintain and modify
- Handles streaming data correctly
- Has better separation of concerns
- Uses modern Swift concurrency properly
- Is more efficient (no polling, no artificial delays)
- Better error reporting with separate stderr
- Less code to understand and debug

---

## Conclusion

The original **RsyncProcess** appears to have evolved with accumulated complexity over time, with features and flags added as needs arose. 

**RsyncProcessStreaming** is a cleaner redesign that learned from those lessons, removing unnecessary complexity while adding proper streaming support and better error handling.

For any new code, **RsyncProcessStreaming is strongly recommended**. For existing code using RsyncProcess, consider migrating when practical, as the benefits in maintainability and reliability are substantial.
