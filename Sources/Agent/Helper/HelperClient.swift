import Core
import Foundation
import XPC

enum HelperNotice: Sendable {
    case status(HelperStatus)
    case reconnected
    case unavailable
}

final class HelperClient: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onNotice: @Sendable (HelperNotice) -> Void
    private var connection: xpc_connection_t?

    init(queue: DispatchQueue, onNotice: @escaping @Sendable (HelperNotice) -> Void) {
        self.queue = queue
        self.onNotice = onNotice
    }

    func send(_ request: HelperRequest, completion: @escaping @Sendable (HelperResponse?) -> Void) {
        guard let data = try? HelperWire.encode(request) else {
            completion(nil)
            return
        }

        let message = xpc_dictionary_create(nil, nil, 0)
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            xpc_dictionary_set_data(message, HelperWire.payloadKey, base, buffer.count)
        }
        xpc_connection_send_message_with_reply(connect(), message, queue) { reply in
            completion(Self.decode(reply))
        }
    }

    private func connect() -> xpc_connection_t {
        if let connection {
            return connection
        }

        let created = xpc_connection_create_mach_service(
            ServiceIdentifier.helper,
            queue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED)
        )
        xpc_connection_set_event_handler(created) { [weak self] event in
            self?.received(event)
        }
        xpc_connection_resume(created)
        connection = created
        return created
    }

    private func received(_ event: xpc_object_t) {
        if xpc_get_type(event) == XPC_TYPE_DICTIONARY {
            if case let .status(status) = Self.decode(event) {
                onNotice(.status(status))
            }
            return
        }
        if event === XPC_ERROR_CONNECTION_INTERRUPTED {
            onNotice(.reconnected)
            return
        }
        connection = nil
        onNotice(.unavailable)
    }

    private static func decode(_ message: xpc_object_t) -> HelperResponse? {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return nil }

        var length = 0
        guard let bytes = xpc_dictionary_get_data(message, HelperWire.payloadKey, &length) else { return nil }
        return try? HelperWire.decode(HelperResponse.self, from: Data(bytes: bytes, count: length))
    }
}
