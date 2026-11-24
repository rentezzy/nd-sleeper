import Core

struct HealthFlipLimiter {
    private static let window: Duration = .seconds(3_600)
    private static let limit = 10

    private var logged: [String: [MonotonicInstant]] = [:]
    private var suppressed: [String: Int] = [:]

    mutating func admit(_ source: String, at now: MonotonicInstant) -> SourceHealthAdmission {
        let recent = (logged[source] ?? []).filter { now - $0 < Self.window }
        guard recent.count < Self.limit else {
            logged[source] = recent
            suppressed[source, default: 0] += 1
            return .suppressed
        }

        logged[source] = recent + [now]
        let skipped = suppressed.removeValue(forKey: source)
        return .logged(suppressedBefore: skipped)
    }
}

enum SourceHealthAdmission {
    case logged(suppressedBefore: Int?)
    case suppressed
}
