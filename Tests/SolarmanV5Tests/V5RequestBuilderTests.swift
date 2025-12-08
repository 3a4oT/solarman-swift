// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

@testable import SolarmanV5
import Testing

/// Tests for `buildV5RequestFrame()` function.
///
/// **Focus:**
/// - Correct frame structure and byte order
/// - Edge cases for serial, sequence, and modbus data
/// - Length calculation edge cases
/// - Checksum calculation correctness
@Suite("V5 Request Builder")
struct V5RequestBuilderTests {
    // MARK: - Basic Structure Tests

    @Test("Frame has correct start and end markers")
    func frameMarkers() {
        let frame = buildV5RequestFrame(serial: 0x1234_5678, sequence: 1, modbusFrame: [])
        #expect(frame.first == 0xA5)
        #expect(frame.last == 0x15)
    }

    @Test("Frame has correct control code")
    func frameControlCode() {
        let frame = buildV5RequestFrame(serial: 0x1234_5678, sequence: 1, modbusFrame: [])
        // Control code at offset 3-4: 0x4510 (LE = 0x10, 0x45)
        #expect(frame[3] == 0x10)
        #expect(frame[4] == 0x45)
    }

    @Test("Frame has correct frame type")
    func frameType() {
        let frame = buildV5RequestFrame(serial: 0x1234_5678, sequence: 1, modbusFrame: [])
        // Frame type at offset 11: 0x02 (inverter)
        #expect(frame[11] == 0x02)
    }

    @Test("Frame has zeroed time fields")
    func zeroedTimeFields() {
        let frame = buildV5RequestFrame(serial: 0x1234_5678, sequence: 1, modbusFrame: [])
        // Sensor type at 12-13
        #expect(frame[12] == 0x00)
        #expect(frame[13] == 0x00)
        // Total working time at 14-17
        #expect(frame[14...17].allSatisfy { $0 == 0x00 })
        // Power on time at 18-21
        #expect(frame[18...21].allSatisfy { $0 == 0x00 })
        // Offset time at 22-25
        #expect(frame[22...25].allSatisfy { $0 == 0x00 })
    }

    // MARK: - Sequence Number Tests

    @Test("Sequence number encoded in Little Endian")
    func sequenceIsLittleEndian() {
        let frame = buildV5RequestFrame(serial: 0, sequence: 0x0102, modbusFrame: [])
        // Sequence at offset 5-6: 0x0102 LE = [0x02, 0x01]
        #expect(frame[5] == 0x02)
        #expect(frame[6] == 0x01)
    }

    @Test("Minimum sequence number (1)")
    func minSequence() {
        let frame = buildV5RequestFrame(serial: 0, sequence: 1, modbusFrame: [])
        #expect(frame[5] == 0x01)
        #expect(frame[6] == 0x00)
    }

    @Test("Maximum sequence number (0xFFFF)")
    func maxSequence() {
        let frame = buildV5RequestFrame(serial: 0, sequence: 0xFFFF, modbusFrame: [])
        #expect(frame[5] == 0xFF)
        #expect(frame[6] == 0xFF)
    }

    @Test("Zero sequence number")
    func zeroSequence() {
        let frame = buildV5RequestFrame(serial: 0, sequence: 0, modbusFrame: [])
        #expect(frame[5] == 0x00)
        #expect(frame[6] == 0x00)
    }

    // MARK: - Serial Number Tests

    @Test("Serial number encoded in Little Endian")
    func serialIsLittleEndian() {
        let frame = buildV5RequestFrame(serial: 0x0102_0304, sequence: 1, modbusFrame: [])
        // Serial at offset 7-10: 0x01020304 LE = [0x04, 0x03, 0x02, 0x01]
        #expect(frame[7] == 0x04)
        #expect(frame[8] == 0x03)
        #expect(frame[9] == 0x02)
        #expect(frame[10] == 0x01)
    }

