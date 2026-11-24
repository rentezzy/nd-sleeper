import Core
import Foundation

enum StatusPrinter {
    enum Tone {
        case normal
        case quiet
        case good
        case warning
        case bad
    }

    struct Row {
        let label: String
        let value: String
        let tone: Tone

        init(_ label: String, _ value: String, _ tone: Tone = .normal) {
            self.label = label
            self.value = value
            self.tone = tone
        }
    }

    struct Section {
        let title: String
        let rows: [Row]
    }

    static func json(_ report: StatusReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    static func text(_ report: StatusReport, style: TerminalStyle) -> String {
        let sections: [Section] = [
            Section(title: "System", rows: systemRows(report)),
            Section(title: "Agents", rows: agentRows(report)),
            Section(title: "Settings", rows: settingRows(report.config)),
            Section(title: "Metrics", rows: metricRows(report.metrics)),
        ].filter { !$0.rows.isEmpty }

        let rows: [Row] = sections.flatMap(\.rows)
        let labelWidth: Int = rows.map(\.label.count).max() ?? 0
        let valueWidth: Int = rows.map(\.value.count).max() ?? 0
        let ruleWidth: Int = min(max(labelWidth + 3 + valueWidth, 32), 64)

        let rendered: [String] = sections.map { render($0, labelWidth: labelWidth, ruleWidth: ruleWidth, style: style) }
        let warningLines: [String] = warnings(report)
        let warningBlock: [String] = warningLines.isEmpty ? [] : [renderWarnings(warningLines, ruleWidth: ruleWidth, style: style)]
        return ([header(report, style: style)] + rendered + warningBlock).joined(separator: "\n\n")
    }

    static func warnings(_ report: StatusReport) -> [String] {
        let version: String? = versionWarning(report)
        let flag: String? = report.flagActual.flatMap { actual in
            actual == report.flagDesired ? nil : "The sleep lock is \(actual ? "on" : "off") but should be \(report.flagDesired ? "on" : "off")."
        }
        let config: String? = report.config.error.map { "\($0.hasSuffix(".") ? $0 : $0 + ".") Using defaults." }
        let darkWake: String? = report.darkWakeDetection
            ? nil
            : "This Mac cannot tell dark wakes from full wakes, so every wake counts as you being back."
        return [version, flag, config, darkWake].compactMap { $0 }
    }

    static func milliseconds(_ nanos: UInt64) -> String {
        let milliseconds: Double = Double(nanos) / 1e6
        guard milliseconds >= 1_000 else { return String(format: "%.1f ms", milliseconds) }
        return String(format: "%.2f s", milliseconds / 1_000)
    }

    static func settings(_ settings: PolicySettings) -> String {
        "battery window \(HumanDuration.format(Double(settings.batteryWindow), precise: true)), battery floor \(settings.batteryFloor)%"
    }

    private static func versionWarning(_ report: StatusReport) -> String? {
        guard let helperVersion = report.helper.version, report.helper.connected else {
            return "The root helper is not reachable, so the Mac cannot be kept awake. Run `nd-sleeper install`."
        }
        let mismatched: [String] = [("agent", report.agentVersion), ("helper", helperVersion)]
            .filter { $0.1 != BuildInfo.version }
            .map { "the \($0.0) runs \($0.1)" }
        guard !mismatched.isEmpty else { return nil }
        return "This command is \(BuildInfo.version) but \(mismatched.joined(separator: " and ")). Run `nd-sleeper install`."
    }

    private static func header(_ report: StatusReport, style: TerminalStyle) -> String {
        let name: String = style.bold("nd-sleeper \(report.agentVersion)")
        let summary: String = styled(summary(report.phase), headerTone(report), style: style)
        let separator: String = style.dim(" · ")
        let uptime: String = style.dim("up \(HumanDuration.format(report.uptimeSeconds))")
        return name + separator + summary + separator + uptime
    }

    private static func headerTone(_ report: StatusReport) -> Tone {
        guard report.flagActual == report.flagDesired else { return .warning }
        return report.flagDesired ? .good : .normal
    }

    private static func render(_ section: Section, labelWidth: Int, ruleWidth: Int, style: TerminalStyle) -> String {
        let title: String = style.bold(section.title)
        let rule: String = style.dim(String(repeating: "─", count: ruleWidth))
        let lines: [String] = section.rows.map { row in
            let label: String = style.dim(row.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0))
            return "\(label)   \(styled(row.value, row.tone, style: style))"
        }
        return ([title, rule] + lines).joined(separator: "\n")
    }

    private static func renderWarnings(_ lines: [String], ruleWidth: Int, style: TerminalStyle) -> String {
        let title: String = style.bold(style.yellow("Warnings"))
        let rule: String = style.dim(String(repeating: "─", count: ruleWidth))
        let items: [String] = lines.map { "\(style.yellow("!")) \($0)" }
        return ([title, rule] + items).joined(separator: "\n")
    }

    private static func styled(_ value: String, _ tone: Tone, style: TerminalStyle) -> String {
        switch tone {
        case .normal: value
        case .quiet: style.dim(value)
        case .good: style.green(value)
        case .warning: style.yellow(value)
        case .bad: style.red(value)
        }
    }

