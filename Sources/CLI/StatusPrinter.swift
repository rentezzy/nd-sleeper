import Core
import Foundation

enum StatusPrinter {
    typealias Row = (label: String, value: String)

    static func json(_ report: StatusReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    static func text(_ report: StatusReport) -> String {
        let sections: [[Row]] = [
            stateRows(report),
            agentRows(report),
            serviceRows(report),
            metricRows(report.metrics),
        ].filter { !$0.isEmpty }

        let width: Int = sections.flatMap { $0 }.map(\.label.count).max() ?? 0
        let body: [String] = sections.map { section in
            section.map { row in "\(row.label.padding(toLength: width, withPad: " ", startingAt: 0))   \(row.value)" }
                .joined(separator: "\n")
        }
        let warnings: [String] = versionWarnings(report)
        let blocks: [String] = [header(report)] + body + (warnings.isEmpty ? [] : [warnings.joined(separator: "\n")])
        return blocks.joined(separator: "\n\n")
    }

    static func versionWarnings(_ report: StatusReport) -> [String] {
        let helper: String? = switch report.helper.version {
        case nil: "helper is not reachable"
        case BuildInfo.version: nil
        case let version?: "helper runs \(version)"
        }
        let agent: String? = report.agentVersion == BuildInfo.version ? nil : "agent runs \(report.agentVersion)"
        let problems: [String] = [agent, helper].compactMap { $0 }
        guard !problems.isEmpty else { return [] }
        return ["Warning: this CLI is \(BuildInfo.version) but the \(problems.joined(separator: " and the ")). Run `nd-sleeper install`."]
    }

    static func milliseconds(_ nanos: UInt64) -> String {
        String(format: "%.1f ms", Double(nanos) / 1e6)
    }

    static func settings(_ settings: PolicySettings) -> String {
        "battery_window \(settings.batteryWindow)s, battery_floor \(settings.batteryFloor)%"
    }

    private static func header(_ report: StatusReport) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let since: String = formatter.string(from: report.startedAt)
        return "nd-sleeper \(report.agentVersion), up \(format(report.uptimeSeconds)) since \(since)"
    }

    private static func stateRows(_ report: StatusReport) -> [Row] {
        let lid: String = report.lidWindowRemainingSeconds.map {
            "\(report.lid.rawValue), \(format($0)) left in the window"
        } ?? report.lid.rawValue
        let override: String = report.override.map(describe) ?? "none"
        return [
            ("Mode", describe(report.phase)),
            ("Power", power(report)),
            ("Lid", lid),
            ("Sleep flag", flag(report)),
            ("Override", override),
        ]
    }

    private static func agentRows(_ report: StatusReport) -> [Row] {
        let sourceRows: [Row] = report.sources.map { source in ("", summary(source)) }
        let noteRows: [Row] = report.sourceNotes.sorted { $0.key < $1.key }.map { name, note in ("", "\(name): \(note)") }
        let rows: [Row] = (sourceRows.isEmpty ? [("", "not watched in this mode")] : sourceRows) + noteRows
        return rows.enumerated().map { index, row in (index == 0 ? "Agents" : "", row.value) }
    }

    private static func serviceRows(_ report: StatusReport) -> [Row] {
        let wakes: String = report.darkWakeDetection ? "dark and full wakes told apart" : "every wake counts as full"
        return [
            ("Settings", "\(settings(report.config.settings)), \(source(report.config))"),
            ("Helper", helper(report.helper)),
            ("Wake detection", wakes),
        ]
    }

    private static func metricRows(_ metrics: ResourceCounters?) -> [Row] {
        guard let metrics else { return [] }
        return [
            ("Events", "\(metrics.events)"),
            ("Source queries", "\(metrics.sourceQueries), \(milliseconds(metrics.sourceQueryNanos)) total"),
            ("Flag changes", "\(metrics.flagChanges)"),
            ("CPU time", milliseconds(metrics.cpuNanos)),
            ("Wakeups", "\(metrics.wakeups)"),
        ]
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
        let source: String = report.power == .ac ? "AC" : "battery"
        let battery: String = report.batteryPercent.map { ", \($0)%" } ?? ""
        return "\(source)\(battery), thermal \(report.thermal.rawValue)"
    }

    private static func flag(_ report: StatusReport) -> String {
        let wanted: String = report.flagDesired ? "on" : "off"
        guard let actual = report.flagActual else { return "unknown, wanted \(wanted)" }
        let actualText: String = actual ? "on" : "off"
        return actual == report.flagDesired ? actualText : "\(actualText), wanted \(wanted)"
    }

    private static func describe(_ override: OverrideStatus) -> String {
        let mode: String = switch override.mode {
        case .hold(force: true): "hold, forced"
        case .hold: "hold"
        case .normal: "normal"
        }
        return override.remainingSeconds.map { "\(mode), \(format($0)) left" } ?? "\(mode), until `auto`"
    }

    private static func summary(_ source: SourceStatus) -> String {
        let working: Int = source.sessions.filter { $0.state == .working }.count
        let waiting: Int = source.sessions.filter { $0.state == .waiting }.count
        let health: String = switch source.health {
        case .ok: "ok"
        case let .degraded(category): "degraded, \(category)"
        case let .unavailable(category): "unavailable, \(category)"
        }
        let stale: String = source.isStale ? ", stale" : ""
        return "\(source.name): \(working) working, \(waiting) waiting, \(health)\(stale)"
    }

    private static func source(_ config: ConfigStatus) -> String {
        if let error = config.error {
            return "built-in defaults because \(error)"
        }
        switch config.source {
        case .file: return "from ~/\(InstallPath.HomeRelative.config)"
        case .defaults: return "built-in defaults"
        }
    }

    private static func helper(_ connection: HelperConnection) -> String {
        guard connection.connected, let version = connection.version else { return "not reachable" }
        let deadline: String = connection.deadlineRemainingSeconds.map { ", battery deadline in \(format($0))" } ?? ""
        return "connected, \(version)\(deadline)"
    }

    private static func format(_ seconds: Double) -> String {
        DurationText.format(.seconds(Int(seconds.rounded(.up))))
    }
}
