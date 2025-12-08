// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

// MARK: - V5FrameError

/// Errors that can occur when parsing V5 frames
public enum V5FrameError: Error, Equatable, Sendable {
    /// Frame is shorter than minimum valid size
    case frameTooShort
    /// Start byte is not 0xA5
    case invalidStartByte
    /// End byte is not 0x15
    case invalidEndByte
    /// Checksum does not match calculated value
    case invalidChecksum
    /// Control code is not a valid response code
    case invalidControlCode
    /// Modbus frame is too short (< 5 bytes)
    case modbusFrameTooShort
    /// Length field does not match actual frame size
    case lengthMismatch
}

// MARK: - V5Response

/// Parsed V5 response frame data
public struct V5Response: Equatable, Sendable {
    /// Request sequence number (echoed back)
    public let sequence: UInt16
    /// Logger serial number
    public let serial: UInt32
    /// Frame type (0x02 for inverter data)
    public let frameType: UInt8
    /// Response status (0x01 = OK)
    public let status: UInt8
    /// Total operating time in seconds
    public let totalWorkingTime: UInt32
    /// Power on time in seconds
    public let powerOnTime: UInt32
    /// Timestamp offset
    public let offsetTime: UInt32
    /// Extracted Modbus RTU frame (including CRC)
    public let modbusFrame: [UInt8]
}

// MARK: - V5Marker

/// V5 frame markers
public enum V5Marker {
    /// Frame start byte
    public static let start: UInt8 = 0xA5
    /// Frame end byte
    public static let end: UInt8 = 0x15
}

// MARK: - V5ControlCode

/// V5 control codes (Little Endian in frame)
public enum V5ControlCode {
    /// Request to inverter: 0x4510 (LE: 0x10 0x45)
    public static let request: UInt16 = 0x4510
    /// Response from inverter: 0x1510 (LE: 0x10 0x15)
    public static let response: UInt16 = 0x1510
    /// Heartbeat/keep-alive: 0x4710 (LE: 0x10 0x47)
    public static let heartbeat: UInt16 = 0x4710
}

// MARK: - V5FrameType

/// V5 frame type values
public enum V5FrameType {
    /// Inverter data frame
    public static let inverter: UInt8 = 0x02
}

// MARK: - V5Status

/// V5 response status values
public enum V5Status {
    /// Real-time data OK
    public static let ok: UInt8 = 0x01
}

// MARK: - V5RequestOffset

/// Byte offsets for V5 request frame fields
public enum V5RequestOffset {
    public static let start = 0
    public static let length = 1
    public static let controlCode = 3
    public static let sequence = 5
    public static let serial = 7
    public static let frameType = 11
    public static let sensorType = 12
    public static let totalWorkingTime = 14
    public static let powerOnTime = 18
    public static let offsetTime = 22
    public static let modbusRTU = 26
}

// MARK: - V5ResponseOffset

/// Byte offsets for V5 response frame fields
public enum V5ResponseOffset {
    public static let start = 0
    public static let length = 1
    public static let controlCode = 3
    public static let sequence = 5
    public static let serial = 7
    public static let frameType = 11
    public static let status = 12
    public static let totalWorkingTime = 13
    public static let powerOnTime = 17
    public static let offsetTime = 21
    public static let modbusRTU = 25
}

// MARK: - V5FrameSize

/// Fixed sizes for V5 frame components
public enum V5FrameSize {
    /// Request header size (before Modbus RTU): 26 bytes
    public static let requestHeader = 26
    /// Response header size (before Modbus RTU): 25 bytes
    public static let responseHeader = 25
    /// Trailer size (checksum + end): 2 bytes
    public static let trailer = 2
    /// Minimum valid frame size
    public static let minimum = 28 // header + trailer
}

// MARK: - Request Frame Builder

