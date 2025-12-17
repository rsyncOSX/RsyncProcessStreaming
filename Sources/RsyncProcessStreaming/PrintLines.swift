//
//  PrintLines.swift
//  RsyncProcess
//
//  Created by Thomas Evensen on 12/11/2025.
//

import Foundation
import Observation

@Observable
public final class PrintLines {
    @MainActor public static let shared = PrintLines()

    // Observable storage of output lines
    public var output: [String] = []

    // The single function you asked to make observable
    public func appendLine(_ line: String) {
        output.append(line)
    }

    /// Clear captured output
    public func clear() {
        output.removeAll()
    }

    public init(output: [String] = []) {
        self.output = output
    }
}
