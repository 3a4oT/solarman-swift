// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

import NIOCore
import NIOEmbedded
@testable import SolarmanV5
import Testing

// MARK: - V5FrameDecoderTests

@Suite("V5 Frame Decoder")
struct V5FrameDecoderTests {
    // MARK: - Basic Decoding

    @Test("Decodes valid V5 frame")
    func decodesValidFrame() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(V5FrameDecoder()))

        // Use standard test vector - valid V5 response frame (34 bytes)
        let frame = TestVectors.validResponse

        var buffer = channel.allocator.buffer(capacity: frame.count)
        buffer.writeBytes(frame)
        try channel.writeInbound(buffer)

        let decoded: [UInt8]? = try channel.readInbound()
        #expect(decoded == frame)
    }

    @Test("Accumulates partial frame")
    func accumulatesPartialFrame() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(V5FrameDecoder()))

        let frame = TestVectors.simpleFrame // 29 bytes

        // Send first 10 bytes
        var buffer1 = channel.allocator.buffer(capacity: 10)
        buffer1.writeBytes(Array(frame[0..<10]))
        try channel.writeInbound(buffer1)

        // No output yet
        let partial: [UInt8]? = try channel.readInbound()
        #expect(partial == nil)

        // Send rest of frame
        var buffer2 = channel.allocator.buffer(capacity: frame.count - 10)
        buffer2.writeBytes(Array(frame[10...]))
        try channel.writeInbound(buffer2)

        let decoded: [UInt8]? = try channel.readInbound()
        #expect(decoded != nil)
        #expect(decoded?.count == frame.count)
    }

    @Test("Decodes multiple frames")
    func decodesMultipleFrames() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(V5FrameDecoder()))

        // Two valid frames back-to-back
        let frame1 = TestVectors.minimumValid
        let frame2 = TestVectors.simpleFrame

        var buffer = channel.allocator.buffer(capacity: frame1.count + frame2.count)
        buffer.writeBytes(frame1)
        buffer.writeBytes(frame2)
        try channel.writeInbound(buffer)

        let decoded1: [UInt8]? = try channel.readInbound()
        let decoded2: [UInt8]? = try channel.readInbound()

        #expect(decoded1 == frame1)
        #expect(decoded2 == frame2)
    }

    // MARK: - Error Cases

    @Test("Throws on invalid start byte")
    func throwsOnInvalidStartByte() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(V5FrameDecoder()))

        // Use valid frame but replace start byte
        var frame = TestVectors.minimumValid
        frame[0] = 0x00 // Invalid start (not 0xA5)

        var buffer = channel.allocator.buffer(capacity: frame.count)
        buffer.writeBytes(frame)

        #expect(throws: V5FrameDecoderError.self) {
            try channel.writeInbound(buffer)
        }
    }

    @Test("Throws on zero length")
    func throwsOnZeroLength() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(V5FrameDecoder()))

        // Use valid frame but set length to 0
        var frame = TestVectors.minimumValid
        frame[1] = 0x00 // Length low byte = 0
        frame[2] = 0x00 // Length high byte = 0

        var buffer = channel.allocator.buffer(capacity: frame.count)
        buffer.writeBytes(frame)

        #expect(throws: V5FrameDecoderError.self) {
            try channel.writeInbound(buffer)
        }
    }

    @Test("Throws on frame too large")
    func throwsOnFrameTooLarge() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(V5FrameDecoder()))

        // V5 frame structure: frame_size = payload_length + 13
        // Max frame size = 1024, so max payload = 1024 - 13 = 1011
        // Length = 1012 would make frame size = 1012 + 13 = 1025 > 1024 max
        var buffer = channel.allocator.buffer(capacity: 10)
        buffer.writeBytes([0xA5, 0xF4, 0x03, 0x00, 0x00, 0x00]) // Length = 0x03F4 = 1012 (LE)

        #expect(throws: V5FrameDecoderError.self) {
            try channel.writeInbound(buffer)
        }
    }

    // MARK: - Edge Cases

    @Test("Waits for complete frame")
    func waitsForCompleteFrame() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(V5FrameDecoder()))

        // V5 frame structure: frame_size = payload_length + 13
        // Frame claims length = 10, so needs 10 + 13 = 23 bytes total
        // Only provide 6 bytes
        var buffer = channel.allocator.buffer(capacity: 6)
        buffer.writeBytes([0xA5, 0x0A, 0x00, 0x42, 0x43, 0x44]) // Need 23 bytes total, only 6 here

        try channel.writeInbound(buffer)

        let decoded: [UInt8]? = try channel.readInbound()
        #expect(decoded == nil) // Should wait for more data
    }

    @Test("Handles maximum valid frame size")
    func handlesMaxValidFrameSize() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(V5FrameDecoder()))

        // Max frame size is 1024 bytes
        // V5 frame structure: frame_size = payload_length + 13
        // Where:
        // - Header: start(1) + length(2) + control(2) + sequence(2) + serial(4) = 11 bytes
        // - Payload: frameType(1) + status(1) + times(12) + modbusFrame = payloadLength bytes
        // - Trailer: checksum(1) + end(1) = 2 bytes
        // So max payload = 1024 - 13 = 1011
        let maxPayload = 1011

        // Build valid V5 frame
        var frame: [UInt8] = [
            0xA5, // Start (1 byte)
            UInt8(truncatingIfNeeded: maxPayload), // Length low
            UInt8(truncatingIfNeeded: maxPayload >> 8), // Length high
            0x10, 0x15, // Control: response (0x1510 LE) (2 bytes)
            0x01, 0x00, // Sequence (2 bytes)
            0x78, 0x56, 0x34, 0x12, // Serial (4 bytes)
        ] // Total so far: 11 bytes (header)

        // Payload must be exactly maxPayload = 1011 bytes
        // payload = frameType(1) + status(1) + times(12) + modbusFrame
        // Already have 0 payload bytes, need to add 1011 bytes
        frame.append(contentsOf: [UInt8](repeating: 0x42, count: maxPayload))

        // Calculate checksum (covers bytes[1..<frame.count])
        let checksum = frame[1..<frame.count].reduce(UInt16(0)) { ($0 + UInt16($1)) & 0xFF }
        frame.append(UInt8(checksum))
        frame.append(0x15) // End

        // Verify: header(11) + payload(1011) + trailer(2) = 1024
        #expect(frame.count == 1024) // Verify we hit exactly max size

        var buffer = channel.allocator.buffer(capacity: frame.count)
        buffer.writeBytes(frame)
        try channel.writeInbound(buffer)

        let decoded: [UInt8]? = try channel.readInbound()
        #expect(decoded?.count == 1024)
    }
}

// MARK: - V5FrameDecoderErrorTests

@Suite("V5 Frame Decoder Error")
struct V5FrameDecoderErrorTests {
    @Test("Invalid start byte error")
    func invalidStartByteError() {
        let error = V5FrameDecoderError.invalidStartByte(0x00)
        #expect(error == .invalidStartByte(0x00))
    }

    @Test("Invalid length error")
    func invalidLengthError() {
        let error = V5FrameDecoderError.invalidLength(0)
        #expect(error == .invalidLength(0))
    }

    @Test("Frame too large error")
    func frameTooLargeError() {
        let error = V5FrameDecoderError.frameTooLarge(2000)
        #expect(error == .frameTooLarge(2000))
    }

    @Test("Incomplete frame at EOF error")
    func incompleteFrameAtEOFError() {
        let error = V5FrameDecoderError.incompleteFrameAtEOF(10)
        #expect(error == .incompleteFrameAtEOF(10))
    }
}
