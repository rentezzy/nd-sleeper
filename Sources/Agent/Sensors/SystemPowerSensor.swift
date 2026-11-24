import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt

enum SystemPowerEvent {
    case willSleep
    case fullWake
    case darkWake
}

final class SystemPowerSensor {
    private typealias Connection = OpaquePointer
    private typealias Handler = @convention(c) (UnsafeMutableRawPointer?, Connection?, UInt32, UInt32) -> Void
    private typealias Create = @convention(c) (CFString, UInt32, UnsafeMutablePointer<Connection?>) -> IOReturn
    private typealias SetNotification = @convention(c) (Connection, UnsafeMutableRawPointer?, Handler) -> IOReturn
    private typealias SetDispatchQueue = @convention(c) (Connection, DispatchQueue?) -> Void
    private typealias Acknowledge = @convention(c) (Connection, UInt32) -> IOReturn
    private typealias Release = @convention(c) (Connection) -> IOReturn

    private struct ConnectionAPI {
        let create: Create
        let setNotification: SetNotification
        let setDispatchQueue: SetDispatchQueue
        let acknowledge: Acknowledge
        let release: Release
    }

    private static let capabilityCPU: UInt32 = 0x1
    private static let capabilityVideo: UInt32 = 0x2

    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private static let connectionAPI: ConnectionAPI? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(handle, "IOPMConnectionCreate"),
              let setNotification = dlsym(handle, "IOPMConnectionSetNotification"),
              let setDispatchQueue = dlsym(handle, "IOPMConnectionSetDispatchQueue"),
              let acknowledge = dlsym(handle, "IOPMConnectionAcknowledgeEvent"),
              let release = dlsym(handle, "IOPMConnectionRelease")
        else { return nil }
        return ConnectionAPI(
            create: unsafeBitCast(create, to: Create.self),
            setNotification: unsafeBitCast(setNotification, to: SetNotification.self),
            setDispatchQueue: unsafeBitCast(setDispatchQueue, to: SetDispatchQueue.self),
            acknowledge: unsafeBitCast(acknowledge, to: Acknowledge.self),
            release: unsafeBitCast(release, to: Release.self)
        )
    }()

    private let queue: DispatchQueue
    private let onEvent: @Sendable (SystemPowerEvent) -> Void
    private var connection: Connection?
    private var lastCapabilities = capabilityCPU | capabilityVideo
    private var rootPort: io_connect_t = 0
    private var fallbackPort: IONotificationPortRef?
    private var fallbackNotifier: io_object_t = 0

    init(queue: DispatchQueue, onEvent: @escaping @Sendable (SystemPowerEvent) -> Void) {
        self.queue = queue
        self.onEvent = onEvent
    }

    var detectsDarkWake: Bool {
        connection != nil
    }

    func arm() {
        guard connection == nil, fallbackPort == nil else { return }
        if !armConnection() {
            armFallback()
        }
    }

    func disarm() {
        if let connection, let api = Self.connectionAPI {
            api.setDispatchQueue(connection, nil)
            _ = api.release(connection)
        }
        connection = nil

        if let fallbackPort {
            IODeregisterForSystemPower(&fallbackNotifier)
            IOServiceClose(rootPort)
            IONotificationPortDestroy(fallbackPort)
        }
        fallbackPort = nil
        rootPort = 0
    }

    private func armConnection() -> Bool {
        guard let api = Self.connectionAPI else { return false }

        var created: Connection?
        guard api.create("nd-sleeper" as CFString, Self.capabilityCPU | Self.capabilityVideo, &created) == kIOReturnSuccess,
              let created
        else { return false }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let handler: Handler = { refcon, connection, token, capabilities in
            guard let refcon, let connection else { return }
            Unmanaged<SystemPowerSensor>.fromOpaque(refcon).takeUnretainedValue()
                .capabilitiesChanged(capabilities, connection: connection, token: token)
        }
        guard api.setNotification(created, refcon, handler) == kIOReturnSuccess else {
            _ = api.release(created)
            return false
        }
        api.setDispatchQueue(created, queue)
        connection = created
        return true
    }

    private func capabilitiesChanged(_ capabilities: UInt32, connection: Connection, token: UInt32) {
        _ = Self.connectionAPI?.acknowledge(connection, token)

        let previous = lastCapabilities
        lastCapabilities = capabilities
        let hasCPU = capabilities & Self.capabilityCPU != 0
        let hasVideo = capabilities & Self.capabilityVideo != 0
        let wasFull = previous & Self.capabilityCPU != 0 && previous & Self.capabilityVideo != 0
        let wasAsleep = previous & Self.capabilityCPU == 0

        if !hasCPU {
            onEvent(.willSleep)
        } else if hasVideo, !wasFull {
            onEvent(.fullWake)
        } else if !hasVideo, wasAsleep {
            onEvent(.darkWake)
        }
    }

    private func armFallback() {
        var port: IONotificationPortRef?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &port, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            Unmanaged<SystemPowerSensor>.fromOpaque(refcon).takeUnretainedValue()
                .systemPowerMessage(messageType, argument: messageArgument)
        }, &fallbackNotifier)
        guard rootPort != 0, let port else { return }

        IONotificationPortSetDispatchQueue(port, queue)
        fallbackPort = port
    }

    private func systemPowerMessage(_ messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemWillSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
            onEvent(.willSleep)
        case Self.systemHasPoweredOn:
            onEvent(.fullWake)
        default:
            break
        }
    }
}
