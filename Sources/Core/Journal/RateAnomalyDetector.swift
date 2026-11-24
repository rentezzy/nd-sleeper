public struct RateAnomalyDetector: Sendable {
    public let counter: String
    public let window: Duration
    public let limit: Int
    private var timestamps: [MonotonicInstant] = []
    private var inIncident = false

    public init(counter: String, window: Duration, limit: Int) {
        self.counter = counter
        self.window = window
        self.limit = limit
    }

    public mutating func record(at now: MonotonicInstant) -> RateAnomaly? {
        let cutoff = now - window
        timestamps = Array((timestamps.filter { $0 > cutoff } + [now]).suffix(limit + 1))

        if timestamps.count <= max(1, limit / 2) {
            inIncident = false
        }
        guard timestamps.count > limit, !inIncident else { return nil }

        inIncident = true
        return RateAnomaly(counter: counter, count: timestamps.count, windowSeconds: Int(window.components.seconds))
    }
}
