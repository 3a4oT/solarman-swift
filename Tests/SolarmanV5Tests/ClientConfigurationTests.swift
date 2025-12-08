// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Petro Rovenskyi

@testable import SolarmanV5
import Testing

// MARK: - ClientConfigurationTests

@Suite("Client Configuration")
struct ClientConfigurationTests {
    // MARK: - SolarmanClientConfiguration

    @Test("Default values match pysolarmanv5")
    func defaultValues() {
        let config = SolarmanClientConfiguration(
            host: "192.168.1.100",
            serial: 1_700_000_001,
        )

        #expect(config.host == "192.168.1.100")
        #expect(config.serial == 1_700_000_001)
        #expect(config.port == 8899) // pysolarmanv5 default
        #expect(config.unitId == 1)
        #expect(config.timeout == .seconds(60)) // pysolarmanv5 socket_timeout
        #expect(config.retries == 3)
        #expect(config.idleTimeout == .seconds(60))
        #expect(config.reconnectionStrategy == .immediate)
        #expect(config.v5ErrorCorrection == false)
    }

    @Test("Custom values are preserved")
    func customValues() {
        let config = SolarmanClientConfiguration(
            host: "10.0.0.1",
            serial: 123_456_789,
            port: 9000,
            unitId: 5,
            timeout: .seconds(30),
            retries: 5,
            idleTimeout: .seconds(120),
            reconnectionStrategy: .exponentialBackoff(),
            v5ErrorCorrection: true,
        )

        #expect(config.host == "10.0.0.1")
        #expect(config.serial == 123_456_789)
        #expect(config.port == 9000)
        #expect(config.unitId == 5)
        #expect(config.timeout == .seconds(30))
        #expect(config.retries == 5)
        #expect(config.idleTimeout == .seconds(120))
        #expect(config.reconnectionStrategy == .exponentialBackoff())
        #expect(config.v5ErrorCorrection == true)
    }

    @Test("Nil idle timeout disables auto-disconnect")
    func nilIdleTimeout() {
        let config = SolarmanClientConfiguration(
            host: "192.168.1.100",
            serial: 1_700_000_001,
            idleTimeout: nil,
        )

        #expect(config.idleTimeout == nil)
    }

    // MARK: - SolarmanConstants

    @Test("Default port is 8899")
    func defaultPort() {
        #expect(SolarmanConstants.defaultPort == 8899)
    }

    @Test("Max frame size is 1024")
    func maxFrameSize() {
        #expect(SolarmanConstants.maxFrameSize == 1024)
    }

    @Test("Min response size is 14")
    func minResponseSize() {
        #expect(SolarmanConstants.minResponseSize == 14)
    }

    // MARK: - ReconnectionStrategy

    @Test("Disabled strategy")
    func disabledStrategy() {
        let strategy = ReconnectionStrategy.disabled
        #expect(strategy == .disabled)
    }

    @Test("Immediate strategy is default")
    func immediateStrategy() {
        let strategy = ReconnectionStrategy.immediate
        #expect(strategy == .immediate)
    }

    @Test("Exponential backoff with defaults")
    func exponentialBackoffDefaults() {
        let strategy = ReconnectionStrategy.exponentialBackoff()
        #expect(strategy == .exponentialBackoff(initialDelay: .milliseconds(100), maxDelay: .seconds(30)))
    }

    @Test("Exponential backoff with custom values")
    func exponentialBackoffCustom() {
        let strategy = ReconnectionStrategy.exponentialBackoff(
            initialDelay: .milliseconds(500),
            maxDelay: .seconds(60),
        )
        #expect(strategy == .exponentialBackoff(initialDelay: .milliseconds(500), maxDelay: .seconds(60)))
    }
}

// MARK: - ClientErrorsTests

@Suite("Client Errors")
struct ClientErrorsTests {
    // MARK: - isRetryable

    @Test("Timeout is retryable")
    func timeoutRetryable() {
        #expect(SolarmanClientError.timeout.isRetryable == true)
    }

    @Test("IO error is retryable")
    func ioErrorRetryable() {
        #expect(SolarmanClientError.ioError("test").isRetryable == true)
    }

    @Test("Channel closed is retryable")
    func channelClosedRetryable() {
        #expect(SolarmanClientError.channelClosed.isRetryable == true)
    }

