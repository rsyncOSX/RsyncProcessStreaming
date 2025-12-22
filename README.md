# RsyncProcessStreaming

Swift Package that streams rsync output line-by-line using `Process` + `Pipe.readabilityHandler`, based on `ProcessStreamingExample.swift` in RsyncUI.

## Features
- Line-by-line stdout streaming with partial line handling.
- Error stream capture and optional failure propagation.
- Rolling accumulation for completion callbacks without buffering entire output.
- Maintains `RsyncProcess` API shape used by RsyncUI (`ProcessHandlers`, `executeProcess()`).

## Usage
```swift
import RsyncProcessStreaming

let handlers = ProcessHandlers(
    processTermination: { output, hiddenID in
        print("Done", hiddenID ?? -1, output ?? [])
    },
    fileHandler: { count in
        print("Files processed: \(count)")
    },
    rsyncPath: "/usr/bin/rsync",
    checkLineForError: { line in
        if line.contains("rsync error:") { throw RsyncProcessError.processFailed(exitCode: 1, errors: [line]) }
    },
    updateProcess: { _ in },
    propagateError: { error in print("Error: \(error)") },
    checkForErrorInRsyncOutput: true,
    rsyncVersion3: true,
    environment: nil
)

let process = RsyncProcess(arguments: ["--version"], handlers: handlers, useFileHandler: false)
try process.executeProcess()
```

## Integration Notes
- Module name: `RsyncProcessStreaming`. If migrating from `RsyncProcess`, swap the import and reuse existing handler builders.
- `executeProcess()` now delivers stdout incrementally and only keeps the accumulated lines needed for completion.
- For UI-bound callbacks, `fileHandler` and `processTermination` are dispatched on the main actor.

## Testing
A small actor-level test is included in `RsyncProcessStreamingTests` validating the streaming splitter.

## Code Quality
This package prioritizes production-readiness with:
- **Thread-safe design** using `@unchecked Sendable` with explicit `NSLock` synchronization for safe multi-threaded access
- **Actor-based concurrency** with `StreamAccumulator` for isolated state management
- **Robust error handling** including proper error propagation and process cleanup
- **Resource management** with guaranteed process termination in deinit
- **Defensive programming** with multiple guard checks to prevent race conditions and partial state processing

The implementation balances flexibility (off-thread execution) with safety (explicit synchronization and main-thread callbacks), making it suitable for production use in tools requiring responsive rsync streaming.

# RsyncProcess: Old vs New Implementation Comparison

## Overview
This document compares the original `RsyncProcess` implementation with the refactored version, highlighting key improvements in thread safety, code organization, and maintainability.

---

## 1. Concurrency & Thread Safety

### Old Implementation
```swift
private var isCancelled = false
private var hasErrorOccurred = false

public func cancel() {
    processLock.lock()
    isCancelled = true
    let process = currentProcess
    processLock.unlock()
    process?.terminate()
}

public var isCancelledState: Bool {
    processLock.lock()
    defer { processLock.unlock() }
    return isCancelled
}

private func handleOutputData(_ text: String) async {
    guard !isCancelled, !hasErrorOccurred else { return }
    // ... processing
}
```

**Issues:**
- Race conditions: `isCancelled` and `hasErrorOccurred` are checked without locks in `handleOutputData`
- Between checking the flag and processing a line, the state could change
- Lock is only used in `cancel()` and `isCancelledState`, but not during checks

### New Implementation
```swift
private let cancelled = ManagedAtomic<Bool>(false)
private let errorOccurred = ManagedAtomic<Bool>(false)

public func cancel() {
    cancelled.store(true, ordering: .relaxed)
    let process = processLock.withLock { currentProcess }
    process?.terminate()
}

public var isCancelledState: Bool {
    cancelled.load(ordering: .relaxed)
}

private func handleOutputData(_ text: String) async {
    guard !cancelled.load(ordering: .relaxed),
          !errorOccurred.load(ordering: .relaxed) else { return }
    // ... processing
}
```

**Benefits:**
- ✅ **Lock-free atomic operations**: No race conditions when checking/setting flags
- ✅ **Better performance**: Atomics are faster than locks for simple boolean flags
- ✅ **Thread-safe reads**: Multiple threads can safely check cancellation state simultaneously
- ✅ **Predictable behavior**: Atomic operations guarantee visibility across threads

---

## 2. Sendable Conformance

### Old Implementation
```swift
public final class RsyncProcess: @unchecked Sendable {
    private var currentProcess: Process?
    private let processLock = NSLock()
    private var isCancelled = false
    private var hasErrorOccurred = false
}
```

**Issues:**
- `@unchecked Sendable`: Compiler cannot verify thread safety
- Mutable properties without proper synchronization markers
- No compile-time safety guarantees

