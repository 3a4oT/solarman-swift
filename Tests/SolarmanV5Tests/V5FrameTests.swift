// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

@testable import SolarmanV5
import Testing

/// Tests for V5 frame constants and structure
///
/// Test vectors generated using pysolarmanv5 reference implementation
/// and verified with manual calculations.
@Suite("V5 Frame")
struct V5FrameTests {
    // MARK: - Constants Tests

    @Test("Frame markers have correct values")
    func frameMarkers() {
        #expect(V5Marker.start == 0xA5)
        #expect(V5Marker.end == 0x15)
    }

    @Test("Control codes have correct values")
    func controlCodes() {
        // Request: 0x4510 (LE in frame: 0x10 0x45)
        #expect(V5ControlCode.request == 0x4510)
        // Response: 0x1510 (LE in frame: 0x10 0x15)
        #expect(V5ControlCode.response == 0x1510)
        // Heartbeat: 0x4710 (LE in frame: 0x10 0x47)
        #expect(V5ControlCode.heartbeat == 0x4710)
    }

    @Test("Frame type values are correct")
    func frameTypes() {
        #expect(V5FrameType.inverter == 0x02)
    }

    @Test("Status values are correct")
    func statusValues() {
        #expect(V5Status.ok == 0x01)
    }

    // MARK: - Offset Tests

    @Test("Request frame offsets are correct")
    func requestOffsets() {
        // Verified against pysolarmanv5 and protocol documentation
        #expect(V5RequestOffset.start == 0)
        #expect(V5RequestOffset.length == 1)
        #expect(V5RequestOffset.controlCode == 3)
        #expect(V5RequestOffset.sequence == 5)
        #expect(V5RequestOffset.serial == 7)
        #expect(V5RequestOffset.frameType == 11)
        #expect(V5RequestOffset.sensorType == 12)
        #expect(V5RequestOffset.totalWorkingTime == 14)
        #expect(V5RequestOffset.powerOnTime == 18)
        #expect(V5RequestOffset.offsetTime == 22)
        #expect(V5RequestOffset.modbusRTU == 26)
    }

    @Test("Response frame offsets are correct")
    func responseOffsets() {
        // Response has 1-byte status vs 2-byte sensor type
        // This shifts Modbus position from 26 to 25
        #expect(V5ResponseOffset.start == 0)
        #expect(V5ResponseOffset.length == 1)
        #expect(V5ResponseOffset.controlCode == 3)
        #expect(V5ResponseOffset.sequence == 5)
        #expect(V5ResponseOffset.serial == 7)
        #expect(V5ResponseOffset.frameType == 11)
        #expect(V5ResponseOffset.status == 12)
        #expect(V5ResponseOffset.totalWorkingTime == 13)
        #expect(V5ResponseOffset.powerOnTime == 17)
        #expect(V5ResponseOffset.offsetTime == 21)
        #expect(V5ResponseOffset.modbusRTU == 25)
    }

    // MARK: - Size Tests

    @Test("Frame sizes are correct")
    func frameSizes() {
        #expect(V5FrameSize.requestHeader == 26)
        #expect(V5FrameSize.responseHeader == 25)
        #expect(V5FrameSize.trailer == 2)
        #expect(V5FrameSize.minimum == 28)
    }

    // MARK: - Test Vector Validation

