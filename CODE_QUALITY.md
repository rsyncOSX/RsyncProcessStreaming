
CODE QUALITY DOCUMENT

Overview

This document outlines the code quality standards, architectural patterns, and best practices for the RsyncProcess Swift Package. It serves as a reference for developers working with this codebase.

1. Architecture

1.1 Actor Isolation Pattern

text
@MainActor
└── RsyncProcess (UI-safe)
    └── StreamAccumulator (Actor for thread-safe accumulation)
Purpose:

@MainActor ensures UI safety and prevents data races
Actor (StreamAccumulator) manages concurrent access to shared mutable state
Separation of concerns between process orchestration and data accumulation
1.2 Error Handling Hierarchy

swift
public enum RsyncProcessError: Error, LocalizedError {
    case executableNotFound(String)
    case processFailed(exitCode: Int32, errors: [String])
    case processCancelled
    case timeout(TimeInterval)
    case invalidState(ProcessState)
}
Key Principles:

All errors are typed and provide localized descriptions
Errors are composable and can be propagated through async boundaries
Each error case includes relevant contextual information
2. Thread Safety

2.1 Sendable Compliance

swift
// All types are designed to be Sendable-safe:
// - Actors (StreamAccumulator) are Sendable by definition
// - Value types (ProcessState) are Sendable
// - Reference types marked @MainActor are Sendable when isolated to MainActor
Critical Rules:

Never access @MainActor isolated properties from non-isolated contexts
Use Task { @MainActor } to bridge non-isolated to MainActor contexts
Ensure all cross-actor communication uses await for suspension points
2.2 State Machine Pattern

swift
public enum ProcessState: CustomStringConvertible {
    case idle
    case running
    case cancelling
    case terminating
    case terminated(exitCode: Int32)
    case failed(Error)
}
Benefits:

Prevents invalid state transitions
Makes state changes explicit and observable
Enables comprehensive logging and debugging
3. Memory Management

3.1 Reference Cycles Prevention

swift
outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
    // Always use weak self in async callbacks
    Task { @MainActor [weak self] in
        guard let self else { return }
        // Strong reference only within Task scope
    }
}
Rules:

Use [weak self] in all closure-based callbacks
Capture self strongly only within bounded async scopes
Clear all strong references in cleanup methods
3.2 Resource Cleanup

swift
private func cleanupProcess() {
    timeoutTimer?.invalidate()
    timeoutTimer = nil
    currentProcess = nil
}

nonisolated deinit {
    Task { @MainActor in
        await self.performDeinitCleanup()
    }
}
Cleanup Sequence:

Invalidate timers
Terminate running processes
Nil out strong references
Schedule MainActor cleanup from deinit
4. Error Prevention Patterns

4.1 Precondition Checking

swift
public init(arguments: [String], /* ... */) {
    precondition(!arguments.isEmpty, "Arguments cannot be empty")
    // Early failure for invalid configurations
}
When to use:

Parameter validation in initializers
State invariants that should never be violated
Development-time assertions (removed in release builds)
4.2 State Validation

swift
public func executeProcess() throws {
    guard case .idle = state else {
        throw RsyncProcessError.invalidState(state)
    }
    // Proceed only from valid state
}
4.3 Defensive Programming

swift
private func handleOutputData(_ text: String) async {
    guard !cancelled, !errorOccurred else { return }
    // Early exit on invalid states
}
5. Performance Considerations

5.1 Streaming Optimization

swift
actor StreamAccumulator {
    private var partialLine: String = ""
    
    func consume(_ text: String) -> [String] {
        // Efficient line buffering without multiple allocations
        var buffer = partialLine
        // Process character by character for proper newline handling
        for char in text { /* ... */ }
    }
}
Optimizations:

Single string buffer for partial lines
Character-by-character processing for precise newline detection
Minimal allocations during streaming
5.2 Pipe Handling Strategy

swift
private func setupPipeHandlers(outputPipe: Pipe, errorPipe: Pipe) {
    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }  // Early exit
        
        Task { @MainActor [weak self] in
            // Process only if still needed
            guard let self, !self.cancelled, !self.errorOccurred else { return }
        }
    }
}
Key Points:

Check for empty data before processing
Early exit from handlers when process is cancelled/errored
Async processing to avoid blocking pipe reading
6. Testing Strategy

6.1 Unit Test Coverage Areas

StreamAccumulator

Line buffering with partial lines
Newline handling (\n, \r\n)
Thread safety under concurrent access
RsyncProcess

State transitions
Error propagation
Cancellation behavior
Timeout handling
Integration Tests

Real rsync process execution
Pipe handling and streaming
Memory management under load
6.2 Testability Patterns

swift
// Make internal types accessible for testing
#if DEBUG
extension RsyncProcess {
    var testAccumulator: StreamAccumulator { accumulator }
    var testCurrentState: ProcessState { state }
}
#endif
7. Code Style & Consistency

7.1 Naming Conventions

Types: PascalCase (e.g., RsyncProcess, StreamAccumulator)
Variables: camelCase (e.g., currentProcess, timeoutInterval)
Constants: camelCase for instance constants
Enums: Cases use camelCase (e.g., .processCancelled)
7.2 Documentation Standards

