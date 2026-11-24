import Core
import Foundation

final class JournalRecorder {
    private let writer = JournalWriter()
    private var limiter = HealthFlipLimiter()
    private var lastHealth: [String: String] = [:]
    private var helperCursor = HelperEventCursor.load()

    func write(_ entry: JournalEntry) {
        writer.write(entry)
    }

    func error(_ message: String) {
        writer.write(JournalEntry(time: Date(), kind: .error, message: message))
    }

    func started(_ diagnostics: StartupDiagnostics, config: ConfigStatus) {
        writer.write(JournalEntry(time: Date(), kind: .started, startup: diagnostics, config: config))
    }

    func configReloaded(_ config: ConfigStatus) {
        writer.write(JournalEntry(time: Date(), kind: .configReloaded, config: config))
    }

    func wake(_ kind: WakeKind) {
        writer.write(JournalEntry(time: Date(), kind: .wake, wake: kind))
    }

    func sourceHealth(_ source: String, _ health: SourceHealth) {
        let key = Self.key(health)
        let previous = lastHealth[source] ?? Self.key(.ok)
        lastHealth[source] = key
        guard key != previous else { return }

        guard case let .logged(suppressedBefore) = limiter.admit(source, at: .now) else { return }
        writer.write(JournalEntry(
            time: Date(),
            kind: .sourceHealth,
            sourceHealth: SourceHealthChange(source: source, health: key, suppressed: suppressedBefore)
        ))
    }

    func helperEvents(from status: HelperStatus) {
        let unseen = helperCursor?.unseen(in: status) ?? status.events
        let latest = status.events.map(\.sequence).max() ?? 0
        let cursor = HelperEventCursor(instance: status.instance, sequence: max(latest, sequenceIfSameInstance(status)))
        unseen.forEach { event in
            writer.write(JournalEntry(time: event.time, kind: .helper, helperEvent: event))
        }
        guard cursor != helperCursor else { return }

        helperCursor = cursor
        cursor.save()
    }

    private func sequenceIfSameInstance(_ status: HelperStatus) -> UInt64 {
        guard let helperCursor, helperCursor.instance == status.instance else { return 0 }
        return helperCursor.sequence
    }

    private static func key(_ health: SourceHealth) -> String {
        switch health {
        case .ok: "ok"
        case let .degraded(category): "degraded:\(category)"
        case let .unavailable(category): "unavailable:\(category)"
        }
    }
}
