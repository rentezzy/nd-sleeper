public enum ActivityAggregator {
    public static func combine(_ snapshots: [SourceSnapshot], now: MonotonicInstant) -> ActivityVerdict {
        let sources = snapshots.map { status(of: $0, now: now) }
        let workingSessions = sources
            .filter(isTrusted)
            .map { $0.sessions.filter { $0.state == .working }.count }
            .reduce(0, +)

        return ActivityVerdict(isWorking: workingSessions > 0, workingSessions: workingSessions, sources: sources)
    }

    public static func nextStaleness(_ snapshots: [SourceSnapshot], now: MonotonicInstant) -> MonotonicInstant? {
        snapshots
            .compactMap { snapshot in snapshot.descriptor.maxStaleness.map { snapshot.updatedAt + $0 } }
            .filter { $0 > now }
            .min()
    }

    private static func status(of snapshot: SourceSnapshot, now: MonotonicInstant) -> SourceStatus {
        let isStale = snapshot.descriptor.maxStaleness.map { snapshot.updatedAt + $0 <= now } ?? false
        return SourceStatus(
            name: snapshot.descriptor.name,
            health: snapshot.report.health,
            isStale: isStale,
            sessions: snapshot.report.sessions
        )
    }

    private static func isTrusted(_ status: SourceStatus) -> Bool {
        guard !status.isStale else { return false }
        guard case .unavailable = status.health else { return true }
        return false
    }
}
