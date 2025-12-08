# SolarmanV5

Production-ready Solarman V5 protocol client in pure Swift, built on [SwiftNIO](https://github.com/apple/swift-nio).

[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2+-F05138.svg?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%20|%20iOS%20|%20Linux-lightgrey.svg)](https://swift.org)
[![SPM Compatible](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

## Overview

SolarmanV5 enables communication with Solarman (IGEN-Tech) WiFi data logging sticks that use the proprietary V5 protocol. These loggers connect solar inverters to the Solarman Cloud and expose a local TCP interface on port 8899.

**Key Insight:** The V5 protocol wraps standard Modbus RTU frames, allowing direct communication with inverters without disrupting cloud operations.

## Features

- **Pure Swift** — No C dependencies
- **SwiftNIO** — High-performance async TCP networking
- **Swift 6.2** — Typed throws, `Span<UInt8>` parsing, `Mutex` request serialization
- **Full Modbus Support** — All 9 function codes supported by pysolarmanv5
- **Observability** — swift-log, swift-metrics, ServiceLifecycle integration

## Compatibility

This library implements the Solarman V5 protocol used by IGEN-Tech WiFi data logging sticks. Compatibility depends on your logger using the V5 protocol on TCP port 8899.

> **Note:** Solis S3-WIFI-ST uses a different protocol and is not supported.

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/3a4oT/solarman-swift.git", from: "1.0.0")
]
```

Then add to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "SolarmanV5", package: "solarman-swift"),
    ]
)
```

## Quick Start

### Scoped Client (CLI / Scripts / Tests)

Auto-closes connection when scope exits. Best for one-off operations:

```swift
import SolarmanV5

let registers = try await withSolarmanV5Client(
    host: "192.168.1.100",
    serial: 1712345678
) { client in
    try await client.readHoldingRegisters(address: 0, count: 10).registers
}
```

### Long-Lived Client (Services / Daemons)

For persistent connections with logging, metrics, and graceful shutdown:

```swift
import Logging
import SolarmanV5
import ServiceLifecycle

let logger = Logger(label: "solar")
let metrics = SolarmanMetrics()

let client = SolarmanV5Client(
    host: "192.168.1.100",
    serial: 1712345678,
    logger: logger,
    metrics: metrics
)

try await client.connect()
let response = try await client.readHoldingRegisters(address: 0, count: 10)
print(response.registers)

// Graceful shutdown with ServiceLifecycle
let group = ServiceGroup(
    services: [client],
    gracefulShutdownSignals: [.sigterm, .sigint],
    logger: logger
)
try await group.run()
```

### Configuration Options

```swift
let config = SolarmanClientConfiguration(
    host: "192.168.1.100",
    serial: 1712345678,
    port: 8899,                              // Default V5 port
    unitId: 1,                               // Modbus slave ID
    timeout: .seconds(60),                   // Per pysolarmanv5 default
    retries: 3,                              // Retry attempts
    idleTimeout: .seconds(60),               // Auto-disconnect on inactivity
    reconnectionStrategy: .exponentialBackoff(
        initialDelay: .milliseconds(100),
        maxDelay: .seconds(30)
    ),
    v5ErrorCorrection: false                 // Naive frame recovery (rare)
)

let client = SolarmanV5Client(
    configuration: config,
    logger: logger,
    metrics: metrics
)
```

## Supported Function Codes

| Code | Function | Method |
|:----:|----------|--------|
| 0x01 | Read Coils | `readCoils(address:count:)` |
| 0x02 | Read Discrete Inputs | `readDiscreteInputs(address:count:)` |
| 0x03 | Read Holding Registers | `readHoldingRegisters(address:count:)` |
| 0x04 | Read Input Registers | `readInputRegisters(address:count:)` |
| 0x05 | Write Single Coil | `writeSingleCoil(address:value:)` |
| 0x06 | Write Single Register | `writeSingleRegister(address:value:)` |
| 0x0F | Write Multiple Coils | `writeMultipleCoils(address:values:)` |
| 0x10 | Write Multiple Registers | `writeMultipleRegisters(address:values:)` |
| 0x16 | Mask Write Register | `maskWriteRegister(address:andMask:orMask:)` |

### Raw Frame Access

For custom function codes or debugging:

```swift
// Without CRC (auto-appended)
let response = try await client.sendRawModbusFrame([0x01, 0x03, 0x00, 0x00, 0x00, 0x0A])

// With CRC (sent as-is)
let response = try await client.sendRawModbusFrameWithCRC(frameWithCRC)
```

## Reconnection Strategies

| Strategy | Description |
|----------|-------------|
| `.disabled` | No auto-reconnect; call `connect()` manually |
| `.immediate` | Reconnect immediately on disconnect (goburrow/modbus style) |
| `.exponentialBackoff(initialDelay:maxDelay:)` | Reconnect with increasing delays (pymodbus style) |

## Error Handling

All client methods throw `SolarmanClientError` with typed throws:

```swift
do {
    let response = try await client.readHoldingRegisters(address: 0, count: 10)
} catch .timeout {
    // Connection or read timed out
} catch .modbusException(let exception) {
    // Device returned Modbus exception (e.g., illegal address)
} catch .v5FrameError(let message) {
    // V5 protocol error (checksum, markers, etc.)
} catch .notConnected {
    // Client not connected
}
```

### Retryable vs Non-Retryable Errors

| Error | Retryable | Notes |
|-------|:---------:|-------|
| `timeout` | Yes | Network delay |
| `ioError` | Yes | Connection reset |
| `channelClosed` | Yes | Unexpected disconnect |
| `connectionFailed` | Yes | Initial connect failed |
| `modbusException` | No | Device rejected request |
| `v5FrameError` | No | Protocol violation |
| `invalidParameter` | No | Invalid input |

## Metrics

When `SolarmanMetrics` is provided, the following Prometheus-compatible metrics are recorded:

| Metric | Type | Labels |
|--------|------|--------|
| `solarman_connection_active` | Gauge | `serial` |
| `solarman_requests_total` | Counter | `serial`, `function_code`, `status` |
| `solarman_request_duration_seconds` | Timer | `serial`, `function_code` |
| `solarman_retries_total` | Counter | `serial`, `function_code` |
| `solarman_reconnections_total` | Counter | `serial` |

## Protocol Details

### V5 Frame Structure

```
┌─────────────────────────────────────────────────────────────────┐
│                        V5 Frame                                 │
├────────┬────────┬──────────────────────────────────┬────────────┤
│ Header │ Payload │        Modbus RTU Frame         │  Trailer   │
│ 11 B   │ 14-15 B │     (Big Endian, with CRC)      │    2 B     │
└────────┴────────┴──────────────────────────────────┴────────────┘
```

| Field | Size | Encoding | Notes |
|-------|:----:|:--------:|-------|
| Start | 1 | — | `0xA5` |
| Length | 2 | LE | Payload size |
| Control Code | 2 | LE | `0x4510` request, `0x1510` response |
| Sequence | 2 | LE | Request ID (echoed in response) |
| Logger Serial | 4 | LE | Data logger serial number |
| Frame Type | 1 | — | `0x02` for inverter |
| Status/Sensor | 1-2 | — | Request vs response differs |
| Timestamps | 12 | LE | Working time, power on, offset |
| Modbus RTU | var | BE | Standard Modbus frame |
| Checksum | 1 | — | `sum(bytes[1..<end-1]) & 0xFF` |
| End | 1 | — | `0x15` |

### Concurrency Model

Requests are serialized using `Synchronization.Mutex`. This matches:
- pysolarmanv5: socket-based, effectively single request at a time
- Most WiFi loggers: don't support concurrent requests

> **Note:** Transaction ID pipelining is NOT supported (V5 protocol limitation).

## Requirements

- Swift 6.2+
- macOS 26+, iOS 26+, or Linux (Ubuntu 24.04+)

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [modbus-swift](https://github.com/3a4oT/modbus-swift) | 1.0.0+ | ModbusCore for PDU/CRC |
| [swift-nio](https://github.com/apple/swift-nio) | 2.91.0+ | TCP networking |
| [swift-log](https://github.com/apple/swift-log) | 1.7.1+ | Structured logging |
| [swift-metrics](https://github.com/apple/swift-metrics) | 2.7.1+ | Metrics collection |
| [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle) | 2.9.1+ | Graceful shutdown |

## Development

### Setup

```bash
# Install SwiftFormat
brew install swiftformat

# Install pre-commit hook (runs SwiftFormat on staged files)
./Scripts/install-hooks.sh
```

### Code Style

This project uses [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) with configuration in `.swiftformat`.

```bash
# Format all files
swiftformat .

# Check without modifying
swiftformat . --lint
```

### Testing

```bash
swift test --filter SolarmanV5
```

## Known Device Quirks

| Issue | Affected Devices | Solution |
|-------|-----------------|----------|
| Double CRC | DEYE, others | `v5ErrorCorrection: true` |
| Response delays | Various | Increase `timeout` |
| Connection limits | Most loggers | Use single client instance |

## References

- [pysolarmanv5](https://github.com/jmccrohan/pysolarmanv5) — Reference Python implementation
- [pysolarmanv5 Protocol Docs](https://pysolarmanv5.readthedocs.io/en/stable/solarmanv5_protocol.html) — Community protocol documentation
- [modbus-swift](https://github.com/3a4oT/modbus-swift) — Swift Modbus implementation

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