swift
/// Single-line summary
///
/// Detailed description with markdown support.
/// 
/// - Parameters:
///   - name: Description with **emphasis**
///   - timeout: Optional parameter description
/// - Returns: Description of return value
/// - Throws: List of possible errors
/// - Note: Important implementation notes
/// - Warning: Critical warnings for callers
/// - Important: Key considerations
/// - Example: Code examples if helpful
7.3 Logging Strategy

swift
Logger.process.debugMessageOnly("RsyncProcess: Action with context")
Logger.process.debugThreadOnly("RsyncProcess: Thread-sensitive debug")
Log Categories:

Process lifecycle events
State transitions
Error conditions
Performance metrics (optional)
Debug information (compile-time conditional)
8. Security Considerations

8.1 Input Validation

swift
// Validate executable path
guard FileManager.default.isExecutableFile(atPath: executablePath) else {
    throw RsyncProcessError.executableNotFound(executablePath)
}

// Validate arguments
precondition(!arguments.isEmpty, "Arguments cannot be empty")
8.2 Process Isolation

Rsync runs as subprocess with no elevated privileges
Environment variables are explicitly set or inherited
Process termination ensures no orphaned processes
9. Maintenance Guidelines

9.1 Code Review Checklist

Thread safety violations
Memory leaks or strong reference cycles
Error handling completeness
State transition correctness
Sendable compliance
Documentation accuracy
Test coverage for new paths
9.2 Breaking Changes Protocol

Major Version: API changes, removals
Minor Version: New features, backward-compatible
Patch Version: Bug fixes, internal improvements
9.3 Deprecation Strategy

swift
@available(*, deprecated, message: "Use newMethod instead")
public func oldMethod() { /* ... */ }
10. Future Improvements Roadmap

10.1 Short-term (Next Release)

Add comprehensive unit tests
Implement process pooling for concurrent executions
Add performance benchmarks
10.2 Medium-term

Support for async/await result API
Configurable logging levels
Enhanced progress reporting
10.3 Long-term

Plugin system for output parsing
Cross-platform improvements
Integration with Swift Concurrency structured concurrency
11. Common Pitfalls & Solutions

11.1 Race Conditions

Problem: Termination handler racing with readability handlers
Solution: Use serial dispatch queue for termination sequencing

11.2 Memory Leaks

Problem: Strong reference cycles in pipe handlers
Solution: Always use [weak self] and guard statements

11.3 Thread Safety Violations

Problem: Accessing MainActor properties from wrong context
Solution: Use Task { @MainActor } for cross-context access

12. Performance Metrics

12.1 Key Metrics to Monitor

Memory Usage: Peak during large file transfers
CPU Utilization: During pipe processing
Response Time: From execute to first output
Throughput: Lines processed per second
12.2 Optimization Targets

Stream processing should add <1ms overhead per MB
Memory growth should be O(1) with stream size
Cancellation should complete within 100ms
This document is maintained alongside the codebase. Update it when architectural changes are made.
Can you make it in one complete markdown document
RsyncProcess Swift Package - Code Quality Document

1. Overview

1.1 Purpose

This document defines the code quality standards, architectural patterns, and best practices for the RsyncProcess Swift Package. It serves as a comprehensive reference for development, maintenance, and code review.

1.2 Scope

Architectural patterns and design decisions
Thread safety and concurrency models
Error handling and state management
Memory management and resource cleanup
Testing and documentation standards
Performance considerations
Security guidelines
2. Architecture

2.1 Actor Isolation Pattern

The package uses a hybrid actor model for optimal thread safety and UI integration:

text
@MainActor (UI-safe isolation)
└── RsyncProcess (Process orchestration)
    └── StreamAccumulator (Actor for thread-safe data accumulation)
Design Rationale:

@MainActor isolation on RsyncProcess ensures safe integration with UI code
Actor (StreamAccumulator) manages concurrent access to mutable state without blocking MainActor
Separation of concerns between process control and data processing
2.2 Error Handling Hierarchy

swift
public enum RsyncProcessError: Error, LocalizedError {
    case executableNotFound(String)
    case processFailed(exitCode: Int32, errors: [String])
    case processCancelled
    case timeout(TimeInterval)
    case invalidState(ProcessState)
}
Key Principles:

Typed errors: All possible failure modes are explicitly enumerated
Localization: All errors provide user-friendly descriptions via LocalizedError
Contextual information: Errors include relevant data (paths, exit codes, timeouts)
Composability: Errors can be propagated through async/await boundaries
2.3 State Machine Pattern

swift
public enum ProcessState: CustomStringConvertible {
    case idle
    case running
    case cancelling
    case terminating
    case terminated(exitCode: Int32)
    case failed(Error)
}
Benefits:

Predictable transitions: State changes follow defined paths
Thread safety: State enum is a value type (Sendable)
Debuggability: Explicit states simplify logging and debugging
Validation: Invalid operations can be prevented based on current state
3. Thread Safety & Concurrency

3.1 Sendable Compliance Strategy

