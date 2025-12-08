// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

import Logging
import Metrics
import ModbusCore
import NIOCore
import NIOPosix
import ServiceLifecycle
import Synchronization

// MARK: - SolarmanV5Client

/// Solarman V5 TCP client for WiFi data loggers (port 8899).
///
/// Thread-safe async client for Solarman V5 protocol communication.
/// Uses `Mutex` for request serialization matching pysolarmanv5 behavior.
///
/// **Protocol Stack:**
/// - V5 Frame (start 0xA5, end 0x15, V5 checksum)
///   - Modbus RTU (with CRC-16)
///     - PDU (function code + data)
///
/// **Concurrency Model:**
/// Requests are serialized using `Synchronization.Mutex`. This matches:
/// - pysolarmanv5: socket-based, effectively single request at a time
/// - Many WiFi loggers don't support concurrent requests
///
/// **Idle Timeout:**
/// Connection automatically closes after `idleTimeout` of inactivity.
/// Reference: pysolarmanv5 `socket_timeout` parameter.
///
/// ## Usage
///
/// **Simple (one-off operations):**
/// ```swift
/// let client = SolarmanV5Client(
///     host: "192.168.1.100",
///     serial: 1700000001
/// )
/// try await client.connect()
///
/// let response = try await client.readHoldingRegisters(address: 0, count: 10)
/// print(response.registers)
///
/// await client.close()
/// ```
///
/// **Long-running service:**
/// ```swift
/// let client = SolarmanV5Client(host: "192.168.1.100", serial: 1700000001)
/// try await client.connect()
///
/// let group = ServiceGroup(
///     services: [client],
///     gracefulShutdownSignals: [.sigterm, .sigint],
///     logger: logger
/// )
/// try await group.run()
/// ```
///
/// Reference: pysolarmanv5 PySolarmanV5Async
public final class SolarmanV5Client: @unchecked Sendable {
    // MARK: Lifecycle

    /// Creates a Solarman V5 client.
    ///
    /// - Parameters:
    ///   - host: Hostname or IP address of the data logging stick
    ///   - serial: Serial number of the data logging stick
    ///   - port: TCP port (default: 8899)
    ///   - unitId: Modbus unit ID (default: 1)
    ///   - timeout: Connection and read timeout (default: 60 seconds, per pysolarmanv5)
    ///   - logger: Optional logger for debugging (default: nil, no logging)
    ///   - metrics: Optional metrics for observability (default: nil, no metrics)
    public init(
        host: String,
        serial: UInt32,
        port: Int = SolarmanConstants.defaultPort,
        unitId: UInt8 = 1,
        timeout: Duration = .seconds(60),
        logger: Logger? = nil,
        metrics: SolarmanMetrics? = nil,
    ) {
        configuration = SolarmanClientConfiguration(
            host: host,
            serial: serial,
            port: port,
            unitId: unitId,
            timeout: timeout,
        )
        self.logger = logger
        self.metrics = metrics
        sequenceGenerator = SequenceNumberGenerator()
        _state = Mutex(.disconnected)
        _channel = Mutex(nil)
        _lastActivity = Mutex(ContinuousClock.now)
        _idleTimerTask = Mutex(nil)
        _currentReconnectDelay = Mutex(nil)
        eventLoopGroup = MultiThreadedEventLoopGroup.singleton
    }

    /// Creates a Solarman V5 client with configuration.
    ///
    /// - Parameters:
    ///   - configuration: Client configuration
    ///   - logger: Optional logger for debugging (default: nil, no logging)
    ///   - metrics: Optional metrics for observability (default: nil, no metrics)
    public init(
        configuration: SolarmanClientConfiguration,
        logger: Logger? = nil,
        metrics: SolarmanMetrics? = nil,
    ) {
        self.configuration = configuration
        self.logger = logger
        self.metrics = metrics
        sequenceGenerator = SequenceNumberGenerator()
        _state = Mutex(.disconnected)
        _channel = Mutex(nil)
        _lastActivity = Mutex(ContinuousClock.now)
        _idleTimerTask = Mutex(nil)
        _currentReconnectDelay = Mutex(nil)
        eventLoopGroup = MultiThreadedEventLoopGroup.singleton
    }

    deinit {
        _idleTimerTask.withLock { $0?.cancel() }
    }

    // MARK: Public

    /// Client configuration.
    public let configuration: SolarmanClientConfiguration

    /// Whether the client is currently connected.
    public var isConnected: Bool {
        _state.withLock { $0 == .connected }
    }

    /// Current connection state.
    public var connectionState: ConnectionState {
        _state.withLock { $0 }
    }