/// Builds a V5 request frame wrapping a Modbus RTU frame.
///
/// Frame structure (all multi-byte values Little Endian):
/// - Start: 0xA5
/// - Length: 15 + len(modbusFrame)
/// - Control: 0x4510 (request)
/// - Sequence: request ID
/// - Serial: logger serial number
/// - Frame type: 0x02
/// - Sensor type: 0x0000
/// - Times: all zeros (12 bytes)
/// - Modbus RTU frame
/// - Checksum: sum of bytes[1..<end-1] & 0xFF
/// - End: 0x15
///
/// - Parameters:
///   - serial: Logger serial number (e.g., 1700000001)
///   - sequence: Request sequence number
///   - modbusFrame: Complete Modbus RTU frame with CRC
/// - Returns: Complete V5 frame ready for transmission
@inlinable
public func buildV5RequestFrame(
    serial: UInt32,
    sequence: UInt16,
    modbusFrame: [UInt8],
) -> [UInt8] {
    // Payload length = 15 (fixed fields after length) + modbus frame
    let payloadLength = UInt16(15 + modbusFrame.count)

    // Pre-allocate frame: header (26) + modbus + trailer (2)
    var frame = [UInt8]()
    frame.reserveCapacity(V5FrameSize.requestHeader + modbusFrame.count + V5FrameSize.trailer)

    // Start marker
    frame.append(V5Marker.start)

    // Length (2 bytes, LE)
    frame.append(UInt8(truncatingIfNeeded: payloadLength))
    frame.append(UInt8(truncatingIfNeeded: payloadLength >> 8))

    // Control code (2 bytes, LE): 0x4510 -> 0x10 0x45
    frame.append(UInt8(truncatingIfNeeded: V5ControlCode.request))
    frame.append(UInt8(truncatingIfNeeded: V5ControlCode.request >> 8))

    // Sequence (2 bytes, LE)
    frame.append(UInt8(truncatingIfNeeded: sequence))
    frame.append(UInt8(truncatingIfNeeded: sequence >> 8))

    // Serial (4 bytes, LE)
    frame.append(UInt8(truncatingIfNeeded: serial))
    frame.append(UInt8(truncatingIfNeeded: serial >> 8))
    frame.append(UInt8(truncatingIfNeeded: serial >> 16))
    frame.append(UInt8(truncatingIfNeeded: serial >> 24))

    // Frame type
    frame.append(V5FrameType.inverter)

    // Sensor type (2 bytes)
    frame.append(0x00)
    frame.append(0x00)

    // Total working time (4 bytes)
    frame.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

    // Power on time (4 bytes)
    frame.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

    // Offset time (4 bytes)
    frame.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

    // Modbus RTU frame
    frame.append(contentsOf: modbusFrame)

    // Checksum: sum of bytes[1..<current_length] & 0xFF
    let checksum = calculateV5Checksum(frame[1...])
    frame.append(checksum)

    // End marker
    frame.append(V5Marker.end)

    return frame
}

// MARK: - Response Frame Validation (Internal)

/// Minimum Modbus RTU frame size (per pysolarmanv5)
@usableFromInline
let minModbusFrameSize = 5

/// Minimum response frame size: header(25) + minModbus(5) + trailer(2)
@usableFromInline
let minResponseFrameSize = V5FrameSize.responseHeader + minModbusFrameSize + V5FrameSize.trailer

/// Validates minimum frame size.
@inlinable
func validateMinimumSize(_ frame: Span<UInt8>) throws(V5FrameError) {
    guard frame.count >= minResponseFrameSize else {
        throw .frameTooShort
    }
}

/// Validates start and end markers.
@inlinable
func validateMarkers(_ frame: Span<UInt8>) throws(V5FrameError) {
    // Defense in depth: use safe access
    guard let startByte = readUInt8(frame, at: 0) else {
        throw .frameTooShort
    }
    guard startByte == V5Marker.start else {
        throw .invalidStartByte
    }
    guard let endByte = readUInt8(frame, at: frame.count - 1) else {
        throw .frameTooShort
    }
    guard endByte == V5Marker.end else {
        throw .invalidEndByte
    }
}

