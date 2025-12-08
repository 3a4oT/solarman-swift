// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

@testable import SolarmanV5
import Testing

/// Tests for double-CRC detection and correction.
///
/// Some inverter/data logger combinations (DEYE, others) erroneously apply
/// Modbus CRC twice. This results in frames ending with `0x0000` because
/// CRC of a frame that already has valid CRC is always zero.
///
/// Reference: pysolarmanv5 `_handle_double_crc()`
@Suite("Double CRC Correction")
struct DoubleCRCTests {
    // MARK: - Detection Tests

    @Test("Detects and corrects double CRC frame")
    func detectDoubleCRC() {
        // Normal Modbus RTU frame: unitId(01) + func(03) + byteCount(02) + data(1234) + CRC
        // CRC of [01 03 02 12 34] = 0x33B5 (LE: B5 33)
        let normalFrame: [UInt8] = [0x01, 0x03, 0x02, 0x12, 0x34, 0xB5, 0x33]

        // Double-CRC frame: normalFrame + 00 00 (CRC of valid CRC frame is always 0x0000)
        let doubleCRCFrame: [UInt8] = [0x01, 0x03, 0x02, 0x12, 0x34, 0xB5, 0x33, 0x00, 0x00]

        let (corrected, wasCorrected) = detectAndCorrectDoubleCRC(doubleCRCFrame[...])

        #expect(wasCorrected == true)
        #expect(corrected == normalFrame)
    }

    @Test("Detects double CRC with different register data")
    func doubleCRCDifferentData() {
        // Read Holding Registers response: unitId(01) + func(03) + byteCount(04) + data(AABBCCDD)
        let data: [UInt8] = [0x01, 0x03, 0x04, 0xAA, 0xBB, 0xCC, 0xDD]
        let crc = calculateModbusCRC16(data)
        let crcLow = UInt8(crc & 0xFF)
        let crcHigh = UInt8(crc >> 8)

        let normalFrame = data + [crcLow, crcHigh]
        let doubleCRCFrame = normalFrame + [0x00, 0x00]

        let (corrected, wasCorrected) = detectAndCorrectDoubleCRC(doubleCRCFrame[...])

        #expect(wasCorrected == true)
        #expect(corrected == normalFrame)
    }

    @Test("Detects double CRC for write response")
    func doubleCRCWriteResponse() {
        // Write Single Register response: unitId(01) + func(06) + addr(0010) + value(1234)
        let data: [UInt8] = [0x01, 0x06, 0x00, 0x10, 0x12, 0x34]
        let crc = calculateModbusCRC16(data)
        let crcLow = UInt8(crc & 0xFF)
        let crcHigh = UInt8(crc >> 8)

        let normalFrame = data + [crcLow, crcHigh]
        let doubleCRCFrame = normalFrame + [0x00, 0x00]

        let (corrected, wasCorrected) = detectAndCorrectDoubleCRC(doubleCRCFrame[...])

        #expect(wasCorrected == true)
        #expect(corrected == normalFrame)
    }

    // MARK: - No Correction Tests

    @Test("No correction for normal frame without double CRC")
    func noDoubleCRCCorrection() {
        let normalFrame: [UInt8] = [0x01, 0x03, 0x02, 0x12, 0x34, 0xB5, 0x33]

        let (result, wasCorrected) = detectAndCorrectDoubleCRC(normalFrame[...])

        #expect(wasCorrected == false)
        #expect(result == normalFrame)
    }

    @Test("No correction for frame ending in 0x0000 but with invalid CRC after strip")
    func noDoubleCRCForInvalidCRC() {
        // Frame ends in 0x0000 but stripping doesn't yield valid CRC
        // This protects against false positives
        let invalidFrame: [UInt8] = [0x01, 0x03, 0x02, 0x12, 0x34, 0xFF, 0xFF, 0x00, 0x00]

        let (result, wasCorrected) = detectAndCorrectDoubleCRC(invalidFrame[...])

        #expect(wasCorrected == false)
        #expect(result == invalidFrame)
    }

    @Test("No correction for frame not ending in 0x0000")
    func noDoubleCRCForWrongEnding() {
        let frame: [UInt8] = [0x01, 0x03, 0x02, 0x12, 0x34, 0xB5, 0x33, 0x01, 0x02]

        let (result, wasCorrected) = detectAndCorrectDoubleCRC(frame[...])

        #expect(wasCorrected == false)
        #expect(result == frame)
    }

    // MARK: - Edge Cases

    @Test("No correction for frame too short (< 6 bytes)")
    func noDoubleCRCForShortFrame() {
        // Frame with less than 6 bytes cannot have double CRC
        // (need at least 4 bytes for valid RTU + 2 bytes for extra CRC)
        let shortFrame: [UInt8] = [0x01, 0x03, 0x00, 0x00]

        let (result, wasCorrected) = detectAndCorrectDoubleCRC(shortFrame[...])

        #expect(wasCorrected == false)
        #expect(result == shortFrame)
    }

    @Test("No correction for empty frame")
    func noDoubleCRCForEmptyFrame() {
        let emptyFrame: [UInt8] = []

        let (result, wasCorrected) = detectAndCorrectDoubleCRC(emptyFrame[...])

        #expect(wasCorrected == false)
        #expect(result == emptyFrame)
    }

    @Test("No correction for minimum RTU frame ending in 0x0000")
    func noDoubleCRCForMinimumFrame() {
        // Exactly 6 bytes ending in 00 00, but candidate would be only 4 bytes
        // and CRC would not validate
        let frame: [UInt8] = [0x01, 0x03, 0x02, 0x00, 0x00, 0x00]

        let (result, wasCorrected) = detectAndCorrectDoubleCRC(frame[...])

        #expect(wasCorrected == false)
        #expect(result == frame)
    }

    // MARK: - Security Tests

    @Test("Does not corrupt valid frame with coincidental 0x0000 ending")
    func securityNoCorruptionOnCoincidentalEnding() {
        // A valid frame where the last register value happens to be 0x0000
        // and CRC happens to end in 0x0000 (extremely rare but possible)
        // The function should NOT strip bytes because stripped frame CRC won't match
        let data: [UInt8] = [0x01, 0x03, 0x02, 0x00, 0x00] // Read result: 0x0000
        let crc = calculateModbusCRC16(data)

        // Only if CRC happens to be 0x0000 would this be an issue
        // In practice, CRC(data) is almost never 0x0000 for valid data
        if crc == 0x0000 {
            // This is the pathological case - frame looks like double-CRC
            // but we can't distinguish. Accept this limitation.
        } else {
            let crcLow = UInt8(crc & 0xFF)
            let crcHigh = UInt8(crc >> 8)
            let normalFrame = data + [crcLow, crcHigh]

            let (result, wasCorrected) = detectAndCorrectDoubleCRC(normalFrame[...])

            #expect(wasCorrected == false)
            #expect(result == normalFrame)
        }
    }
}