Component	Sendable Status	Isolation	Notes
RsyncProcess	✅	@MainActor	MainActor-isolated types are Sendable
StreamAccumulator	✅	actor	Actors are Sendable by definition
ProcessState	✅	Value type	Pure Swift enum with Sendable associated values
Timer	❌	MainActor-only	Must only be accessed from MainActor
3.2 Critical Thread Safety Rules

MainActor Access Rule: Never access @MainActor isolated properties from non-isolated contexts
Cross-Actor Communication: Always use await for suspension points when calling actor methods
Timer Safety: Timer instances must only be created and invalidated on MainActor
Closure Captures: Always use [weak self] in closure-based callbacks to prevent cycles
3.3 Safe Cross-Context Patterns

swift
// Pattern 1: Non-isolated to MainActor
nonisolated deinit {
    Task { @MainActor in
        await self.performDeinitCleanup()
    }
}

// Pattern 2: Closure handler to MainActor
outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
    Task { @MainActor [weak self] in
        guard let self else { return }
        // Safe MainActor access here
    }
}

// Pattern 3: Actor method call
private func handleOutputData(_ text: String) async {
    let lines = await accumulator.consume(text)  // Suspends properly
}
4. Memory Management

4.1 Reference Cycle Prevention

Problem: Pipe readability handlers can create strong reference cycles

Solution: Four-layer protection strategy:

swift
private func setupPipeHandlers(outputPipe: Pipe, errorPipe: Pipe) {
    // Layer 1: Weak capture in closure
    outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
        
        // Layer 2: Early exit on empty data
        let data = handle.availableData
        guard !data.isEmpty else { return }
        
        // Layer 3: Weak capture in async Task
        Task { @MainActor [weak self] in
            
            // Layer 4: Guard statement in task
            guard let self else { return }
            
            // Safe processing with strong reference
            await self.handleOutputData(text)
        }
    }
}
4.2 Resource Cleanup Protocol

Cleanup Sequence (must follow this order):

Stop callbacks: Set pipe readability handlers to nil
Terminate process: Call process.terminate() if running
Invalidate timers: Call timer?.invalidate() on MainActor
Clear references: Set currentProcess = nil, timeoutTimer = nil
Reset state: Update state = .idle or appropriate terminal state
Implementation:

swift
private func cleanupProcess() {
    // Must be called from MainActor
    timeoutTimer?.invalidate()
    timeoutTimer = nil
    currentProcess = nil
}

nonisolated deinit {
    // Schedule cleanup on MainActor
    Task { @MainActor in
        await self.performDeinitCleanup()
    }
}

@MainActor
private func performDeinitCleanup() async {
    if let process = currentProcess, process.isRunning {
        process.terminate()
        Logger.process.debugMessageOnly("Process terminated in deinit")
    }
    timeoutTimer?.invalidate()
}
4.3 Reusability Pattern

The class supports multiple executions through proper reset:

swift
public func executeProcess() throws {
    // 1. State validation
    guard case .idle = state else { /* throw error */ }
    
    // 2. Reset all mutable state
    cancelled = false
    errorOccurred = false
    state = .running
    accumulator = StreamAccumulator()  // Fresh instance
    
    // 3. Execute new process
    // ...
}
5. Error Prevention & Validation

5.1 Precondition Checking

Use preconditions for development-time assertions:

swift
public init(arguments: [String], /* ... */) {
    // Fail fast during development
    precondition(!arguments.isEmpty, "Arguments cannot be empty")
    
    if let rsyncPath = handlers.rsyncPath {
        precondition(!rsyncPath.isEmpty, 
                    "Rsync path cannot be empty if provided")
    }
    
    // Initialize properties...
}
When to use preconditions:

Parameter validation in initializers
State invariants that should never be violated
Development and testing builds only (removed in release)
5.2 State Validation

Validate state before operations:

swift
public func executeProcess() throws {
    // Prevent invalid state transitions
    guard case .idle = state else {
        throw RsyncProcessError.invalidState(state)
    }
    
    // Proceed with execution...
}
5.3 Defensive Programming

Early exit patterns:

swift
private func handleOutputData(_ text: String) async {
    // Multiple early exit checks
    guard !cancelled, !errorOccurred else { return }
    
    let lines = await accumulator.consume(text)
    guard !lines.isEmpty else { return }
    
    for line in lines {
        // Re-check for each line
        if cancelled || errorOccurred { break }
        await processOutputLine(line)
    }
}
6. Performance Optimization

6.1 Streaming Efficiency

StreamAccumulator optimizations:

swift
actor StreamAccumulator {
    private var partialLine: String = ""
    
    func consume(_ text: String) -> [String] {
        var lines: [String] = []
        var buffer = partialLine  // Start with existing partial
        
        // Character-by-character processing for precise control
        for char in text {
            if char == "\n" {
                // Handle both \r\n and \n line endings
                if buffer.hasSuffix("\r") {
                    buffer.removeLast()
                }
                if !buffer.isEmpty {
                    lines.append(buffer)
                }
                buffer = ""
            } else {
                buffer.append(char)
            }
        }
        
        partialLine = buffer  // Store remaining partial
        self.lines.append(contentsOf: lines)
        return lines
    }
}
Optimization Benefits:

Minimal allocations: Single buffer reused across calls
Efficient newline handling: Works with both Unix and Windows line endings
Zero-copy for complete lines: Lines returned directly without copying
6.2 Pipe Handling Strategy

Efficient pipe data processing:

swift
outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
    let data = handle.availableData
    
    // Quick checks before async dispatch
    guard !data.isEmpty else { return }
    guard let text = String(data: data, encoding: .utf8) else { return }
    guard !text.isEmpty else { return }
    
    // Only then dispatch to MainActor
    Task { @MainActor [weak self] in
        // Additional state checks
        guard let self, !self.cancelled else { return }
        await self.handleOutputData(text)
    }
}
6.3 Performance Targets

Metric	Target	Measurement
Memory overhead	< 1 MB baseline	Measure with Instruments
Processing latency	< 10ms per 1KB chunk	Time from pipe read to handler
Cancellation response	< 100ms	Time from cancel() to termination
Throughput	> 10,000 lines/second	Benchmark with synthetic data
7. Testing Strategy

7.1 Unit Test Coverage Areas

7.1.1 StreamAccumulator Tests

swift
// Test 1: Line buffering
func testPartialLineBuffering() async {
    let accumulator = StreamAccumulator()
    let lines1 = await accumulator.consume("partial")
    XCTAssertEqual(lines1, [])  // No complete lines
    
    let lines2 = await accumulator.consume(" line\n")
    XCTAssertEqual(lines2, ["partial line"])
}

// Test 2: Newline variants
func testNewlineVariants() async {
    let accumulator = StreamAccumulator()
    let text = "line1\r\nline2\nline3\r\n"
    let lines = await accumulator.consume(text)
    XCTAssertEqual(lines, ["line1", "line2", "line3"])
}

// Test 3: Thread safety (concurrent access)
func testConcurrentAccess() async {
    let accumulator = StreamAccumulator()
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<100 {
            group.addTask {
                await accumulator.consume("line \(i)\n")
            }
        }
    }
    let snapshot = await accumulator.snapshot()
    XCTAssertEqual(snapshot.count, 100)
}
7.1.2 RsyncProcess State Tests

swift
// Test 1: State transitions
func testValidStateTransitions() {
    let process = makeTestProcess()
    
    // idle → running
    try process.executeProcess()
    XCTAssertEqual(process.currentState, .running)
    
    // running → cancelling → terminated
    process.cancel()
    // Wait for termination...
}

// Test 2: Invalid operations
func testExecuteFromNonIdleState() {
    let process = makeTestProcess()
    try process.executeProcess()
    
    // Should throw when already running
    XCTAssertThrowsError(try process.executeProcess()) { error in
        XCTAssertTrue(error is RsyncProcessError)
    }
}
7.1.3 Error Propagation Tests

swift
// Test 1: Executable not found
func testExecutableNotFound() {
    let handlers = ProcessHandlers(rsyncPath: "/invalid/path/rsync")
    let process = RsyncProcess(arguments: ["-v"], handlers: handlers)
    
    XCTAssertThrowsError(try process.executeProcess()) { error in
        guard case .executableNotFound = error as? RsyncProcessError else {
            XCTFail("Wrong error type")
            return
        }
    }
}

// Test 2: Process failure exit code
func testProcessFailedError() async {
    // Mock process that returns non-zero exit code
    // Verify error propagation through handlers
}
7.2 Integration Test Strategy

7.2.1 Real Rsync Execution

swift
// Test with actual rsync command (requires rsync in PATH)
func testRealRsyncExecution() async throws {
    let handlers = ProcessHandlers(
        processTermination: { output, _ in
            XCTAssertFalse(output?.isEmpty ?? true)
        },
        // ... other handlers
    )
    
    let process = RsyncProcess(
        arguments: ["--version"],
        handlers: handlers
    )
    
    try process.executeProcess()
    
    // Wait for completion with timeout
    let completed = await waitForCompletion(process, timeout: 5)
    XCTAssertTrue(completed)
    XCTAssertEqual(process.terminationStatus, 0)
}
7.2.2 Performance Tests

swift
// Test 1: Memory usage under load
func testMemoryUsageDuringLargeTransfer() {
    measureMetrics([.memory], automaticallyStartMeasuring: true) {
        // Generate large synthetic output
        let process = makeLargeOutputProcess()
        try? process.executeProcess()
        
        // Wait for processing to complete
        stopMeasuring()
    }
}

// Test 2: Cancellation responsiveness
func testCancellationResponseTime() {
    let process = makeLongRunningProcess()
    try? process.executeProcess()
    
    let startTime = Date()
    process.cancel()
    
    // Wait for cancellation to complete
    let responseTime = Date().timeIntervalSince(startTime)
    XCTAssertLessThan(responseTime, 0.1)  // < 100ms
}
7.3 Test Utilities

swift
#if DEBUG
// Internal test accessors
extension RsyncProcess {
    nonisolated var testAccumulator: StreamAccumulator {
        get async { await accumulator }
    }
    
    nonisolated var testCurrentState: ProcessState {
        get async { await currentState }
    }
}

// Mock Process for testing
class MockProcess: Process {
    var mockIsRunning = false
    var mockTerminationStatus: Int32 = 0
    var mockProcessIdentifier: Int32 = 12345
    