    /// Connects to the Solarman device.
    ///
    /// - Throws: `SolarmanClientError.connectionFailed` if connection fails
    /// - Throws: `SolarmanClientError.timeout` if connection times out
    /// - Throws: `SolarmanClientError.alreadyConnected` if already connected
    public func connect() async throws(SolarmanClientError) {
        let currentState = _state.withLock { $0 }
        guard currentState == .disconnected else {
            if currentState == .connected {
                throw .alreadyConnected
            }
            throw .connectionFailed("Invalid state: \(currentState)")
        }

        _state.withLock { $0 = .connecting }
        logger?.debug("Connecting to \(configuration.host):\(configuration.port)")

        do {
            let timeoutNanos = configuration.timeout.components.seconds * 1_000_000_000 +
                configuration.timeout.components.attoseconds / 1_000_000_000

            let bootstrap = ClientBootstrap(group: eventLoopGroup)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .channelOption(.socketOption(.so_keepalive), value: 1)
                .connectTimeout(.nanoseconds(timeoutNanos))
                .channelInitializer { channel in
                    channel.pipeline.addHandlers([
                        ByteToMessageHandler(V5FrameDecoder()),
                        V5ResponseHandler(),
                    ])
                }

            let newChannel = try await bootstrap.connect(
                host: configuration.host,
                port: configuration.port,
            ).get()

            _channel.withLock { $0 = newChannel }
            _state.withLock { $0 = .connected }
            recordActivity()
            metrics?.recordConnect()
            logger?.debug("Connected to \(configuration.host):\(configuration.port)")

        } catch {
            _state.withLock { $0 = .disconnected }
            _channel.withLock { $0 = nil }

            if "\(error)".contains("timed out") || "\(error)".contains("timeout") {
                throw .timeout
            }
            throw .connectionFailed("\(error)")
        }
    }

    /// Closes the connection gracefully.
    public func close() async {
        let currentState = _state.withLock { $0 }
        guard currentState == .connected || currentState == .connecting else {
            return
        }

        _state.withLock { $0 = .disconnecting }
        cancelIdleTimer()
        logger?.debug("Disconnecting from \(configuration.host):\(configuration.port)")

        let ch = _channel.withLock { $0 }
        if let ch {
            try? await ch.close()
        }

        _channel.withLock { $0 = nil }
        _state.withLock { $0 = .disconnected }
        metrics?.recordDisconnect()
        logger?.debug("Disconnected from \(configuration.host):\(configuration.port)")
    }

