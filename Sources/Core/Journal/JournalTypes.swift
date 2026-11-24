import Foundation

public struct ResourceCounters: Codable, Equatable, Sendable {
    public var events: UInt64
    public var sourceQueries: UInt64
    public var sourceQueryNanos: UInt64
    public var flagChanges: UInt64
    public var cpuNanos: UInt64
    public var wakeups: UInt64

    public static let zero = ResourceCounters(
        events: 0,
        sourceQueries: 0,
        sourceQueryNanos: 0,
        flagChanges: 0,
        cpuNanos: 0,
        wakeups: 0
    )

    public init(
        events: UInt64,
        sourceQueries: UInt64,
        sourceQueryNanos: UInt64,
        flagChanges: UInt64,
        cpuNanos: UInt64,
        wakeups: UInt64
    ) {
        self.events = events
        self.sourceQueries = sourceQueries
        self.sourceQueryNanos = sourceQueryNanos
        self.flagChanges = flagChanges
        self.cpuNanos = cpuNanos
        self.wakeups = wakeups
    }

    public func delta(since earlier: ResourceCounters) -> ResourceCounters {
        ResourceCounters(
            events: events.subtractingClamped(earlier.events),
            sourceQueries: sourceQueries.subtractingClamped(earlier.sourceQueries),
            sourceQueryNanos: sourceQueryNanos.subtractingClamped(earlier.sourceQueryNanos),
            flagChanges: flagChanges.subtractingClamped(earlier.flagChanges),
            cpuNanos: cpuNanos.subtractingClamped(earlier.cpuNanos),
            wakeups: wakeups.subtractingClamped(earlier.wakeups)
        )
    }
}

public struct RateAnomaly: Codable, Equatable, Sendable {
    public let counter: String
    public let count: Int
    public let windowSeconds: Int
}

public struct JournalReadings: Codable, Equatable, Sendable {
    public let power: PowerSource
    public let lid: LidState
    public let batteryPercent: Int?
    public let thermal: ThermalLevel
    public let agentsWorking: Bool

    public init(_ readings: SystemReadings, agentsWorking: Bool) {
        power = readings.power
        lid = readings.lid
        batteryPercent = readings.batteryPercent
        thermal = readings.thermal
        self.agentsWorking = agentsWorking
    }
}

public enum JournalKind: String, Codable, Sendable {
    case started
    case transition
    case configReloaded
    case wake
    case sourceHealth
    case helper
    case anomaly
    case error
}

public enum WakeKind: String, Codable, Sendable {
    case dark
    case full
}

public struct StartupDiagnostics: Codable, Equatable, Sendable {
    public let version: String
    public let darkWakeAPI: Bool
    public let sources: [String]

    public init(version: String, darkWakeAPI: Bool, sources: [String]) {
        self.version = version
        self.darkWakeAPI = darkWakeAPI
        self.sources = sources
    }
}

public struct SourceHealthChange: Codable, Equatable, Sendable {
    public let source: String
    public let health: String
    public let suppressed: Int?

    public init(source: String, health: String, suppressed: Int?) {
        self.source = source
        self.health = health
        self.suppressed = suppressed
    }
}

public struct JournalEntry: Codable, Equatable, Sendable {
    public let time: Date
    public let kind: JournalKind
    public let from: Phase?
    public let to: Phase?
    public let reason: TransitionReason?
    public let flagOn: Bool?
    public let readings: JournalReadings?
    public let counters: ResourceCounters?
    public let anomaly: RateAnomaly?
    public let startup: StartupDiagnostics?
    public let config: ConfigStatus?
    public let wake: WakeKind?
    public let sourceHealth: SourceHealthChange?
    public let helperEvent: HelperEvent?
    public let message: String?

    public init(
        time: Date,
        kind: JournalKind,
        from: Phase? = nil,
        to: Phase? = nil,
        reason: TransitionReason? = nil,
        flagOn: Bool? = nil,
        readings: JournalReadings? = nil,
        counters: ResourceCounters? = nil,
        anomaly: RateAnomaly? = nil,
        startup: StartupDiagnostics? = nil,
        config: ConfigStatus? = nil,
        wake: WakeKind? = nil,
        sourceHealth: SourceHealthChange? = nil,
        helperEvent: HelperEvent? = nil,
        message: String? = nil
    ) {
        self.time = time
        self.kind = kind
        self.from = from
        self.to = to
        self.reason = reason
        self.flagOn = flagOn
        self.readings = readings
        self.counters = counters
        self.anomaly = anomaly
        self.startup = startup
        self.config = config
        self.wake = wake
        self.sourceHealth = sourceHealth
        self.helperEvent = helperEvent
        self.message = message
    }
}

private extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