    override var isRunning: Bool { mockIsRunning }
    override var terminationStatus: Int32 { mockTerminationStatus }
    override var processIdentifier: Int32 { mockProcessIdentifier }
    
    override func terminate() {
        mockIsRunning = false
        mockTerminationStatus = -1
        // Simulate termination handler
        terminationHandler?(self)
    }
}
#endif
7.4 Continuous Integration

GitHub Actions Workflow:

yaml
name: RsyncProcess Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - name: Build and Test
        run: |
          swift build
          swift test --parallel --sanitize=thread
          swift test --parallel -c release
Test Categories:

Unit Tests: Fast, isolated, no external dependencies
Integration Tests: Requires rsync, runs in CI only
Performance Tests: Benchmarked against targets
Thread Sanitizer: Always run with TSAN enabled
8. Code Style & Consistency

8.1 Naming Conventions

Element	Convention	Examples
Types	PascalCase	RsyncProcess, StreamAccumulator
Variables	camelCase	currentProcess, timeoutInterval
Constants	camelCase (instance)	arguments, hiddenID
Enum cases	camelCase	.processCancelled, .executableNotFound
Actor methods	camelCase (async)	consume(), flushTrailing()
Private methods	camelCase (leading underscore optional)	setupPipeHandlers, _internalHelper
8.2 Documentation Standards

8.2.1 Public API Documentation

swift
/// Single-line summary ending with period.
///
/// Detailed description explaining purpose, behavior, and key considerations.
/// Use markdown for **emphasis** and `code` snippets.
///
/// - Parameters:
///   - arguments: Array of command-line arguments to pass to rsync.
///     Each argument should be a separate string.
///   - hiddenID: Optional identifier passed through to termination handler.
///     Useful for correlating multiple processes.
///   - handlers: Configuration for all process callbacks and behaviors.
///   - timeout: Optional timeout in seconds. Process will be terminated
///     if it exceeds this duration. Defaults to `nil` (no timeout).
///
/// - Returns: Nothing (`Void`), or describe return value.
///
/// - Throws: `RsyncProcessError.executableNotFound` if rsync path is invalid.
///           `RsyncProcessError.invalidState` if process is not idle.
///
/// - Note: This method is `@MainActor` isolated for UI safety.
///
/// - Important: Call `cancel()` to terminate a running process.
///
/// - Warning: Do not call `executeProcess()` multiple times concurrently.
///
/// ## Example
/// ```swift
/// let process = RsyncProcess(arguments: ["-av", "source/", "dest/"])
/// try process.executeProcess()
/// ```
public init(
    arguments: [String],
    hiddenID: Int? = nil,
    handlers: ProcessHandlers,
    useFileHandler: Bool = false,
    timeout: TimeInterval? = nil
) { /* ... */ }
8.2.2 Internal Documentation

swift
// Brief comment for simple methods
private func logProcessStart(_ process: Process) {
    guard let path = process.executableURL else { return }
    Logger.process.debugMessageOnly("Starting: \(path)")
}

/// Detailed comment for complex logic
///
/// Handles the final stage of process termination, including:
/// 1. Processing any remaining pipe data
/// 2. Flushing partial lines from accumulator
/// 3. Determining termination reason (success, failure, cancellation)
/// 4. Calling appropriate handlers
///
/// - Parameters:
///   - finalOutputData: Any data remaining in stdout pipe
///   - finalErrorData: Any data remaining in stderr pipe
///   - task: The terminated Process instance
private func processFinalOutput(
    finalOutputData: Data,
    finalErrorData: Data,
    task: Process
) async { /* ... */ }
8.3 Logging Strategy

Logging Levels and Categories:

swift
extension Logger {
    private static let subsystem = "com.yourapp.rsync"
    
    static let process = Logger(subsystem: subsystem, category: "process")
    static let accumulator = Logger(subsystem: subsystem, category: "accumulator")
    static let performance = Logger(subsystem: subsystem, category: "performance")
}

// Usage patterns:
Logger.process.debugMessageOnly("RsyncProcess: Starting execution")
Logger.process.debugThreadOnly("RsyncProcess: Thread context debug")
Logger.performance.info("Process completed in \(duration)s")
When to log:

✅ Process lifecycle events (start, termination, cancellation)
✅ State transitions
✅ Error conditions with context
✅ Performance metrics (compile-time conditional)
✅ Debug information during development
When NOT to log:

❌ Inside tight loops (use sampling)
❌ Sensitive data (paths, filenames in production)
❌ High-frequency events without rate limiting
9. Security Considerations

9.1 Input Validation

Executable Path Validation:

swift
let executablePath = handlers.rsyncPath ?? "/usr/bin/rsync"

// 1. Check file exists and is executable
guard FileManager.default.isExecutableFile(atPath: executablePath) else {
    throw RsyncProcessError.executableNotFound(executablePath)
}

// 2. Additional security checks (optional)
if handlers.enforceSecurity {
    // Check path is within allowed directories
    // Verify binary signature
    // Validate permissions
}
Argument Sanitization:

