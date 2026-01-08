# Code Quality Guidelines

This document outlines the code quality standards, best practices, and conventions for the RsyncProcessStreaming Swift package.

## Table of Contents
- [Overview](#overview)
- [Code Standards](#code-standards)
- [Architecture Principles](#architecture-principles)
- [Concurrency and Thread Safety](#concurrency-and-thread-safety)
- [Error Handling](#error-handling)
- [Testing Requirements](#testing-requirements)
- [Documentation Standards](#documentation-standards)
- [Performance Guidelines](#performance-guidelines)
- [Code Review Checklist](#code-review-checklist)
- [Tooling and Automation](#tooling-and-automation)

## Overview

RsyncProcessStreaming is a Swift 6.2+ package designed for macOS 14+ that provides real-time streaming of rsync process output with minimal memory overhead and comprehensive error handling. Code quality is paramount for reliability in production environments.

### Quality Goals
- **Reliability**: Zero data loss during stream processing
- **Safety**: Strong concurrency guarantees using Swift 6 features
- **Performance**: Low memory footprint with efficient streaming
- **Maintainability**: Clear, documented, testable code
- **Compatibility**: Stable API surface for downstream consumers

## Code Standards

### Swift Language Version
- **Minimum**: Swift 6.2
- **Target platform**: macOS 14.0+
- **Language mode**: Swift 6 with strict concurrency checking enabled

### Naming Conventions

#### Types
- Use descriptive PascalCase names: `RsyncProcess`, `StreamAccumulator`, `ProcessHandlers`
- Prefix errors with context: `RsyncProcessError`
- Actors should have descriptive names indicating their isolation domain

#### Functions and Variables
- Use camelCase: `executeProcess()`, `currentProcess`, `lineCounter`
- Boolean properties should read naturally: `isRunning`, `isCancelledState`, `useFileHandler`
- Private properties should be clearly marked with `private`
- Avoid abbreviations unless universally understood (e.g., `rsync`, `ID`)

#### Constants
- Use descriptive names: `executablePath`, not `path`
- Environment keys should be clear: `environment`, `rsyncPath`

### Code Organization

#### File Structure
```
Sources/
  RsyncProcessStreaming/
    RsyncProcessStreaming.swift      # Main process orchestration
    ProcessHandlers.swift             # Handler configuration
    Internal/                         # Implementation details
      PackageLogger.swift             # Logging utilities
      ThreadUtils.swift               # Thread diagnostics
```

#### Within Files
1. Import statements
2. Type declarations (errors, structs, classes)
3. Initialization
4. Public API
5. Private implementation details
6. Extensions (in separate file or clearly marked)

### SwiftLint Integration

The project uses SwiftLint with specific rules:

#### Disabled Rules (with justification)
- `line_length`: Disabled at file level where long descriptive names or URLs are needed
- `function_parameter_count`: Disabled for `ProcessHandlers` which requires comprehensive configuration

#### Enforcement Priority
- **Critical**: Force unwrapping, implicitly unwrapped optionals
- **High**: Retain cycles, memory leaks, data races
- **Medium**: Naming conventions, line length
- **Low**: Whitespace, formatting (handled by formatter)

## Architecture Principles

### Separation of Concerns

#### RsyncProcess (MainActor-isolated)
- **Responsibility**: Process lifecycle management
- **Isolation**: MainActor for UI integration safety
- **State**: Owns `Process` instance and cancellation state
- **Does NOT**: Parse rsync output or implement business logic

#### StreamAccumulator (Actor)
- **Responsibility**: Thread-safe line accumulation
- **Isolation**: Custom actor for concurrent access
- **State**: Output buffers, error buffers, counters
- **Does NOT**: Invoke callbacks or manage process lifecycle

#### ProcessHandlers (Struct)
- **Responsibility**: Configuration and callback routing
- **Pattern**: Dependency injection of all external behaviors
- **Immutability**: Sendable struct with function references
- **Does NOT**: Maintain state

### Dependency Injection

All external behaviors are injected via `ProcessHandlers`:
```swift
public struct ProcessHandlers: @unchecked Sendable {
    let processTermination: ([String]?, Int?) -> Void
    let fileHandler: (Int) -> Void
    let checkLineForError: (String) throws -> Void
    let propagateError: (Error) -> Void
    // ... etc
}
```

**Benefits**:
- Testability: Mock all external dependencies
- Flexibility: Configure behavior without modifying core code
- Isolation: No hidden coupling to application code

### Actor Isolation Strategy

#### When to Use MainActor
- UI-bound state (process running status)
- Callbacks that update UI elements
- Process lifecycle operations (`cancel()`, `executeProcess()`)

#### When to Use Custom Actors
- Shared mutable state accessed from multiple contexts (`StreamAccumulator`)
- Performance-critical accumulation that shouldn't block main thread

#### When to Use @unchecked Sendable
- Only for `ProcessHandlers` where all members are known-safe function references
- Must document why unchecked is necessary (closures are Sendable-by-capture)

## Concurrency and Thread Safety

### Swift 6 Concurrency Model

#### Data Race Prevention
- **Never** use unprotected shared mutable state
- **Always** use `actor` or `MainActor` for mutable state
- **Verify** Sendable conformance for types crossing isolation boundaries

#### Best Practices

##### Weak Self in Closures
```swift
outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
    guard let self else { return }
    // ...
}
```
**Rationale**: Prevents retain cycles between process and pipe handlers

##### Task Creation
```swift
Task { @MainActor [weak self] in
    guard let self else { return }
    await handleOutputData(text)
}
```
**Rationale**: Explicit actor context and lifecycle management

##### Actor Method Calls
```swift
let newLines = await accumulator.consume(text)
```
**Rationale**: Enforced suspension points prevent data races

### Synchronization Patterns

#### Pipe Handler Race Conditions
```swift
// Give brief moment for in-flight readability handlers to complete
try? await Task.sleep(for: .milliseconds(50))
```
**Why**: Termination handler can fire before final readability callbacks
**Alternative**: Not acceptable to lose trailing output
**Trade-off**: 50ms delay acceptable for data completeness

#### Actor Message Ordering
- Actor methods execute in arrival order
- `consume()` before `flushTrailing()` guarantees correct line boundaries
- `snapshot()` returns consistent view of accumulated state

## Error Handling

### Error Types

#### RsyncProcessError Enum
```swift
public enum RsyncProcessError: Error, LocalizedError {
    case executableNotFound(String)
    case processFailed(exitCode: Int32, errors: [String])
    case processCancelled
}
```

#### Error Context Requirements
- **Always** include relevant diagnostic information
- **Never** throw generic errors without context
- **Prefer** domain-specific error types over `NSError`

### Error Propagation

#### Synchronous Errors
```swift
guard FileManager.default.isExecutableFile(atPath: executablePath) else {
    throw RsyncProcessError.executableNotFound(executablePath)
}
```
**Pattern**: Throw immediately for precondition failures

#### Asynchronous Errors
```swift
handlers.propagateError(error)
```
**Pattern**: Inject error handler to avoid crossing actor boundaries

#### Per-Line Error Checking
```swift
try handlers.checkLineForError(line)
```
**Pattern**: Early error detection before process completes

### Error Recovery

#### No Automatic Retry
- Caller decides retry strategy
- Package provides error details for informed decisions
- Idempotent operations are caller's responsibility

#### Resource Cleanup
```swift
outputPipe.fileHandleForReading.readabilityHandler = nil
errorPipe.fileHandleForReading.readabilityHandler = nil
```
**Required**: Always clean up handlers in termination path

### Error Logging

Use structured logging for diagnostics:
```swift
Logger.process.debugMessageOnly("RsyncProcessStreaming: Process cancelled")
```

**Guidelines**:
- Log at appropriate levels (debug, info, error)
- Include context (process ID, line numbers)
- Never log sensitive data (file contents, credentials)

## Testing Requirements

### Test Coverage Goals
- **Critical paths**: 100% (process lifecycle, error handling)
- **Happy paths**: 100% (successful execution, streaming)
- **Edge cases**: >90% (cancellation, partial lines, stderr)
- **Overall target**: >85% line coverage

### Testing Patterns

#### Unit Tests
- Test isolated components (actors, utilities)
- Mock all external dependencies
- Use Swift Testing framework

```swift
@Test func testStreamAccumulatorLineBreaking() async {
    let accumulator = StreamAccumulator()
    let lines = await accumulator.consume("line1\nline2\n")
    #expect(lines.count == 2)
}
```

#### Integration Tests
- Test full process execution with real rsync
- Verify handler callbacks fire correctly
- Test cancellation during execution

```swift
@Test func testProcessExecutionWithRealRsync() async throws {
    var terminated = false
    let handlers = ProcessHandlers(
        processTermination: { _, _ in terminated = true },
        // ... other handlers
    )
    let process = RsyncProcess(arguments: ["--version"], handlers: handlers)
    try process.executeProcess()
    // Wait and verify termination
}
```

#### Edge Case Tests
- Empty output
- Output without newlines
- Stderr-only output
- Cancellation at various execution points
- Process failures with non-zero exit codes

### Test Organization
```
Tests/
  RsyncProcessStreamingTests/
    RsyncProcessStreamingTests.swift    # Integration tests
    StreamAccumulatorTests.swift         # Unit tests (if separated)
    ProcessHandlersTests.swift           # Configuration tests
```

### Mocking Strategy

#### Process Handler Mocks
```swift
var capturedOutput: [String]?
let handlers = ProcessHandlers(
    processTermination: { output, _ in capturedOutput = output },
    fileHandler: { _ in },
    // ... minimal implementation
)
```

#### File System Mocks
- Use temporary directories for test files
- Clean up in teardown
- Never depend on system-wide state

## Documentation Standards

### Public API Documentation

#### Required Elements
1. Summary (one line)
2. Detailed description
3. Parameter documentation
4. Return value documentation
5. Throws documentation
6. Example usage (for complex APIs)

#### Example
```swift
/// Executes the rsync process with configured arguments and streams output.
///
/// Validates the rsync executable exists, spawns the process, and sets up
/// real-time streaming handlers for stdout and stderr. The process runs
/// asynchronously with callbacks fired via the configured `ProcessHandlers`.
///
/// - Throws: `RsyncProcessError.executableNotFound` if rsync is not found at the configured path
/// - Note: This method is MainActor-isolated for safe UI integration
/// - Important: Call `cancel()` to terminate a running process before deallocation
public func executeProcess() throws {
    // ...
}
```

### Code Comments

#### When to Comment
- **Always**: Complex algorithms or non-obvious logic
- **Often**: Actor isolation reasoning
- **Sometimes**: Business logic context
- **Never**: Obvious code that reads clearly

#### Comment Style
```swift
// Give a brief moment for any in-flight readability handler callbacks to complete
// This ensures we don't race with pending data processing
try? await Task.sleep(for: .milliseconds(50))
```

**Good**: Explains WHY and the problem being solved
**Bad**: "Sleep for 50ms" (just repeats code)

### README Synchronization
- Keep [README.md](README.md) in sync with public API
- Update examples when API changes
- Document breaking changes prominently

## Performance Guidelines

### Memory Management

#### Streaming vs Buffering
- **Do**: Stream line-by-line with accumulation
- **Don't**: Buffer entire output before processing
- **Why**: Large rsync outputs can exceed available memory

#### Resource Lifecycle
```swift
// Setup
let outputPipe = Pipe()
process.standardOutput = outputPipe

// Teardown
outputPipe.fileHandleForReading.readabilityHandler = nil
```
**Critical**: Always remove handlers to prevent memory leaks

### CPU Efficiency

#### Avoid Repeated Work
```swift
// Good: Filter once during split
let newLines = parts.dropLast().filter { !$0.isEmpty }

// Bad: Filter same array multiple times
let parts = combined.components(separatedBy: .newlines)
let filtered = parts.filter { !$0.isEmpty }
let dropped = filtered.dropLast()
```

#### Prefer Built-in Operations
- Use `components(separatedBy:)` over manual parsing
- Use `filter` and `map` over explicit loops
- Trust Foundation types for performance

### Concurrency Overhead

#### Actor Contention
- `StreamAccumulator` methods are intentionally lightweight
- Minimize work inside actor methods
- Move heavy processing outside isolated regions

#### Task Creation Cost
- Acceptable for pipe handlers (low frequency relative to data volume)
- Avoid creating tasks in tight loops

## Code Review Checklist

### Before Submitting PR

#### Functionality
- [ ] Feature works as described
- [ ] Edge cases handled
- [ ] Error paths tested
- [ ] No regressions in existing features

#### Code Quality
- [ ] Follows naming conventions
- [ ] Appropriate access levels (public/internal/private)
- [ ] No force unwrapping (`!`) without documented safety justification
- [ ] No `@unchecked Sendable` without documented reasoning
- [ ] SwiftLint passes with no new warnings

#### Concurrency Safety
- [ ] Actor isolation appropriate
- [ ] No data races (Swift 6 strict checking passes)
- [ ] Weak self used in closures where appropriate
- [ ] No blocking operations on MainActor

#### Documentation
- [ ] Public API fully documented
- [ ] Complex logic commented
- [ ] README updated if needed
- [ ] Breaking changes noted in changelog

#### Testing
- [ ] Unit tests added for new logic
- [ ] Integration tests updated if behavior changed
- [ ] All tests pass locally
- [ ] Test coverage maintained or improved

### During Review

#### Questions to Ask
1. Is this the simplest solution that works?
2. Are there hidden dependencies or coupling?
3. How does this fail? Is failure handled gracefully?
4. Could this cause data races or deadlocks?
5. Is the API intuitive for consumers?
6. What's the performance impact?

#### Red Flags
- ⚠️ `@unchecked Sendable` on types with mutable state
- ⚠️ Blocking operations (synchronous file I/O, sleep on MainActor)
- ⚠️ Force unwrapping without documented invariant
- ⚠️ Retain cycles in closures
- ⚠️ Missing error handling
- ⚠️ Undefined behavior on cancellation

## Tooling and Automation

### Build System
- **Swift Package Manager**: Official dependency management
- **Xcode**: Primary development environment
- **Command line**: `swift build`, `swift test` for CI

### Static Analysis
- **SwiftLint**: Enforces style and catches common issues
- **Swift 6 compiler**: Data race detection via strict concurrency checking
- **Format**: Consider [swift-format](https://github.com/apple/swift-format) for consistency

### Continuous Integration

#### Required CI Checks
1. Build succeeds on macOS 14+
2. All tests pass
3. SwiftLint passes
4. Documentation builds (if generating docs)
5. Test coverage meets threshold (>85%)

#### Recommended CI Pipeline
```yaml
# Example GitHub Actions
- name: Build
  run: swift build
  
- name: Run Tests
  run: swift test -v
  
- name: SwiftLint
  run: swiftlint lint --strict
```

### Local Development Setup

#### Prerequisites
```bash
# Install SwiftLint
brew install swiftlint

# Verify Swift version
swift --version  # Should be 6.2+
```

#### Pre-commit Hooks (Recommended)
```bash
#!/bin/sh
# .git/hooks/pre-commit
swiftlint lint --quiet
if [ $? -ne 0 ]; then
    echo "SwiftLint failed. Please fix warnings before committing."
    exit 1
fi
```

### Release Process

#### Version Numbering
- **Major**: Breaking API changes
- **Minor**: New features, backward compatible
- **Patch**: Bug fixes only

#### Pre-release Checklist
- [ ] All tests pass
- [ ] README updated
- [ ] CHANGELOG updated
- [ ] Version bumped in Package.swift
- [ ] Documentation generated and reviewed
- [ ] Breaking changes documented
- [ ] Migration guide prepared (if major version)

#### Tagging
```bash
git tag -a v1.2.3 -m "Release 1.2.3"
git push origin v1.2.3
```

## Maintenance Philosophy

### Technical Debt
- **Track it**: Document TODOs with context
- **Prioritize it**: Address in planning cycles
- **Don't ignore it**: Small debts become large ones

### Deprecation Policy
1. Announce deprecation in release notes
2. Provide migration path in documentation
3. Mark API with `@available(*, deprecated)`
4. Remove in next major version (minimum 1 release later)

### Backward Compatibility
- **Preserve** public API across minor versions
- **Extend** via new methods rather than changing signatures
- **Deprecate** before removing

### Dependencies
- **Minimize**: Prefer Foundation and standard library
- **Audit**: Review dependency security and maintenance
- **Pin**: Use exact versions in Package.resolved for reproducibility

---

## Summary

Quality in RsyncProcessStreaming means:
1. **Correctness**: No data loss, no races, predictable behavior
2. **Clarity**: Code that reads like documentation
3. **Completeness**: Comprehensive tests and docs
4. **Compatibility**: Stable, well-versioned API
5. **Performance**: Efficient use of memory and CPU

Every contribution should strengthen these pillars. When in doubt, favor simplicity, safety, and clear communication over cleverness or premature optimization.

**Questions or suggestions?** Open an issue to discuss code quality improvements.
