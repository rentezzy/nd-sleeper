import Core
import Dispatch

enum TimerKey: Hashable, Sendable {
    case policy(DeadlineKind)
    case sourceStaleness
}

final class Timekeeper {
    private struct Entry {
        let timer: DispatchSourceTimer
        let at: MonotonicInstant
    }

    private let queue: DispatchQueue
    private let onFire: @Sendable (TimerKey, MonotonicInstant) -> Void
    private var entries: [TimerKey: Entry] = [:]

    init(queue: DispatchQueue, onFire: @escaping @Sendable (TimerKey, MonotonicInstant) -> Void) {
        self.queue = queue
        self.onFire = onFire
    }

    func schedule(_ key: TimerKey, at instant: MonotonicInstant) {
        cancel(key)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, (instant - .now).seconds), leeway: .seconds(1))
        let onFire = onFire
        timer.setEventHandler { [weak self] in
            self?.entries[key] = nil
            onFire(key, instant)
        }
        timer.resume()
        entries[key] = Entry(timer: timer, at: instant)
    }

    func cancel(_ key: TimerKey) {
        entries.removeValue(forKey: key)?.timer.cancel()
    }

    func rearmAll() {
        entries.forEach { key, entry in schedule(key, at: entry.at) }
    }
}
