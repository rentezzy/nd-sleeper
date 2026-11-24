import Agent
import Core
import Foundation
import Helper

@main
struct NdSleeperCommand {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            try run(arguments)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("\(error.message)\n".utf8))
            exit(error.exitCode)
        } catch {
            FileHandle.standardError.write(Data("nd-sleeper failed unexpectedly. Check `nd-sleeper logs`.\n".utf8))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let name = arguments.first else {
            print(Commands.topLevelHelp)
            return
        }

        let rest = Array(arguments.dropFirst())
        switch name {
        case "-h", "--help":
            print(Commands.topLevelHelp)
        case "--version":
            print("nd-sleeper \(BuildInfo.version)")
        case "help":
            try printHelp(for: rest.first)
        case "helper":
            HelperService().run()
        case "agent":
            Engine().run()
        case Installer.rootInstallCommand:
            guard let source = rest.first else { throw CLIError.failure("Missing source path.") }
            try Installer.rootInstall(source: source)
        case Installer.rootUninstallCommand:
            try Installer.rootUninstall()
        default:
            guard let spec = Commands.named(name) else {
                throw CLIError.usage("Unknown command \(name).", command: nil)
            }
            let parsed = try ArgumentParser.parse(rest, for: spec)
            guard !parsed.wantsHelp else {
                print(spec.help)
                return
            }
            try execute(spec, parsed)
        }
    }

    private static func printHelp(for name: String?) throws {
        guard let name else {
            print(Commands.topLevelHelp)
            return
        }
        guard let spec = Commands.named(name) else {
            throw CLIError.usage("Unknown command \(name).", command: nil)
        }
        print(spec.help)
    }

    private static func execute(_ spec: CommandSpec, _ parsed: ParsedArguments) throws {
        switch spec.name {
        case Commands.status.name:
            try status(json: parsed.flags.contains("--json"), metrics: parsed.flags.contains("--metrics"))
        case Commands.hold.name:
            let duration = try ArgumentParser.duration(parsed.positionals.first, command: spec.name)
            try send(.setOverride(.hold(duration: duration, force: parsed.flags.contains("--force"))))
            print(duration.map { "Holding awake for \(DurationText.format($0))." } ?? "Holding awake until `nd-sleeper auto`.")
        case Commands.normal.name:
            let duration = try ArgumentParser.duration(parsed.positionals.first, command: spec.name)
            try send(.setOverride(.normal(duration: duration)))
            print(duration.map { "Normal macOS sleep for \(DurationText.format($0))." } ?? "Normal macOS sleep until `nd-sleeper auto`.")
        case Commands.auto.name:
            try send(.auto)
            print("Back to automatic behavior.")
        case Commands.sleep.name:
            try send(.sleepNow)
            print("Sleeping.")
        case Commands.reload.name:
            try reload()
        case Commands.logs.name:
            let since = try ArgumentParser.duration(parsed.options["--since"], command: spec.name)
            LogsCommand.run(since: since, json: parsed.flags.contains("--json"))
        case Commands.install.name:
            try Installer.install()
        case Commands.uninstall.name:
            try Installer.uninstall()
        default:
            throw CLIError.usage("Unknown command \(spec.name).", command: nil)
        }
    }

    private static func status(json: Bool, metrics: Bool) throws {
        let response = try ControlClient.send(.status(includeMetrics: metrics))
        guard case let .status(report) = response else {
            throw CLIError.failure(failureMessage(response))
        }
        if json {
            print(try StatusPrinter.json(report))
            StatusPrinter.warnings(report).forEach { FileHandle.standardError.write(Data("\($0)\n".utf8)) }
        } else {
            print(StatusPrinter.text(report, style: TerminalStyle.detect()))
        }
    }

    private static func reload() throws {
        let response = try ControlClient.send(.reload)
        guard case let .config(config) = response else {
            throw CLIError.failure(failureMessage(response))
        }
        let origin: String = config.source == .file ? "Reloaded config.toml" : "No config.toml, using defaults"
        print("\(origin): \(StatusPrinter.settings(config.settings)).")
    }

    private static func send(_ request: ControlRequest) throws {
        let response = try ControlClient.send(request)
        guard response == .ok else {
            throw CLIError.failure(failureMessage(response))
        }
    }

    private static func failureMessage(_ response: ControlResponse) -> String {
        guard case let .failed(reason) = response else { return "The nd-sleeper agent gave an unexpected answer." }
        return reason.hasSuffix(".") ? "nd-sleeper refused: \(reason)" : "nd-sleeper refused: \(reason)."
    }
}
