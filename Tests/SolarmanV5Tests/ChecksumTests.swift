// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

@testable import SolarmanV5
import Testing

/// Tests for Solarman V5 checksum calculation
///
/// Algorithm: sum of all bytes & 0xFF
/// Applied to frame bytes excluding: Start (0xA5), Checksum, End (0x15)
@Suite("V5 Checksum")
struct ChecksumTests {
    // MARK: - Basic Algorithm Tests

    @Test("Empty input returns zero")
    func emptyInput() {
        let result = calculateV5Checksum([UInt8]())
        #expect(result == 0)
    }

    @Test("Single byte returns itself")
    func singleByte() {
        #expect(calculateV5Checksum([0x00]) == 0x00)
        #expect(calculateV5Checksum([0x01]) == 0x01)
        #expect(calculateV5Checksum([0xFF]) == 0xFF)
        #expect(calculateV5Checksum([0x42]) == 0x42)
    }

    @Test("Sum without overflow")
    func sumNoOverflow() {
        // 0x10 + 0x20 + 0x30 = 0x60
        #expect(calculateV5Checksum([0x10, 0x20, 0x30]) == 0x60)

        // 1 + 2 + 3 + 4 + 5 = 15 = 0x0F
        #expect(calculateV5Checksum([1, 2, 3, 4, 5]) == 0x0F)
    }

    @Test("Sum with overflow wraps to single byte")
    func sumWithOverflow() {
        // 0xFF + 0x01 = 0x100 -> 0x00
        #expect(calculateV5Checksum([0xFF, 0x01]) == 0x00)

        // 0xFF + 0x02 = 0x101 -> 0x01
        #expect(calculateV5Checksum([0xFF, 0x02]) == 0x01)

        // 0x80 + 0x80 = 0x100 -> 0x00
        #expect(calculateV5Checksum([0x80, 0x80]) == 0x00)

        // 0xFF + 0xFF = 0x1FE -> 0xFE
        #expect(calculateV5Checksum([0xFF, 0xFF]) == 0xFE)

        // 0xFF * 3 = 0x2FD -> 0xFD
        #expect(calculateV5Checksum([0xFF, 0xFF, 0xFF]) == 0xFD)
    }

    @Test("Large array with multiple overflows")
    func largeArrayMultipleOverflows() {
        // 256 bytes of 0x01 = 256 = 0x100 -> 0x00
        let bytes = [UInt8](repeating: 0x01, count: 256)
        #expect(calculateV5Checksum(bytes) == 0x00)

        // 257 bytes of 0x01 = 257 = 0x101 -> 0x01
        let bytes257 = [UInt8](repeating: 0x01, count: 257)
        #expect(calculateV5Checksum(bytes257) == 0x01)

        // 100 bytes of 0xFF = 100 * 255 = 25500 = 0x639C -> 0x9C
        let bytesFF = [UInt8](repeating: 0xFF, count: 100)
        #expect(calculateV5Checksum(bytesFF) == 0x9C)
    }

    // MARK: - Span Input Tests

    @Test("Span input works correctly")
    func spanInput() {
        let array: [UInt8] = [0x10, 0x20, 0x30, 0x40]
        let result = array.withUnsafeBufferPointer { buffer in
            let span = Span<UInt8>(_unsafeStart: buffer.baseAddress!, count: buffer.count)
            return calculateV5Checksum(span)
        }
        // 0x10 + 0x20 + 0x30 + 0x40 = 0xA0
        #expect(result == 0xA0)
    }

    // MARK: - ArraySlice Input Tests

    @Test("ArraySlice input works correctly")
    func arraySliceInput() {
        let array: [UInt8] = [0xAA, 0x10, 0x20, 0x30, 0xBB]
        let slice = array[1..<4] // [0x10, 0x20, 0x30]
        #expect(calculateV5Checksum(slice) == 0x60)
    }

    // MARK: - Simulated V5 Frame Tests

    @Test("Simulated V5 frame header checksum")
    func simulatedV5FrameHeader() {
        // Simulated frame content (excluding Start 0xA5, Checksum, End 0x15):
        // Length: 0x1F 0x00 (31, little-endian)
        // Control: 0x10 0x45 (0x4510, little-endian)
        // Seq: 0x01 0x00
        // Serial: 0x78 0x56 0x34 0x12 (0x12345678, little-endian)
        // FrameType: 0x02
        // SensorType: 0x00 0x00
        // TotalWorkingTime: 0x00 0x00 0x00 0x00
        // PowerOnTime: 0x00 0x00 0x00 0x00
        // OffsetTime: 0x00 0x00 0x00 0x00
        // Modbus: 0x01 0x03 0x00 0x00 0x00 0x01 0x84 0x0A

        let frameContent: [UInt8] = [
            // Length (2 bytes)
            0x1F, 0x00,
            // Control code (2 bytes)
            0x10, 0x45,
            // Sequence (2 bytes)
            0x01, 0x00,
            // Logger serial (4 bytes)
            0x78, 0x56, 0x34, 0x12,
            // Frame type (1 byte)
            0x02,
            // Sensor type (2 bytes)
            0x00, 0x00,
            // Total working time (4 bytes)
            0x00, 0x00, 0x00, 0x00,
            // Power on time (4 bytes)
            0x00, 0x00, 0x00, 0x00,
            // Offset time (4 bytes)
            0x00, 0x00, 0x00, 0x00,
            // Modbus RTU frame (8 bytes: read 1 register from address 0)
            0x01, 0x03, 0x00, 0x00, 0x00, 0x01, 0x84, 0x0A,
        ]

        let checksum = calculateV5Checksum(frameContent)

        // Manual calculation:
        // 0x1F + 0x00 + 0x10 + 0x45 + 0x01 + 0x00 + 0x78 + 0x56 + 0x34 + 0x12
        // + 0x02 + 0x00 + 0x00 + 0x00 + 0x00 + 0x00 + 0x00 + 0x00 + 0x00 + 0x00
        // + 0x00 + 0x00 + 0x00 + 0x00 + 0x01 + 0x03 + 0x00 + 0x00 + 0x00 + 0x01 + 0x84 + 0x0A
        // = 31 + 0 + 16 + 69 + 1 + 0 + 120 + 86 + 52 + 18
        // + 2 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0 + 0
        // + 0 + 0 + 0 + 0 + 1 + 3 + 0 + 0 + 0 + 1 + 132 + 10
        // = 542 = 0x21E -> 0x1E
        #expect(checksum == 0x1E)
    }
}