    /// Reads holding registers (Function Code 0x03).
    ///
    /// - Parameters:
    ///   - address: Starting register address (0-65535)
    ///   - count: Number of registers to read (1-125)
    /// - Returns: Response with register values
    /// - Throws: `SolarmanClientError` on any failure
    public func readHoldingRegisters(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> ReadRegistersResponse {
        try validateReadParameters(count: count)

        let rtuResponse = try await sendReadRequest(
            functionCode: ModbusFunctionCode.readHoldingRegisters,
            address: address,
            count: count,
        )
        return rtuResponse.toReadRegistersResponse()
    }

    /// Reads input registers (Function Code 0x04).
    ///
    /// - Parameters:
    ///   - address: Starting register address (0-65535)
    ///   - count: Number of registers to read (1-125)
    /// - Returns: Response with register values
    /// - Throws: `SolarmanClientError` on any failure
    public func readInputRegisters(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> ReadRegistersResponse {
        try validateReadParameters(count: count)

        let rtuResponse = try await sendReadRequest(
            functionCode: ModbusFunctionCode.readInputRegisters,
            address: address,
            count: count,
        )
        return rtuResponse.toReadRegistersResponse()
    }

    // MARK: - Raw Read Operations (Debug/Advanced)

    /// Reads holding registers with raw response (FC 0x03).
    ///
    /// Returns raw RTU response for debugging, custom parsing, or
    /// non-standard device implementations. Exposes raw bytes without
    /// interpretation.
    ///
    /// For normal use, prefer `readHoldingRegisters()` which returns
    /// a typed `ReadRegistersResponse`.
    ///
    /// Reference: goburrow/modbus returns `[]byte` for raw access
    ///
    /// - Parameters:
    ///   - address: Starting register address (0-65535)
    ///   - count: Number of registers to read (1-125)
    /// - Returns: Raw RTU response with `.data: [UInt8]` access
    public func readHoldingRegistersRaw(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> RTUReadResponse {
        try validateReadParameters(count: count)

        return try await sendReadRequest(
            functionCode: ModbusFunctionCode.readHoldingRegisters,
            address: address,
            count: count,
        )
    }

    /// Reads input registers with raw response (FC 0x04).
    ///
    /// Returns raw RTU response for debugging or custom parsing.
    /// For normal use, prefer `readInputRegisters()`.
    ///
    /// - Parameters:
    ///   - address: Starting register address (0-65535)
    ///   - count: Number of registers to read (1-125)
    /// - Returns: Raw RTU response with `.data: [UInt8]` access
    public func readInputRegistersRaw(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> RTUReadResponse {
        try validateReadParameters(count: count)

        return try await sendReadRequest(
            functionCode: ModbusFunctionCode.readInputRegisters,
            address: address,
            count: count,
        )
    }

    /// Reads coils with raw response (FC 0x01).
    ///
    /// Returns raw RTU response for debugging or custom parsing.
    /// For normal use, prefer `readCoils()`.
    ///
    /// - Parameters:
    ///   - address: Starting coil address (0-65535)
    ///   - count: Number of coils to read (1-2000)
    /// - Returns: Raw RTU response with `.data: [UInt8]` access
    public func readCoilsRaw(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> RTUReadResponse {
        try validateCoilReadParameters(count: count)

        return try await sendRequest(
            rtuFrame: buildRTUReadCoilsRequest(
                address: address,
                count: count,
                unitId: configuration.unitId,
            ),
            functionCode: ModbusFunctionCode.readCoils,
        )
    }

    /// Reads discrete inputs with raw response (FC 0x02).
    ///
    /// Returns raw RTU response for debugging or custom parsing.
    /// For normal use, prefer `readDiscreteInputs()`.
    ///
    /// - Parameters:
    ///   - address: Starting input address (0-65535)
    ///   - count: Number of inputs to read (1-2000)
    /// - Returns: Raw RTU response with `.data: [UInt8]` access
    public func readDiscreteInputsRaw(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> RTUReadResponse {
        try validateCoilReadParameters(count: count)

        return try await sendRequest(
            rtuFrame: buildRTUReadDiscreteInputsRequest(
                address: address,
                count: count,
                unitId: configuration.unitId,
            ),
            functionCode: ModbusFunctionCode.readDiscreteInputs,
        )
    }

    // MARK: - Coil Operations (FC 0x01, 0x02, 0x05, 0x0F)

    /// Reads coils (Function Code 0x01).
    ///
    /// Reference: pysolarmanv5 `read_coils(register_addr, quantity)`
    ///
    /// - Parameters:
    ///   - address: Starting coil address (0-65535)
    ///   - count: Number of coils to read (1-2000)
    /// - Returns: Response with coil values as booleans
    /// - Throws: `SolarmanClientError` on any failure
    public func readCoils(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> ReadBitsResponse {
        try validateCoilReadParameters(count: count)

        let rtuResponse = try await sendRequest(
            rtuFrame: buildRTUReadCoilsRequest(
                address: address,
                count: count,
                unitId: configuration.unitId,
            ),
            functionCode: ModbusFunctionCode.readCoils,
        )
        return rtuResponse.toReadBitsResponse(requestedCount: count)
    }

    /// Reads discrete inputs (Function Code 0x02).
    ///
    /// Reference: pysolarmanv5 `read_discrete_inputs(register_addr, quantity)`
    ///
    /// - Parameters:
    ///   - address: Starting input address (0-65535)
    ///   - count: Number of inputs to read (1-2000)
    /// - Returns: Response with input values as booleans
    /// - Throws: `SolarmanClientError` on any failure
    public func readDiscreteInputs(
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> ReadBitsResponse {
        try validateCoilReadParameters(count: count)

        let rtuResponse = try await sendRequest(
            rtuFrame: buildRTUReadDiscreteInputsRequest(
                address: address,
                count: count,
                unitId: configuration.unitId,
            ),
            functionCode: ModbusFunctionCode.readDiscreteInputs,
        )
        return rtuResponse.toReadBitsResponse(requestedCount: count)
    }

    /// Writes a single coil (Function Code 0x05).
    ///
    /// Reference: pysolarmanv5 `write_coil(register_addr, value)`
    ///
    /// - Parameters:
    ///   - address: Coil address (0-65535)
    ///   - value: True for ON, False for OFF
    /// - Returns: Response echoing address and value
    /// - Throws: `SolarmanClientError` on any failure
    public func writeSingleCoil(
        address: UInt16,
        value: Bool,
    ) async throws(SolarmanClientError) -> WriteSingleCoilResponse {
        let rtuResponse = try await sendWriteRequest(
            rtuFrame: buildRTUWriteSingleCoilRequest(
                address: address,
                value: value,
                unitId: configuration.unitId,
            ),
            functionCode: ModbusFunctionCode.writeSingleCoil,
        )
        return rtuResponse.toWriteSingleCoilResponse()
    }

    /// Writes multiple coils (Function Code 0x0F).
    ///
    /// Reference: pysolarmanv5 `write_multiple_coils(register_addr, values)`
    ///
    /// - Parameters:
    ///   - address: Starting coil address (0-65535)
    ///   - values: Coil values to write (1-1968 coils)
    /// - Returns: Response confirming address and quantity
    /// - Throws: `SolarmanClientError` on any failure
    public func writeMultipleCoils(
        address: UInt16,
        values: [Bool],
    ) async throws(SolarmanClientError) -> WriteMultipleCoilsResponse {
        try validateCoilWriteParameters(count: UInt16(values.count))

        let rtuResponse = try await sendWriteRequest(
            rtuFrame: buildRTUWriteMultipleCoilsRequest(
                address: address,
                values: values,
                unitId: configuration.unitId,
            ),
            functionCode: ModbusFunctionCode.writeMultipleCoils,
        )
        return rtuResponse.toWriteMultipleCoilsResponse()
    }

    // MARK: - Write Register Operations (FC 0x06, 0x10, 0x16)

    /// Writes a single holding register (Function Code 0x06).
    ///
    /// Reference: pysolarmanv5 `write_holding_register(register_addr, value)`
    ///
    /// - Parameters:
    ///   - address: Register address (0-65535)
    ///   - value: Value to write (0-65535)
    /// - Returns: Response echoing address and value
    /// - Throws: `SolarmanClientError` on any failure
    public func writeSingleRegister(
        address: UInt16,
        value: UInt16,
    ) async throws(SolarmanClientError) -> WriteSingleRegisterResponse {
        let rtuResponse = try await sendWriteRequest(
            rtuFrame: buildRTUWriteSingleRegisterRequest(
                address: address,
                value: value,
                unitId: configuration.unitId,
            ),
            functionCode: ModbusFunctionCode.writeSingleRegister,
        )
        return rtuResponse.toWriteSingleRegisterResponse()
    }

    /// Writes multiple holding registers (Function Code 0x10).
    ///
    /// Reference: pysolarmanv5 `write_multiple_holding_registers(register_addr, values)`
    ///
    /// - Parameters:
    ///   - address: Starting register address (0-65535)
    ///   - values: Values to write (1-123 registers)
    /// - Returns: Response confirming address and quantity
    /// - Throws: `SolarmanClientError` on any failure
    public func writeMultipleRegisters(
        address: UInt16,
        values: [UInt16],
    ) async throws(SolarmanClientError) -> WriteMultipleRegistersResponse {
        try validateRegisterWriteParameters(count: UInt16(values.count))

        let rtuResponse = try await sendWriteRequest(
            rtuFrame: buildRTUWriteMultipleRegistersRequest(
                address: address,
                values: values,
                unitId: configuration.unitId,
            ),
            functionCode: ModbusFunctionCode.writeMultipleRegisters,
        )
        return rtuResponse.toWriteMultipleRegistersResponse()
    }

    /// Performs mask write on a holding register (Function Code 0x16).
    ///
    /// The formula applied: `Result = (Current_Value AND And_Mask) OR Or_Mask`
    ///
    /// Reference: pysolarmanv5 `masked_write_holding_register(register_addr, and_mask, or_mask)`
    ///
    /// - Parameters:
    ///   - address: Register address (0-65535)
    ///   - andMask: AND mask for bitwise operation
    ///   - orMask: OR mask for bitwise operation
    /// - Returns: Response echoing address and masks
    /// - Throws: `SolarmanClientError` on any failure
    public func maskWriteRegister(
        address: UInt16,
        andMask: UInt16,
        orMask: UInt16,
    ) async throws(SolarmanClientError) -> MaskWriteRegisterResponse {
        let rtuResponse = try await sendWriteRequest(
            rtuFrame: buildRTUMaskWriteRegisterRequest(
                address: address,
                andMask: andMask,
                orMask: orMask,
                unitId: configuration.unitId,
            ),
            functionCode: ModbusFunctionCode.maskWriteRegister,
        )
        return rtuResponse.toMaskWriteRegisterResponse()
    }

    // MARK: - Raw Frame Support

    /// Sends a raw Modbus RTU frame (without CRC - will be appended automatically).
    ///
    /// Use this for custom function codes or direct protocol access.
    ///
    /// Reference: pysolarmanv5 `send_raw_modbus_frame(mb_request_frame)`
    ///
    /// - Parameter frame: Raw Modbus RTU frame without CRC (unitId + functionCode + data)
    /// - Returns: Raw response frame bytes (including CRC)
    /// - Throws: `SolarmanClientError` on any failure
    public func sendRawModbusFrame(
        _ frame: [UInt8],
    ) async throws(SolarmanClientError) -> [UInt8] {
        guard frame.count >= 2 else {
            throw .invalidParameter("Frame must contain at least unitId and functionCode")
        }

        let frameWithCRC = appendModbusCRC(frame)
        let functionCode = frame[1]

        return try await sendRawRequest(
            rtuFrame: frameWithCRC,
            functionCode: functionCode,
        )
    }

    /// Sends a raw Modbus RTU frame with CRC already included.
    ///
    /// - Parameter frameWithCRC: Complete Modbus RTU frame including CRC
    /// - Returns: Raw response frame bytes (including CRC)
    /// - Throws: `SolarmanClientError` on any failure
    public func sendRawModbusFrameWithCRC(
        _ frameWithCRC: [UInt8],
    ) async throws(SolarmanClientError) -> [UInt8] {
        guard frameWithCRC.count >= 4 else {
            throw .invalidParameter("Frame must be at least 4 bytes (unitId + functionCode + CRC)")
        }

        let functionCode = frameWithCRC[1]

        return try await sendRawRequest(
            rtuFrame: frameWithCRC,
            functionCode: functionCode,
        )
    }

    // MARK: Private

    private let logger: Logger?
    private let metrics: SolarmanMetrics?
    private let eventLoopGroup: EventLoopGroup
    private let sequenceGenerator: SequenceNumberGenerator
    private let _state: Mutex<ConnectionState>
    private let _channel: Mutex<Channel?>
    private let _lastActivity: Mutex<ContinuousClock.Instant>
    private let _idleTimerTask: Mutex<Task<Void, Never>?>
    private let _currentReconnectDelay: Mutex<Duration?>

    /// Validates read request parameters.
    private func validateReadParameters(count: UInt16) throws(SolarmanClientError) {
        guard count >= 1 else {
            throw .invalidParameter("count must be >= 1")
        }
        guard count <= 125 else {
            throw .invalidParameter("count must be <= 125")
        }
    }

    /// Validates coil read parameters.
    private func validateCoilReadParameters(count: UInt16) throws(SolarmanClientError) {
        guard count >= 1 else {
            throw .invalidParameter("count must be >= 1")
        }
        guard count <= 2000 else {
            throw .invalidParameter("count must be <= 2000")
        }
    }

    /// Validates coil write parameters.
    private func validateCoilWriteParameters(count: UInt16) throws(SolarmanClientError) {
        guard count >= 1 else {
            throw .invalidParameter("count must be >= 1")
        }
        guard count <= 1968 else {
            throw .invalidParameter("count must be <= 1968")
        }
    }

    /// Validates register write parameters.
    private func validateRegisterWriteParameters(count: UInt16) throws(SolarmanClientError) {
        guard count >= 1 else {
            throw .invalidParameter("count must be >= 1")
        }
        guard count <= 123 else {
            throw .invalidParameter("count must be <= 123")
        }
    }

    /// Sends a read request with retry logic.
    private func sendReadRequest(
        functionCode: UInt8,
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> RTUReadResponse {
        var lastError: SolarmanClientError?
        let maxAttempts = configuration.retries + 1
        let startTime = ContinuousClock.now

        for attempt in 1...maxAttempts {
            do {
                let result = try await performReadRequest(
                    functionCode: functionCode,
                    address: address,
                    count: count,
                )
                metrics?.recordRequest(functionCode: functionCode, duration: ContinuousClock.now - startTime)
                return result
            } catch {
                lastError = error

                guard error.isRetryable else {
                    metrics?.recordRequestError(functionCode: functionCode, error: error.metricsLabel)
                    throw error
                }

                guard attempt < maxAttempts else {
                    break
                }

                metrics?.recordRetry(functionCode: functionCode)
                logger?.debug("Retry \(attempt)/\(maxAttempts - 1) after error: \(error)")

                await close()
            }
        }

        metrics?.recordRequestError(functionCode: functionCode, error: lastError?.metricsLabel ?? "unknown")
        throw lastError ?? .connectionFailed("All retry attempts failed")
    }

    /// Performs a single read request attempt.
    private func performReadRequest(
        functionCode: UInt8,
        address: UInt16,
        count: UInt16,
    ) async throws(SolarmanClientError) -> RTUReadResponse {
        try await ensureConnected()

        let ch = _channel.withLock { $0 }
        guard let ch, ch.isActive else {
            throw .notConnected
        }

        let sequence = sequenceGenerator.next()

        // Build Modbus RTU frame
        let rtuFrame = buildRTUReadRequest(
            address: address,
            count: count,
            unitId: configuration.unitId,
        )

        // Wrap in V5 frame
        let v5Frame = buildV5RequestFrame(
            serial: configuration.serial,
            sequence: sequence,
            modbusFrame: rtuFrame,
        )

        // Send request
        var buffer = ch.allocator.buffer(capacity: v5Frame.count)
        buffer.writeBytes(v5Frame)
        logger?.trace("TX: \(v5Frame.hexString)")

        do {
            try await ch.writeAndFlush(buffer)
            recordActivity()
        } catch {
            throw .ioError("Write failed: \(error)")
        }

        // Wait for response with timeout
        return try await waitForResponse(
            channel: ch,
            expectedSequence: sequence,
            expectedFunction: functionCode,
        )
    }

    /// Sends a generic request with pre-built RTU frame.
    private func sendRequest(
        rtuFrame: [UInt8],
        functionCode: UInt8,
    ) async throws(SolarmanClientError) -> RTUReadResponse {
        var lastError: SolarmanClientError?
        let maxAttempts = configuration.retries + 1
        let startTime = ContinuousClock.now

        for attempt in 1...maxAttempts {
            do {
                let result = try await performRequest(
                    rtuFrame: rtuFrame,
                    functionCode: functionCode,
                )
                metrics?.recordRequest(functionCode: functionCode, duration: ContinuousClock.now - startTime)
                return result
            } catch {
                lastError = error
                guard error.isRetryable, attempt < maxAttempts else {
                    if !error.isRetryable {
                        metrics?.recordRequestError(functionCode: functionCode, error: error.metricsLabel)
                        throw error
                    }
                    break
                }
                metrics?.recordRetry(functionCode: functionCode)
                logger?.debug("Retry \(attempt)/\(maxAttempts - 1) after error: \(error)")
                await close()
            }
        }
        metrics?.recordRequestError(functionCode: functionCode, error: lastError?.metricsLabel ?? "unknown")
        throw lastError ?? .connectionFailed("All retry attempts failed")
    }

    /// Sends a write request with pre-built RTU frame.
    private func sendWriteRequest(
        rtuFrame: [UInt8],
        functionCode: UInt8,
    ) async throws(SolarmanClientError) -> RTUWriteResponse {
        var lastError: SolarmanClientError?
        let maxAttempts = configuration.retries + 1
        let startTime = ContinuousClock.now

        for attempt in 1...maxAttempts {
            do {
                let result = try await performWriteRequest(
                    rtuFrame: rtuFrame,
                    functionCode: functionCode,
                )
                metrics?.recordRequest(functionCode: functionCode, duration: ContinuousClock.now - startTime)
                return result
            } catch {
                lastError = error
                guard error.isRetryable, attempt < maxAttempts else {
                    if !error.isRetryable {
                        metrics?.recordRequestError(functionCode: functionCode, error: error.metricsLabel)
                        throw error
                    }
                    break
                }
                metrics?.recordRetry(functionCode: functionCode)
                logger?.debug("Retry \(attempt)/\(maxAttempts - 1) after error: \(error)")
                await close()
            }
        }
        metrics?.recordRequestError(functionCode: functionCode, error: lastError?.metricsLabel ?? "unknown")
        throw lastError ?? .connectionFailed("All retry attempts failed")
    }

    /// Sends a raw request and returns raw response bytes.
    private func sendRawRequest(
        rtuFrame: [UInt8],
        functionCode: UInt8,
    ) async throws(SolarmanClientError) -> [UInt8] {
        var lastError: SolarmanClientError?
        let maxAttempts = configuration.retries + 1
        let startTime = ContinuousClock.now

        for attempt in 1...maxAttempts {
            do {
                let result = try await performRawRequest(rtuFrame: rtuFrame)
                metrics?.recordRequest(functionCode: functionCode, duration: ContinuousClock.now - startTime)
                return result
            } catch {
                lastError = error
                guard error.isRetryable, attempt < maxAttempts else {
                    if !error.isRetryable {
                        metrics?.recordRequestError(functionCode: functionCode, error: error.metricsLabel)
                        throw error
                    }
                    break
                }
                metrics?.recordRetry(functionCode: functionCode)
                logger?.debug("Retry \(attempt)/\(maxAttempts - 1) after error: \(error)")
                await close()
            }
        }
        metrics?.recordRequestError(functionCode: functionCode, error: lastError?.metricsLabel ?? "unknown")
        throw lastError ?? .connectionFailed("All retry attempts failed")
    }

    /// Performs a single request attempt with pre-built RTU frame.
    private func performRequest(
        rtuFrame: [UInt8],
        functionCode: UInt8,
    ) async throws(SolarmanClientError) -> RTUReadResponse {
        try await ensureConnected()

        let ch = _channel.withLock { $0 }
        guard let ch, ch.isActive else {
            throw .notConnected
        }

        let sequence = sequenceGenerator.next()

        let v5Frame = buildV5RequestFrame(
            serial: configuration.serial,
            sequence: sequence,
            modbusFrame: rtuFrame,
        )

        var buffer = ch.allocator.buffer(capacity: v5Frame.count)
        buffer.writeBytes(v5Frame)
        logger?.trace("TX: \(v5Frame.hexString)")

        do {
            try await ch.writeAndFlush(buffer)
            recordActivity()
        } catch {
            throw .ioError("Write failed: \(error)")
        }

        return try await waitForResponse(
            channel: ch,
            expectedSequence: sequence,
            expectedFunction: functionCode,
        )
    }

    /// Performs a single write request attempt.
    private func performWriteRequest(
        rtuFrame: [UInt8],
        functionCode: UInt8,
    ) async throws(SolarmanClientError) -> RTUWriteResponse {
        try await ensureConnected()

        let ch = _channel.withLock { $0 }
        guard let ch, ch.isActive else {
            throw .notConnected
        }

        let sequence = sequenceGenerator.next()

        let v5Frame = buildV5RequestFrame(
            serial: configuration.serial,
            sequence: sequence,
            modbusFrame: rtuFrame,
        )

        var buffer = ch.allocator.buffer(capacity: v5Frame.count)
        buffer.writeBytes(v5Frame)
        logger?.trace("TX: \(v5Frame.hexString)")

        do {
            try await ch.writeAndFlush(buffer)
            recordActivity()
        } catch {
            throw .ioError("Write failed: \(error)")
        }

        return try await waitForWriteResponse(
            channel: ch,
            expectedSequence: sequence,
            expectedFunction: functionCode,
        )
    }

    /// Performs a single raw request attempt.
    private func performRawRequest(
        rtuFrame: [UInt8],
    ) async throws(SolarmanClientError) -> [UInt8] {
        try await ensureConnected()

        let ch = _channel.withLock { $0 }
        guard let ch, ch.isActive else {
            throw .notConnected
        }

        let sequence = sequenceGenerator.next()

        let v5Frame = buildV5RequestFrame(
            serial: configuration.serial,
            sequence: sequence,
            modbusFrame: rtuFrame,
        )

        var buffer = ch.allocator.buffer(capacity: v5Frame.count)
        buffer.writeBytes(v5Frame)
        logger?.trace("TX: \(v5Frame.hexString)")

        do {
            try await ch.writeAndFlush(buffer)
            recordActivity()
        } catch {
            throw .ioError("Write failed: \(error)")
        }

        return try await waitForRawResponse(
            channel: ch,
            expectedSequence: sequence,
        )
    }

    /// Waits for V5 response with timeout and validates sequence.
    ///
    /// Common logic extracted from waitForResponse, waitForWriteResponse, waitForRawResponse.
    private func waitForV5Response(
        channel: Channel,
        expectedSequence: UInt16,
    ) async throws(SolarmanClientError) -> ValidatedV5Response {
        let handler: V5ResponseHandler
        do {
            handler = try await channel.pipeline.handler(type: V5ResponseHandler.self).get()
        } catch {
            throw .ioError("Handler not found: \(error)")
        }

        let eventLoop = channel.eventLoop

        let responseBytes: [UInt8]
        do {
            responseBytes = try await withThrowingTaskGroup(of: [UInt8].self) { group in
                group.addTask {
                    try await handler.waitForResponse(on: eventLoop)
                }

                group.addTask { [timeout = configuration.timeout] in
                    try await Task.sleep(for: timeout)
                    throw SolarmanClientError.timeout
                }

                guard let result = try await group.next() else {
                    throw SolarmanClientError.timeout
                }
                group.cancelAll()
                return result
            }
        } catch let error as SolarmanClientError {
            throw error
        } catch {
            throw .timeout
        }

        logger?.trace("RX: \(responseBytes.hexString)")

        // Parse V5 frame
        let v5Response: ValidatedV5Response
        do {
            v5Response = try parseV5ResponseFrame(responseBytes)
        } catch {
            throw .v5FrameError("\(error)")
        }

        // Validate sequence number (low byte only, per V5 protocol specification)
        //
        // The 2-byte sequence field has different semantics for each byte:
        // - Low byte: echoed back from request, used for request/response matching
        // - High byte: incremented by data logging stick for each response
        //
        // Reference: https://pysolarmanv5.readthedocs.io/en/stable/solarmanv5_protocol.html
        guard let responseSequence = v5Response.sequence else {
            throw .v5FrameError("Missing sequence number")
        }
        let expectedLowByte = UInt8(truncatingIfNeeded: expectedSequence)
        let responseLowByte = UInt8(truncatingIfNeeded: responseSequence)
        guard responseLowByte == expectedLowByte else {
            throw .sequenceMismatch(expected: expectedSequence, got: responseSequence)
        }

        return v5Response
    }

    /// Parses RTU read response with optional double-CRC correction.
    private func parseReadResponseWithDoubleCRCCorrection(
        _ modbusFrame: ArraySlice<UInt8>,
        expectedFunction: UInt8,
    ) throws(SolarmanClientError) -> RTUReadResponse {
        // First try without correction
        do {
            return try parseRTUReadResponse(
                Array(modbusFrame),
                expectedUnitId: configuration.unitId,
                expectedFunction: expectedFunction,
            )
        } catch {
            // If CRC error and v5ErrorCorrection enabled, try double-CRC correction
            if case .invalidCRC = error, configuration.v5ErrorCorrection {
                let (correctedFrame, wasCorrected) = detectAndCorrectDoubleCRC(modbusFrame)
                if wasCorrected {
                    logger?.debug("Double-CRC detected and corrected")
                    do {
                        return try parseRTUReadResponse(
                            correctedFrame,
                            expectedUnitId: configuration.unitId,
                            expectedFunction: expectedFunction,
                        )
                    } catch {
                        throw mapRTUParseError(error)
                    }
                }
            }
            throw mapRTUParseError(error)
        }
    }

    /// Parses RTU write response with optional double-CRC correction.
    private func parseWriteResponseWithDoubleCRCCorrection(
        _ modbusFrame: ArraySlice<UInt8>,
        expectedFunction: UInt8,
    ) throws(SolarmanClientError) -> RTUWriteResponse {
        // First try without correction
        do {
            return try parseRTUWriteResponse(
                Array(modbusFrame),
                expectedUnitId: configuration.unitId,
                expectedFunction: expectedFunction,
            )
        } catch {
            // If CRC error and v5ErrorCorrection enabled, try double-CRC correction
            if case .invalidCRC = error, configuration.v5ErrorCorrection {
                let (correctedFrame, wasCorrected) = detectAndCorrectDoubleCRC(modbusFrame)
                if wasCorrected {
                    logger?.debug("Double-CRC detected and corrected")
                    do {
                        return try parseRTUWriteResponse(
                            correctedFrame,
                            expectedUnitId: configuration.unitId,
                            expectedFunction: expectedFunction,
                        )
                    } catch {
                        throw mapRTUParseError(error)
                    }
                }
            }
            throw mapRTUParseError(error)
        }
    }

    /// Waits for read response with timeout.
    private func waitForResponse(
        channel: Channel,
        expectedSequence: UInt16,
        expectedFunction: UInt8,
    ) async throws(SolarmanClientError) -> RTUReadResponse {
        let v5Response = try await waitForV5Response(channel: channel, expectedSequence: expectedSequence)
        return try parseReadResponseWithDoubleCRCCorrection(
            v5Response.modbusFrame,
            expectedFunction: expectedFunction,
        )
    }

    /// Waits for write response with timeout.
    private func waitForWriteResponse(
        channel: Channel,
        expectedSequence: UInt16,
        expectedFunction: UInt8,
    ) async throws(SolarmanClientError) -> RTUWriteResponse {
        let v5Response = try await waitForV5Response(channel: channel, expectedSequence: expectedSequence)
        return try parseWriteResponseWithDoubleCRCCorrection(
            v5Response.modbusFrame,
            expectedFunction: expectedFunction,
        )
    }

    /// Waits for raw response with timeout.
    private func waitForRawResponse(
        channel: Channel,
        expectedSequence: UInt16,
    ) async throws(SolarmanClientError) -> [UInt8] {
        let v5Response = try await waitForV5Response(channel: channel, expectedSequence: expectedSequence)
        return Array(v5Response.modbusFrame)
    }

    // MARK: - Idle Timeout

    private func recordActivity() {
        _lastActivity.withLock { $0 = ContinuousClock.now }
        resetIdleTimer()
    }

    private func resetIdleTimer() {
        guard let idleTimeout = configuration.idleTimeout else {
            return
        }

        _idleTimerTask.withLock { task in
            task?.cancel()
            task = Task { [weak self] in
                try? await Task.sleep(for: idleTimeout)
                guard !Task.isCancelled else {
                    return
                }
                await self?.closeIfIdle()
            }
        }
    }

    private func cancelIdleTimer() {
        _idleTimerTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private func closeIfIdle() async {
        guard let idleTimeout = configuration.idleTimeout else {
            return
        }

        let lastActivity = _lastActivity.withLock { $0 }
        let elapsed = ContinuousClock.now - lastActivity

        if elapsed >= idleTimeout {
            await close()
        }
    }

    // MARK: - Auto-Reconnection

    private func ensureConnected() async throws(SolarmanClientError) {
        let currentState = _state.withLock { $0 }

        if currentState == .connected {
            resetReconnectDelay()
            return
        }

        switch configuration.reconnectionStrategy {
        case .disabled:
            throw .notConnected

        case .immediate:
            metrics?.recordReconnection()
            try await connect()
            resetReconnectDelay()

        case let .exponentialBackoff(initialDelay, maxDelay):
            let delay = _currentReconnectDelay.withLock { currentDelay -> Duration in
                let delayToUse = currentDelay ?? initialDelay
                let nextDelay = min(delayToUse * 2, maxDelay)
                currentDelay = nextDelay
                return delayToUse
            }

            do {
                try await Task.sleep(for: delay)
            } catch {
                throw .connectionFailed("Reconnection cancelled")
            }
            metrics?.recordReconnection()
            try await connect()
        }
    }

    private func resetReconnectDelay() {
        _currentReconnectDelay.withLock { $0 = nil }
    }

    /// Maps RTU parse errors to SolarmanClientError.
    private func mapRTUParseError(_ error: RTUError) -> SolarmanClientError {
        switch error {
        case let .exceptionResponse(exception):
            .modbusException(exception)
        case .invalidCRC:
            .rtuError("Invalid CRC")
        case .frameTooShort:
            .rtuError("Frame too short")
        case let .unitIdMismatch(expected, got):
            .rtuError("Unit ID mismatch: expected \(expected), got \(got)")
        case let .unexpectedFunctionCode(expected, got):
            .rtuError("Function code mismatch: expected \(expected), got \(got)")
        case let .byteCountMismatch(expected, got):
            .rtuError("Byte count mismatch: expected \(expected), got \(got)")
        }
    }
}

// MARK: Service

extension SolarmanV5Client: Service {
    /// Runs the client as a service, waiting for graceful shutdown.
    ///
    /// When used with `ServiceGroup`, the client will:
    /// 1. Wait for graceful shutdown signal (SIGTERM, SIGINT)
    /// 2. Close the connection gracefully
    ///
    /// Reference: swift-service-lifecycle
    public func run() async throws {
        try await gracefulShutdown()
        await close()
    }
}
