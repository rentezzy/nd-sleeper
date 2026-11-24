import Core

struct CLIError: Error {
    let message: String
    let exitCode: Int32

    static func usage(_ message: String, command: String?) -> CLIError {
        let hint = command.map { "nd-sleeper \($0) --help" } ?? "nd-sleeper --help"
        return CLIError(message: "\(message)\nRun `\(hint)` for usage.", exitCode: 64)
    }

    static func failure(_ message: String) -> CLIError {
        CLIError(message: message, exitCode: 1)
    }
}

struct ParsedArguments {
    let positionals: [String]
    let flags: Set<String>
    let options: [String: String]
    let wantsHelp: Bool
}

enum ArgumentParser {
    static func parse(_ arguments: [String], for spec: CommandSpec) throws -> ParsedArguments {
        guard !arguments.contains("--help"), !arguments.contains("-h") else {
            return ParsedArguments(positionals: [], flags: [], options: [:], wantsHelp: true)
        }

        let parsed = try parse(arguments[...], spec: spec)
        guard parsed.positionals.count <= spec.maxPositionals else {
            throw CLIError.usage("Too many arguments.", command: spec.name)
        }
        return ParsedArguments(
            positionals: parsed.positionals,
            flags: parsed.flags,
            options: parsed.options,
            wantsHelp: false
        )
    }

    private static func parse(
        _ arguments: ArraySlice<String>,
        spec: CommandSpec
    ) throws -> (positionals: [String], flags: Set<String>, options: [String: String]) {
        guard let first = arguments.first else { return ([], [], [:]) }

        let rest = arguments.dropFirst()
        if spec.flags.contains(first) {
            let parsed = try parse(rest, spec: spec)
            return (parsed.positionals, parsed.flags.union([first]), parsed.options)
        }
        if spec.options.contains(first) {
            guard let value = rest.first, !value.hasPrefix("-") else {
                throw CLIError.usage("\(first) needs a value.", command: spec.name)
            }
            let parsed = try parse(rest.dropFirst(), spec: spec)
            return (parsed.positionals, parsed.flags, parsed.options.merging([first: value]) { new, _ in new })
        }
        if first.hasPrefix("-") {
            throw CLIError.usage("Unknown option \(first).", command: spec.name)
        }
        let parsed = try parse(rest, spec: spec)
        return ([first] + parsed.positionals, parsed.flags, parsed.options)
    }

    static func duration(_ text: String?, command: String) throws -> Duration? {
        guard let text else { return nil }
        guard let duration = DurationText.parse(text) else {
            throw CLIError.usage("\"\(text)\" is not a duration. Use values like 45m, 2h or 1h30m, up to 30d.", command: command)
        }
        return duration
    }
}