swift
// Consider adding argument validation if needed
private func validateArguments(_ arguments: [String]) throws {
    guard !arguments.contains("--daemon") else {
        throw RsyncProcessError.processFailed(
            exitCode: -1,
            errors: ["Daemon mode not allowed"]
        )
    }
    
    // Add other security restrictions as needed
}
9.2 Process Isolation

Security Measures:

No elevated privileges: Rsync runs with same permissions as host app
Controlled environment: Environment variables can be restricted
Resource limits: Consider adding memory/CPU limits for untrusted sources
Timeout enforcement: Prevents hanging processes
Environment Variable Control:

swift
// Default environment (secure)
let defaultEnvironment = [
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "HOME": NSHomeDirectory(),
    // Remove potentially dangerous variables
    // "SSH_AUTH_SOCK": nil,  // Explicitly excluded
]

process.environment = handlers.environment ?? defaultEnvironment
10. Maintenance Guidelines

10.1 Code Review Checklist

Architecture & Design

Proper actor isolation (@MainActor, actor)
No thread safety violations
Appropriate error handling hierarchy
State machine completeness and correctness
Sendable compliance for all types
Memory Management

No strong reference cycles in closures
Proper weak/unowned capture usage
Resource cleanup in all code paths
No leaks in deinit/cleanup methods
Error Handling

All errors are properly typed and localized
Error propagation through async boundaries
Appropriate use of throws, Result, or completion handlers
Error recovery or cleanup on failure
Performance

Efficient data structures for expected workloads
Minimal allocations in hot paths
Early exit patterns for invalid states
Appropriate use of inout vs copy
Testing

Unit tests for core logic
Integration tests for real scenarios
Edge case coverage (cancellation, timeout, errors)
Performance tests for critical paths
10.2 Breaking Changes Protocol

Versioning Strategy:

MAJOR (X.0.0): Breaking API changes, removals
MINOR (0.X.0): New features, backward-compatible
PATCH (0.0.X): Bug fixes, internal improvements
Deprecation Process:

swift
// Step 1: Mark as deprecated with guidance
@available(*, deprecated, message: "Use execute() with timeout parameter instead")
public func executeProcess() throws { /* ... */ }

// Step 2: Provide alternative API
public func execute(timeout: TimeInterval? = nil) async throws -> ProcessResult {
    // New implementation
}

// Step 3: Remove in next major version (with migration guide)
Migration Guides:

Include in README.md
Provide code examples for common migration paths
List automated migration tools if available
10.3 Dependency Management

Swift Version Compatibility:

swift
// Package.swift
let package = Package(
    name: "RsyncProcess",
    platforms: [
        .macOS(.v12),      // Minimum supported
        .iOS(.v15),        // If cross-platform
    ],
    products: [/* ... */],
    dependencies: [
        // Keep minimal dependencies
    ],
    targets: [/* ... */]
)
Third-party Dependencies:

❌ Avoid unless absolutely necessary
✅ Use Swift system libraries when possible
✅ Vendor small, stable dependencies if needed
✅ Document all dependencies and their purposes
11. Common Pitfalls & Solutions

11.1 Race Conditions

Problem 1: Termination handler racing with readability handlers

Solution: Serial dispatch queue for termination sequencing

swift
private func setupTerminationHandler(process: Process, outputPipe: Pipe, errorPipe: Pipe) {
    let terminationQueue = DispatchQueue(
        label: "com.rsync.process.termination",
        qos: .userInitiated
    )
    
    process.terminationHandler = { [weak self] task in
        terminationQueue.async {
            // 1. Stop handlers first
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            
            // 2. Read remaining data
            let finalOutputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            
            // 3. Process on MainActor
            Task { @MainActor [weak self] in
                await self?.processFinalOutput(/* ... */)
            }
        }
    }
}
Problem 2: Concurrent access to accumulator state

Solution: Actor isolation ensures serialized access

swift
actor StreamAccumulator {
    // All state mutations are isolated to actor
    func consume(_ text: String) -> [String] {
        // Guaranteed serial execution
    }
}
11.2 Memory Leaks

Problem: Strong reference cycles in pipe handlers

Solution: Multi-layer weak reference strategy

swift
outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
    // Layer 1: Weak in outer closure
    Task { @MainActor [weak self] in
        // Layer 2: Weak in async task
        guard let self else { return }
        // Layer 3: Guard statement
    }
}
Problem: Retaining Process after termination

Solution: Explicit cleanup in termination handler

swift
private func handleTermination(task: Process) async {
    defer {
        cleanupProcess()  // Clear all references
    }
    // ... termination logic
}
11.3 Thread Safety Violations

Problem: Accessing MainActor properties from wrong context

Solution: Always use Task { @MainActor } for cross-context access

swift
// WRONG - Compiler error
nonisolated func someMethod() {
    let state = self.state  // ❌ Cannot access MainActor property
}

// CORRECT
nonisolated func someMethod() {
    Task { @MainActor in
        let state = self.state  // ✅ Safe on MainActor
    }
}
Problem: Timer accessed from non-MainActor context

Solution: Isolate all timer operations to MainActor

swift
@MainActor
private func startTimeoutTimer() {
    // Timer must be created on MainActor
    timeoutTimer = Timer.scheduledTimer(/* ... */)
}