    @Test("Request frame test vector structure")
    func requestFrameTestVector() {
        // Test vector generated with pysolarmanv5 reference
        // Serial: 0x12345678, Sequence: 0x0001
        // Modbus: Read 1 register from address 0 (01 03 00 00 00 01 84 0A)
        let frame: [UInt8] = [
            0xA5, // Start
            0x17, 0x00, // Length: 23 (LE)
            0x10, 0x45, // Control: 0x4510 (LE)
            0x01, 0x00, // Sequence: 1 (LE)
            0x78, 0x56, 0x34, 0x12, // Serial: 0x12345678 (LE)
            0x02, // Frame type: inverter
            0x00, 0x00, // Sensor type
            0x00, 0x00, 0x00, 0x00, // Total working time
            0x00, 0x00, 0x00, 0x00, // Power on time
            0x00, 0x00, 0x00, 0x00, // Offset time
            0x01, 0x03, 0x00, 0x00, 0x00, 0x01, 0x84, 0x0A, // Modbus RTU
            0x16, // Checksum (verified: sum of bytes[1..<34] & 0xFF = 534 & 0xFF = 0x16)
            0x15, // End
        ]

        // Verify structure
        #expect(frame.count == 36)
        #expect(frame[V5RequestOffset.start] == V5Marker.start)
        #expect(frame[frame.count - 1] == V5Marker.end)

        // Verify length field (little endian)
        let length = UInt16(frame[1]) | (UInt16(frame[2]) << 8)
        #expect(length == 23) // 15 + 8 (modbus frame length)

        // Verify control code (little endian)
        let controlCode = UInt16(frame[3]) | (UInt16(frame[4]) << 8)
        #expect(controlCode == V5ControlCode.request)

        // Verify sequence (little endian)
        let sequence = UInt16(frame[5]) | (UInt16(frame[6]) << 8)
        #expect(sequence == 1)

        // Verify serial (little endian)
        let serial = UInt32(frame[7]) | (UInt32(frame[8]) << 8) |
            (UInt32(frame[9]) << 16) | (UInt32(frame[10]) << 24)
        #expect(serial == 0x1234_5678)

        // Verify frame type
        #expect(frame[V5RequestOffset.frameType] == V5FrameType.inverter)

        // Verify Modbus RTU starts at correct offset
        #expect(frame[V5RequestOffset.modbusRTU] == 0x01) // Slave address
        #expect(frame[V5RequestOffset.modbusRTU + 1] == 0x03) // Function code

        // Verify checksum
        let checksumData = frame[1..<(frame.count - 2)]
        let calculatedChecksum = calculateV5Checksum(checksumData)
        #expect(calculatedChecksum == frame[frame.count - 2])
        #expect(calculatedChecksum == 0x16)
    }

    // MARK: - Frame Builder Tests

    @Test("Build request frame matches test vector")
    func buildRequestFrame() {
        // Same parameters as test vector
        let serial: UInt32 = 0x1234_5678
        let sequence: UInt16 = 0x0001
        let modbusFrame: [UInt8] = [0x01, 0x03, 0x00, 0x00, 0x00, 0x01, 0x84, 0x0A]

        let frame = buildV5RequestFrame(
            serial: serial,
            sequence: sequence,
            modbusFrame: modbusFrame,
        )

        // Expected frame from pysolarmanv5 reference
        let expected: [UInt8] = [
            0xA5, 0x17, 0x00, 0x10, 0x45, 0x01, 0x00,
            0x78, 0x56, 0x34, 0x12, 0x02, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x03,
            0x00, 0x00, 0x00, 0x01, 0x84, 0x0A, 0x16, 0x15,
        ]

        #expect(frame == expected)
    }

    @Test("Build request frame with different serial")
    func buildRequestFrameDifferentSerial() {
        // Use a real-world serial number format (starts with 17/21/40)
        let serial: UInt32 = 1_700_000_001
        let sequence: UInt16 = 0x0042
        let modbusFrame: [UInt8] = [0x01, 0x03, 0x00, 0x6B, 0x00, 0x03, 0x74, 0x17]

        let frame = buildV5RequestFrame(
            serial: serial,
            sequence: sequence,
            modbusFrame: modbusFrame,
        )

        // Verify structure
        #expect(frame[0] == V5Marker.start)
        #expect(frame[frame.count - 1] == V5Marker.end)

        // Verify serial (little endian)
        // 1700000001 = 0x6553A101
        let serialLE = UInt32(frame[7]) | (UInt32(frame[8]) << 8) |
            (UInt32(frame[9]) << 16) | (UInt32(frame[10]) << 24)
        #expect(serialLE == 1_700_000_001)

        // Verify sequence
        let seqLE = UInt16(frame[5]) | (UInt16(frame[6]) << 8)
        #expect(seqLE == 0x0042)

        // Verify checksum is correct
        let checksumData = frame[1..<(frame.count - 2)]
        let calculatedChecksum = calculateV5Checksum(checksumData)
        #expect(calculatedChecksum == frame[frame.count - 2])
    }

