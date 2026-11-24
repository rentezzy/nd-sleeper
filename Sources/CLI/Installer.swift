import Core
import Darwin
import Foundation
import Helper

enum Installer {
    static let rootInstallCommand = "root-install"
    static let rootUninstallCommand = "root-uninstall"

    static func install() throws {
        try requireUser("install")
        let source = try ownExecutablePath()

        Launchctl.bootoutAndWait(agentTarget)
        print("Installing the root helper. sudo may ask for your password.")
        guard runAsRoot([rootInstallCommand, source]) else {
            throw CLIError.failure("Installing the root helper failed. Run `nd-sleeper install` again.")
        }

        try writeFile(plist(agentPlistContents), to: agentPlistPath, mode: 0o644)
        guard Launchctl.run(["bootstrap", guiDomain, agentPlistPath]) else {
            throw CLIError.failure("The user agent did not start. Run `nd-sleeper install` again.")
        }
        print("Installed nd-sleeper \(BuildInfo.version). Check it with `nd-sleeper status`.")
    }

    static func uninstall() throws {
        try requireUser("uninstall")

        let userFailures = [
            Launchctl.bootoutAndWait(agentTarget) ? nil : "stop the user agent",
            remove(agentPlistPath) ? nil : "remove \(agentPlistPath)",
            remove(ControlClient.socketPath) ? nil : "remove the control socket",
        ].compactMap { $0 }
        _ = remove("\(NSHomeDirectory())/\(InstallPath.HomeRelative.helperEventCursor)")
        _ = rmdir((ControlClient.socketPath as NSString).deletingLastPathComponent)

        print("Removing the root helper. sudo may ask for your password.")
        let rootSucceeded = runAsRoot([rootUninstallCommand])
        let failures = userFailures + (rootSucceeded ? [] : ["finish the root steps (see above)"])
        guard failures.isEmpty else {
            throw CLIError.failure("Uninstall could not \(failures.joined(separator: ", ")). Run `nd-sleeper uninstall` again.")
        }
        print("Uninstalled. The kernel sleep flag is off. The journal in ~/Library/Logs/nd-sleeper/ was kept.")
    }

    static func rootInstall(source: String) throws {
        try requireRoot()
        guard FileManager.default.isExecutableFile(atPath: source) else {
            throw CLIError.failure("\(source) is not an executable file.")
        }

        try installBinary(from: source)
        try writeFile(plist(helperPlistContents), to: InstallPath.helperPlist, mode: 0o644)
        Launchctl.bootoutAndWait(helperTarget)
        guard Launchctl.run(["bootstrap", "system", InstallPath.helperPlist]) else {
            throw CLIError.failure("The root helper did not start.")
        }
    }

    static func rootUninstall() throws {
        try requireRoot()

        let stopped = Launchctl.bootoutAndWait(helperTarget)
        let flagCleared = SleepFlag.isOn() == false || SleepFlag.clear()
        let failures = [
            stopped ? nil : "stop the root helper",
            remove(InstallPath.helperPlist) ? nil : "remove \(InstallPath.helperPlist)",
            flagCleared ? nil : "clear the kernel sleep flag (run `sudo pmset -a disablesleep 0`)",
            remove(InstallPath.binary) ? nil : "remove \(InstallPath.binary)",
        ].compactMap { $0 }

        guard failures.isEmpty else {
            throw CLIError.failure("Could not \(failures.joined(separator: ", ")).")
        }
    }

    private static func installBinary(from source: String) throws {
        let target = InstallPath.binary
        guard URL(fileURLWithPath: source).resolvingSymlinksInPath().path != target else { return }

        let directory = (target as NSString).deletingLastPathComponent
        let staged = "\(directory)/.nd-sleeper.\(getpid())"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try? FileManager.default.removeItem(atPath: staged)
        do {
            try FileManager.default.copyItem(atPath: source, toPath: staged)
            try setRootOwned(staged, mode: 0o755)
        } catch {
            try? FileManager.default.removeItem(atPath: staged)
            throw CLIError.failure("Could not stage the binary in \(directory).")
        }
        guard rename(staged, target) == 0 else {
            try? FileManager.default.removeItem(atPath: staged)
            throw CLIError.failure("Could not move the binary to \(target).")
        }
    }

