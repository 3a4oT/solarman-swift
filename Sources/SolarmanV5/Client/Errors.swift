// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

// MARK: - SolarmanClientError

/// Errors that can occur during Solarman V5 client operations.
///
/// This is the canonical error type for all client operations.
/// All async client methods throw this type exclusively.
public enum SolarmanClientError: Error, Equatable, Sendable {
    /// Not connected to device
    case notConnected

    /// Already connected
    case alreadyConnected

    /// Connection failed with reason
    case connectionFailed(String)

    /// Operation timed out
    case timeout

    /// V5 frame error (checksum, markers, etc.)
    case v5FrameError(String)

    /// Sequence number mismatch in response
    case sequenceMismatch(expected: UInt16, got: UInt16)

    /// Modbus exception response from device
    case modbusException(ModbusException)

    /// RTU frame error (CRC, length, etc.)
    case rtuError(String)

    /// I/O error during communication
    case ioError(String)

    /// Invalid parameter (e.g., count > 125)
    case invalidParameter(String)

    /// Channel closed unexpectedly
    case channelClosed

    // MARK: Public

    /// Whether this error is transient and operation can be retried.
    ///
    /// Retryable errors are typically network/timing issues.
    /// Non-retryable errors are protocol violations or device rejections.
    public var isRetryable: Bool {
        switch self {
        case .timeout,
             .ioError,
             .channelClosed,
             .connectionFailed:
            true
        case .notConnected,
             .alreadyConnected,
             .invalidParameter,
             .modbusException,
             .sequenceMismatch,
             .v5FrameError,
             .rtuError:
            false
        }
    }

    /// Short label for metrics dimension.
    public var metricsLabel: String {
        switch self {
        case .notConnected: "not_connected"
        case .alreadyConnected: "already_connected"
        case .connectionFailed: "connection_failed"
        case .timeout: "timeout"
        case .sequenceMismatch: "sequence_mismatch"
        case .v5FrameError: "v5_frame_error"
        case .modbusException: "modbus_exception"
        case .rtuError: "rtu_error"
        case .ioError: "io_error"
        case .invalidParameter: "invalid_parameter"
        case .channelClosed: "channel_closed"
        }
    }
}
