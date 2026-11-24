import Foundation

public enum HelperDeadline: Codable, Equatable, Sendable {
    case automatic(window: Duration)
    case timedHold(remaining: Duration)
    case untimedHold(remaining: Duration?)

    public var batteryLimit: Duration {
        switch self {
        case let .automatic(window):
            Self.clampedWindow(window) + SafetyLimit.helperDeadlineMargin
        case let .timedHold(remaining):
            min(max(remaining, .zero), SafetyLimit.maxOverrideDuration) + SafetyLimit.helperDeadlineMargin
        case let .untimedHold(remaining):
            min(max(remaining ?? SafetyLimit.untimedBatteryHoldCap, .zero), SafetyLimit.untimedBatteryHoldCap)
        }
    }

    public static let defaultAutomatic = HelperDeadline.automatic(window: PolicySettings.defaults.windowDuration)

    private static func clampedWindow(_ window: Duration) -> Duration {
        let range = SafetyLimit.batteryWindowSeconds
        return min(max(window, .seconds(range.lowerBound)), .seconds(range.upperBound))
    }
}

public enum HelperEventKind: String, Codable, Sendable {
    case startedOnBattery
    case agentDisconnected
    case unpluggedWithoutAgent
    case batteryDeadline
    case stopping
    case listenerFailed
}

public struct HelperEvent: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let time: Date
    public let kind: HelperEventKind
    public let sleptLidClosed: Bool

    public init(sequence: UInt64, time: Date, kind: HelperEventKind, sleptLidClosed: Bool) {
        self.sequence = sequence
        self.time = time
        self.kind = kind
        self.sleptLidClosed = sleptLidClosed
    }
}

public enum HelperRequest: Codable, Equatable, Sendable {
    case setFlagOn(HelperDeadline)
    case setFlagOff
    case sleepNow
    case readStatus
}

public struct HelperStatus: Codable, Equatable, Sendable {
    public let version: String
    public let flagOn: Bool?
    public let onBattery: Bool
    public let deadlineRemainingSeconds: Double?
    public let instance: String
    public let events: [HelperEvent]

    public init(
        version: String,
        flagOn: Bool?,
        onBattery: Bool,
        deadlineRemainingSeconds: Double?,
        instance: String,
        events: [HelperEvent]
    ) {
        self.version = version
        self.flagOn = flagOn
        self.onBattery = onBattery
        self.deadlineRemainingSeconds = deadlineRemainingSeconds
        self.instance = instance
        self.events = events
    }
}

public enum HelperResponse: Codable, Equatable, Sendable {
    case status(HelperStatus)
    case failed(reason: String, status: HelperStatus)
}

public enum HelperWire {
    public static let payloadKey = "payload"

    public static func encode(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}
