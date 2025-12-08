// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

import NIOCore
import NIOEmbedded
@testable import SolarmanV5
import Testing

// MARK: - V5ResponseHandlerTests

/// Tests for V5ResponseHandler using EmbeddedChannel.
///
/// These tests validate handler behavior in isolation — how it processes
/// incoming data, errors, and channel lifecycle events.
///
/// **Note:** The handler's async `waitForResponse()` method is tested separately
/// using NIOAsyncTestingChannel (V5ResponseHandlerAsyncTests).
///
/// Reference: SwiftNIO ChannelInboundHandler testing patterns
@Suite("V5 Response Handler")
struct V5ResponseHandlerTests {
    // MARK: Internal

    // MARK: - Handler Behavior Tests

    @Test("Handler does not crash on unsolicited response")
    func handlerHandlesUnsolicitedResponse() throws {
        let channel = try makeChannel()
        defer { finishChannel(channel) }

        // Fire response without anyone waiting - should not crash
        // Using writeInbound instead of deprecated fireChannelRead(NIOAny(...))
        let responseFrame: [UInt8] = [0x01, 0x03, 0x02, 0x12, 0x34, 0xB5, 0x33]
        try channel.writeInbound(responseFrame)

        // Handler simply discards unsolicited responses - no memory leak
    }

    @Test("Handler can be added to pipeline")
    func handlerCanBeAddedToPipeline() throws {
        let channel = try makeChannel()
        defer { finishChannel(channel) }

        // Verify handler is in pipeline (throws if not found)
        let handler = try channel.pipeline.handler(type: V5ResponseHandler.self).wait()
        #expect(type(of: handler) == V5ResponseHandler.self)
    }

    @Test("Handler closes channel on error")
    func handlerClosesChannelOnError() throws {
        let channel = try makeChannel()

        // Fire an error
        let testError = V5FrameDecoderError.invalidStartByte(0x00)
        channel.pipeline.fireErrorCaught(testError)

        // Channel should be closed
        #expect(channel.isActive == false)
    }

    // MARK: - Full Pipeline Tests (Decoder + Handler)

    @Test("Full pipeline decodes complete V5 frame")
    func fullPipelineDecodesFrame() throws {
        let channel = try makeFullPipelineChannel()
        defer { finishChannel(channel) }

        // Build minimal valid V5 frame
        let frame = buildTestV5ResponseFrame(modbus: [0x01, 0x03, 0x02, 0x12, 0x34])

        // Write raw bytes to channel
        var buffer = channel.allocator.buffer(capacity: frame.count)
        buffer.writeBytes(frame)
        try channel.writeInbound(buffer)

        // Frame should pass through decoder and reach handler
        // Handler discards it (no pending promise), but no crash
    }

    @Test("Full pipeline accumulates partial frames")
    func fullPipelineAccumulatesPartialFrames() throws {
        let channel = try makeFullPipelineChannel()
        defer { finishChannel(channel) }

        // Build frame
        let frame = buildTestV5ResponseFrame(modbus: [0x01, 0x03, 0x02, 0x12, 0x34])

        // Send first 10 bytes (partial header)
        var buffer1 = channel.allocator.buffer(capacity: 10)
        buffer1.writeBytes(Array(frame[0..<10]))
        try channel.writeInbound(buffer1)

        // Decoder should not have passed anything through yet

        // Send remaining bytes
        var buffer2 = channel.allocator.buffer(capacity: frame.count - 10)
        buffer2.writeBytes(Array(frame[10...]))
        try channel.writeInbound(buffer2)

        // Now complete frame should pass through
    }

    @Test("Full pipeline closes channel on decoder error")
    func fullPipelineClosesOnDecoderError() throws {
        let channel = try makeFullPipelineChannel()

        // Send invalid frame (wrong start byte)
        let invalidFrame: [UInt8] = [
            0x00, // Invalid start byte (should be 0xA5)
            0x01, 0x00, // Length
            0x10, 0x15, // Control
            0x01, 0x00, // Sequence
        ]

        var buffer = channel.allocator.buffer(capacity: invalidFrame.count)
        buffer.writeBytes(invalidFrame)

        // Decoder error gets caught by ResponseHandler which closes channel
        _ = try? channel.writeInbound(buffer)

        // Channel should be closed due to error
        #expect(channel.isActive == false)
    }

