//
//  ThreadUtils.swift
//  RsyncProcess
//
//  Created by Thomas Evensen on 12/11/2025.
//

import Foundation

extension Thread {
    nonisolated static var isMain: Bool { isMainThread }
    nonisolated static var currentThread: Thread { Thread.current }

    nonisolated static func checkIsMainThread() -> Bool {
        Thread.isMainThread
    }
}