/// Validates length field matches actual frame size.
@inlinable
func validateLength(_ frame: Span<UInt8>) throws(V5FrameError) {
    // Bounds already validated by validateMinimumSize
    guard let declaredLength = readUInt16LE(frame, at: V5ResponseOffset.length) else {
        throw .frameTooShort
    }
    // V5 frame structure:
    // - Header: start(1) + length(2) + control(2) + sequence(2) + serial(4) = 11 bytes
    // - Payload: frameType(1) + sensorType(2) + times(12) + modbusFrame = declaredLength bytes
    // - Trailer: checksum(1) + end(1) = 2 bytes
    // Total = declaredLength + 13
    let expectedFrameSize = Int(declaredLength) + 13
    guard frame.count == expectedFrameSize else {
        throw .lengthMismatch
    }
}

/// Validates checksum.
@inlinable
func validateChecksum(_ frame: Span<UInt8>) throws(V5FrameError) {
    // Checksum covers bytes[1..<frame.count-2]
    var sum: UInt = 0
    for i in 1..<(frame.count - 2) {
        // Defense in depth: use safe access
        guard let byte = readUInt8(frame, at: i) else {
            throw .frameTooShort
        }
        sum &+= UInt(byte)
    }
    let calculatedChecksum = UInt8(truncatingIfNeeded: sum)
    // Defense in depth: use safe access
    guard let storedChecksum = readUInt8(frame, at: frame.count - 2) else {
        throw .frameTooShort
    }
    guard storedChecksum == calculatedChecksum else {
        throw .invalidChecksum
    }
}

/// Validates control code is response type.
@inlinable
func validateControlCode(_ frame: Span<UInt8>) throws(V5FrameError) {
    // Bounds already validated by validateMinimumSize
    guard let controlCode = readUInt16LE(frame, at: V5ResponseOffset.controlCode) else {
        throw .frameTooShort
    }
    guard controlCode == V5ControlCode.response else {
        throw .invalidControlCode
    }
}

/// Validates Modbus frame has minimum required size.
@inlinable
func validateModbusSize(_ frame: Span<UInt8>) throws(V5FrameError) {
    let modbusSize = frame.count - V5ResponseOffset.modbusRTU - V5FrameSize.trailer
    guard modbusSize >= minModbusFrameSize else {
        throw .modbusFrameTooShort
    }
}

// MARK: - ValidatedV5Response

/// Validated V5 response providing safe field access.
///
/// After validation, field accessors are guaranteed to succeed.
public struct ValidatedV5Response: Sendable {
    // MARK: Lifecycle

    /// Internal initializer - only called after validation
    @usableFromInline
    init(frameBytes: [UInt8]) {
        self.frameBytes = frameBytes
    }

    // MARK: Public

    /// Request sequence number (echoed back)
    public var sequence: UInt16? {
        readUInt16LE(frameBytes, at: V5ResponseOffset.sequence)
    }

    /// Logger serial number
    public var serial: UInt32? {
        readUInt32LE(frameBytes, at: V5ResponseOffset.serial)
    }

    /// Frame type (0x02 for inverter data)
    public var frameType: UInt8? {
        readUInt8(frameBytes, at: V5ResponseOffset.frameType)
    }

    /// Response status (0x01 = OK)
    public var status: UInt8? {
        readUInt8(frameBytes, at: V5ResponseOffset.status)
    }

    /// Total operating time in seconds
    public var totalWorkingTime: UInt32? {
        readUInt32LE(frameBytes, at: V5ResponseOffset.totalWorkingTime)
    }

    /// Power on time in seconds
    public var powerOnTime: UInt32? {
        readUInt32LE(frameBytes, at: V5ResponseOffset.powerOnTime)
    }

    /// Timestamp offset
    public var offsetTime: UInt32? {
        readUInt32LE(frameBytes, at: V5ResponseOffset.offsetTime)
    }

    /// Extracted Modbus RTU frame (including CRC)
    public var modbusFrame: ArraySlice<UInt8> {
        frameBytes[V5ResponseOffset.modbusRTU..<(frameBytes.count - V5FrameSize.trailer)]
    }

    // MARK: Private