@MainActor  
private func cleanupProcess() {
    // Timer must be invalidated on MainActor
    timeoutTimer?.invalidate()
}
11.4 Error Handling Gaps

Problem: Silent failures in async callbacks

Solution: Structured concurrency with error propagation

swift
private func processOutputLine(_ line: String) async {
    do {
        try handlers.checkLineForError(line)
    } catch {
        // Immediately propagate and stop processing
        errorOccurred = true
        currentProcess?.terminate()
        handlers.propagateError(error)
    }
}
Problem: Lost errors during cancellation

Solution: Prioritize error handling in termination

swift
private func handleTermination(task: Process) async {
    // Priority 1: Cancellation
    if cancelled {
        handlers.propagateError(RsyncProcessError.processCancelled)
        return
    }
    
    // Priority 2: Output processing errors
    if errorOccurred {
        // Already propagated
        return
    }
    
    // Priority 3: Exit code errors
    if task.terminationStatus != 0 {
        let error = RsyncProcessError.processFailed(/* ... */)
        handlers.propagateError(error)
    }
}
12. Performance Metrics & Benchmarks

12.1 Key Performance Indicators (KPIs)

Metric	Target	Measurement Method	Acceptable Range
Memory Usage	< 5 MB baseline	Instruments Allocations	0-10 MB
Peak Memory	< 50 MB under load	Instruments Memory Graph	0-100 MB
Startup Latency	< 50ms to first output	Date.timeIntervalSince	0-100ms
Processing Throughput	> 10K lines/sec	Synthetic benchmark	5K-50K lines/sec
Cancellation Time	< 100ms	Measurement from cancel()	0-200ms
Pipe Read Latency	< 1ms per 1KB	ContinuousClock	0-5ms
CPU Utilization	< 5% per process	Instruments CPU	0-10%
12.2 Benchmarking Strategy

12.2.1 Synthetic Load Test

swift
func benchmarkThroughput() async throws {
    // Generate synthetic rsync-like output
    let lineCount = 100_000
    let testData = (0..<lineCount).map {
        "file\($0).txt sent 1024 bytes  speedup 1.0\n"
    }.joined()
    
    let process = RsyncProcess(arguments: ["--benchmark"])
    
    let startTime = ContinuousClock.now
    
    // Simulate processing
    for chunk in testData.chunked(by: 1024) {
        await process.simulateOutput(chunk)
    }
    
    let endTime = ContinuousClock.now
    let duration = endTime - startTime
    let linesPerSecond = Double(lineCount) / duration.seconds
    
    print("Throughput: \(linesPerSecond) lines/sec")
}
12.2.2 Memory Profiling Test

swift
func testMemoryGrowth() {
    autoreleasepool {
        let process = RsyncProcess(arguments: /* ... */)
        
        // Track memory before
        let startMemory = report_memory()
        
        // Process large dataset
        for _ in 0..<1000 {
            process.processLargeChunk()
        }
        
        // Track memory after
        let endMemory = report_memory()
        let growth = endMemory - startMemory
        
        XCTAssertLessThan(growth, 10 * 1024 * 1024) // < 10MB growth
    }
}
12.3 Performance Optimization Targets

Target 1: Reduce Allocations in Hot Paths

swift
// BEFORE: Multiple allocations per line
func processLine(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.components(separatedBy: " ")
    // ... multiple allocations
}

// AFTER: Reuse buffers, in-place processing
actor StreamAccumulator {
    private var buffer = ""
    
    func consume(_ text: String) -> [String] {
        buffer.append(text)  // In-place append
        // Process in buffer, extract complete lines
        let lines = extractCompleteLines(from: &buffer)
        return lines
    }
}
Target 2: Minimize MainActor Contention

swift
// BEFORE: All processing on MainActor
private func handleOutputData(_ text: String) async {
    // Heavy processing blocks MainActor
    let result = processHeavily(text)
    await updateUI(result)
}

// AFTER: Offload to actor, then update MainActor
private func handleOutputData(_ text: String) async {
    // Process on accumulator actor
    let lines = await accumulator.consume(text)
    
    // Only update UI on MainActor
    await MainActor.run {
        updateUI(with: lines)
    }
}
Target 3: Efficient Pipe Reading

swift
// Read in optimal chunk sizes
outputPipe.fileHandleForReading.readabilityHandler = { handle in
    // Experiment with chunk sizes for optimal performance
    let chunkSize = 4096  // Common page size
    let data = handle.readData(ofLength: chunkSize)
    
    // Process if we have enough data
    if data.count >= 1024 || data.isEmpty {
        processChunk(data)
    }
}
12.4 Continuous Performance Monitoring

GitHub Actions Performance Workflow:

yaml
name: Performance Benchmarks
on:
  schedule:
    - cron: '0 0 * * 0'  # Weekly
  push:
    branches: [main]

jobs:
  benchmark:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run Benchmarks
        run: |
          swift run --configuration release BenchmarkTool \
            --iterations 100 \
            --output benchmark.json
      - name: Upload Results
        uses: actions/upload-artifact@v3
        with:
          name: benchmark-results
          path: benchmark.json