    @Test("Build request frame with empty modbus")
    func buildRequestFrameEmptyModbus() {
        let frame = buildV5RequestFrame(
            serial: 0x1234_5678,
            sequence: 1,
            modbusFrame: [],
        )

        // Header (26) + trailer (2) = 28 bytes minimum
        #expect(frame.count == 28)

        // Length should be 15 (payload before modbus)
        let length = UInt16(frame[1]) | (UInt16(frame[2]) << 8)
        #expect(length == 15)

        // Checksum still valid
        let checksumData = frame[1..<(frame.count - 2)]
        let calculatedChecksum = calculateV5Checksum(checksumData)
        #expect(calculatedChecksum == frame[frame.count - 2])
    }

    // MARK: - Response Frame Parser Tests

    @Test("Parse valid response frame")
    func parseValidResponse() throws {
        // Use test vector with correct V5 frame structure
        // Frame size = length_field + 13
        let frame = TestVectors.validResponse

        let response = try parseV5ResponseFrame(frame)

        #expect(response.sequence == 1)
        #expect(response.serial == 0x1234_5678)
        #expect(response.frameType == 0x02)
        #expect(response.status == 0x01)
        #expect(response.totalWorkingTime == 3600)
        #expect(response.powerOnTime == 1800)
        #expect(response.offsetTime == 0)
        #expect(Array(response.modbusFrame) == [0x01, 0x03, 0x02, 0x12, 0x34, 0xB5, 0x33])
    }

