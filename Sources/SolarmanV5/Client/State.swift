// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

import Synchronization

// MARK: - SequenceNumberGenerator

/// Thread-safe sequence number generator for V5 protocol.
///
/// Generates sequential IDs from 1 to 65535, wrapping around.
/// ID 0 is skipped per V5 protocol convention.
public final class SequenceNumberGenerator: Sendable {
    // MARK: Lifecycle

    public init() {
        _counter = Mutex(0)
    }

    // MARK: Public

    /// Generates the next sequence number (1-65535).
    public func next() -> UInt16 {
        _counter.withLock { counter in
            counter = counter &+ 1
            if counter == 0 {
                counter = 1 // Skip 0
            }
            return counter
        }
    }

    /// Resets the counter (for testing).
    public func reset() {
        _counter.withLock { $0 = 0 }
    }

    // MARK: Private

    private let _counter: Mutex<UInt16>
}
