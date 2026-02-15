//
//  AsyncSemaphore.swift
//  EncameraCore
//
//  Created for concurrency limiting in async contexts.
//

import Foundation

/// A cooperative async semaphore that limits concurrent access without blocking threads.
public actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) { self.count = value }

    public func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    public func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }
}
