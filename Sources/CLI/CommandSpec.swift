struct CommandSpec {
    let name: String
    let usage: String
    let summary: String
    let details: String
    let flags: Set<String>
    let options: Set<String>
    let maxPositionals: Int

    var help: String {
        """
        Usage: nd-sleeper \(usage)

        \(summary)

        \(details)
        """
    }
}

enum Commands {
    static let all: [CommandSpec] = [status, hold, normal, auto, sleep, reload, logs, install, uninstall]

    static func named(_ name: String) -> CommandSpec? {
        all.first { $0.name == name }
    }

    static let status = CommandSpec(
        name: "status",
        usage: "status [--json] [--metrics]",
        summary: "Shows what nd-sleeper is doing and why.",
        details: """
        Prints the uptime, mode, power source, lid, battery, thermal state, the kernel sleep flag (wanted and \
        actual), any override, the time left in the lid-closed window, agent sessions per source with their \
        health, the active settings and where they came from, and the helper connection.

        Options:
          --json      Print machine-readable output.
          --metrics   Add resource counters since the agent started: events, source queries and their time, \
        flag changes, CPU time and wakeups.
        """,
        flags: ["--json", "--metrics"],
        options: [],
        maxPositionals: 0
    )

    static let hold = CommandSpec(
        name: "hold",
        usage: "hold [duration] [--force]",
        summary: "Keeps the Mac awake with the lid closed regardless of agent activity.",
        details: """
        Lasts until the duration ends or `nd-sleeper auto` runs. Without a duration it holds until `auto`, \
        but on battery an untimed hold ends after 4 hours. On battery the 20% floor and serious heat still end \
        the hold unless --force is given.

        Arguments:
          duration    How long to hold, such as 45m, 2h or 1h30m. At most 30 days.

        Options:
          --force     Ignore the battery floor and the thermal cutoff.
        """,
        flags: ["--force"],
        options: [],
        maxPositionals: 1
    )

    static let normal = CommandSpec(
        name: "normal",
        usage: "normal [duration]",
        summary: "Restores normal macOS sleep, on AC too.",
        details: """
        Lasts until the duration ends or `nd-sleeper auto` runs.

        Arguments:
          duration    How long to stay in normal mode, such as 1h. At most 30 days.
        """,
        flags: [],
        options: [],
        maxPositionals: 1
    )

    static let auto = CommandSpec(
        name: "auto",
        usage: "auto",
        summary: "Clears any override and returns to automatic behavior.",
        details: "Use it to end a `hold` or `normal` early.",
        flags: [],
        options: [],
        maxPositionals: 0
    )

    static let sleep = CommandSpec(
        name: "sleep",
        usage: "sleep",
        summary: "Sleeps the Mac now.",
        details: """
        Needed because the Apple menu Sleep item does nothing while the kernel sleep flag is set. \
        Clears any override, so automatic behavior resumes when you wake the Mac.
        """,
        flags: [],
        options: [],
        maxPositionals: 0
    )

    static let reload = CommandSpec(
        name: "reload",
        usage: "reload",
        summary: "Re-reads ~/.config/nd-sleeper/config.toml and applies it now.",
        details: """
        Settings are battery_window (seconds, 60 to 14400, default 1800) and battery_floor (percent, 1 to 99, \
        default 20). Without the file the defaults apply. If the file has an error, nothing changes and the \
        error is printed.
        """,
        flags: [],
        options: [],
        maxPositionals: 0
    )

    static let logs = CommandSpec(
        name: "logs",
        usage: "logs [--since <duration>] [--json]",
        summary: "Prints state transitions with their reasons and resource counters.",
        details: """
        Reads the journal in ~/Library/Logs/nd-sleeper/ directly, so it works while the agent is stopped.

        Options:
          --since <duration>   Only show entries newer than this, such as 1h or 7d.
          --json               Print the raw journal lines.
        """,
        flags: ["--json"],
        options: ["--since"],
        maxPositionals: 0
    )

    static let install = CommandSpec(
        name: "install",
        usage: "install",
        summary: "Installs or upgrades the root helper and the user agent, then starts them.",
        details: """
        Copies this binary to /usr/local/libexec/nd-sleeper and registers com.nd.sleeper.helper (root) and \
        com.nd.sleeper.agent (you). Asks for your password for the root steps only. Safe to run again.
        """,
        flags: [],
        options: [],
        maxPositionals: 0
    )

    static let uninstall = CommandSpec(
        name: "uninstall",
        usage: "uninstall",
        summary: "Clears the kernel sleep flag, stops both services and removes them.",
        details: """
        Clears the flag directly, even if the helper is already gone, and checks that it reads off. \
        Asks for your password. The journal in ~/Library/Logs/nd-sleeper/ is kept.
        """,
        flags: [],
        options: [],
        maxPositionals: 0
    )

    static var topLevelHelp: String {
        let width = all.map(\.usage.count).max() ?? 0
        let lines = all.map { "  \($0.usage.padding(toLength: width, withPad: " ", startingAt: 0))   \($0.summary)" }
        return """
        nd-sleeper keeps a MacBook awake with the lid closed on AC, and on battery only while AI agents work.

        Usage: nd-sleeper <command> [options]

        Commands:
        \(lines.joined(separator: "\n"))

        Durations look like 45m, 2h or 1h30m.
        Run `nd-sleeper help <command>` or `nd-sleeper <command> --help` for details.
        Options: -h, --help   --version
        """
    }
}
