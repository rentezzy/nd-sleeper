import Core
import Darwin
import Foundation

struct ControlServerError: Error, CustomStringConvertible {
    let description: String
}

final class ControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (ControlRequest, @escaping @Sendable (ControlResponse) -> Void) -> Void

    private static let ioTimeout = timeval(tv_sec: 2, tv_usec: 0)

    private let directory: String
    private let socketPath: String
    private let handler: Handler
    private let ioQueue = DispatchQueue(label: "\(ServiceIdentifier.agent).control", attributes: .concurrent)
    private var listenSource: DispatchSourceRead?

    init(home: String = NSHomeDirectory(), handler: @escaping Handler) {
        directory = home + "/" + InstallPath.HomeRelative.controlDirectory
        socketPath = directory + "/" + InstallPath.controlSocketFileName
        self.handler = handler
    }

    func start() throws {
        try preparePrivateDirectory()
        let descriptor = try bindListeningSocket()

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPending(on: descriptor)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        listenSource = source
    }

    private func preparePrivateDirectory() throws {
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw ControlServerError(description: "cannot create \(directory)")
        }

        var info = stat()
        guard lstat(directory, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid()
        else { throw ControlServerError(description: "\(directory) is not a directory owned by this user") }

        if info.st_mode & 0o077 != 0, chmod(directory, 0o700) != 0 {
            throw ControlServerError(description: "cannot restrict \(directory) to mode 0700")
        }
    }

    private func bindListeningSocket() throws -> Int32 {
        unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlServerError(description: "socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlServerError(description: "cannot create the control socket") }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw ControlServerError(description: "cannot listen on \(socketPath)")
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        return descriptor
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            ioQueue.async { [weak self] in
                self?.serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        guard isSameUser(client) else {
            close(client)
            return
        }
        configure(client)

        let request = readLine(from: client).flatMap { try? ControlWire.decode(ControlRequest.self, from: $0) }
        guard let request else {
            respond(.failed("malformed request"), to: client)
            return
        }
        handler(request) { response in
            self.ioQueue.async {
                self.respond(response, to: client)
            }
        }
    }

    private func isSameUser(_ client: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(client, &uid, &gid) == 0 && uid == getuid()
    }

    private func configure(_ client: Int32) {
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var timeout = Self.ioTimeout
        var noSigpipe: Int32 = 1
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    private func readLine(from client: Int32) -> Data? {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while received.count < ControlWire.maxMessageBytes {
            let count = read(client, &chunk, chunk.count)
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

    private func respond(_ response: ControlResponse, to client: Int32) {
        defer { close(client) }
        guard let data = try? ControlWire.encode(response) else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(client, base + offset, buffer.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}
