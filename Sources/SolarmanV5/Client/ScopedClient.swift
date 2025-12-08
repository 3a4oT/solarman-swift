// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

import Logging

// MARK: - Scoped Client Helper

/// Executes an operation with a connected Solarman V5 client, ensuring cleanup.
///
/// Creates a client, connects, executes the operation, and closes the connection
/// regardless of success or failure. Best for one-off operations in CLI tools,
/// scripts, or tests.
///
/// **Example:**
/// ```swift
/// let registers = try await withSolarmanV5Client(
///     host: "192.168.1.100",
///     serial: 1712345678
/// ) { client in
///     try await client.readHoldingRegisters(address: 0, count: 10).registers
/// }
/// ```
///
/// Reference: ModbusKit `withModbusTCPClient` pattern
///
/// - Parameters:
///   - host: Hostname or IP address of the data logging stick
///   - serial: Serial number of the data logging stick
///   - port: TCP port (default: 8899)
///   - unitId: Modbus unit ID (default: 1)
///   - timeout: Connection and read timeout (default: 60 seconds)
///   - logger: Optional logger for debugging
///   - operation: Async closure to execute with the connected client
/// - Returns: The result of the operation
/// - Throws: `SolarmanClientError` on connection or operation failure
@inlinable
public func withSolarmanV5Client<Result>(
    host: String,
    serial: UInt32,
    port: Int = SolarmanConstants.defaultPort,
    unitId: UInt8 = 1,
    timeout: Duration = .seconds(60),
    logger: Logger? = nil,
    operation: (SolarmanV5Client) async throws(SolarmanClientError) -> Result,
) async throws(SolarmanClientError) -> Result {
    let client = SolarmanV5Client(
        host: host,
        serial: serial,
        port: port,
        unitId: unitId,
        timeout: timeout,
        logger: logger,
    )

    try await client.connect()

    do {
        let result = try await operation(client)
        await client.close()
        return result
    } catch {
        await client.close()
        throw error
    }
}

/// Executes an operation with a connected Solarman V5 client using configuration.
///
/// Variant that accepts `SolarmanClientConfiguration` for full control over
/// client settings including retries, idle timeout, and reconnection strategy.
///
/// **Example:**
/// ```swift
/// let config = SolarmanClientConfiguration(
///     host: "192.168.1.100",
///     serial: 1712345678,
///     timeout: .seconds(30),
///     retries: 5
/// )
///
/// let registers = try await withSolarmanV5Client(configuration: config) { client in
///     try await client.readHoldingRegisters(address: 0, count: 10).registers
/// }
/// ```
///
/// - Parameters:
///   - configuration: Client configuration
///   - logger: Optional logger for debugging
///   - metrics: Optional metrics for observability
///   - operation: Async closure to execute with the connected client
/// - Returns: The result of the operation
/// - Throws: `SolarmanClientError` on connection or operation failure
@inlinable
public func withSolarmanV5Client<Result>(
    configuration: SolarmanClientConfiguration,
    logger: Logger? = nil,
    metrics: SolarmanMetrics? = nil,
    operation: (SolarmanV5Client) async throws(SolarmanClientError) -> Result,
) async throws(SolarmanClientError) -> Result {
    let client = SolarmanV5Client(
        configuration: configuration,
        logger: logger,
        metrics: metrics,
    )

    try await client.connect()

    do {
        let result = try await operation(client)
        await client.close()
        return result
    } catch {
        await client.close()
        throw error
    }
}
