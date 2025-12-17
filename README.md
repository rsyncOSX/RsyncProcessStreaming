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
    environment: nil,
    printLine: { line in print("line: \(line)") }
)

let process = RsyncProcess(arguments: ["--version"], handlers: handlers, useFileHandler: false)
try process.executeProcess()
```

## Integration Notes
- Module name: `RsyncProcessStreaming`. If migrating from `RsyncProcess`, swap the import and reuse existing handler builders.
- `executeProcess()` now delivers stdout incrementally and only keeps the accumulated lines needed for completion.
- For UI-bound callbacks, `printLine`, `fileHandler`, and `processTermination` are dispatched on the main actor.

## Testing
A small actor-level test is included in `RsyncProcessStreamingTests` validating the streaming splitter.
