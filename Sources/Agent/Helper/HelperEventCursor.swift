import Core
import Foundation

struct HelperEventCursor: Equatable {
    let instance: String
    let sequence: UInt64

    static func load(home: String = NSHomeDirectory()) -> HelperEventCursor? {
        guard let text = try? String(contentsOfFile: path(home: home), encoding: .utf8) else { return nil }

        let parts = text.split(separator: " ")
        guard parts.count == 2, let sequence = UInt64(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return HelperEventCursor(instance: String(parts[0]), sequence: sequence)
    }

    func save(home: String = NSHomeDirectory()) {
        let file = Self.path(home: home)
        let directory = (file as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? Data("\(instance) \(sequence)".utf8).write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    func unseen(in status: HelperStatus) -> [HelperEvent] {
        guard instance == status.instance else { return status.events }
        return status.events.filter { $0.sequence > sequence }
    }

    private static func path(home: String) -> String {
        "\(home)/\(InstallPath.HomeRelative.helperEventCursor)"
    }
}