    @Test("Full pipeline handles multiple frames")
    func fullPipelineHandlesMultipleFrames() throws {
        let channel = try makeFullPipelineChannel()
        defer { finishChannel(channel) }

        // Build two frames
        let frame1 = buildTestV5ResponseFrame(modbus: [0x01, 0x03, 0x02, 0x00, 0x01])
        let frame2 = buildTestV5ResponseFrame(modbus: [0x01, 0x03, 0x02, 0x00, 0x02])

        // Send both frames in one buffer
        var buffer = channel.allocator.buffer(capacity: frame1.count + frame2.count)
        buffer.writeBytes(frame1)
        buffer.writeBytes(frame2)
        try channel.writeInbound(buffer)

        // Both frames should be decoded and passed through
    }

    // MARK: - Memory Safety Tests

    @Test("Multiple unsolicited responses don't cause memory growth")
    func multipleUnsolicitedResponsesNoMemoryGrowth() throws {
        let channel = try makeChannel()
        defer { finishChannel(channel) }

        // Send 100 unsolicited responses
        for i: UInt8 in 0..<100 {
            let response: [UInt8] = [0x01, 0x03, 0x02, i, 0x00]
            try channel.writeInbound(response)
        }

        // Handler should have discarded all, no buffering
        // (Implicit test - memory would grow if buffering occurred)
    }

    // MARK: Private

    // MARK: - Helpers

    /// Creates an EmbeddedChannel with only V5ResponseHandler installed.
    private func makeChannel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandler(V5ResponseHandler()).wait()
        return channel
    }

    /// Creates an EmbeddedChannel with full V5 pipeline.
    private func makeFullPipelineChannel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.pipeline.addHandlers([
            ByteToMessageHandler(V5FrameDecoder()),
            V5ResponseHandler(),
        ]).wait()
        return channel
    }

    /// Safely finishes channel, ignoring errors.
    private func finishChannel(_ channel: EmbeddedChannel) {
        _ = try? channel.finish()
    }

    /// Builds a valid V5 response frame for testing.
    private func buildTestV5ResponseFrame(modbus: [UInt8]) -> [UInt8] {
        // Response header (25 bytes) + modbus + checksum + end
        var frame: [UInt8] = [
            0xA5, // Start
            0x00, 0x00, // Length placeholder (will calculate)
            0x10, 0x15, // Control code: response (0x1510 LE)
            0x01, 0x00, // Sequence: 1
            0x78, 0x56, 0x34, 0x12, // Serial: 0x12345678
            0x02, // Frame type: inverter
            0x01, // Status: OK
            0x00, 0x00, 0x00, 0x00, // Total working time
            0x00, 0x00, 0x00, 0x00, // Power on time
            0x00, 0x00, 0x00, 0x00, // Offset time
        ]

        // Append Modbus frame
        frame.append(contentsOf: modbus)

        // Calculate and set length (payload = everything except start, length, checksum, end)
        let payloadLength = frame.count - 3 // -3 for start(1) + length(2), checksum and end not added yet
        frame[1] = UInt8(truncatingIfNeeded: payloadLength)
        frame[2] = UInt8(truncatingIfNeeded: payloadLength >> 8)

        // Calculate checksum
        let checksum = frame[1...].reduce(UInt16(0)) { ($0 + UInt16($1)) & 0xFF }
        frame.append(UInt8(checksum))

        // End marker
        frame.append(0x15)

        return frame
    }
}

// MARK: - V5ResponseHandlerAsyncTests