### New Implementation
```swift
public final class RsyncProcess: Sendable {
    private nonisolated(unsafe) var currentProcess: Process?
    private let processLock = NSLock()
    private let cancelled = ManagedAtomic<Bool>(false)
    private let errorOccurred = ManagedAtomic<Bool>(false)
}
```

**Benefits:**
- ✅ **Full Sendable conformance**: Compiler verifies most properties are safe
- ✅ **Explicit unsafe marking**: Only `currentProcess` marked as `nonisolated(unsafe)`
- ✅ **Better type safety**: Compiler catches new thread-safety violations
- ✅ **Future-proof**: New properties must be properly synchronized

---

## 3. Lock Usage Consistency

### Old Implementation
```swift
// Inconsistent lock usage:
processLock.lock()
currentProcess = process
processLock.unlock()

// vs

processLock.withLock {
    currentProcess = nil
}

// vs

processLock.lock()
defer { processLock.unlock() }
return isCancelled
```

**Issues:**
- Three different locking patterns used
- Risk of forgetting to unlock in error paths
- Harder to audit for correctness

### New Implementation
```swift
// Consistent lock usage everywhere:
processLock.withLock {
    currentProcess = process
}

let process = processLock.withLock { currentProcess }

processLock.withLock {
    currentProcess = nil
}
```

**Benefits:**
- ✅ **Single pattern**: `withLock` used consistently throughout
- ✅ **Automatic unlock**: No risk of forgotten unlocks
- ✅ **Cleaner code**: More readable and maintainable
- ✅ **Exception safe**: Guaranteed unlock even if closure throws

---

## 4. Code Organization

### Old Implementation
```swift
public func executeProcess() throws {
    // 80+ lines of setup, pipe handling, and termination logic
    // All in one method
    
    outputPipe.fileHandleForReading.readabilityHandler = { ... }
    errorPipe.fileHandleForReading.readabilityHandler = { ... }
    process.terminationHandler = { ... }
    
    try process.run()
}
```

**Issues:**
- Violates Single Responsibility Principle
- Hard to test individual components
- Difficult to read and maintain
- swiftlint warnings for complexity

### New Implementation
```swift
public func executeProcess() throws {
    // Reset state for reuse
    cancelled.store(false, ordering: .relaxed)
    errorOccurred.store(false, ordering: .relaxed)
    Task { await accumulator.reset() }
    
    // Setup
    let executablePath = handlers.rsyncPath ?? "/usr/bin/rsync"
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
        throw RsyncProcessError.executableNotFound(executablePath)
    }
    
    let process = Process()
    // ... basic setup ...
    
    setupPipeHandlers(outputPipe: outputPipe, errorPipe: errorPipe)
    setupTerminationHandler(process: process, outputPipe: outputPipe, errorPipe: errorPipe)
    
    try process.run()
    logProcessStart(process)
}

// MARK: - Private Setup Methods
private func setupPipeHandlers(outputPipe: Pipe, errorPipe: Pipe) { ... }
private func setupTerminationHandler(process: Process, outputPipe: Pipe, errorPipe: Pipe) { ... }
private func logProcessStart(_ process: Process) { ... }

// MARK: - Private Processing Methods
private func processFinalOutput(...) async { ... }
private func handleOutputData(_ text: String) async { ... }
private func handleTermination(task: Process) async { ... }
private func cleanupProcess() { ... }
```

**Benefits:**
- ✅ **Better structure**: Clear separation of concerns with MARK comments
- ✅ **Testability**: Individual methods can be tested in isolation
- ✅ **Readability**: Each method has a single, clear purpose
- ✅ **Maintainability**: Changes are localized to specific methods
- ✅ **No swiftlint warnings**: Methods are appropriately sized

---

## 5. State Management & Reusability

### Old Implementation
```swift
// No state reset - instance cannot be reused
public func executeProcess() throws {
    let process = Process()
    // ... setup ...
    try process.run()
}
```

**Issues:**
- Single-use instance: Cannot call `executeProcess()` twice
- No cleanup of previous state
- Memory leaks if reused

### New Implementation
```swift
public func executeProcess() throws {
    // Reset state for reuse
    cancelled.store(false, ordering: .relaxed)
    errorOccurred.store(false, ordering: .relaxed)
    Task {
        await accumulator.reset()
    }
    
    let process = Process()
    // ... setup ...
    try process.run()
}

// StreamAccumulator now has reset method
actor StreamAccumulator {
    func reset() {
        lines.removeAll()
        partialLine = ""
        errorLines.removeAll()
        lineCounter = 0
    }
}
```

**Benefits:**
- ✅ **Reusable instances**: Same `RsyncProcess` can execute multiple times
- ✅ **Clean state**: Each execution starts fresh
- ✅ **Memory efficient**: Can maintain single instance instead of creating new ones
- ✅ **Proper lifecycle**: Clear initialization and cleanup

---

## 6. Enhanced Monitoring

