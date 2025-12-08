// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

// MARK: - SolarmanClientConfiguration

/// Configuration for Solarman V5 TCP client.
///
/// Based on pysolarmanv5 parameters.
public struct SolarmanClientConfiguration: Sendable, Equatable {
    // MARK: Lifecycle

    /// Creates a client configuration.
    ///
    /// - Parameters:
    ///   - host: Hostname or IP address of the data logging stick
    ///   - serial: Serial number of the data logging stick
    ///   - port: TCP port (default: 8899)
    ///   - unitId: Modbus unit ID (default: 1)
    ///   - timeout: Connection and read timeout (default: 60 seconds, per pysolarmanv5)
    ///   - retries: Number of retry attempts (default: 3)
    ///   - idleTimeout: Idle timeout before auto-disconnect (default: 60 seconds, nil to disable)
    ///   - reconnectionStrategy: Strategy for auto-reconnection (default: .immediate)
    ///   - v5ErrorCorrection: Enable naive V5 error correction (default: false)
    public init(
        host: String,
        serial: UInt32,
        port: Int = SolarmanConstants.defaultPort,
        unitId: UInt8 = 1,
        timeout: Duration = .seconds(60),
        retries: Int = 3,
        idleTimeout: Duration? = .seconds(60),
        reconnectionStrategy: ReconnectionStrategy = .immediate,
        v5ErrorCorrection: Bool = false,
    ) {
        self.host = host
        self.serial = serial
        self.port = port
        self.unitId = unitId
        self.timeout = timeout
        self.retries = retries
        self.idleTimeout = idleTimeout
        self.reconnectionStrategy = reconnectionStrategy
        self.v5ErrorCorrection = v5ErrorCorrection
    }

    // MARK: Public

    /// Hostname or IP address of the data logging stick
    public let host: String

    /// Serial number of the data logging stick (required for V5 protocol)
    public let serial: UInt32

    /// TCP port (default: 8899)
    public let port: Int

    /// Modbus unit ID (default: 1)
    public let unitId: UInt8

    /// Connection and read timeout (default: 60 seconds)
    public let timeout: Duration

    /// Number of retry attempts (default: 3)
    public let retries: Int

    /// Idle timeout before auto-disconnect.
    ///
    /// Connection automatically closes after this duration of inactivity.
    /// Set to `nil` to disable idle timeout.
    public let idleTimeout: Duration?

    /// Strategy for automatic reconnection after connection loss.
    public let reconnectionStrategy: ReconnectionStrategy

    /// Enable naive V5 error correction.
    ///
    /// When enabled, attempts to recover from certain V5 protocol errors.
    /// Reference: pysolarmanv5 `v5_error_correction` parameter.
    public let v5ErrorCorrection: Bool
}

// MARK: - SolarmanConstants

/// Solarman V5 protocol constants.
public enum SolarmanConstants {
    /// Default TCP port for Solarman V5 loggers
    public static let defaultPort = 8899

    /// Maximum frame size
    public static let maxFrameSize = 1024

    /// Minimum valid response size (header + checksum + end)
    public static let minResponseSize = 14
}

// MARK: - ReconnectionStrategy

/// Strategy for handling reconnection after connection loss.
///
/// Reference implementations:
/// - `.immediate`: goburrow/modbus pattern — reconnect in Send() if disconnected
/// - `.exponentialBackoff`: pymodbus pattern — delay doubles on each failure
public enum ReconnectionStrategy: Sendable, Equatable {
    /// No automatic reconnection. Client stays disconnected after connection loss.
    /// User must call `connect()` explicitly.
    case disabled

    /// Reconnect immediately when disconnected (goburrow/modbus pattern).
    /// Simple and reliable for most devices.
    /// **Default strategy.**
    case immediate

    /// Reconnect with exponential backoff (pymodbus pattern).
    /// Delay doubles after each failed attempt, up to maxDelay.
    /// Useful for rate-limited or overloaded servers.
    ///
    /// - Parameters:
    ///   - initialDelay: Starting delay between reconnection attempts (default: 100ms)
    ///   - maxDelay: Maximum delay cap (default: 30 seconds)
    case exponentialBackoff(initialDelay: Duration = .milliseconds(100), maxDelay: Duration = .seconds(30))
}