    private static func writeFile(_ data: Data, to path: String, mode: Int) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = "\(directory)/.\((path as NSString).lastPathComponent).\(getpid())"
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: temporary))
            if geteuid() == 0 {
                try setRootOwned(temporary, mode: mode)
            } else {
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            throw CLIError.failure("Could not write \(path).")
        }
        guard rename(temporary, path) == 0 else {
            try? FileManager.default.removeItem(atPath: temporary)
            throw CLIError.failure("Could not write \(path).")
        }
    }

    private static func setRootOwned(_ path: String, mode: Int) throws {
        try FileManager.default.setAttributes(
            [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: mode],
            ofItemAtPath: path
        )
    }

    private static func remove(_ path: String) -> Bool {
        try? FileManager.default.removeItem(atPath: path)
        return !FileManager.default.fileExists(atPath: path)
    }

    private static func plist(_ contents: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
    }

    private static var helperTarget: String {
        "system/\(ServiceIdentifier.helper)"
    }

    private static var guiDomain: String {
        "gui/\(getuid())"
    }

    private static var agentTarget: String {
        "\(guiDomain)/\(ServiceIdentifier.agent)"
    }

    private static var agentPlistPath: String {
        "\(NSHomeDirectory())/\(InstallPath.HomeRelative.agentPlist)"
    }

    private static var helperPlistContents: [String: Any] {
        [
            "Label": ServiceIdentifier.helper,
            "ProgramArguments": [InstallPath.binary, "helper"],
            "MachServices": [ServiceIdentifier.helper: true],
            "RunAtLoad": true,
            "KeepAlive": true,
        ]
    }

    private static var agentPlistContents: [String: Any] {
        [
            "Label": ServiceIdentifier.agent,
            "ProgramArguments": [InstallPath.binary, "agent"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "LimitLoadToSessionType": "Aqua",
        ]
    }

    private static func requireUser(_ command: String) throws {
        guard geteuid() != 0 else {
            throw CLIError.failure("Run `nd-sleeper \(command)` as yourself, not with sudo. It asks for your password when needed.")
        }
    }

    private static func requireRoot() throws {
        guard geteuid() == 0 else {
            throw CLIError.failure("This step needs root. Use `nd-sleeper install` or `nd-sleeper uninstall` instead.")
        }
    }

    private static func ownExecutablePath() throws -> String {
        guard let url = Bundle.main.executableURL else {
            throw CLIError.failure("Could not find the nd-sleeper binary to install.")
        }
        return url.resolvingSymlinksInPath().path
    }

    private static func runAsRoot(_ arguments: [String]) -> Bool {
        guard let executable = try? ownExecutablePath() else { return false }
        return ProcessRunner.runInTerminal("/usr/bin/sudo", [executable] + arguments)
    }
}

enum Launchctl {
    @discardableResult
    static func run(_ arguments: [String]) -> Bool {
        ProcessRunner.runQuietly("/bin/launchctl", arguments)
    }

    static func isLoaded(_ target: String) -> Bool {
        ProcessRunner.runQuietly("/bin/launchctl", ["print", target])
    }

    @discardableResult
    static func bootoutAndWait(_ target: String) -> Bool {
        run(["bootout", target])
        let attempts = 40
        let stepMicroseconds: useconds_t = 50_000
        return (0..<attempts).contains { attempt in
            if attempt > 0 { usleep(stepMicroseconds) }
            return !isLoaded(target)
        }
    }
}

enum ProcessRunner {
    static func runQuietly(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func runInTerminal(_ executable: String, _ arguments: [String]) -> Bool {
        let words: [String] = [executable] + arguments
        let argv: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals: sigset_t = sigset_t((1 << (SIGINT - 1)) | (1 << (SIGQUIT - 1)))
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))

        let previousInterrupt = signal(SIGINT, SIG_IGN)
        let previousQuit = signal(SIGQUIT, SIG_IGN)
        defer {
            signal(SIGINT, previousInterrupt)
            signal(SIGQUIT, previousQuit)
        }

        fflush(nil)
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, nil, &attributes, argv, environ) == 0 else { return false }
        return exitedSuccessfully(waitForExit(pid))
    }

    private static func waitForExit(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return nil }
        }
        return status
    }

    private static func exitedSuccessfully(_ status: Int32?) -> Bool {
        guard let status else { return false }
        let exited: Bool = status & 0x7f == 0
        let code: Int32 = (status >> 8) & 0xff
        return exited && code == 0
    }
}
