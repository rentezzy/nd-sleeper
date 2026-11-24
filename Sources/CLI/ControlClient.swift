import Core
import Darwin
import Foundation

enum ControlClient {
    private static let timeout = timeval(tv_sec: 5, tv_usec: 0)

    static var socketPath: String {
        "\(NSHomeDirectory())/\(InstallPath.HomeRelative.controlDirectory)/\(InstallPath.controlSocketFileName)"
    }

    static func send(_ request: ControlRequest) throws -> ControlResponse {
        let descriptor = try connect()
        defer { close(descriptor) }

        guard let data = try? ControlWire.encode(request), writeAll(data, to: descriptor) else {
            throw CLIError.failure("Could not send the request to the nd-sleeper agent.")
        }
        guard let line = readLine(from: descriptor),
              let response = try? ControlWire.decode(ControlResponse.self, from: line)
        else { throw CLIError.failure("The nd-sleeper agent did not answer. Check `nd-sleeper logs`.") }
        return response
    }

    private static func connect() throws -> Int32 {
        let notRunning = CLIError.failure("""
            The nd-sleeper agent is not running.
            Run `nd-sleeper install` to install or restart it.
            """)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw notRunning }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw notRunning }

        var timeout = Self.timeout
        var noSigpipe: Int32 = 1
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw notRunning
        }
        return descriptor
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private static func readLine(from descriptor: Int32) -> Data? {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while received.count < ControlWire.maxMessageBytes {
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { return nil }
            received.append(contentsOf: chunk.prefix(count))
            if let newline = received.firstIndex(of: UInt8(ascii: "\n")) {
                return received.prefix(upTo: newline)
            }
        }
        return nil
    }
}
