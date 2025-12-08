// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

import NIOCore

// MARK: - V5FrameDecoderError

/// Errors from V5FrameDecoder.
///
/// These indicate protocol violations that cannot be recovered from.
/// Reference: pysolarmanv5 does not attempt resync on corrupt frames.
enum V5FrameDecoderError: Error, Equatable, Sendable {
    /// Start byte is not 0xA5
    case invalidStartByte(UInt8)

    /// Length field is invalid (too small or exceeds maximum)
    case invalidLength(UInt16)

    /// Frame exceeds maximum size (1024 bytes)
    case frameTooLarge(Int)

    /// Connection closed with incomplete frame in buffer
    case incompleteFrameAtEOF(Int)
}

// MARK: - V5FrameDecoder

/// NIO decoder for Solarman V5 frames.
///
/// Accumulates bytes until a complete V5 frame is received.
/// Validates frame structure before passing to handler.
///
/// **Frame Format:**
/// - Start: 0xA5 (1 byte)
/// - Length: payload size (2 bytes, Little Endian)
/// - Payload: control code, sequence, serial, etc.
/// - Checksum: sum of bytes[1..<end-1] & 0xFF (1 byte)
/// - End: 0x15 (1 byte)
///
/// **Error Handling:**
/// Invalid frames throw errors rather than attempting resynchronization.
/// This matches pysolarmanv5 behavior — V5 runs over reliable TCP transport,
/// so corrupt frames indicate serious issues that warrant connection closure.
///
/// Reference: pysolarmanv5 v5_error_correction is optional and rarely needed.
final class V5FrameDecoder: ByteToMessageDecoder, Sendable {
    typealias InboundOut = [UInt8]

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // Need at least start byte + length field (3 bytes) to determine frame size
        guard buffer.readableBytes >= 3 else {
            return .needMoreData
        }

        // Peek at start byte — must be 0xA5
        guard let startByte = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) else {
            return .needMoreData
        }

        guard startByte == V5Marker.start else {
            throw V5FrameDecoderError.invalidStartByte(startByte)
        }

        // Peek at length field (bytes 1-2, Little Endian)
        guard
            let lengthLow = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self),
            let lengthHigh = buffer.getInteger(at: buffer.readerIndex + 2, as: UInt8.self) else {
            return .needMoreData
        }

        let payloadLength = UInt16(lengthLow) | (UInt16(lengthHigh) << 8)

        // Validate length field
        // Minimum payload: control(2) + sequence(2) + serial(4) + frameType(1) + status(1) + times(12) + minModbus(5) =
        // 27
        // But we accept any payload >= 1 and let higher layer validate
        guard payloadLength >= 1 else {
            throw V5FrameDecoderError.invalidLength(payloadLength)
        }

        // Calculate total frame size
        // V5 frame structure:
        // - Header: start(1) + length(2) + control(2) + sequence(2) + serial(4) = 11 bytes
        // - Payload: frameType(1) + sensorType(2) + times(12) + modbusFrame = payloadLength bytes
        // - Trailer: checksum(1) + end(1) = 2 bytes
        // Total = payloadLength + 13
        let frameSize = Int(payloadLength) + 13

        // Validate against maximum frame size
        guard frameSize <= SolarmanConstants.maxFrameSize else {
            throw V5FrameDecoderError.frameTooLarge(frameSize)
        }

        // Wait for complete frame
        guard buffer.readableBytes >= frameSize else {
            return .needMoreData
        }

        // Extract complete frame
        guard let frameBytes = buffer.readBytes(length: frameSize) else {
            return .needMoreData
        }

        context.fireChannelRead(wrapInboundOut(frameBytes))
        return .continue
    }

    /// Handle channel closure or decoder removal.
    ///
    /// For V5, any leftover bytes in the buffer when the connection closes
    /// indicates an incomplete frame — this is always an error condition.
    ///
    /// Reference: pysolarmanv5 closes connection on any frame error.
    func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF _: Bool,
    ) throws -> DecodingState {
        // First, try to decode any complete frames still in the buffer
        while buffer.readableBytes > 0 {
            let result = try decode(context: context, buffer: &buffer)
            if result == .needMoreData {
                break
            }
        }

        // If there's still data left after decoding complete frames, it's a partial frame
        if buffer.readableBytes > 0 {
            throw V5FrameDecoderError.incompleteFrameAtEOF(buffer.readableBytes)
        }

        return .needMoreData
    }
}