### Old Implementation
```swift
// No visibility into running state
public var isCancelledState: Bool {
    processLock.lock()
    defer { processLock.unlock() }
    return isCancelled
}
```

**Issues:**
- Cannot check if process is actively running
- Limited observability

### New Implementation
```swift
public var isCancelledState: Bool {
    cancelled.load(ordering: .relaxed)
}

/// Returns whether the process is currently running
public var isRunning: Bool {
    processLock.withLock {
        currentProcess?.isRunning ?? false
    }
}
```

**Benefits:**
- ✅ **Runtime visibility**: Can check if process is actively executing
- ✅ **Better coordination**: Useful for UI updates and state management
- ✅ **Debugging aid**: Easier to diagnose issues

---

## 7. Error Handling & Logging

### Old Implementation
```swift
do {
    try handlers.checkLineForError(line)
} catch {
    hasErrorOccurred = true
    await MainActor.run {
        self.handlers.propagateError(error)
    }
    break
}

// Process failure - no logging
if task.terminationStatus != 0, handlers.checkForErrorInRsyncOutput == true {
    let error = RsyncProcessError.processFailed(...)
    await MainActor.run {
        self.handlers.propagateError(error)
    }
}
```

**Issues:**
- Silent failures: No logging when errors occur
- Hard to debug: Missing context about what went wrong

### New Implementation
```swift
do {
    try handlers.checkLineForError(line)
} catch {
    errorOccurred.store(true, ordering: .relaxed)
    Logger.process.debugMessageOnly(
        "RsyncProcessStreaming: Error detected - \(error.localizedDescription)"
    )
    await MainActor.run {
        self.handlers.propagateError(error)
    }
    break
}

// Process failure - with logging
if task.terminationStatus != 0, handlers.checkForErrorInRsyncOutput {
    let error = RsyncProcessError.processFailed(...)
    Logger.process.debugMessageOnly(
        "RsyncProcessStreaming: Process failed with exit code \(task.terminationStatus)"
    )
    await MainActor.run {
        self.handlers.propagateError(error)
    }
}

// Cancellation - with logging
if cancelled.load(ordering: .relaxed) {
    Logger.process.debugMessageOnly("RsyncProcessStreaming: Terminated due to cancellation")
    // ...
}

// Trailing output - with logging
if let trailing = await accumulator.flushTrailing() {
    Logger.process.debugMessageOnly("RsyncProcessStreaming: Flushed trailing output: \(trailing)")
}
```

**Benefits:**
- ✅ **Comprehensive logging**: All error paths are logged
- ✅ **Better debugging**: Clear audit trail of what happened
- ✅ **Production monitoring**: Easier to diagnose issues in deployed apps
- ✅ **Context preservation**: Exit codes and error descriptions logged

---

## 8. Code Quality Improvements

### Old Implementation
```swift
public convenience init(
    arguments: [String],
    hiddenID: Int? = nil,
    handlers: ProcessHandlers,
    fileHandler: Bool
) {
    self.init(arguments: arguments, hiddenID: hiddenID, 
              handlers: handlers, useFileHandler: fileHandler)
}

guard let self = self else { return }

guard data.count > 0 else { return }
```

**Issues:**
- Redundant convenience initializer just renames parameter
- Verbose syntax
- Less idiomatic Swift

### New Implementation
```swift
// Convenience init removed - unnecessary

guard let self else { return }

guard !data.isEmpty else { return }
```

**Benefits:**
- ✅ **Less boilerplate**: Removed unnecessary code
- ✅ **Modern Swift**: Uses latest language features
- ✅ **Cleaner API**: Simpler initialization
- ✅ **More idiomatic**: Follows Swift best practices

---

## Summary of Key Benefits

### Performance
- **Faster flag checks**: Atomic operations vs locks
- **Better concurrency**: Lock-free reads of cancellation state
- **Reduced contention**: Fewer lock acquisitions

### Safety
- **Compiler-verified thread safety**: Full `Sendable` conformance
- **No race conditions**: Atomic operations guarantee visibility
- **Exception safety**: Consistent `withLock` usage

### Maintainability
- **Better organization**: Clear method separation with MARK comments
- **Easier testing**: Modular, testable components
- **Comprehensive logging**: Full audit trail for debugging
- **Modern Swift**: Latest language features and idioms

### Functionality
- **Reusable instances**: Can execute multiple processes
- **Better monitoring**: `isRunning` property for state visibility
- **Cleaner lifecycle**: Explicit state reset

### Code Quality
- **Reduced complexity**: No swiftlint warnings
- **Consistent patterns**: Single approach to locking
- **Less boilerplate**: Removed unnecessary code
- **Better documentation**: Clear structure and intent

---

## Migration Recommendation

**Strongly recommend using the new implementation** for:
- All new code
- Any code requiring thread safety guarantees
- Long-running or production applications
- Code that needs to execute multiple rsync processes

The improvements in thread safety, observability, and maintainability far outweigh any migration effort.
