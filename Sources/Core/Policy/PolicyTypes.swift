public typealias MonotonicInstant = ContinuousClock.Instant

public enum PowerSource: String, Codable, Sendable {
    case ac
    case battery
}

public enum LidState: String, Codable, Sendable {
    case open
    case closed
}

public enum ThermalLevel: String, Codable, Sendable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }
}

public struct SystemReadings: Equatable, Sendable {
    public var power: PowerSource
    public var lid: LidState
    public var batteryPercent: Int?
    public var thermal: ThermalLevel

    public init(power: PowerSource, lid: LidState, batteryPercent: Int?, thermal: ThermalLevel) {
        self.power = power
        self.lid = lid
        self.batteryPercent = batteryPercent
        self.thermal = thermal
    }
}

public enum OverrideRequest: Codable, Equatable, Sendable {
    case hold(duration: Duration?, force: Bool)
    case normal(duration: Duration?)
}

public enum OverrideMode: Codable, Equatable, Sendable {
    case hold(force: Bool)
    case normal
}

public struct Override: Equatable, Sendable {
    public let mode: OverrideMode
    public let expiresAt: MonotonicInstant?
}

public enum ReconcileCause: String, Codable, Sendable {
    case started
    case powerChanged
    case woke
    case darkWoke
    case refresh
}

public enum PolicyCommand: Equatable, Sendable {
    case setOverride(OverrideRequest)
    case auto
    case sleepNow
}

public enum DeadlineKind: String, Codable, Sendable, CaseIterable {
    case lidClosedWindow
    case overrideExpiry
    case holdBatteryCap
    case sleepRetry
}

public enum PolicyEvent: Equatable, Sendable {
    case reconcile(SystemReadings, agentsWorking: Bool, cause: ReconcileCause)
    case lidChanged(LidState)
    case thermalChanged(ThermalLevel)
    case batteryChanged(percent: Int)
    case activityChanged(isWorking: Bool)
    case command(PolicyCommand)
    case deadlineFired(DeadlineKind, scheduledFor: MonotonicInstant)
    case helperFlagObserved(isOn: Bool)
    case settingsChanged(PolicySettings)
}

public enum BatteryGuard: Equatable, Sendable {
    case automatic(window: Duration, windowEndsAt: MonotonicInstant?)
    case timedHold(endsAt: MonotonicInstant)
    case untimedHold(capEndsAt: MonotonicInstant?)
}

public enum FlagRequest: Equatable, Sendable {
    case off
    case on(BatteryGuard)

    public var isOn: Bool {
        self != .off
    }
}

public enum DemandInput: String, Codable, Sendable, CaseIterable {
    case powerSource
    case systemPower
    case lid
    case thermal
    case batteryPercent
    case agentActivity
}

public enum Phase: String, Codable, Sendable {
    case pluggedIn
    case normalOverride
    case holdOverride
    case batteryLidOpen
    case batteryLidClosedWorking
    case batteryStressed
    case sleepRequested
}

public enum TransitionReason: String, Codable, Sendable {
    case started
    case woke
    case darkWoke
    case refreshed
    case powerChanged
    case lidOpened
    case lidClosed
    case thermalChanged
    case batteryChanged
    case agentsStarted
    case agentsStopped
    case overrideSet
    case overrideCleared
    case overrideExpired
    case holdCapReached
    case batteryFloor
    case thermalCutoff
    case windowExpired
    case sleepCommand
    case sleepRetry
    case helperFlagMismatch
    case settingsChanged
}

public struct Transition: Equatable, Sendable {
    public let from: Phase?
    public let to: Phase
    public let reason: TransitionReason
    public let flag: FlagRequest
    public let override: Override?
}

public enum PolicyAction: Equatable, Sendable {
    case setFlag(FlagRequest)
    case requestReconcile
    case sleepNow
    case setDemand(Set<DemandInput>)
    case scheduleDeadline(DeadlineKind, at: MonotonicInstant)
    case cancelDeadline(DeadlineKind)
    case record(Transition)
}

public struct SleepRequest: Equatable, Sendable {
    public let requestedAt: MonotonicInstant
    public let retryAt: MonotonicInstant?
}

public struct PolicyInputs: Equatable, Sendable {
    public var readings: SystemReadings
    public var settings: PolicySettings
    public var agentsWorking: Bool
    public var override: Override?
    public var lidWindowEndsAt: MonotonicInstant?
    public var holdCapEndsAt: MonotonicInstant?
    public var sleepRequest: SleepRequest?
    public var reconcilePending: Bool

    public init(readings: SystemReadings, settings: PolicySettings) {
        self.readings = readings
        self.settings = settings
        agentsWorking = false
        reconcilePending = false
    }
}

public struct PolicyOutputs: Equatable, Sendable {
    public let phase: Phase
    public let flag: FlagRequest
    public let demand: Set<DemandInput>
    public let deadlines: [DeadlineKind: MonotonicInstant]
}

public struct PolicyState: Equatable, Sendable {
    public let inputs: PolicyInputs
    public let outputs: PolicyOutputs?

    public init(readings: SystemReadings, settings: PolicySettings) {
        inputs = PolicyInputs(readings: readings, settings: settings)
        outputs = nil
    }

    init(inputs: PolicyInputs, outputs: PolicyOutputs?) {
        self.inputs = inputs
        self.outputs = outputs
    }
}
