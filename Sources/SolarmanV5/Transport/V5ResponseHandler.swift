// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

import NIOConcurrencyHelpers
import NIOCore

// MARK: - V5ResponseHandler

/// Handler that accumulates V5 responses for async retrieval.
///
/// **Thread Safety:**
/// Uses `EventLoopPromise` instead of raw `CheckedContinuation` to prevent race conditions.
/// This pattern is recommended by SwiftNIO developers for bridging channel handlers to async/await.
///
/// **Security Considerations:**
/// - Promise can only be completed once (prevents double-resume crashes)
/// - No buffering of unsolicited responses (prevents memory exhaustion)
/// - All state access protected by NIOLock
///
/// Reference: ModbusKit's ModbusResponseHandler pattern
final class V5ResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    // MARK: Internal

    typealias InboundIn = [UInt8]
    typealias InboundOut = Never

    func channelRead(context _: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        lock.lock()
        if let promise = pendingPromise {
            pendingPromise = nil
            lock.unlock()
            promise.succeed(frame)
        } else {
            lock.unlock()
            // No pending request — discard unsolicited response
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        lock.lock()
        if let promise = pendingPromise {
            pendingPromise = nil
            lock.unlock()
            promise.fail(error)
        } else {
            lock.unlock()
        }
        context.close(promise: nil)
    }

    func channelInactive(context _: ChannelHandlerContext) {
        lock.lock()
        if let promise = pendingPromise {
            pendingPromise = nil
            lock.unlock()
            promise.fail(SolarmanClientError.channelClosed)
        } else {
            lock.unlock()
        }
    }

    /// Waits for the next response using EventLoopPromise.
    ///
    /// Safe against race conditions because EventLoopPromise:
    /// - Is created synchronously before any async suspension
    /// - Can only be completed once (NIO enforces this)
    /// - Handles the case where response arrives before await
    ///
    /// **Cancellation Support:**
    /// Uses `withTaskCancellationHandler` to fail the promise when the Task is cancelled.
    /// This prevents promise leaks when timeout occurs in the calling code.
    ///
    /// - Parameter eventLoop: The channel's event loop
    /// - Returns: Raw response bytes
    /// - Throws: Error if response fails, channel closes, or task is cancelled
    func waitForResponse(on eventLoop: EventLoop) async throws -> [UInt8] {
        let promise = eventLoop.makePromise(of: [UInt8].self)

        lock.lock()
        pendingPromise = promise
        lock.unlock()

        return try await withTaskCancellationHandler {
            try await promise.futureResult.get()
        } onCancel: {
            // Fail promise on cancellation to prevent leaks
            // This runs synchronously on cancellation, safe because promise.fail is thread-safe
            lock.lock()
            pendingPromise = nil
            lock.unlock()
            // Always fail the promise we created - it's safe to call fail multiple times
            // (NIO will ignore subsequent calls)
            promise.fail(CancellationError())
        }
    }

    // MARK: Private

    private var pendingPromise: EventLoopPromise<[UInt8]>?
    private let lock = NIOLock()
}
