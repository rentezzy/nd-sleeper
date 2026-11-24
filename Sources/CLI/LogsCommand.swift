import Core
import Foundation

enum LogsCommand {
    static func run(since: Duration?, json: Bool) {
        let cutoff = since.map { Date().addingTimeInterval(-$0.seconds) }
        let decoder = JournalCoding.makeDecoder()
        let entries = lines()
            .compactMap { line in (try? decoder.decode(JournalEntry.self, from: Data(line.utf8))).map { (line, $0) } }
            .filter { _, entry in cutoff.map { entry.time >= $0 } ?? true }

        guard !entries.isEmpty else {
            if !json {
                print(cutoff == nil ? "No journal entries yet." : "No journal entries in that time.")
            }
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        entries.forEach { line, entry in print(json ? line : format(entry, formatter: formatter)) }
    }

    private static func lines() -> [String] {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(InstallPath.HomeRelative.journalDirectory)
        let names: [String] = JournalFiles.rotated.reversed() + [JournalFiles.current]
        let contents: [String] = names.compactMap { name in
            try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        }
        return contents.flatMap { $0.split(separator: "\n").map(String.init) }
    }

    private static func format(_ entry: JournalEntry, formatter: DateFormatter) -> String {
        let time = formatter.string(from: entry.time)
        switch entry.kind {
        case .transition:
            return "\(time)  \(transition(entry))\(readings(entry.readings))\(counters(entry.counters))"
        case .anomaly:
            let anomaly = entry.anomaly.map { "\($0.counter) \($0.count) in \($0.windowSeconds)s" } ?? "unknown"
            return "\(time)  anomaly: \(anomaly)"
        case .error:
            return "\(time)  error: \(entry.message ?? "unknown")"
        case .started:
            return "\(time)  started \(started(entry))"
        case .configReloaded:
            return "\(time)  settings reloaded: \(config(entry.config))"
        case .wake:
            return "\(time)  \(entry.wake?.rawValue ?? "unknown") wake"
        case .sourceHealth:
            return "\(time)  \(health(entry.sourceHealth))"
        case .helper:
            return "\(time)  \(helper(entry.helperEvent))"
        }
    }

    private static func started(_ entry: JournalEntry) -> String {
        guard let startup = entry.startup else { return "" }
        let darkWake: String = startup.darkWakeAPI ? "dark wake detection on" : "dark wake detection off"
        return "\(startup.version), \(darkWake), sources \(startup.sources.joined(separator: ", ")), \(config(entry.config))"
    }

    private static func config(_ config: ConfigStatus?) -> String {
        guard let config else { return "unknown" }
        let source: String = config.source == .file ? "from config.toml" : "defaults"
        return "\(StatusPrinter.settings(config.settings)) (\(source))"
    }

    private static func health(_ change: SourceHealthChange?) -> String {
        guard let change else { return "source health changed" }
        let suppressed: String = change.suppressed.map { " (\($0) similar changes not logged)" } ?? ""
        return "\(change.source) health \(change.health)\(suppressed)"
    }

    private static func helper(_ event: HelperEvent?) -> String {
        guard let event else { return "helper event" }
        let reason: String = switch event.kind {
        case .startedOnBattery: "it started on battery"
        case .agentDisconnected: "the agent disconnected on battery"
        case .unpluggedWithoutAgent: "unplugged while the agent was not running"
        case .batteryDeadline: "its battery deadline passed"
        case .stopping: "the helper is stopping"
        case .listenerFailed: "the helper could not start its service"
        }
        let slept: String = event.sleptLidClosed ? ", slept with the lid closed" : ""
        return "helper cleared the sleep flag because \(reason)\(slept)"
    }

    private static func transition(_ entry: JournalEntry) -> String {
        let from = entry.from?.rawValue ?? "start"
        let to = entry.to?.rawValue ?? "?"
        let reason = entry.reason?.rawValue ?? "?"
        let flag = entry.flagOn.map { $0 ? "flag on" : "flag off" } ?? ""
        return "\(from) -> \(to)  \(reason)  \(flag)"
    }

    private static func readings(_ readings: JournalReadings?) -> String {
        guard let readings else { return "" }
        let battery = readings.batteryPercent.map { " \($0)%" } ?? ""
        let agents = readings.agentsWorking ? "agents working" : "agents idle"
        return "  [\(readings.power.rawValue) lid \(readings.lid.rawValue)\(battery) \(readings.thermal.rawValue), \(agents)]"
    }

    private static func counters(_ counters: ResourceCounters?) -> String {
        guard let counters else { return "" }
        return "  events \(counters.events), queries \(counters.sourceQueries), "
            + "cpu \(StatusPrinter.milliseconds(counters.cpuNanos)), wakeups \(counters.wakeups)"
    }
}
