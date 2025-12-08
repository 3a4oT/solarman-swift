// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

// MARK: - Solarman V5 Checksum

/// Calculates Solarman V5 frame checksum.
///
/// Algorithm: Sum all bytes, return result modulo 256.
///
/// Per protocol specification, checksum is computed on the entire V5 frame
/// **excluding**: Start byte (0xA5), Checksum byte itself, and End byte (0x15).
///
/// Reference: pysolarmanv5 `_calculate_checksum` function
///
/// - Parameter bytes: The bytes to checksum (frame[1..<frame.count-2])
/// - Returns: Single byte checksum (sum & 0xFF)
@inlinable
public func calculateV5Checksum(_ bytes: Span<UInt8>) -> UInt8 {
    var sum: UInt = 0
    for i in bytes.indices {
        sum &+= UInt(bytes[i])
    }
    return UInt8(truncatingIfNeeded: sum)
}

/// Overload for Array input (convenience)
@inlinable
public func calculateV5Checksum(_ bytes: [UInt8]) -> UInt8 {
    var sum: UInt = 0
    for byte in bytes {
        sum &+= UInt(byte)
    }
    return UInt8(truncatingIfNeeded: sum)
}

/// Overload for ArraySlice input (convenience)
@inlinable
public func calculateV5Checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
    var sum: UInt = 0
    for byte in bytes {
        sum &+= UInt(byte)
    }
    return UInt8(truncatingIfNeeded: sum)
}