    private static func systemRows(_ report: StatusReport) -> [Row] {
        let window: [Row] = report.lidWindowRemainingSeconds.map { [Row("Window left", HumanDuration.format($0))] } ?? []
        return [
            Row("Mode", mode(report.phase)),
            Row("Power", power(report)),
            Row("Lid", report.lid == .closed ? "Closed" : "Open"),
            thermalRow(report.thermal),
            sleepRow(report),
            overrideRow(report.override),
        ] + window
    }

    private static func agentRows(_ report: StatusReport) -> [Row] {
        let names: [String] = Array(Set(report.sourceDisplayNames.keys).union(report.sourceNotes.keys)).sorted()
        return names.flatMap { name in
            let source: SourceStatus? = report.sources.first { $0.name == name }
            let displayName: String = report.sourceDisplayNames[name] ?? name
            let note: [Row] = report.sourceNotes[name].map { [Row("caffeinate", capitalized($0), .quiet)] } ?? []
            return [sourceRow(displayName, source, power: report.power)] + note
        }
    }

    private static func settingRows(_ config: ConfigStatus) -> [Row] {
        [
            Row("Battery window", HumanDuration.format(Double(config.settings.batteryWindow), precise: true)),
            Row("Battery floor", "\(config.settings.batteryFloor)%"),
        ]
    }

    private static func metricRows(_ metrics: ResourceCounters?) -> [Row] {
        guard let metrics else { return [] }
        return [
            Row("Events", "\(metrics.events)"),
            Row("Queries", "\(metrics.sourceQueries), \(milliseconds(metrics.sourceQueryNanos)) total"),
            Row("Flag changes", "\(metrics.flagChanges)"),
            Row("CPU", milliseconds(metrics.cpuNanos)),
            Row("Wakeups", "\(metrics.wakeups)"),
        ]
    }

    private static func summary(_ phase: Phase) -> String {
        switch phase {
        case .pluggedIn: "keeping awake on AC"
        case .normalOverride: "normal sleep"
        case .holdOverride: "holding awake"
        case .batteryLidOpen: "watching agents"
        case .batteryLidClosedWorking: "awake for agents"
        case .batteryStressed: "normal sleep"
        case .sleepRequested: "going to sleep"
        }
    }

    private static func mode(_ phase: Phase) -> String {
        switch phase {
        case .pluggedIn: "Plugged in, stays awake with the lid closed"
        case .normalOverride: "Normal macOS sleep"
        case .holdOverride: "Holding awake"
        case .batteryLidOpen: "On battery, watching agents"
        case .batteryLidClosedWorking: "On battery, awake while agents work"
        case .batteryStressed: "On battery, normal sleep for low battery or heat"
        case .sleepRequested: "Sleep requested"
        }
    }

    private static func power(_ report: StatusReport) -> String {
        let source: String = report.power == .ac ? "AC" : "Battery"
        return report.batteryPercent.map { "\(source), \($0)%" } ?? source
    }

    private static func thermalRow(_ level: ThermalLevel) -> Row {
        let tone: Tone = switch level {
        case .nominal, .fair: .normal
        case .serious: .warning
        case .critical: .bad
        }
        return Row("Thermal", capitalized(level.rawValue), tone)
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func sleepRow(_ report: StatusReport) -> Row {
        let wanted: String = report.flagDesired ? "Blocked" : "Allowed"
        guard let actual = report.flagActual else { return Row("Sleep", "Unknown, helper not reachable", .warning) }
        guard actual == report.flagDesired else { return Row("Sleep", actual ? "Blocked" : "Allowed", .bad) }
        return Row("Sleep", wanted)
    }

    private static func overrideRow(_ override: OverrideStatus?) -> Row {
        guard let override else { return Row("Override", "None", .quiet) }
        let mode: String = switch override.mode {
        case .hold(force: true): "Hold, forced"
        case .hold: "Hold"
        case .normal: "Normal"
        }
        let length: String = override.remainingSeconds.map { "\(HumanDuration.format($0)) left" } ?? "until auto"
        return Row("Override", "\(mode), \(length)", .warning)
    }

    private static func sourceRow(_ displayName: String, _ source: SourceStatus?, power: PowerSource) -> Row {
        guard let source else {
            return Row(displayName, power == .ac ? "Not watched on AC" : "Not watched right now", .quiet)
        }
        if case let .unavailable(category) = source.health {
            return Row(displayName, "Unavailable, \(category.replacingOccurrences(of: "_", with: " "))", .bad)
        }
        let working: Int = source.sessions.filter { $0.state == .working }.count
        let waiting: Int = source.sessions.filter { $0.state == .waiting }.count
        let counts: String = working + waiting == 0 ? "Idle" : "\(working) working, \(waiting) waiting"
        let stale: String = source.isStale ? ", stale" : ""
        guard case let .degraded(category) = source.health else {
            return Row(displayName, counts + stale, working > 0 ? .good : .normal)
        }
        return Row(displayName, "\(counts)\(stale), degraded, \(category.replacingOccurrences(of: "_", with: " "))", .warning)
    }
}