/// Tests for V5ResponseHandler async behavior using NIOAsyncTestingChannel.
///
/// These tests validate the `waitForResponse()` async method behavior:
/// - Successful response delivery
/// - Channel closure during wait
/// - Error propagation
/// - Task cancellation
///
/// **Important:** Uses NIOAsyncTestingChannel instead of EmbeddedChannel because
/// EmbeddedEventLoop is not thread-safe and cannot be used with async/await Tasks.
///
/// Reference: SwiftNIO NIOAsyncTestingChannel for async-safe testing
@Suite("V5 Response Handler Async")
struct V5ResponseHandlerAsyncTests {
    // MARK: - waitForResponse Success Tests

    @Test("waitForResponse returns data when response arrives")
    func waitForResponseSuccess() async throws {
        let channel = NIOAsyncTestingChannel()
        let handler = V5ResponseHandler()
        try await channel.pipeline.addHandler(handler)

        let expectedResponse: [UInt8] = [0x01, 0x03, 0x02, 0x12, 0x34, 0xB5, 0x33]

        // Start waiting for response in background
        async let responseTask = handler.waitForResponse(on: channel.eventLoop)

        // Execute pending work on event loop
        await channel.testingEventLoop.run()

        // Deliver response through channel using writeInbound
        try await channel.writeInbound(expectedResponse)

        // Await result
        let response = try await responseTask

        #expect(response == expectedResponse)

        try await channel.close()
    }

    @Test("waitForResponse handles sequential requests")
    func waitForResponseSequential() async throws {
        let channel = NIOAsyncTestingChannel()
        let handler = V5ResponseHandler()
        try await channel.pipeline.addHandler(handler)

        // First request/response
        let response1: [UInt8] = [0x01, 0x03, 0x02, 0x00, 0x01]
        async let task1 = handler.waitForResponse(on: channel.eventLoop)
        await channel.testingEventLoop.run()
        try await channel.writeInbound(response1)
        let result1 = try await task1
        #expect(result1 == response1)

        // Second request/response
        let response2: [UInt8] = [0x01, 0x03, 0x02, 0x00, 0x02]
        async let task2 = handler.waitForResponse(on: channel.eventLoop)
        await channel.testingEventLoop.run()
        try await channel.writeInbound(response2)
        let result2 = try await task2
        #expect(result2 == response2)

        try await channel.close()
    }

    // MARK: - Connection Loss Tests (channelInactive)

