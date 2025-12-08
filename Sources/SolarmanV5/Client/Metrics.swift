// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

import Metrics

// MARK: - SolarmanMetrics

/// Metrics container for Solarman V5 client observability.
///
/// Provides Prometheus-compatible metrics for monitoring Solarman V5 clients.
/// All metrics are optional — if no backend is configured, they are no-ops.
///
/// **Usage:**
/// ```swift
/// let metrics = SolarmanMetrics(serial: 1712345678)
/// let client = SolarmanV5Client(host: "192.168.1.100", serial: 1712345678, metrics: metrics)
/// ```
///
/// **Metric Names:**
/// - `solarman_requests_total` — Counter with dimensions: `function_code`, `status`, `serial`
/// - `solarman_request_duration_seconds` — Timer with dimensions: `function_code`, `serial`
/// - `solarman_connection_active` — Gauge (1 = connected, 0 = disconnected)
/// - `solarman_retries_total` — Counter with dimension: `function_code`, `serial`
/// - `solarman_reconnections_total` — Counter with dimension: `serial`
///
/// Reference: ModbusKit ModbusMetrics pattern
public struct SolarmanMetrics: Sendable {
    // MARK: Lifecycle

    /// Creates metrics with optional serial number for multi-device monitoring.
    ///
    /// - Parameters:
    ///   - prefix: Label prefix for all metrics (default: "solarman")
    ///   - serial: Optional data logger serial number for dimension
    public init(prefix: String = "solarman", serial: UInt32? = nil) {
        self.prefix = prefix
        self.serial = serial
    }

    // MARK: Public

    /// Label prefix for all metrics.
    public let prefix: String

    /// Optional serial number for multi-device dimension.
    public let serial: UInt32?

    // MARK: - Request Metrics

    /// Records a successful request.
    ///
    /// - Parameters:
    ///   - functionCode: Modbus function code (e.g., 0x03, 0x04)
    ///   - duration: Request duration
    public func recordRequest(functionCode: UInt8, duration: Duration) {
        let fcLabel = functionCodeLabel(functionCode)

        Counter(
            label: "\(prefix)_requests_total",
            dimensions: baseDimensions + [("function_code", fcLabel), ("status", "success")],
        ).increment()

        Timer(
            label: "\(prefix)_request_duration_seconds",
            dimensions: baseDimensions + [("function_code", fcLabel)],
        ).recordNanoseconds(duration.nanoseconds)
    }

    /// Records a failed request.
    ///
    /// - Parameters:
    ///   - functionCode: Modbus function code
    ///   - error: Error type for dimension
    public func recordRequestError(functionCode: UInt8, error: String) {
        let fcLabel = functionCodeLabel(functionCode)

        Counter(
            label: "\(prefix)_requests_total",
            dimensions: baseDimensions + [("function_code", fcLabel), ("status", "error"), ("error", error)],
        ).increment()
    }

    // MARK: - Connection Metrics

    /// Records a new connection.
    public func recordConnect() {
        Gauge(
            label: "\(prefix)_connection_active",
            dimensions: baseDimensions,
        ).record(1)
    }

    /// Records a disconnection.
    public func recordDisconnect() {
        Gauge(
            label: "\(prefix)_connection_active",
            dimensions: baseDimensions,
        ).record(0)
    }

    /// Records a reconnection attempt.
    public func recordReconnection() {
        Counter(
            label: "\(prefix)_reconnections_total",
            dimensions: baseDimensions,
        ).increment()
    }

    // MARK: - Retry Metrics

    /// Records a retry attempt.
    ///
    /// - Parameter functionCode: Modbus function code being retried
    public func recordRetry(functionCode: UInt8) {
        let fcLabel = functionCodeLabel(functionCode)

        Counter(
            label: "\(prefix)_retries_total",
            dimensions: baseDimensions + [("function_code", fcLabel)],
        ).increment()
    }

    // MARK: Private

    /// Base dimensions including serial if available.
    private var baseDimensions: [(String, String)] {
        if let serial {
            return [("serial", String(serial))]
        }
        return []
    }

    /// Converts function code to human-readable label.
    private func functionCodeLabel(_ fc: UInt8) -> String {
        switch fc {
        case 0x01: "read_coils"
        case 0x02: "read_discrete_inputs"
        case 0x03: "read_holding_registers"
        case 0x04: "read_input_registers"
        case 0x05: "write_single_coil"
        case 0x06: "write_single_register"
        case 0x0F: "write_multiple_coils"
        case 0x10: "write_multiple_registers"
        case 0x16: "mask_write_register"
        default: formatFunctionCode(fc)
        }
    }
}

// MARK: - Duration Extension

extension Duration {
    /// Converts Duration to nanoseconds for Timer recording.
    @usableFromInline
    var nanoseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
