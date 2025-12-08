// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

import ModbusCore

// MARK: - SolarmanClient

/// Async Solarman V5 client protocol.
///
/// Enables dependency injection and mocking for tests.
/// API mirrors pysolarmanv5 `PySolarmanV5Async`.
///
/// Reference: ModbusKit `ModbusClient` protocol pattern
public protocol SolarmanClient: Sendable {
    /// Whether the client is currently connected.
    var isConnected: Bool { get }

    /// Connects to the Solarman device.
    ///
    /// - Throws: `SolarmanClientError.connectionFailed` if connection fails
    /// - Throws: `SolarmanClientError.timeout` if connection times out
    /// - Throws: `SolarmanClientError.alreadyConnected` if already connected
    func connect() async throws(SolarmanClientError)

    /// Closes the connection gracefully.
    ///
    /// Safe to call multiple times. Does nothing if not connected.
    func close() async

    // MARK: - Register Operations

    /// Reads holding registers (Function Code 0x03).
    ///
    /// - Parameters:
    ///   - address: Starting register address (0-65535)
    ///   - count: Number of registers to read (1-125)
    /// - Returns: Response with register values
    /// - Throws: `SolarmanClientError` on any failure
    func readHoldingRegisters(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> ReadRegistersResponse

    /// Reads input registers (Function Code 0x04).
    ///
    /// - Parameters:
    ///   - address: Starting register address (0-65535)
    ///   - count: Number of registers to read (1-125)
    /// - Returns: Response with register values
    /// - Throws: `SolarmanClientError` on any failure
    func readInputRegisters(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> ReadRegistersResponse

    /// Writes a single holding register (Function Code 0x06).
    ///
    /// - Parameters:
    ///   - address: Register address (0-65535)
    ///   - value: Value to write (0-65535)
    /// - Returns: Response echoing address and value
    /// - Throws: `SolarmanClientError` on any failure
    func writeSingleRegister(
        address: UInt16,
        value: UInt16,
    ) async throws(SolarmanClientError) -> WriteSingleRegisterResponse

    /// Writes multiple holding registers (Function Code 0x10).
    ///
    /// - Parameters:
    ///   - address: Starting register address (0-65535)
    ///   - values: Values to write (1-123 registers)
    /// - Returns: Response confirming address and quantity
    /// - Throws: `SolarmanClientError` on any failure
    func writeMultipleRegisters(
        address: UInt16,
        values: [UInt16],
    ) async throws(SolarmanClientError) -> WriteMultipleRegistersResponse

    // MARK: - Coil Operations

    /// Reads coils (Function Code 0x01).
    ///
    /// - Parameters:
    ///   - address: Starting coil address (0-65535)
    ///   - count: Number of coils to read (1-2000)
    /// - Returns: Response with coil values as booleans
    /// - Throws: `SolarmanClientError` on any failure
    func readCoils(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> ReadBitsResponse

    /// Reads discrete inputs (Function Code 0x02).
    ///
    /// - Parameters:
    ///   - address: Starting input address (0-65535)
    ///   - count: Number of inputs to read (1-2000)
    /// - Returns: Response with input values as booleans
    /// - Throws: `SolarmanClientError` on any failure
    func readDiscreteInputs(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> ReadBitsResponse

    /// Writes a single coil (Function Code 0x05).
    ///
    /// - Parameters:
    ///   - address: Coil address (0-65535)
    ///   - value: True for ON, False for OFF
    /// - Returns: Response echoing address and value
    /// - Throws: `SolarmanClientError` on any failure
    func writeSingleCoil(
        address: UInt16,
        value: Bool,
    ) async throws(SolarmanClientError) -> WriteSingleCoilResponse

    /// Writes multiple coils (Function Code 0x0F).
    ///
    /// - Parameters:
    ///   - address: Starting coil address (0-65535)
    ///   - values: Coil values to write (1-1968 coils)
    /// - Returns: Response confirming address and quantity
    /// - Throws: `SolarmanClientError` on any failure
    func writeMultipleCoils(
        address: UInt16,
        values: [Bool],
    ) async throws(SolarmanClientError) -> WriteMultipleCoilsResponse

    // MARK: - Advanced Operations

    /// Performs mask write on a holding register (Function Code 0x16).
    ///
    /// Formula: `Result = (Current_Value AND andMask) OR orMask`
    ///
    /// - Parameters:
    ///   - address: Register address (0-65535)
    ///   - andMask: AND mask for bitwise operation
    ///   - orMask: OR mask for bitwise operation
    /// - Returns: Response echoing address and masks
    /// - Throws: `SolarmanClientError` on any failure
    func maskWriteRegister(
        address: UInt16,
        andMask: UInt16,
        orMask: UInt16,
    ) async throws(SolarmanClientError) -> MaskWriteRegisterResponse

    // MARK: - Raw Frame Access

    /// Sends a raw Modbus RTU frame (without CRC - will be appended automatically).
    ///
    /// - Parameter frame: Raw Modbus RTU frame without CRC (unitId + functionCode + data)
    /// - Returns: Raw response frame bytes (including CRC)
    /// - Throws: `SolarmanClientError` on any failure
    func sendRawModbusFrame(_ frame: [UInt8]) async throws(SolarmanClientError) -> [UInt8]

    /// Sends a raw Modbus RTU frame with CRC already included.
    ///
    /// - Parameter frameWithCRC: Complete Modbus RTU frame including CRC
    /// - Returns: Raw response frame bytes (including CRC)
    /// - Throws: `SolarmanClientError` on any failure
    func sendRawModbusFrameWithCRC(_ frameWithCRC: [UInt8]) async throws(SolarmanClientError) -> [UInt8]
}

// MARK: - SolarmanV5Client + SolarmanClient

extension SolarmanV5Client: SolarmanClient {}
