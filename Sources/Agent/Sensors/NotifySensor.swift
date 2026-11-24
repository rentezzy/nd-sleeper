import Dispatch
import notify

final class NotifySensor {
    private let name: String
    private let queue: DispatchQueue
    private let onFire: @Sendable () -> Void
    private var token = NOTIFY_TOKEN_INVALID

    init(name: String, queue: DispatchQueue, onFire: @escaping @Sendable () -> Void) {
        self.name = name
        self.queue = queue
        self.onFire = onFire
    }

    var isArmed: Bool {
        token != NOTIFY_TOKEN_INVALID
    }

    func arm() {
        guard !isArmed else { return }
        let onFire = onFire
        let status = notify_register_dispatch(name, &token, queue) { _ in onFire() }
        if status != NOTIFY_STATUS_OK {
            token = NOTIFY_TOKEN_INVALID
        }
    }

    func disarm() {
        guard isArmed else { return }
        notify_cancel(token)
        token = NOTIFY_TOKEN_INVALID
    }
}
