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
        }
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