Performance Regression Detection:

swift
// In CI pipeline
func detectPerformanceRegression(current: BenchmarkResults, 
                                baseline: BenchmarkResults) -> Bool {
    let regressionThreshold = 0.10  // 10% degradation
    
    for (metric, currentValue) in current.metrics {
        guard let baselineValue = baseline.metrics[metric] else { continue }
        
        let degradation = (currentValue - baselineValue) / baselineValue
        if degradation > regressionThreshold {
            print("⚠️ Performance regression in \(metric): \(degradation * 100)%")
            return true
        }
    }
    
    return false
}
13. Future Improvements Roadmap

13.1 Short-term (Next 1-2 Releases)

13.1.1 Enhanced Async/Await API

swift
// Current: Callback-based
process.executeProcess { result in
    switch result {
    case .success(let output):
        // Handle success
    case .failure(let error):
        // Handle error
    }
}

// Proposed: Async/await
public extension RsyncProcess {
    func execute() async throws -> ProcessResult {
        // Returns structured result with output and metadata
    }
}
13.1.2 Process Pooling

swift
actor ProcessPool {
    private var availableProcesses: [RsyncProcess] = []
    private var maxConcurrent: Int
    
    func execute(arguments: [String]) async throws -> ProcessResult {
        // Reuse or create process
        // Manage concurrent execution limits
    }
}
13.1.3 Progress Reporting

swift
public struct ProgressUpdate: Sendable {
    let filesTransferred: Int
    let bytesTransferred: Int64
    let totalBytes: Int64?
    let currentFile: String?
}

public extension RsyncProcess {
    var progress: AsyncStream<ProgressUpdate> {
        // Stream progress updates from rsync output
    }
}
13.2 Medium-term (Next 3-6 Months)

13.2.1 Cross-platform Support

swift
#if os(macOS)
let defaultRsyncPath = "/usr/bin/rsync"
#elseif os(Linux)
let defaultRsyncPath = "/usr/bin/rsync"
#elseif os(Windows)
let defaultRsyncPath = "C:\\Program Files\\rsync\\rsync.exe"
#endif
13.2.2 Configuration Presets

swift
public struct RsyncConfiguration: Sendable {
    let arguments: [String]
    let timeout: TimeInterval?
    let retryCount: Int
    let bandwidthLimit: Int?  // KB/s
    
    static var backup: RsyncConfiguration {
        RsyncConfiguration(
            arguments: ["-av", "--delete", "--progress"],
            timeout: 3600,
            retryCount: 3
        )
    }
}
13.2.3 Plugin System

swift
protocol OutputParserPlugin: Sendable {
    func parse(line: String) -> ParsedLine?
}

public extension RsyncProcess {
    func register(plugin: OutputParserPlugin) {
        // Allow custom output parsing
    }
}
13.3 Long-term (6+ Months)

13.3.1 Advanced Monitoring

swift
public struct ProcessMetrics: Sendable {
    let cpuUsage: Double
    let memoryUsage: Int64
    let ioReadBytes: Int64
    let ioWriteBytes: Int64
}

public extension RsyncProcess {
    var metrics: AsyncStream<ProcessMetrics> {
        // Real-time process metrics
    }
}
13.3.2 Distributed Execution

swift
protocol RsyncCluster {
    func executeOnNode(_ arguments: [String], 
                       node: NodeIdentifier) async throws -> ProcessResult
}

public class DistributedRsyncProcess {
    // Execute rsync across multiple nodes
    // Load balancing and failover
}
13.3.3 Advanced Error Recovery

swift
public enum RecoveryStrategy {
    case retry(maxAttempts: Int)
    case fallback(to: [String])
    case partialContinue(skipErrors: Bool)
}

public extension RsyncProcess {
    func executeWithRecovery(strategy: RecoveryStrategy) async throws -> ProcessResult {
        // Automatic error recovery based on strategy
    }
}
14. Appendices

14.1 Glossary

Term	Definition
Actor	Swift concurrency primitive for managing mutable state
MainActor	Special actor that executes on the main thread
Sendable	Type that can be safely passed across concurrency domains
Pipe	Unidirectional inter-process communication channel
Process	Foundation class for executing subprocesses
StreamAccumulator	Actor that accumulates and processes output streams
ProcessState	Enum representing the lifecycle state of a process
14.2 Decision Records

Decision 1: Actor vs DispatchQueue

Chosen: Swift Actors
Reason: Built-in compiler checking, better integration with Swift concurrency
Alternative considered: DispatchQueue with locks
Decision 2: MainActor isolation

Chosen: Isolate entire RsyncProcess to MainActor
Reason: UI safety, simpler integration with AppKit/UIKit
Alternative considered: Non-isolated with explicit MainActor dispatch
Decision 3: Error handling approach

Chosen: Throwing functions + typed errors
Reason: Swift-native, works well with async/await
Alternative considered: Result type or completion handlers
14.3 External References

Swift Concurrency Documentation
Actor Isolation in Swift
Foundation Process Documentation
Rsync Manual
This document is maintained alongside the codebase. Update it when architectural changes, new patterns, or significant refactorings occur. Last updated: $(date)


