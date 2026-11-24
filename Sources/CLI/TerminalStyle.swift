import Darwin
import Foundation

struct TerminalStyle {
    let enabled: Bool

    static func detect() -> TerminalStyle {
        let environment: [String: String] = ProcessInfo.processInfo.environment
        let isTerminal: Bool = isatty(STDOUT_FILENO) == 1
        let noColor: Bool = !(environment["NO_COLOR"] ?? "").isEmpty
        return TerminalStyle(enabled: isTerminal && !noColor && environment["TERM"] != "dumb")
    }

    func bold(_ text: String) -> String {
        wrap(text, "1")
    }

    func dim(_ text: String) -> String {
        wrap(text, "2")
    }

    func green(_ text: String) -> String {
        wrap(text, "32")
    }

    func yellow(_ text: String) -> String {
        wrap(text, "33")
    }

    func red(_ text: String) -> String {
        wrap(text, "31")
    }

    private func wrap(_ text: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }
}