    /// Raw frame bytes (validated)
    private let frameBytes: [UInt8]
}

/// Parses and validates a V5 response frame.
///
/// Performs all security validations in order:
/// 1. Minimum frame length
/// 2. Start/end markers
/// 3. Length field cross-validation
/// 4. Checksum verification
/// 5. Control code validation
/// 6. Modbus frame minimum size
///
/// - Parameter frame: Raw V5 response frame bytes
/// - Returns: Validated response with safe field accessors
/// - Throws: `V5FrameError` if validation fails
@inlinable
public func parseV5ResponseFrame(_ frame: Span<UInt8>) throws(V5FrameError) -> ValidatedV5Response {
    // All validations
    try validateMinimumSize(frame)
    try validateMarkers(frame)
    try validateLength(frame)
    try validateChecksum(frame)
    try validateControlCode(frame)
    try validateModbusSize(frame)

    // Copy to array for storage (frame is borrowed, can't store Span)
    var bytes = [UInt8]()
    bytes.reserveCapacity(frame.count)
    for i in frame.indices {
        bytes.append(frame[i])
    }

    return ValidatedV5Response(frameBytes: bytes)
}

/// Convenience overload for Array input.
@inlinable
public func parseV5ResponseFrame(_ frame: [UInt8]) throws(V5FrameError) -> ValidatedV5Response {
    try parseV5ResponseFrame(frame.span)
}

// MARK: - Double CRC Correction

/// Detects and corrects the double-CRC bug found in some inverters.
///
/// Some inverter/data logger combinations (DEYE, others) erroneously append
/// the Modbus CRC twice. This results in frames ending with `0x0000` because
/// CRC of a frame that already has valid CRC is always 0x0000.
///
/// **Security Note:** This function validates CRC AFTER stripping bytes.
/// It does NOT blindly truncate data — it only returns corrected frame
/// if the stripped frame has valid CRC.
///
/// **Algorithm:**
/// 1. Check if frame ends with `0x0000` (signature of double-CRC)
/// 2. Strip trailing 2 bytes to get candidate frame
/// 3. Validate CRC on candidate frame
/// 4. Return corrected frame ONLY if CRC validates
///
/// Reference: pysolarmanv5 `_handle_double_crc()`
///
/// - Parameter modbusFrame: Modbus RTU frame bytes (with CRC)
/// - Returns: Tuple of (correctedFrame, wasDoubleCRC)
@inlinable
public func detectAndCorrectDoubleCRC(_ modbusFrame: ArraySlice<UInt8>) -> (frame: [UInt8], corrected: Bool) {
    let frameArray = Array(modbusFrame)

    // Must have at least 6 bytes: unitId(1) + fc(1) + data(min 0) + CRC(2) + extra_CRC(2)
    guard frameArray.count >= 6 else {
        return (frameArray, false)
    }

    // Check for trailing 0x0000 (signature of double-CRC)
    // Use safe access via readUInt8
    guard let secondLast = readUInt8(frameArray, at: frameArray.count - 2),
          let last = readUInt8(frameArray, at: frameArray.count - 1),
          secondLast == 0x00,
          last == 0x00 else {
        return (frameArray, false)
    }

    // Strip trailing 2 bytes
    let candidate = Array(frameArray.dropLast(2))

    // Candidate must have at least 4 bytes: unitId(1) + fc(1) + CRC(2)
    guard candidate.count >= 4 else {
        return (frameArray, false)
    }

    // Validate CRC on candidate (data without CRC bytes)
    let dataWithoutCRC = Array(candidate.dropLast(2))
    let expectedCRC = calculateModbusCRC16(dataWithoutCRC)

    // Read CRC from candidate using safe access (little-endian in Modbus RTU)
    guard let actualCRC = readUInt16LE(candidate, at: candidate.count - 2) else {
        return (frameArray, false)
    }

    if actualCRC == expectedCRC {
        // Double-CRC confirmed and corrected
        return (candidate, true)
    }

    // Not double-CRC or invalid — return original
    return (frameArray, false)
}
