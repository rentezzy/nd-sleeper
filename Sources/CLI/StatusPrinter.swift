import Core
import Foundation

enum StatusPrinter {
    static func json(_ report: StatusReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    static func text(_ report: StatusReport) -> String {
        let override: String = report.override.map(describe) ?? "none"
        let summary: [(String, String)] = [
            ("Mode", describe(report.phase)),
            ("Power", power(report)),
            ("Lid", report.lid.rawValue),
            ("Sleep flag", flag(report)),
            ("Override", override),
        ]
        let window: [(String, String)] = report.lidWindowRemainingSeconds.map { [("Lid window", "\(format($0)) left")] } ?? []
        let rows: [(String, String)] = summary + window + agentRows(report) + metricRows(report.metrics)

        let width = rows.map(\.0.count).max() ?? 0
        let body = rows.map { "\($0.0.padding(toLength: width, withPad: " ", startingAt: 0))   \($0.1)" }
        let warnings = versionWarnings(report)
        return (body + (warnings.isEmpty ? [] : [""] + warnings)).joined(separator: "\n")
    }

    static func versionWarnings(_ report: StatusReport) -> [String] {
        let helper: String? = switch report.helperVersion {
        case nil: "helper is not reachable"
        case BuildInfo.version: nil
        case let version?: "helper runs \(version)"
        }
        let agent = report.agentVersion == BuildInfo.version ? nil : "agent runs \(report.agentVersion)"
        let problems = [agent, helper].compactMap { $0 }
        guard !problems.isEmpty else { return [] }
        return ["Warning: this CLI is \(BuildInfo.version) but the \(problems.joined(separator: " and the ")). Run `nd-sleeper install`."]
    }

    private static func describe(_ phase: Phase) -> String {
        switch phase {
        case .pluggedIn: "plugged in, stays awake with the lid closed"
        case .normalOverride: "normal macOS sleep (override)"
        case .holdOverride: "holding awake (override)"
        case .batteryLidOpen: "on battery, lid open, watching agents"
        case .batteryLidClosedWorking: "on battery, lid closed, awake while agents work"
        case .batteryStressed: "on battery, low battery or heat, normal sleep"
        case .sleepRequested: "sleep requested"
        }
    }

    private static func power(_ report: StatusReport) -> String {
        let source = report.power == .ac ? "AC" : "battery"
        let battery = report.batteryPercent.map { ", \($0)%" } ?? ""
        return "\(source)\(battery), thermal \(report.thermal.rawValue)"
    }

    private static func flag(_ report: StatusReport) -> String {
        let wanted = report.flagDesired ? "on" : "off"
        guard let actual = report.flagActual else { return "unknown, wanted \(wanted)" }
        let actualText = actual ? "on" : "off"
        return actual == report.flagDesired ? actualText : "\(actualText), wanted \(wanted)"
    }

    private static func describe(_ override: OverrideStatus) -> String {
        let mode = switch override.mode {
        case .hold(force: true): "hold, forced"
        case .hold: "hold"
        case .normal: "normal"
        }
        return override.remainingSeconds.map { "\(mode), \(format($0)) left" } ?? "\(mode), until `auto`"
    }

    private static func agentRows(_ report: StatusReport) -> [(String, String)] {
        guard !report.sources.isEmpty else {
            let notes = report.sourceNotes.sorted { $0.key < $1.key }.map { ("", "\($0.key): \($0.value)") }
            return [("Agents", "not watched in this mode")] + notes
        }

        return report.sources.enumerated().flatMap { index, source in
            let working = source.sessions.filter { $0.state == .working }.count
            let waiting = source.sessions.filter { $0.state == .waiting }.count
            let health = switch source.health {
            case .ok: "ok"
            case let .degraded(reason): "degraded, \(reason)"
            case let .unavailable(reason): "unavailable, \(reason)"
            }
            let stale = source.isStale ? ", stale" : ""
            let label = index == 0 ? "Agents" : ""
            let note = report.sourceNotes[source.name].map { [("", "\(source.name): \($0)")] } ?? []
            return [(label, "\(source.name): \(working) working, \(waiting) waiting, \(health)\(stale)")] + note
        }
    }

    private static func metricRows(_ metrics: ResourceCounters?) -> [(String, String)] {
        guard let metrics else { return [] }
        return [
            ("Events", "\(metrics.events)"),
            ("Source queries", "\(metrics.sourceQueries), \(milliseconds(metrics.sourceQueryNanos)) total"),
            ("Flag changes", "\(metrics.flagChanges)"),
            ("CPU time", milliseconds(metrics.cpuNanos)),
            ("Wakeups", "\(metrics.wakeups)"),
        ]
    }

    static func milliseconds(_ nanos: UInt64) -> String {
        String(format: "%.1f ms", Double(nanos) / 1e6)
    }

    private static func format(_ seconds: Double) -> String {
        DurationText.format(.seconds(Int(seconds.rounded(.up))))
    }
}
