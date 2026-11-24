import Darwin

enum ProcessList {
    static func caffeinateParents() -> [String] {
        allPIDs()
            .filter { name(of: $0) == "caffeinate" }
            .compactMap(parentPID)
            .map { parent in "\(name(of: parent) ?? "unknown") (\(parent))" }
    }

    private static func allPIDs() -> [pid_t] {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: capacity * 2)
        let count = pids.withUnsafeMutableBytes { buffer in
            Int(proc_listallpids(buffer.baseAddress, Int32(buffer.count)))
        }
        return Array(pids.prefix(max(0, count)))
    }

    private static func name(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