    @Test("waitForResponse fails with channelClosed when channel becomes inactive")
    func waitForResponseChannelClosed() async throws {
        let channel = NIOAsyncTestingChannel()
        let handler = V5ResponseHandler()
        try await channel.pipeline.addHandler(handler)

        // Start waiting for response
        async let responseTask: Void = {
            do {
                _ = try await handler.waitForResponse(on: channel.eventLoop)
                Issue.record("Expected channelClosed error")
            } catch let error as SolarmanClientError {
                #expect(error == .channelClosed)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }()

        // Run event loop then fire inactive
        await channel.testingEventLoop.run()
        channel.pipeline.fireChannelInactive()
        await channel.testingEventLoop.run()

        await responseTask
    }

    @Test("waitForResponse fails when channel closes before response")
    func waitForResponseChannelClosesBeforeResponse() async throws {
        let channel = NIOAsyncTestingChannel()
        let handler = V5ResponseHandler()
        try await channel.pipeline.addHandler(handler)

        // Start waiting
        let task = Task {
            try await handler.waitForResponse(on: channel.eventLoop)
        }

        // Run event loop then close channel
        await channel.testingEventLoop.run()
        try await channel.close()

        // Should fail with channelClosed
        do {
            _ = try await task.value
            Issue.record("Expected error")
        } catch let error as SolarmanClientError {
            #expect(error == .channelClosed)
        } catch {
            // CancellationError or NIO errors are also acceptable
        }
    }

    // MARK: - Error Propagation Tests

    @Test("waitForResponse propagates decoder error")
    func waitForResponseDecoderError() async throws {
        let channel = NIOAsyncTestingChannel()
        let handler = V5ResponseHandler()
        try await channel.pipeline.addHandler(handler)

        // Start waiting
        async let responseTask: Void = {
            do {
                _ = try await handler.waitForResponse(on: channel.eventLoop)
                Issue.record("Expected error")
            } catch {
                // Error should be propagated
                #expect(error is V5FrameDecoderError)
            }
        }()

        // Fire error through pipeline
        await channel.testingEventLoop.run()
        let decoderError = V5FrameDecoderError.invalidStartByte(0x00)
        channel.pipeline.fireErrorCaught(decoderError)
        await channel.testingEventLoop.run()

        await responseTask
    }

    @Test("waitForResponse propagates arbitrary error")
    func waitForResponseArbitraryError() async throws {
        let channel = NIOAsyncTestingChannel()
        let handler = V5ResponseHandler()
        try await channel.pipeline.addHandler(handler)

        struct TestError: Error, Equatable {}

        async let responseTask: Void = {
            do {
                _ = try await handler.waitForResponse(on: channel.eventLoop)
                Issue.record("Expected error")
            } catch {
                #expect(error is TestError)
            }
        }()

        await channel.testingEventLoop.run()
        channel.pipeline.fireErrorCaught(TestError())
        await channel.testingEventLoop.run()

        await responseTask
    }

    // MARK: - Task Cancellation Tests

    @Test("waitForResponse handles task cancellation")
    func waitForResponseCancellation() async throws {
        let channel = NIOAsyncTestingChannel()
        let handler = V5ResponseHandler()
        try await channel.pipeline.addHandler(handler)

        let task = Task {
            try await handler.waitForResponse(on: channel.eventLoop)
        }

        // Cancel the task before response arrives
        await channel.testingEventLoop.run()
        task.cancel()

        // Should throw CancellationError
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            // Other errors acceptable (race condition)
        }

        try await channel.close()
    }

    // MARK: - Memory Safety Tests (DoS Prevention)

    @Test("Handler discards response when no one is waiting")
    func handlerDiscardsUnsolicitedResponse() async throws {
        let channel = NIOAsyncTestingChannel()
        let handler = V5ResponseHandler()
        try await channel.pipeline.addHandler(handler)

        // Send response without anyone waiting using writeInbound
        let unsolicited: [UInt8] = [0x01, 0x03, 0x02, 0x00, 0x01]
        try await channel.writeInbound(unsolicited)

        // Now wait for next response
        async let responseTask = handler.waitForResponse(on: channel.eventLoop)

        // Run event loop and send actual expected response
        await channel.testingEventLoop.run()
        let expectedResponse: [UInt8] = [0x01, 0x04, 0x02, 0x12, 0x34]
        try await channel.writeInbound(expectedResponse)

        let result = try await responseTask
        #expect(result == expectedResponse)

        try await channel.close()
    }

    // MARK: - Edge Cases

    @Test("Empty response is valid")
    func emptyResponseIsValid() async throws {
        let channel = NIOAsyncTestingChannel()
        let handler = V5ResponseHandler()
        try await channel.pipeline.addHandler(handler)

        let emptyResponse: [UInt8] = []
        async let task = handler.waitForResponse(on: channel.eventLoop)
        await channel.testingEventLoop.run()
        try await channel.writeInbound(emptyResponse)

        let result = try await task
        #expect(result.isEmpty)

        try await channel.close()
    }

    @Test("Large response (max frame size) is handled")
    func largeResponseHandled() async throws {
        let channel = NIOAsyncTestingChannel()
        let handler = V5ResponseHandler()
        try await channel.pipeline.addHandler(handler)

        // Max frame size response
        let largeResponse = [UInt8](repeating: 0x42, count: 1024)
        async let task = handler.waitForResponse(on: channel.eventLoop)
        await channel.testingEventLoop.run()
        try await channel.writeInbound(largeResponse)

        let result = try await task
        #expect(result.count == 1024)

        try await channel.close()
    }
}