    @Test("Parse response frame - invalid start byte")
    func parseInvalidStartByte() {
        var frame: [UInt8] = [
            0xA5, 0x1D, 0x00, 0x10, 0x15, 0x01, 0x00,
            0x78, 0x56, 0x34, 0x12, 0x02, 0x01,
            0x10, 0x0E, 0x00, 0x00, 0x08, 0x07, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x01, 0x03, 0x02, 0x12, 0x34, 0xB5, 0x33,
            0xBB, 0x15,
        ]
        frame[0] = 0x00 // Wrong start byte

        #expect(throws: V5FrameError.invalidStartByte) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Parse response frame - invalid end byte")
    func parseInvalidEndByte() {
        var frame = TestVectors.validResponse
        frame[frame.count - 1] = 0x00 // Wrong end byte

        #expect(throws: V5FrameError.invalidEndByte) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Parse response frame - invalid checksum")
    func parseInvalidChecksum() {
        var frame = TestVectors.validResponse
        frame[frame.count - 2] = 0x00 // Wrong checksum

        #expect(throws: V5FrameError.invalidChecksum) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Parse response frame - frame too short")
    func parseFrameTooShort() {
        let frame: [UInt8] = [0xA5, 0x13] // Only 2 bytes

        #expect(throws: V5FrameError.frameTooShort) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Parse response frame - invalid control code")
    func parseInvalidControlCode() {
        // Use TestVectors with request control code
        #expect(throws: V5FrameError.invalidControlCode) {
            try parseV5ResponseFrame(TestVectors.requestControl)
        }
    }

    @Test("Parse response frame - length mismatch")
    func parseLengthMismatch() {
        var frame = TestVectors.validResponse
        // Set wrong length (0xFF instead of correct value)
        frame[1] = 0xFF

        #expect(throws: V5FrameError.lengthMismatch) {
            try parseV5ResponseFrame(frame)
        }
    }

    // MARK: - Security Edge Case Tests

    @Test("Parse minimum valid response frame")
    func parseMinimumValidFrame() throws {
        // Minimum valid frame: 32 bytes (5-byte modbus)
        let response = try parseV5ResponseFrame(TestVectors.minimumValid)
        #expect(response.sequence == 1)
        #expect(Array(response.modbusFrame) == [0x01, 0x03, 0x00, 0x85, 0xC8])
    }

    @Test("Parse frame exactly one byte too short")
    func parseFrameOneByteTooShort() {
        // Minimum is 32 bytes, provide 31
        let frame = [UInt8](repeating: 0xA5, count: 31)

        #expect(throws: V5FrameError.frameTooShort) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Parse frame with length field smaller than actual")
    func parseLengthFieldTooSmall() {
        var frame = TestVectors.validResponse
        // Set length to smaller value
        frame[1] = 0x10 // Much smaller than actual

        #expect(throws: V5FrameError.lengthMismatch) {
            try parseV5ResponseFrame(frame)
        }
    }

    // NOTE: modbusFrameTooShort is currently unreachable because:
    // - Frame < 32 bytes: fails frameTooShort first
    // - Frame >= 32 bytes: modbusSize = frame.count - 25 - 2 >= 5 always
    // The error exists for defense-in-depth and potential future changes.

    @Test("Parse empty frame")
    func parseEmptyFrame() {
        let frame: [UInt8] = []

        #expect(throws: V5FrameError.frameTooShort) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Parse frame with all zeros")
    func parseAllZerosFrame() {
        // 34 bytes of zeros - should fail on start byte
        let frame = [UInt8](repeating: 0x00, count: 34)

        #expect(throws: V5FrameError.invalidStartByte) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Parse frame with all 0xFF")
    func parseAllFFFrame() {
        // 34 bytes of 0xFF - should fail on start byte
        let frame = [UInt8](repeating: 0xFF, count: 34)

        #expect(throws: V5FrameError.invalidStartByte) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Parse frame with correct markers but garbage content")
    func parseGarbageContent() {
        // Start and end are correct, but everything else is garbage
        var frame = [UInt8](repeating: 0x42, count: 34)
        frame[0] = 0xA5 // Correct start
        frame[33] = 0x15 // Correct end

        // Should fail on length mismatch (0x4242 != actual payload)
        #expect(throws: V5FrameError.lengthMismatch) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Parse frame with heartbeat control code")
    func parseHeartbeatControlCode() {
        // Use TestVectors with heartbeat control code
        #expect(throws: V5FrameError.invalidControlCode) {
            try parseV5ResponseFrame(TestVectors.heartbeatControl)
        }
    }

    @Test("Parse frame with maximum UInt16 length field")
    func parseMaxLengthField() {
        var frame = TestVectors.validResponse
        // Set length field to 0xFFFF
        frame[1] = 0xFF
        frame[2] = 0xFF

        #expect(throws: V5FrameError.lengthMismatch) {
            try parseV5ResponseFrame(frame)
        }
    }

    @Test("Parse frame with zero length field")
    func parseZeroLengthField() {
        var frame = TestVectors.validResponse
        // Set length field to 0x0000
        frame[1] = 0x00
        frame[2] = 0x00

        #expect(throws: V5FrameError.lengthMismatch) {
            try parseV5ResponseFrame(frame)
        }
    }

    // MARK: - Real-World Format Tests

    @Test("Parse realistic Deye inverter response")
    func parseRealisticDeyeResponse() throws {
        // Realistic response based on production Deye inverter frame structure
        let response = try parseV5ResponseFrame(TestVectors.realisticDeyeResponse)

        // Verify serial number: 3112345678 (fake but realistic 31xxxxxxx format)
        #expect(response.serial == 3_112_345_678)

        // Verify sequence
        #expect(response.sequence == 1)

        // Verify frame type and status
        #expect(response.frameType == 0x02) // Inverter data
        #expect(response.status == 0x01) // OK

        // Verify Modbus RTU frame: 01 03 02 00 02 44 38
        // Unit ID: 0x01, Function: 0x03 (read holding), Byte count: 0x02
        // Data: 0x0002 (register value), CRC: 0x3844 (LE: 44 38)
        let modbusFrame = Array(response.modbusFrame)
        #expect(modbusFrame.count == 7)
        #expect(modbusFrame[0] == 0x01) // Unit ID
        #expect(modbusFrame[1] == 0x03) // Function code (read holding)
        #expect(modbusFrame[2] == 0x02) // Byte count
        #expect(modbusFrame[3] == 0x00) // Data high byte
        #expect(modbusFrame[4] == 0x02) // Data low byte (register value = 2)

        // Verify CRC is valid
        let dataWithoutCRC = Array(modbusFrame.dropLast(2))
        let expectedCRC = calculateModbusCRC16(dataWithoutCRC)
        let actualCRC = UInt16(modbusFrame[5]) | (UInt16(modbusFrame[6]) << 8)
        #expect(actualCRC == expectedCRC)
    }
}