    @Test("Connection failed is retryable")
    func connectionFailedRetryable() {
        #expect(SolarmanClientError.connectionFailed("test").isRetryable == true)
    }

    @Test("Not connected is not retryable")
    func notConnectedNotRetryable() {
        #expect(SolarmanClientError.notConnected.isRetryable == false)
    }

    @Test("Already connected is not retryable")
    func alreadyConnectedNotRetryable() {
        #expect(SolarmanClientError.alreadyConnected.isRetryable == false)
    }

    @Test("Invalid parameter is not retryable")
    func invalidParameterNotRetryable() {
        #expect(SolarmanClientError.invalidParameter("test").isRetryable == false)
    }

    @Test("Modbus exception is not retryable")
    func modbusExceptionNotRetryable() {
        #expect(SolarmanClientError.modbusException(.illegalFunction).isRetryable == false)
    }

    @Test("Sequence mismatch is not retryable")
    func sequenceMismatchNotRetryable() {
        #expect(SolarmanClientError.sequenceMismatch(expected: 1, got: 2).isRetryable == false)
    }

    @Test("V5 frame error is not retryable")
    func v5FrameErrorNotRetryable() {
        #expect(SolarmanClientError.v5FrameError("test").isRetryable == false)
    }

    @Test("RTU error is not retryable")
    func rtuErrorNotRetryable() {
        #expect(SolarmanClientError.rtuError("test").isRetryable == false)
    }

    // MARK: - metricsLabel

    @Test("Metrics labels are correct")
    func metricsLabels() {
        #expect(SolarmanClientError.notConnected.metricsLabel == "not_connected")
        #expect(SolarmanClientError.alreadyConnected.metricsLabel == "already_connected")
        #expect(SolarmanClientError.connectionFailed("").metricsLabel == "connection_failed")
        #expect(SolarmanClientError.timeout.metricsLabel == "timeout")
        #expect(SolarmanClientError.sequenceMismatch(expected: 0, got: 0).metricsLabel == "sequence_mismatch")
        #expect(SolarmanClientError.v5FrameError("").metricsLabel == "v5_frame_error")
        #expect(SolarmanClientError.modbusException(.illegalFunction).metricsLabel == "modbus_exception")
        #expect(SolarmanClientError.rtuError("").metricsLabel == "rtu_error")
        #expect(SolarmanClientError.ioError("").metricsLabel == "io_error")
        #expect(SolarmanClientError.invalidParameter("").metricsLabel == "invalid_parameter")
        #expect(SolarmanClientError.channelClosed.metricsLabel == "channel_closed")
    }
}

// MARK: - ConnectionStateTests

@Suite("Connection State")
struct ConnectionStateTests {
    @Test("All states are distinct")
    func allStatesDistinct() {
        let states: [ConnectionState] = [.disconnected, .connecting, .connected, .disconnecting]
        for (i, state1) in states.enumerated() {
            for (j, state2) in states.enumerated() {
                if i == j {
                    #expect(state1 == state2)
                } else {
                    #expect(state1 != state2)
                }
            }
        }
    }
}

// MARK: - SequenceNumberGeneratorTests

@Suite("Sequence Number Generator")
struct SequenceNumberGeneratorTests {
    @Test("First value is 1")
    func firstValue() {
        let generator = SequenceNumberGenerator()
        #expect(generator.next() == 1)
    }

    @Test("Values increment sequentially")
    func incrementSequentially() {
        let generator = SequenceNumberGenerator()
        #expect(generator.next() == 1)
        #expect(generator.next() == 2)
        #expect(generator.next() == 3)
    }

    @Test("Reset returns to 0")
    func reset() {
        let generator = SequenceNumberGenerator()
        _ = generator.next()
        _ = generator.next()
        generator.reset()
        #expect(generator.next() == 1)
    }

    @Test("Skips zero on overflow")
    func skipsZero() {
        let generator = SequenceNumberGenerator()
        // Generate 65535 values to get to overflow point
        for _ in 1..<65535 {
            _ = generator.next()
        }
        #expect(generator.next() == 65535)
        #expect(generator.next() == 1) // Skips 0, wraps to 1
    }
}
