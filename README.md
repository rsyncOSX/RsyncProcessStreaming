
# RsyncProcessStreaming
RsyncProcessStreaming is a Swift package for executing `rsync` while streaming stdout and stderr in real time. It keeps memory usage low, surfaces errors quickly, and mirrors the handler-oriented API used in RsyncUI.

## Purpose
Provide a robust, handler-driven interface to run `rsync` with live output streaming, error-aware processing, cancellation, and optional timeout control—ideal for responsive CLIs and UIs.

## Core Capabilities
- **Live line-by-line streaming**: Streams stdout incrementally and preserves partial lines until complete, enabling responsive UIs and progress indicators.
- **Error-aware processing**: Captures stderr separately and lets clients enforce custom error detection per line before the process completes.
- **Rolling accumulation**: Maintains an in-memory rolling buffer of all output without requiring full buffering before callbacks fire.
- **Resource-safe lifecycle**: Starts, monitors, cancels, and cleans up `Process` instances without leaking pipe handlers.
- **Configurable environment**: Supports custom `rsync` paths and environment variables to match user installations.

## Installation
### Swift Package Manager (remote)
Add the package to your `Package.swift` dependencies:

```swift
dependencies: [
  .package(url: "https://github.com/<your-org>/RsyncProcessStreaming.git", from: "0.1.0")
]
```

Then add `RsyncProcessStreaming` to your target:

```swift
targets: [
  .target(
    name: "YourApp",
    dependencies: [
      .product(name: "RsyncProcessStreaming", package: "RsyncProcessStreaming")
    ]
  )
]
```

### Local checkout
If you have the repo locally, you can add it as a local package in Xcode or reference it via a relative path in a workspace.

## Supported Platforms
- macOS 14+

## Quick Start
Here's a minimal example to sync two directories with live progress:

```swift
import RsyncProcessStreaming

@MainActor
func syncFolders() async throws {
    let handlers = ProcessHandlers(
        processTermination: { output, _ in
            if let lines = output {
                print("✓ Sync completed with \(lines.count) output lines")
            }
        },
        fileHandler: { count in
            print("📦 Processed \(count) files...")
        },
        rsyncPath: "/usr/bin/rsync",
        checkLineForError: { line in
            // Detect rsync errors in real time
            if line.contains("rsync error:") || line.contains("failed:") {
                throw RsyncProcessError.processFailed(exitCode: 1, errors: [line])
            }
        },
        updateProcess: { process in
            if let pid = process?.processIdentifier {
                print("🚀 Process started with PID: \(pid)")
            }
        },
        propagateError: { error in
            print("❌ Error: \(error.localizedDescription)")
        },
        checkForErrorInRsyncOutput: true,
        environment: nil
    )
    
    let process = RsyncProcess(
        arguments: ["-av", "--progress", "~/source/", "~/destination/"],
        handlers: handlers,
        useFileHandler: true,
        timeout: 60
    )
    
    try process.executeProcess()
}

// Usage
Task { @MainActor in
    try await syncFolders()
}
```

**Key Points:**
- Set `useFileHandler: true` to get per-line progress callbacks.
- Use `checkLineForError` to abort on custom error patterns.
- `timeout` ensures runaway processes terminate automatically.
- All output is accumulated and delivered to `processTermination`.

## Public API Highlights
- **`RsyncProcess`** ([Sources/RsyncProcessStreaming/RsyncProcessStreaming.swift](Sources/RsyncProcessStreaming/RsyncProcessStreaming.swift))
  - `init(arguments:hiddenID:handlers:useFileHandler:timeout:)` wires rsync arguments with a user-provided handler set and optional timeout.
  - `executeProcess()` validates the executable, spawns the process, wires streaming handlers, and begins collection.
  - `cancel()` terminates a running process, marking it as cancelled for downstream handling.
  - State surfaces via `isRunning` and `isCancelled` to simplify UI binding.
  - Convenience surfaces: `currentState`, `commandDescription`, `processIdentifier`, `terminationStatus`.

