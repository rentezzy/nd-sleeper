import Foundation

public enum HelperDeadline: Codable, Equatable, Sendable {
    case automatic
    case timedHold(remaining: Duration)
    case untimedHold(remaining: Duration?)

    public var batteryLimit: Duration {
        switch self {
        case .automatic:
            SafetyLimit.autoHelperDeadline
        case let .timedHold(remaining):
            min(max(remaining, .zero), SafetyLimit.maxOverrideDuration) + SafetyLimit.helperDeadlineMargin
        case let .untimedHold(remaining):
            min(max(remaining ?? SafetyLimit.untimedBatteryHoldCap, .zero), SafetyLimit.untimedBatteryHoldCap)
        }
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

    public init(version: String, flagOn: Bool?, onBattery: Bool, deadlineRemainingSeconds: Double?) {
        self.version = version
        self.flagOn = flagOn
        self.onBattery = onBattery
        self.deadlineRemainingSeconds = deadlineRemainingSeconds
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
