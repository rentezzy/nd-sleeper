import Core
import Foundation
import SQLite3

public final class T3ActivitySource: ActivitySource, @unchecked Sendable {
    public let descriptor = ActivitySourceDescriptor(
        name: "t3",
        capabilities: [.reportsWaitingOnUser],
        maxStaleness: nil
    )

    private static let sessionsQuery = """
        SELECT r.thread_id,
               EXISTS (SELECT 1 FROM orchestration_v2_projection_runtime_requests q
                       WHERE q.thread_id = r.thread_id AND q.status = 'pending')
        FROM orchestration_v2_projection_runs r
        WHERE r.status IN ('preparing', 'starting', 'running')
        """
    private static let busyTimeoutMilliseconds: Int32 = 250
    private static let idleThrottle: Duration = .seconds(1)
    private static let workingThrottle: Duration = .seconds(12)

    private let queue = DispatchQueue(label: "\(ServiceIdentifier.agent).t3")
    private let directoryPath: String
    private let databasePath: String
    private var onReport: (@Sendable (ActivityReport) -> Void)?
    private var database: OpaquePointer?
    private var statement: OpaquePointer?
    private var walSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var suspendedSources: [DispatchSourceFileSystemObject] = []
    private var resumeWork: DispatchWorkItem?
    private var lastReport: ActivityReport?
    private var queries: UInt64 = 0
    private var queryNanos: UInt64 = 0

    public init(directory: String = NSHomeDirectory() + "/.t3/userdata") {
        directoryPath = directory
        databasePath = directory + "/statev2.sqlite"
    }

    public func start(onReport: @escaping @Sendable (ActivityReport) -> Void) async -> ActivityReport {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.startWatching(onReport: onReport))
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopWatching()
                continuation.resume()
            }
        }
    }

    public func statusNote() async -> String? {
        let holders = ProcessList.caffeinateParents()
        guard !holders.isEmpty else { return "no caffeinate assertion" }
        return "caffeinate held by \(holders.joined(separator: ", "))"
    }

    private func startWatching(onReport: @escaping @Sendable (ActivityReport) -> Void) -> ActivityReport {
        stopWatching()
        self.onReport = onReport
        armDirectoryWatch()
        armWalWatch()
        let report = query()
        lastReport = report
        return report
    }

    private func stopWatching() {
        onReport = nil
        resumeWork?.cancel()
        resumeWork = nil
        cancel(walSource)
        walSource = nil
        cancel(directorySource)
        directorySource = nil
        closeDatabase()
        lastReport = nil
    }

    private func armDirectoryWatch() {
        let descriptor = open(directoryPath, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, isWatching else { return }
            if walSource == nil {
                armWalWatch()
            }
            changed()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        directorySource = source
    }

    private func armWalWatch() {
        cancel(walSource)
        walSource = nil

        let descriptor = open(databasePath + "-wal", O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, unowned source] in
            guard let self, isWatching else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                armWalWatch()
            }
            changed()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        walSource = source
    }

    private var isWatching: Bool {
        onReport != nil && suspendedSources.isEmpty
    }

    private func changed() {
        let report = query()
        if report.sessions != lastReport?.sessions || report.health != lastReport?.health {
            lastReport = report
            onReport?(report)
        }
        throttle(working: report.sessions.contains { $0.state == .working })
    }

    private func throttle(working: Bool) {
        suspendedSources = [walSource, directorySource].compactMap { $0 }
        suspendedSources.forEach { $0.suspend() }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            resumeWork = nil
            resumeWatches()
            if walSource == nil {
                armWalWatch()
            }
        }
        resumeWork = work
        let window = working ? Self.workingThrottle : Self.idleThrottle
        queue.asyncAfter(deadline: .now() + window.seconds, execute: work)
    }

    private func resumeWatches() {
        suspendedSources.forEach { $0.resume() }
        suspendedSources = []
    }

    private func cancel(_ source: DispatchSourceFileSystemObject?) {
        guard let source else { return }
        if suspendedSources.contains(where: { $0 === source }) {
            source.resume()
            suspendedSources.removeAll { $0 === source }
        }
        source.cancel()
    }

    private func query() -> ActivityReport {
        let started = ContinuousClock.now
        let result = runQuery()
        let elapsed = ContinuousClock.now - started
        queries += 1
        queryNanos += UInt64(max(0, elapsed.seconds) * 1e9)
        let cost = SourceCost(queries: queries, queryNanos: queryNanos)

        switch result {
        case let .success(sessions):
            return ActivityReport(sessions: sessions, health: .ok, cost: cost)
        case let .failure(error):
            closeDatabase()
            return ActivityReport(sessions: [], health: .unavailable(error.message), cost: cost)
        }
    }

    private struct QueryError: Error {
        let message: String
    }

    private func runQuery() -> Result<[ActivitySession], QueryError> {
        switch preparedStatement() {
        case let .failure(error): .failure(error)
        case let .success(statement): readSessions(statement)
        }
    }

    private func readSessions(_ statement: OpaquePointer) -> Result<[ActivitySession], QueryError> {
        defer { sqlite3_reset(statement) }

        var sessions: [ActivitySession] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let id = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "unknown"
                let waiting = sqlite3_column_int(statement, 1) != 0
                sessions.append(ActivitySession(id: id, state: waiting ? .waiting : .working, label: nil))
            case SQLITE_DONE:
                return .success(sessions)
            default:
                return .failure(QueryError(message: lastErrorMessage(fallback: "query failed")))
            }
        }
    }

    private func preparedStatement() -> Result<OpaquePointer, QueryError> {
        if let statement {
            return .success(statement)
        }
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return .failure(QueryError(message: "T3 database not found"))
        }

        var opened: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(opened)
            return .failure(QueryError(message: "cannot open the T3 database"))
        }
        database = opened
        sqlite3_busy_timeout(opened, Self.busyTimeoutMilliseconds)

        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(opened, Self.sessionsQuery, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            return .failure(QueryError(message: lastErrorMessage(fallback: "T3 schema changed")))
        }
        statement = prepared
        return .success(prepared)
    }

    private func lastErrorMessage(fallback: String) -> String {
        guard let database, let message = sqlite3_errmsg(database) else { return fallback }
        return "\(fallback): \(String(cString: message))"
    }

    private func closeDatabase() {
        sqlite3_finalize(statement)
        statement = nil
        sqlite3_close(database)
        database = nil
    }
}