- **`ProcessHandlers`** ([Sources/RsyncProcessStreaming/ProcessHandlers.swift](Sources/RsyncProcessStreaming/ProcessHandlers.swift))
  - Callbacks for termination, per-file counting, process updates, error propagation, and per-line error checks.
  - Configuration knobs for rsync path, rsync v3 compatibility, stderr checking, and environment.
  - `withOutputCapture(...)` convenience builder for common setups.

- **`StreamAccumulator`** (internal) ([Sources/RsyncProcessStreaming/Internal/StreamAccumulator.swift](Sources/RsyncProcessStreaming/Internal/StreamAccumulator.swift))
  - Actor that splits incoming text into lines, preserves trailing partials, and counts lines for progress callbacks.
  - Retains both stdout and stderr snapshots for post-run inspection.

- **Logging utilities** ([Sources/RsyncProcessStreaming/Internal/PackageLogger.swift](Sources/RsyncProcessStreaming/Internal/PackageLogger.swift))
  - `Logger.process` category with debug-only helpers for command and thread diagnostics.

## Execution Flow
1. **Setup**: Build `ProcessHandlers` to define callbacks and configure rsync path/version/environment.
2. **Start**: Instantiate `RsyncProcess` and call `executeProcess()`; validation guards against missing executables.
3. **Streaming**: `AsyncStream` readers feed stdout/stderr into `StreamAccumulator`, emitting lines to callbacks immediately.
4. **Error detection**: Custom `checkLineForError` can abort early; stderr content is recorded for termination review.
5. **Termination**: Final buffers flush, `processTermination` fires with accumulated stdout and optional hidden ID, and `updateProcess(nil)` clears state.
6. **Cancellation**: `cancel()` stops the underlying process and propagates `processCancelled` to consumers.

## Error Model
- **`executableNotFound`**: rsync path fails executability check.
- **`processFailed`**: Non-zero exit combined with collected stderr when `checkForErrorInRsyncOutput` is enabled.
- **`processCancelled`**: User-requested cancellation path.
- **`timeout`**: Process terminated after exceeding configured `timeout` interval.
- Errors propagate through `propagateError` for centralized handling.

## Configuration and Extensibility
- **Rsync location**: Override via `rsyncPath` to support custom installs or sandboxed environments.
- **Environment**: Supply `environment` to mirror user shells or inject required variables.
- **Version flags**: `rsyncVersion3` allows downstream callers to tailor behavior for legacy rsync output patterns.
- **File progress**: Enable `useFileHandler` to receive per-line counts for UI progress or telemetry.

## Testing and Quality
- Unit and integration tests live in [Tests/RsyncProcessStreamingTests](Tests/RsyncProcessStreamingTests) using Swift Testing to cover line splitting, termination callbacks, cancellation, and error detection hooks.
- Code quality practices are tracked in [CODE_QUALITY.md](CODE_QUALITY.md) with concurrency, error handling, and testing notes.

## Example Usage
```swift
import RsyncProcessStreaming

let handlers = ProcessHandlers.withOutputCapture(
    processTermination: { output, hiddenID in
        print("Completed", hiddenID ?? -1)
        print(output ?? [])
    },
    fileHandler: { count in print("Lines processed: \(count)") },
    rsyncPath: "/usr/bin/rsync",
    checkLineForError: { line in
        if line.contains("rsync error:") {
            throw RsyncProcessError.processFailed(exitCode: 1, errors: [line])
        }
    },
    updateProcess: { _ in },
    propagateError: { error in print("Error: \(error)") },
    logger: { _, _ in },
    checkForErrorInRsyncOutput: true,
    rsyncVersion3: true,
    environment: nil
)

let process = RsyncProcess(arguments: ["--version"], handlers: handlers, useFileHandler: false, timeout: 5)
try process.executeProcess()
```

## When to Use This Package
- Building Swift clients that need responsive, real-time rsync output (CLI or UI).
- Integrating with RsyncUI-compatible handler signatures.
- Minimizing memory footprint while still retaining full stdout/stderr history.
- Implementing cancellable, error-aware rsync workflows with Swift concurrency.

## Build & Test
Use the provided VS Code tasks or `xcrun` directly:

```bash
# Build
xcrun swift build

# Run tests (verbose)
xcrun swift test -v
```
