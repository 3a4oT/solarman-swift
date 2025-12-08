// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

// Re-export ModbusCore so consumers get binary helpers, CRC, RTU, etc.
@_exported import ModbusCore

// MARK: - SolarmanV5

/// Solarman V5 protocol implementation for WiFi data loggers.
///
/// This module provides:
/// - V5 frame construction (request) and parsing (response)
/// - Async/await TCP client for port 8899
/// - Connection management, retries, metrics
/// - Feature parity with pysolarmanv5
///
/// Dependencies: ModbusCore, SwiftNIO, swift-log, swift-metrics, swift-service-lifecycle
public enum SolarmanV5 {}
