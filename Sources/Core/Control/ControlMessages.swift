import Foundation

public enum ControlRequest: Codable, Equatable, Sendable {
    case status(includeMetrics: Bool)
    case setOverride(OverrideRequest)
    case auto
    case sleepNow
    case reload
}

public enum ControlResponse: Codable, Equatable, Sendable {
    case status(StatusReport)
    case config(ConfigStatus)
    case ok
    case failed(String)
}

public struct OverrideStatus: Codable, Equatable, Sendable {
    public let mode: OverrideMode
    public let remainingSeconds: Double?

    public init(mode: OverrideMode, remainingSeconds: Double?) {
        self.mode = mode
        self.remainingSeconds = remainingSeconds
    }
}

public struct HelperConnection: Codable, Equatable, Sendable {
    public let connected: Bool
    public let version: String?
    public let deadlineRemainingSeconds: Double?

    public init(connected: Bool, version: String?, deadlineRemainingSeconds: Double?) {
        self.connected = connected
        self.version = version
        self.deadlineRemainingSeconds = deadlineRemainingSeconds
    }
}

public struct StatusReport: Codable, Equatable, Sendable {
    public let agentVersion: String
    public let startedAt: Date
    public let uptimeSeconds: Double
    public let darkWakeDetection: Bool
    public let config: ConfigStatus
    public let helper: HelperConnection
    public let phase: Phase
    public let power: PowerSource
    public let lid: LidState
    public let batteryPercent: Int?
    public let thermal: ThermalLevel
    public let flagDesired: Bool
    public let flagActual: Bool?
    public let override: OverrideStatus?
    public let lidWindowRemainingSeconds: Double?
    public let sources: [SourceStatus]
    public let sourceNotes: [String: String]
    public let sourceDisplayNames: [String: String]
    public let metrics: ResourceCounters?

    public init(
        agentVersion: String,
        startedAt: Date,
        uptimeSeconds: Double,
        darkWakeDetection: Bool,
        config: ConfigStatus,
        helper: HelperConnection,
        phase: Phase,
        power: PowerSource,
        lid: LidState,
        batteryPercent: Int?,
        thermal: ThermalLevel,
        flagDesired: Bool,
        flagActual: Bool?,
        override: OverrideStatus?,
        lidWindowRemainingSeconds: Double?,
        sources: [SourceStatus],
        sourceNotes: [String: String],
        sourceDisplayNames: [String: String],
        metrics: ResourceCounters?
    ) {
        self.agentVersion = agentVersion
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
        self.darkWakeDetection = darkWakeDetection
        self.config = config
        self.helper = helper
        self.phase = phase
        self.power = power
        self.lid = lid
        self.batteryPercent = batteryPercent
        self.thermal = thermal
        self.flagDesired = flagDesired
        self.flagActual = flagActual
        self.override = override
        self.lidWindowRemainingSeconds = lidWindowRemainingSeconds
        self.sources = sources
        self.sourceNotes = sourceNotes
        self.sourceDisplayNames = sourceDisplayNames
        self.metrics = metrics
    }
}

public enum ControlWire {
    public static let maxMessageBytes = 64 * 1024
    public static let malformedRequest = "malformed request"

    public static func encode(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value) + Data("\n".utf8)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}
