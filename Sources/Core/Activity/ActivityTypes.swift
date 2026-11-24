public struct ActivityCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let reportsWaitingOnUser = ActivityCapabilities(rawValue: 1 << 0)
    public static let tracksProcessExit = ActivityCapabilities(rawValue: 1 << 1)
}

public struct ActivitySourceDescriptor: Equatable, Sendable {
    public let name: String
    public let displayName: String
    public let capabilities: ActivityCapabilities
    public let maxStaleness: Duration?

    public init(name: String, displayName: String, capabilities: ActivityCapabilities, maxStaleness: Duration?) {
        self.name = name
        self.displayName = displayName
        self.capabilities = capabilities
        self.maxStaleness = maxStaleness
    }
}

public enum SessionState: String, Codable, Sendable {
    case working
    case waiting
    case idle
}

public struct ActivitySession: Codable, Equatable, Sendable {
    public let id: String
    public let state: SessionState
    public let label: String?

    public init(id: String, state: SessionState, label: String?) {
        self.id = id
        self.state = state
        self.label = label
    }
}

public enum SourceHealth: Codable, Equatable, Sendable {
    case ok
    case degraded(String)
    case unavailable(String)
}

public struct SourceCost: Equatable, Sendable {
    public let queries: UInt64
    public let queryNanos: UInt64

    public static let zero = SourceCost(queries: 0, queryNanos: 0)

    public init(queries: UInt64, queryNanos: UInt64) {
        self.queries = queries
        self.queryNanos = queryNanos
    }
}

public struct ActivityReport: Equatable, Sendable {
    public let sessions: [ActivitySession]
    public let health: SourceHealth
    public let cost: SourceCost

    public init(sessions: [ActivitySession], health: SourceHealth, cost: SourceCost) {
        self.sessions = sessions
        self.health = health
        self.cost = cost
    }
}

public struct SourceSnapshot: Equatable, Sendable {
    public let descriptor: ActivitySourceDescriptor
    public let report: ActivityReport
    public let updatedAt: MonotonicInstant

    public init(descriptor: ActivitySourceDescriptor, report: ActivityReport, updatedAt: MonotonicInstant) {
        self.descriptor = descriptor
        self.report = report
        self.updatedAt = updatedAt
    }
}

public struct SourceStatus: Codable, Equatable, Sendable {
    public let name: String
    public let health: SourceHealth
    public let isStale: Bool
    public let sessions: [ActivitySession]
}

public struct ActivityVerdict: Equatable, Sendable {
    public let isWorking: Bool
    public let workingSessions: Int
    public let sources: [SourceStatus]
}
