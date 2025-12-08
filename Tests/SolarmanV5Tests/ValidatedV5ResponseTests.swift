// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

@testable import SolarmanV5
import Testing

/// Tests for ValidatedV5Response struct field accessors.
///
/// After `parseV5ResponseFrame()` validates the frame, these tests verify
/// that individual field extraction works correctly with proper byte order
/// and offset handling.
///
/// **Security Focus:**
/// - All accessors return Optional (defense in depth)
/// - Correct Little Endian parsing for V5 fields
/// - Correct Big Endian parsing for Modbus RTU payload
/// - ArraySlice extraction for modbusFrame
@Suite("Validated V5 Response")
struct ValidatedV5ResponseTests {
    // MARK: Internal

    // MARK: - Valid Response Field Extraction

    @Test("Extracts sequence number correctly")
    func extractsSequence() throws {
        let response = try parseV5ResponseFrame(makeValidResponse(sequence: 0x1234))
        #expect(response.sequence == 0x1234)
    }

    @Test("Extracts serial number correctly")
    func extractsSerial() throws {
        let response = try parseV5ResponseFrame(makeValidResponse(serial: 0x1234_5678))
        #expect(response.serial == 0x1234_5678)
    }

    @Test("Extracts frame type correctly")
    func extractsFrameType() throws {
        let response = try parseV5ResponseFrame(makeValidResponse(frameType: 0x02))
        #expect(response.frameType == 0x02)
    }

    @Test("Extracts status correctly")
    func extractsStatus() throws {
        let response = try parseV5ResponseFrame(makeValidResponse(status: 0x01))
        #expect(response.status == 0x01)
    }

    @Test("Extracts total working time correctly")
    func extractsTotalWorkingTime() throws {
        let response = try parseV5ResponseFrame(makeValidResponse(totalWorkingTime: 3600))
        #expect(response.totalWorkingTime == 3600)
    }

    @Test("Extracts power on time correctly")
    func extractsPowerOnTime() throws {
        let response = try parseV5ResponseFrame(makeValidResponse(powerOnTime: 1800))
        #expect(response.powerOnTime == 1800)
    }

    @Test("Extracts offset time correctly")
    func extractsOffsetTime() throws {
        let response = try parseV5ResponseFrame(makeValidResponse(offsetTime: 7200))
        #expect(response.offsetTime == 7200)
    }

    @Test("Extracts modbus frame correctly")
    func extractsModbusFrame() throws {
        let modbusData: [UInt8] = [0x01, 0x03, 0x02, 0x12, 0x34, 0xB5, 0x33]
        let response = try parseV5ResponseFrame(makeValidResponse(modbus: modbusData))
        #expect(Array(response.modbusFrame) == modbusData)
    }

    // MARK: - Endianness Tests

    @Test("Sequence uses Little Endian")
    func sequenceIsLittleEndian() throws {
        // Sequence 0x0102 stored as [0x02, 0x01] in frame
        let response = try parseV5ResponseFrame(makeValidResponse(sequence: 0x0102))
        #expect(response.sequence == 0x0102)
    }

    @Test("Serial uses Little Endian")
    func serialIsLittleEndian() throws {
        // Serial 0x01020304 stored as [0x04, 0x03, 0x02, 0x01] in frame
        let response = try parseV5ResponseFrame(makeValidResponse(serial: 0x0102_0304))
        #expect(response.serial == 0x0102_0304)
    }

    @Test("Times use Little Endian")
    func timesUseLittleEndian() throws {
        // Time 0x01020304 stored as [0x04, 0x03, 0x02, 0x01] in frame
        let response = try parseV5ResponseFrame(makeValidResponse(totalWorkingTime: 0x0102_0304))
        #expect(response.totalWorkingTime == 0x0102_0304)
    }

    // MARK: - Edge Values

    @Test("Handles maximum sequence number")
    func maxSequence() throws {
        let response = try parseV5ResponseFrame(makeValidResponse(sequence: 0xFFFF))
        #expect(response.sequence == 0xFFFF)
    }

    @Test("Handles zero sequence number")
    func zeroSequence() throws {
        let response = try parseV5ResponseFrame(makeValidResponse(sequence: 0x0000))
        #expect(response.sequence == 0x0000)
    }

    @Test("Handles maximum serial number")
    func maxSerial() throws {
        let response = try parseV5ResponseFrame(makeValidResponse(serial: 0xFFFF_FFFF))
        #expect(response.serial == 0xFFFF_FFFF)
    }

    @Test("Handles real-world serial number format")
    func realWorldSerial() throws {
        // Real serial numbers start with 17/21/40
        let response = try parseV5ResponseFrame(makeValidResponse(serial: 1_700_000_001))
        #expect(response.serial == 1_700_000_001)
    }

    @Test("Handles maximum time values")
    func maxTimeValues() throws {
        let response = try parseV5ResponseFrame(makeValidResponse(
            totalWorkingTime: 0xFFFF_FFFF,
            powerOnTime: 0xFFFF_FFFF,
            offsetTime: 0xFFFF_FFFF,
        ))
        #expect(response.totalWorkingTime == 0xFFFF_FFFF)
        #expect(response.powerOnTime == 0xFFFF_FFFF)
        #expect(response.offsetTime == 0xFFFF_FFFF)
    }

