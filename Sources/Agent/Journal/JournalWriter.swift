import Core
import Foundation
import os

final class JournalWriter {
    private static let maxBytes: UInt64 = 1024 * 1024

    private let directory: URL
    private let logger = Logger(subsystem: ServiceIdentifier.logSubsystem, category: "journal")
    private let encoder = JournalCoding.makeEncoder()

    init(home: String = NSHomeDirectory()) {
        directory = URL(fileURLWithPath: home).appendingPathComponent(InstallPath.HomeRelative.journalDirectory)
    }

    func write(_ entry: JournalEntry) {
        guard let data = try? encoder.encode(entry) else { return }
        let line = String(decoding: data, as: UTF8.self)
        log(line, kind: entry.kind)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try rotateIfNeeded()
            try append(data + Data("\n".utf8))
        } catch {
            logger.error("journal write failed")
        }
    }

    private var current: URL {
        directory.appendingPathComponent(JournalFiles.current)
    }

    private func log(_ line: String, kind: JournalKind) {
        switch kind {
        case .anomaly: logger.fault("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        default: logger.notice("\(line, privacy: .public)")
        }
    }

    private func append(_ data: Data) throws {
        guard FileManager.default.fileExists(atPath: current.path) else {
            try data.write(to: current)
            return
        }
        let handle = try FileHandle(forWritingTo: current)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func rotateIfNeeded() throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: current.path)
        guard let size = attributes?[.size] as? UInt64, size >= Self.maxBytes else { return }

        let manager = FileManager.default
        let chain = ([JournalFiles.current] + JournalFiles.rotated).map { directory.appendingPathComponent($0) }
        if let oldest = chain.last {
            try? manager.removeItem(at: oldest)
        }
        for (newer, older) in zip(chain, chain.dropFirst()).reversed() where manager.fileExists(atPath: newer.path) {
            try manager.moveItem(at: newer, to: older)
        }
    }
}