    @Test("Real-world serial number (17xxxxxxx)")
    func realWorldSerial17() {
        let serial: UInt32 = 1_700_000_001 // 0x6553A101
        let frame = buildV5RequestFrame(serial: serial, sequence: 1, modbusFrame: [])

        // Verify Little Endian encoding
        let decodedSerial = UInt32(frame[7]) |
            (UInt32(frame[8]) << 8) |
            (UInt32(frame[9]) << 16) |
            (UInt32(frame[10]) << 24)
        #expect(decodedSerial == serial)
    }

    @Test("Real-world serial number (21xxxxxxx)")
    func realWorldSerial21() {
        let serial: UInt32 = 2_100_000_001 // 0x7D2B7501
        let frame = buildV5RequestFrame(serial: serial, sequence: 1, modbusFrame: [])

        let decodedSerial = UInt32(frame[7]) |
            (UInt32(frame[8]) << 8) |
            (UInt32(frame[9]) << 16) |
            (UInt32(frame[10]) << 24)
        #expect(decodedSerial == serial)
    }

    @Test("Maximum serial number (0xFFFFFFFF)")
    func maxSerial() {
        let frame = buildV5RequestFrame(serial: 0xFFFF_FFFF, sequence: 1, modbusFrame: [])
        #expect(frame[7] == 0xFF)
        #expect(frame[8] == 0xFF)
        #expect(frame[9] == 0xFF)
        #expect(frame[10] == 0xFF)
    }

    @Test("Zero serial number")
    func zeroSerial() {
        let frame = buildV5RequestFrame(serial: 0, sequence: 1, modbusFrame: [])
        #expect(frame[7...10].allSatisfy { $0 == 0x00 })
    }

    // MARK: - Length Field Tests

    @Test("Length field correct for empty modbus")
    func lengthEmptyModbus() {
        let frame = buildV5RequestFrame(serial: 0, sequence: 1, modbusFrame: [])
        // Length = 15 (fixed fields after length, before modbus)
        let length = UInt16(frame[1]) | (UInt16(frame[2]) << 8)
        #expect(length == 15)
    }

    @Test("Length field correct for 8-byte modbus")
    func length8ByteModbus() {
        let modbus: [UInt8] = [0x01, 0x03, 0x00, 0x00, 0x00, 0x01, 0x84, 0x0A]
        let frame = buildV5RequestFrame(serial: 0, sequence: 1, modbusFrame: modbus)
        // Length = 15 + 8 = 23
        let length = UInt16(frame[1]) | (UInt16(frame[2]) << 8)
        #expect(length == 23)
    }

    @Test("Length field correct for large modbus")
    func lengthLargeModbus() {
        let modbus = [UInt8](repeating: 0x42, count: 500)
        let frame = buildV5RequestFrame(serial: 0, sequence: 1, modbusFrame: modbus)
        // Length = 15 + 500 = 515
        let length = UInt16(frame[1]) | (UInt16(frame[2]) << 8)
        #expect(length == 515)
    }

    // MARK: - Modbus Data Tests

    @Test("Modbus data appended correctly")
    func modbusDataAppended() {
        let modbus: [UInt8] = [0x01, 0x03, 0x00, 0x00, 0x00, 0x01, 0x84, 0x0A]
        let frame = buildV5RequestFrame(serial: 0, sequence: 1, modbusFrame: modbus)

        // Modbus starts at offset 26
        let extractedModbus = Array(frame[26..<(frame.count - 2)])
        #expect(extractedModbus == modbus)
    }

    @Test("Empty modbus frame is valid")
    func emptyModbusFrame() {
        let frame = buildV5RequestFrame(serial: 0, sequence: 1, modbusFrame: [])

        // Frame should still be valid: header(26) + trailer(2) = 28
        #expect(frame.count == 28)
        #expect(frame.first == 0xA5)
        #expect(frame.last == 0x15)
    }

    @Test("Large modbus frame")
    func largeModbusFrame() {
        // Maximum Modbus write: 123 registers * 2 + overhead
        let modbus = [UInt8](repeating: 0x42, count: 260)
        let frame = buildV5RequestFrame(serial: 0, sequence: 1, modbusFrame: modbus)

        // Frame size: header(26) + modbus(260) + trailer(2) = 288
        #expect(frame.count == 288)

        // Verify modbus data intact
        let extractedModbus = Array(frame[26..<(frame.count - 2)])
        #expect(extractedModbus == modbus)
    }