    // MARK: - Modbus Frame Extraction Edge Cases

    @Test("Extracts minimum modbus frame (5 bytes)")
    func minimumModbusFrame() throws {
        // Minimum: unitId(1) + fc(1) + data(1) + CRC(2)
        let minModbus: [UInt8] = [0x01, 0x03, 0x00, 0x85, 0xC8]
        let response = try parseV5ResponseFrame(makeValidResponse(modbus: minModbus))
        #expect(Array(response.modbusFrame) == minModbus)
        #expect(response.modbusFrame.count == 5)
    }

    @Test("Extracts large modbus frame")
    func largeModbusFrame() throws {
        // Read 125 registers response: unitId(1) + fc(1) + byteCount(1) + 250 bytes + CRC(2)
        var largeModbus: [UInt8] = [0x01, 0x03, 0xFA] // byteCount = 250
        largeModbus.append(contentsOf: [UInt8](repeating: 0x42, count: 250))
        // Add placeholder CRC (actual frame would have valid CRC)
        largeModbus.append(contentsOf: [0x00, 0x00])

        let response = try parseV5ResponseFrame(makeValidResponse(modbus: largeModbus))
        #expect(response.modbusFrame.count == 255)
    }

    @Test("Modbus frame slice has correct indices")
    func modbusFrameSliceIndices() throws {
        let modbus: [UInt8] = [0x01, 0x03, 0x02, 0x12, 0x34, 0xB5, 0x33]
        let response = try parseV5ResponseFrame(makeValidResponse(modbus: modbus))

        // Verify it's a proper slice (not starting at 0)
        #expect(response.modbusFrame.startIndex == V5ResponseOffset.modbusRTU)
    }

    // MARK: Private

    // MARK: - Helpers

    /// Builds a valid V5 response frame with customizable fields.
    ///
    /// V5 frame structure:
    /// - Header: start(1) + length(2) + control(2) + sequence(2) + serial(4) = 11 bytes
    /// - Payload: frameType(1) + status(1) + times(12) + modbus = 14 + modbus.count
    /// - Trailer: checksum(1) + end(1) = 2 bytes
    /// - Total: payload + 13
    private func makeValidResponse(
        sequence: UInt16 = 0x0001,
        serial: UInt32 = 0x1234_5678,
        frameType: UInt8 = 0x02,
        status: UInt8 = 0x01,
        totalWorkingTime: UInt32 = 0,
        powerOnTime: UInt32 = 0,
        offsetTime: UInt32 = 0,
        modbus: [UInt8] = [0x01, 0x03, 0x02, 0x12, 0x34, 0xB5, 0x33],
    ) -> [UInt8] {
        // Payload = frametype(1) + status(1) + times(12) + modbus
        let payloadLength = 14 + modbus.count

        var frame: [UInt8] = [0xA5] // Start

        // Length (LE)
        frame.append(UInt8(truncatingIfNeeded: payloadLength))
        frame.append(UInt8(truncatingIfNeeded: payloadLength >> 8))

        // Control: response (0x1510 LE)
        frame.append(0x10)
        frame.append(0x15)

        // Sequence (LE)
        frame.append(UInt8(truncatingIfNeeded: sequence))
        frame.append(UInt8(truncatingIfNeeded: sequence >> 8))

        // Serial (LE)
        frame.append(UInt8(truncatingIfNeeded: serial))
        frame.append(UInt8(truncatingIfNeeded: serial >> 8))
        frame.append(UInt8(truncatingIfNeeded: serial >> 16))
        frame.append(UInt8(truncatingIfNeeded: serial >> 24))

        // Frame type
        frame.append(frameType)

        // Status
        frame.append(status)

        // Total working time (LE)
        frame.append(UInt8(truncatingIfNeeded: totalWorkingTime))
        frame.append(UInt8(truncatingIfNeeded: totalWorkingTime >> 8))
        frame.append(UInt8(truncatingIfNeeded: totalWorkingTime >> 16))
        frame.append(UInt8(truncatingIfNeeded: totalWorkingTime >> 24))

        // Power on time (LE)
        frame.append(UInt8(truncatingIfNeeded: powerOnTime))
        frame.append(UInt8(truncatingIfNeeded: powerOnTime >> 8))
        frame.append(UInt8(truncatingIfNeeded: powerOnTime >> 16))
        frame.append(UInt8(truncatingIfNeeded: powerOnTime >> 24))

        // Offset time (LE)
        frame.append(UInt8(truncatingIfNeeded: offsetTime))
        frame.append(UInt8(truncatingIfNeeded: offsetTime >> 8))
        frame.append(UInt8(truncatingIfNeeded: offsetTime >> 16))
        frame.append(UInt8(truncatingIfNeeded: offsetTime >> 24))

        // Modbus RTU frame
        frame.append(contentsOf: modbus)

        // Calculate checksum (sum of bytes[1..<current_length] & 0xFF)
        let checksum = frame[1...].reduce(UInt8(0)) { $0 &+ $1 }
        frame.append(checksum)

        // End marker
        frame.append(0x15)

        return frame
    }
}
