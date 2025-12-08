// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

@testable import SolarmanV5
import Testing

/// Security-focused tests for V5 frame parsing.
///
/// These tests cover CVE-style attack vectors and edge cases that could
/// cause buffer overflows, memory corruption, or denial of service.
///
/// **Reference vulnerabilities:**
/// - CVE-2024-10918: libmodbus stack overflow from response length
/// - CVE-2022-0367: libmodbus heap overflow in modbus_reply
///
/// **Attack vectors tested:**
/// - Length field manipulation (larger/smaller than actual)
/// - Truncated frames mid-field
/// - Integer overflow in length calculations
/// - Maximum size boundary conditions
@Suite("V5 Frame Security")
struct V5FrameSecurityTests {
    // MARK: Internal

    // MARK: - Length Field Attack Vectors

    @Test("Rejects length field 0xFFFF (max UInt16)")
    func rejectsMaxLengthField() {
        var frame = makeMinimalValidFrame()
        // Set length to maximum UInt16
        frame[1] = 0xFF
        frame[2] = 0xFF

        #expect(throws: V5FrameError.lengthMismatch) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects length field larger than frame")
    func rejectsLengthLargerThanFrame() {
        var frame = makeMinimalValidFrame()
        // Set length to 1000 (0x03E8) but frame is only 32 bytes
        frame[1] = 0xE8
        frame[2] = 0x03

        #expect(throws: V5FrameError.lengthMismatch) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects length field smaller than frame")
    func rejectsLengthSmallerThanFrame() {
        var frame = makeMinimalValidFrame()
        // Set length to 10 but frame has more payload
        frame[1] = 0x0A
        frame[2] = 0x00

        #expect(throws: V5FrameError.lengthMismatch) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects zero length field")
    func rejectsZeroLength() {
        var frame = makeMinimalValidFrame()
        frame[1] = 0x00
        frame[2] = 0x00

        #expect(throws: V5FrameError.lengthMismatch) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects length field off by one (too small)")
    func rejectsLengthOffByOneSmall() {
        var frame = makeMinimalValidFrame()
        // V5 frame structure: frame_size = payload_length + 13
        // So actual payload = frame.count - 13
        let actualPayload = frame.count - 13
        // Set length to actualPayload - 1
        frame[1] = UInt8(truncatingIfNeeded: actualPayload - 1)
        frame[2] = UInt8(truncatingIfNeeded: (actualPayload - 1) >> 8)

        #expect(throws: V5FrameError.lengthMismatch) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects length field off by one (too large)")
    func rejectsLengthOffByOneLarge() {
        var frame = makeMinimalValidFrame()
        // V5 frame structure: frame_size = payload_length + 13
        let actualPayload = frame.count - 13
        // Set length to actualPayload + 1
        frame[1] = UInt8(truncatingIfNeeded: actualPayload + 1)
        frame[2] = UInt8(truncatingIfNeeded: (actualPayload + 1) >> 8)

        #expect(throws: V5FrameError.lengthMismatch) {
            try parseV5ResponseFrame(frame)
        }
    }

    // MARK: - Truncated Frame Attacks (CVE-style)

    @Test("Rejects frame truncated after start byte")
    func rejectsTruncatedAfterStart() {
        let frame: [UInt8] = [0xA5]

        #expect(throws: V5FrameError.frameTooShort) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects frame truncated mid-length field")
    func rejectsTruncatedMidLength() {
        let frame: [UInt8] = [0xA5, 0x1B] // Missing second byte of length

        #expect(throws: V5FrameError.frameTooShort) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects frame truncated mid-sequence")
    func rejectsTruncatedMidSequence() {
        // Frame with only partial sequence (offset 5-6)
        let frame: [UInt8] = [
            0xA5, 0x1B, 0x00, // Start + length
            0x10, 0x15, // Control
            0x01, // Only first byte of sequence
        ]

        #expect(throws: V5FrameError.frameTooShort) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects frame truncated mid-serial")
    func rejectsTruncatedMidSerial() {
        // Frame with only partial serial (offset 7-10)
        let frame: [UInt8] = [
            0xA5, 0x1B, 0x00, // Start + length
            0x10, 0x15, // Control
            0x01, 0x00, // Sequence
            0x78, 0x56, // Only 2 bytes of 4-byte serial
        ]

        #expect(throws: V5FrameError.frameTooShort) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects frame truncated mid-time field")
    func rejectsTruncatedMidTimeField() {
        // Frame with only partial time field
        let frame: [UInt8] = [
            0xA5, 0x1B, 0x00, // Start + length
            0x10, 0x15, // Control
            0x01, 0x00, // Sequence
            0x78, 0x56, 0x34, 0x12, // Serial
            0x02, // Frame type
            0x01, // Status
            0x00, 0x00, // Only 2 bytes of 4-byte time
        ]

        #expect(throws: V5FrameError.frameTooShort) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects frame with header but no modbus data")
    func rejectsHeaderOnlyNoModbus() {
        // Complete header but zero modbus bytes
        let frame: [UInt8] = [
            0xA5, 0x16, 0x00, // Start + length (22)
            0x10, 0x15, // Control
            0x01, 0x00, // Sequence
            0x78, 0x56, 0x34, 0x12, // Serial
            0x02, // Frame type
            0x01, // Status
            0x00, 0x00, 0x00, 0x00, // Total working time
            0x00, 0x00, 0x00, 0x00, // Power on time
            0x00, 0x00, 0x00, 0x00, // Offset time
            // No modbus data!
            0x00, // Checksum placeholder
            0x15, // End
        ]

        #expect(throws: V5FrameError.frameTooShort) {
            try parseV5ResponseFrame(frame)
        }
    }

    // MARK: - Boundary Conditions

    @Test("Accepts exactly minimum valid frame size (32 bytes)")
    func acceptsExactMinimumSize() throws {
        // Minimum: header(25) + minModbus(5) + trailer(2) = 32
        let frame = makeMinimalValidFrame()
        #expect(frame.count == 32)

        let response = try parseV5ResponseFrame(frame)
        #expect(response.modbusFrame.count == 5)
    }

    @Test("Rejects frame one byte less than minimum (31 bytes)")
    func rejects31Bytes() {
        var frame = makeMinimalValidFrame()
        frame.removeLast() // Remove end byte

        #expect(throws: V5FrameError.self) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Accepts maximum practical frame size")
    func acceptsMaxPracticalSize() throws {
        // Build frame with large Modbus response (250 register bytes)
        var modbusData: [UInt8] = [0x01, 0x03, 0xFA] // byteCount = 250
        modbusData.append(contentsOf: [UInt8](repeating: 0x42, count: 250))
        // Add valid CRC
        let crc = calculateModbusCRC16(Array(modbusData.dropLast(0)))
        modbusData.append(UInt8(truncatingIfNeeded: crc))
        modbusData.append(UInt8(truncatingIfNeeded: crc >> 8))

        let frame = makeValidFrame(modbus: modbusData)
        let response = try parseV5ResponseFrame(frame)

        #expect(response.modbusFrame.count == 255)
    }

    // MARK: - Checksum Attacks

    @Test("Rejects frame with all-zero checksum on valid data")
    func rejectsZeroChecksumOnValidData() {
        var frame = makeMinimalValidFrame()
        frame[frame.count - 2] = 0x00 // Zero out checksum

        #expect(throws: V5FrameError.invalidChecksum) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects frame with 0xFF checksum")
    func rejectsFFChecksum() {
        var frame = makeMinimalValidFrame()
        frame[frame.count - 2] = 0xFF // Invalid checksum

        #expect(throws: V5FrameError.invalidChecksum) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects frame with checksum off by one")
    func rejectsChecksumOffByOne() {
        var frame = makeMinimalValidFrame()
        let actualChecksum = frame[frame.count - 2]
        frame[frame.count - 2] = actualChecksum &+ 1 // Off by one

        #expect(throws: V5FrameError.invalidChecksum) {
            try parseV5ResponseFrame(frame)
        }
    }

    // MARK: - Control Code Attacks

    @Test("Rejects request control code in response")
    func rejectsRequestControlCode() {
        var frame = makeMinimalValidFrame()
        // Change control code to request (0x4510 LE = 0x10, 0x45)
        frame[3] = 0x10
        frame[4] = 0x45
        // Fix checksum
        let checksum = frame[1..<(frame.count - 2)].reduce(UInt16(0)) { ($0 + UInt16($1)) & 0xFF }
        frame[frame.count - 2] = UInt8(checksum)

        #expect(throws: V5FrameError.invalidControlCode) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects heartbeat control code")
    func rejectsHeartbeatControlCode() {
        var frame = makeMinimalValidFrame()
        // Change control code to heartbeat (0x4710 LE = 0x10, 0x47)
        frame[3] = 0x10
        frame[4] = 0x47
        // Fix checksum
        let checksum = frame[1..<(frame.count - 2)].reduce(UInt16(0)) { ($0 + UInt16($1)) & 0xFF }
        frame[frame.count - 2] = UInt8(checksum)

        #expect(throws: V5FrameError.invalidControlCode) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects unknown control code")
    func rejectsUnknownControlCode() {
        var frame = makeMinimalValidFrame()
        // Set unknown control code
        frame[3] = 0xFF
        frame[4] = 0xFF
        // Fix checksum
        let checksum = frame[1..<(frame.count - 2)].reduce(UInt16(0)) { ($0 + UInt16($1)) & 0xFF }
        frame[frame.count - 2] = UInt8(checksum)

        #expect(throws: V5FrameError.invalidControlCode) {
            try parseV5ResponseFrame(frame)
        }
    }

    // MARK: - Marker Byte Attacks

    @Test("Rejects 0x00 as start byte")
    func rejectsNullStartByte() {
        var frame = makeMinimalValidFrame()
        frame[0] = 0x00

        #expect(throws: V5FrameError.invalidStartByte) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects 0xFF as start byte")
    func rejectsFFStartByte() {
        var frame = makeMinimalValidFrame()
        frame[0] = 0xFF

        #expect(throws: V5FrameError.invalidStartByte) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects end marker value as start byte")
    func rejectsEndAsStart() {
        var frame = makeMinimalValidFrame()
        frame[0] = 0x15 // End marker used as start

        #expect(throws: V5FrameError.invalidStartByte) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects start marker value as end byte")
    func rejectsStartAsEnd() {
        var frame = makeMinimalValidFrame()
        frame[frame.count - 1] = 0xA5 // Start marker used as end

        #expect(throws: V5FrameError.invalidEndByte) {
            try parseV5ResponseFrame(frame)
        }
    }

    // MARK: - Fuzz-like Random Data

    @Test("Rejects random bytes of minimum size")
    func rejectsRandomBytesMinSize() {
        // 32 random bytes (minimum frame size)
        let frame: [UInt8] = [
            0x42, 0x17, 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56,
            0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11, 0x22, 0x33,
            0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB,
            0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x01, 0x02, 0x03,
        ]

        #expect(throws: V5FrameError.self) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects all 0x00 bytes")
    func rejectsAllZeros() {
        let frame = [UInt8](repeating: 0x00, count: 32)

        #expect(throws: V5FrameError.invalidStartByte) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Rejects all 0xFF bytes")
    func rejectsAllFF() {
        let frame = [UInt8](repeating: 0xFF, count: 32)

        #expect(throws: V5FrameError.invalidStartByte) {
            try parseV5ResponseFrame(frame)
        }
    }

    // MARK: Private

    // MARK: - Helpers

    /// Creates minimal valid V5 response frame (32 bytes).
    private func makeMinimalValidFrame() -> [UInt8] {
        TestVectors.minimumValid
    }

    /// Creates a valid V5 response frame with specified Modbus data.
    ///
    /// V5 frame structure:
    /// - Header: start(1) + length(2) + control(2) + sequence(2) + serial(4) = 11 bytes
    /// - Payload: frameType(1) + status(1) + times(12) + modbusFrame = payloadLength bytes
    /// - Trailer: checksum(1) + end(1) = 2 bytes
    /// - Total: payloadLength + 13
    private func makeValidFrame(modbus: [UInt8]) -> [UInt8] {
        // Payload = frameType(1) + status(1) + times(12) + modbus
        let payloadLength = 14 + modbus.count

        var frame: [UInt8] = [
            0xA5, // Start
            UInt8(truncatingIfNeeded: payloadLength), // Length low
            UInt8(truncatingIfNeeded: payloadLength >> 8), // Length high
            0x10, 0x15, // Control: response (0x1510 LE)
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

        // Calculate checksum (sum of bytes[1..<end] & 0xFF)
        let checksum = frame[1...].reduce(UInt16(0)) { ($0 + UInt16($1)) & 0xFF }
        frame.append(UInt8(checksum))

        // End marker
        frame.append(0x15)

        return frame
    }
}