    // MARK: - Checksum Tests

    @Test("Checksum is valid")
    func checksumIsValid() {
        let modbus: [UInt8] = [0x01, 0x03, 0x00, 0x00, 0x00, 0x01, 0x84, 0x0A]
        let frame = buildV5RequestFrame(serial: 0x1234_5678, sequence: 1, modbusFrame: modbus)

        // Calculate expected checksum
        let expectedChecksum = calculateV5Checksum(frame[1..<(frame.count - 2)])

        // Verify checksum in frame
        #expect(frame[frame.count - 2] == expectedChecksum)
    }

    @Test("Checksum changes with different serial")
    func checksumChangesWithSerial() {
        let modbus: [UInt8] = [0x01, 0x03, 0x00, 0x00]
        let frame1 = buildV5RequestFrame(serial: 0x1111_1111, sequence: 1, modbusFrame: modbus)
        let frame2 = buildV5RequestFrame(serial: 0x2222_2222, sequence: 1, modbusFrame: modbus)

        #expect(frame1[frame1.count - 2] != frame2[frame2.count - 2])
    }

    @Test("Checksum changes with different sequence")
    func checksumChangesWithSequence() {
        let modbus: [UInt8] = [0x01, 0x03, 0x00, 0x00]
        let frame1 = buildV5RequestFrame(serial: 0x1234_5678, sequence: 1, modbusFrame: modbus)
        let frame2 = buildV5RequestFrame(serial: 0x1234_5678, sequence: 2, modbusFrame: modbus)

        #expect(frame1[frame1.count - 2] != frame2[frame2.count - 2])
    }

    @Test("Checksum changes with different modbus data")
    func checksumChangesWithModbus() {
        let frame1 = buildV5RequestFrame(serial: 0x1234_5678, sequence: 1, modbusFrame: [0x01, 0x03])
        let frame2 = buildV5RequestFrame(serial: 0x1234_5678, sequence: 1, modbusFrame: [0x01, 0x04])

        #expect(frame1[frame1.count - 2] != frame2[frame2.count - 2])
    }

    // MARK: - Frame Size Tests

    @Test("Minimum frame size (empty modbus)")
    func minFrameSize() {
        let frame = buildV5RequestFrame(serial: 0, sequence: 1, modbusFrame: [])
        // header(26) + trailer(2) = 28
        #expect(frame.count == 28)
    }

    @Test("Frame size matches pysolarmanv5 test vector")
    func frameSizeMatchesPythonTestVector() {
        // Test vector from V5FrameTests
        let modbus: [UInt8] = [0x01, 0x03, 0x00, 0x00, 0x00, 0x01, 0x84, 0x0A]
        let frame = buildV5RequestFrame(serial: 0x1234_5678, sequence: 1, modbusFrame: modbus)
        // header(26) + modbus(8) + trailer(2) = 36
        #expect(frame.count == 36)
    }

    // MARK: - pysolarmanv5 Compatibility Tests

    @Test("Matches pysolarmanv5 reference frame exactly")
    func matchesPythonReference() {
        // This test vector is generated using pysolarmanv5 reference implementation
        let serial: UInt32 = 0x1234_5678
        let sequence: UInt16 = 0x0001
        let modbus: [UInt8] = [0x01, 0x03, 0x00, 0x00, 0x00, 0x01, 0x84, 0x0A]

        let frame = buildV5RequestFrame(serial: serial, sequence: sequence, modbusFrame: modbus)

        let expected: [UInt8] = [
            0xA5, 0x17, 0x00, 0x10, 0x45, 0x01, 0x00,
            0x78, 0x56, 0x34, 0x12, 0x02, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x03,
            0x00, 0x00, 0x00, 0x01, 0x84, 0x0A, 0x16, 0x15,
        ]

        #expect(frame == expected)
    }
}
